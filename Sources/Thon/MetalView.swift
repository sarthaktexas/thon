import SwiftUI
import MetalKit
import Combine

/// MTKView with cryo-EM-viewer style interaction: drag = pan, wheel/pinch = zoom at cursor, double-click = fit.
final class InteractiveMTKView: MTKView {
    var state: ViewState!
    var cursor: CursorState!
    var onKey: ((NSEvent) -> Bool)?
    var onPeek: ((Bool) -> Void)?           // Space held / released: hide / show the overlays
    private(set) var peeking = false
    private var resignObserver: NSObjectProtocol?
    var picker: PickController?
    var sweep: CropSession?                 // the crop editor: while active it owns the left mouse button
    var measure: MeasureState?
    private var measureDown = false         // a ruler gesture (not an Option-pan) is in progress
    private var quickDown = false           // a ⌘-drag quick measurement is in progress (works in every tool)
    private var measureOn: Bool { measure?.enabled ?? false }
    private var pickDown: CGPoint?          // mouse-down location in view points while a pick gesture is active
    private var pickerOn: Bool { picker?.enabled ?? false }
    private var sweepDown: CGPoint?         // mouse-down location in view points while a crop-editor gesture is active
    private var sweepOn: Bool { sweep?.active ?? false }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var scale: Double { Double(window?.backingScaleFactor ?? 2) }

    private func pixelPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: Double(p.x) * scale, y: Double(p.y) * scale)
    }
    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: state.center.x + (p.x - state.viewPixels.width / 2) / state.zoom,
                y: state.center.y + (p.y - state.viewPixels.height / 2) / state.zoom)
    }

    /// Pick coordinates (array indices) under the event.
    private func pickPoint(_ e: NSEvent) -> CGPoint {
        let p = imagePoint(pixelPoint(e)); return CGPoint(x: p.x - 0.5, y: p.y - 0.5)
    }
    /// Screen-space hit tolerance (10 points) in image pixels.
    private var hitRadiusPx: Double { 10 * scale / state.zoom }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Quick measurement: ⌘-drag from any tool. The tool in use is not changed, and the line goes with the next click.
        if !peeking, event.modifierFlags.contains(.command), let m = measure {
            quickDown = true
            m.quickBegin(at: imagePoint(pixelPoint(event)))
            return
        }
        measure?.quickClear()
        // Ruler: drag to measure; hold Option to pan instead.
        if !peeking, let m = measure, m.enabled, !event.modifierFlags.contains(.option) {
            measureDown = true
            m.mouseDown(at: imagePoint(pixelPoint(event)), radiusPx: hitRadiusPx)
            return
        }
        if !peeking, let cs = sweep, cs.active {
            sweepDown = convert(event.locationInWindow, from: nil)
            cs.pointerDown(at: pickPoint(event), tolerancePx: hitRadiusPx, region: event.modifierFlags.contains(.option))
            return
        }
        if !peeking, let p = picker, p.enabled {
            pickDown = convert(event.locationInWindow, from: nil)
            p.mouseDown(at: pickPoint(event), radiusPx: hitRadiusPx, shift: event.modifierFlags.contains(.shift))
            return
        }
        if event.clickCount == 2 { state.fit() }
    }
    override func mouseDragged(with event: NSEvent) {
        if quickDown, let m = measure {
            m.quickDrag(to: imagePoint(pixelPoint(event)), constrain: event.modifierFlags.contains(.shift))
            cursor.set(image: imagePoint(pixelPoint(event)))
            return
        }
        if measureDown, let m = measure {
            m.mouseDragged(to: imagePoint(pixelPoint(event)), constrain: event.modifierFlags.contains(.shift))
            cursor.set(image: imagePoint(pixelPoint(event)))
            return
        }
        if let cs = sweep, cs.active, let down = sweepDown {
            let now = convert(event.locationInWindow, from: nil)
            switch cs.pointerDragged(to: pickPoint(event), movedPoints: hypot(Double(now.x - down.x), Double(now.y - down.y))) {
            case .pan: break
            case .none, .handled: cursor.set(image: imagePoint(pixelPoint(event))); return
            }
        } else if let p = picker, p.enabled, let down = pickDown {
            let now = convert(event.locationInWindow, from: nil)
            let mode = p.mouseDragged(to: pickPoint(event), movedPoints: hypot(Double(now.x - down.x), Double(now.y - down.y)),
                                      shift: event.modifierFlags.contains(.shift))
            if mode != .pan { cursor.set(image: imagePoint(pixelPoint(event))); return }
        }
        state.center = CGPoint(x: state.center.x - Double(event.deltaX) * scale / state.zoom,
                               y: state.center.y - Double(event.deltaY) * scale / state.zoom)
        cursor.set(image: imagePoint(pixelPoint(event)))
    }
    override func mouseUp(with event: NSEvent) {
        if quickDown, let m = measure {
            m.quickEnd(minLengthPx: max(hitRadiusPx * 0.4, 2))
            quickDown = false
            return
        }
        if measureDown, let m = measure {
            m.mouseUp(at: imagePoint(pixelPoint(event)), radiusPx: hitRadiusPx)
            measureDown = false
            return
        }
        if let cs = sweep, sweepDown != nil {
            cs.pointerUp(at: pickPoint(event))
            sweepDown = nil
            return
        }
        if let p = picker, p.enabled, pickDown != nil {
            p.mouseUp(at: pickPoint(event), shift: event.modifierFlags.contains(.shift))
        }
        pickDown = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        measure?.quickClear()
        if !peeking, let m = measure, m.enabled { m.rightClick(at: imagePoint(pixelPoint(event)), radiusPx: hitRadiusPx); return }
        if !peeking, let cs = sweep, cs.active { cs.rightClick(at: pickPoint(event), tolerancePx: hitRadiusPx) }
        else if !peeking, let p = picker, p.enabled { p.rightClick(at: pickPoint(event), radiusPx: hitRadiusPx) }
        else { super.rightMouseDown(with: event) }
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: (pickerOn || measureOn || sweepOn) ? .crosshair : .arrow)
    }
    override func mouseMoved(with event: NSEvent) { cursor.set(image: imagePoint(pixelPoint(event))) }
    override func mouseExited(with event: NSEvent) { cursor.set(image: nil) }

    override func scrollWheel(with event: NSEvent) {
        let zoomModifier = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
        if event.hasPreciseScrollingDeltas && !zoomModifier {
            state.center = CGPoint(x: state.center.x - Double(event.scrollingDeltaX) * scale / state.zoom,
                                   y: state.center.y - Double(event.scrollingDeltaY) * scale / state.zoom)
        } else {
            let k = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
            state.setZoom(state.zoom * exp(Double(event.scrollingDeltaY) * k), about: pixelPoint(event))
        }
        cursor.set(image: imagePoint(pixelPoint(event)))
    }
    override func magnify(with event: NSEvent) {
        // crop editor: pinching over a circle resizes it; anywhere else it zooms as usual
        if !peeking, let cs = sweep, cs.active,
           cs.pinch(at: pickPoint(event), tolerancePx: hitRadiusPx, scale: 1 + Double(event.magnification), began: event.phase.contains(.began)) { return }
        state.setZoom(state.zoom * (1 + Double(event.magnification)), about: pixelPoint(event))
    }
    override func keyDown(with event: NSEvent) {
        if OverlayPeek.isPeekKey(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            setPeeking(true)                 // key repeat just re-asserts it
            return
        }
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if OverlayPeek.isPeekKeyCode(event.keyCode) { setPeeking(false) } else { super.keyUp(with: event) }
    }

    private func setPeeking(_ on: Bool) {
        guard on != peeking else { return }
        peeking = on
        onPeek?(on)
    }
    /// A key-up that arrives while another window or app has the focus never reaches the view, so release on focus loss.
    override func resignFirstResponder() -> Bool {
        setPeeking(false)
        return super.resignFirstResponder()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let w = window else { setPeeking(false); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.setPeeking(false)
        }
    }
    deinit { if let o = resignObserver { NotificationCenter.default.removeObserver(o) } }
}

struct MicrographView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let v = InteractiveMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.colorPixelFormat = .bgra8Unorm
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.clearColor = MTLClearColor(red: 0.075, green: 0.078, blue: 0.086, alpha: 1)
        v.state = model.view
        v.cursor = model.cursor
        v.onKey = { [weak model] e in model?.handleKey(e) ?? false }
        v.onPeek = { [weak model] on in model?.overlaysHidden = on }
        v.picker = model.picks
        v.sweep = model.picks.crops
        v.measure = model.measure
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ v: InteractiveMTKView, context: Context) { context.coordinator.sync(v) }

    @MainActor
    final class Coordinator {
        let model: AppModel
        var renderer: MicrographRenderer?
        var bag = Set<AnyCancellable>()
        var lastGeneration = -1

        init(model: AppModel) { self.model = model }

        func attach(_ view: InteractiveMTKView) {
            guard let dev = view.device else { model.loadError = "No Metal device is available on this machine."; return }
            let r: MicrographRenderer
            do { r = try MicrographRenderer(device: dev, pixelFormat: view.colorPixelFormat, state: model.view) }
            catch { model.loadError = error.localizedDescription; return }
            view.delegate = r
            renderer = r
            model.renderer = r
            r.onProcessedStats = { [weak model] st in model?.applyProcessedStats(st) }
            model.picks.$enabled
                .sink { [weak view] _ in DispatchQueue.main.async { view?.window?.invalidateCursorRects(for: view!) } }
                .store(in: &bag)
            model.picks.crops.$active
                .sink { [weak view] _ in DispatchQueue.main.async { if let view { view.window?.invalidateCursorRects(for: view) } } }
                .store(in: &bag)
            model.measure.$enabled
                .sink { [weak view] _ in DispatchQueue.main.async { view?.window?.invalidateCursorRects(for: view!) } }
                .store(in: &bag)
            model.view.objectWillChange
                .sink { [weak view] _ in DispatchQueue.main.async { view?.setNeedsDisplay(view?.bounds ?? .zero) } }
                .store(in: &bag)
            Publishers.CombineLatest(model.view.$lowpassSigma, model.view.$flattenSigma)
                .dropFirst()
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .sink { [weak r] _ in r?.reprocess() }
                .store(in: &bag)
        }

        func sync(_ view: InteractiveMTKView) {
            guard lastGeneration != model.generation, let doc = model.doc, let r = renderer else { return }
            lastGeneration = model.generation
            let w = doc.entry.width, h = doc.entry.height, px = doc.pixels, mean = doc.stats.mean
            DispatchQueue.main.async { r.setImage(width: w, height: h, pixels: px, mean: mean); view.setNeedsDisplay(view.bounds) }
        }
    }
}
