import SwiftUI
import Combine

/// One ruler line. Endpoints are viewer image coordinates (continuous, pixel i spans [i, i+1)), so the
/// length in pixels is exact regardless of zoom.
struct MeasureLine: Identifiable, Equatable {
    let id = UUID()
    var a: CGPoint
    var b: CGPoint

    var dx: Double { Double(b.x - a.x) }
    var dy: Double { Double(b.y - a.y) }
    var lengthPx: Double { hypot(dx, dy) }
    /// Length in Å, nil when the image has no calibration.
    func lengthA(pixelSizeA: Double?) -> Double? { pixelSizeA.map { lengthPx * $0 } }
    /// Direction in degrees, 0 = to the right, counter-clockwise positive (image y runs downwards).
    var angleDeg: Double { atan2(-dy, dx) * 180 / .pi }

    func label(pixelSizeA: Double?, useAngstroms: Bool) -> String {
        let px = String(format: lengthPx < 100 ? "%.1f px" : "%.0f px", lengthPx)
        guard let a = lengthA(pixelSizeA: pixelSizeA) else { return px + " (uncalibrated)" }
        return LengthUnits.format(angstroms: a, useAngstroms: useAngstroms) + "  ·  " + px
    }

    /// Distance from `p` to the segment a–b, in image pixels.
    func distance(to p: CGPoint) -> Double {
        let vx = dx, vy = dy, wx = Double(p.x - a.x), wy = Double(p.y - a.y)
        let len2 = vx * vx + vy * vy
        let t = len2 > 0 ? min(max((vx * wx + vy * wy) / len2, 0), 1) : 0
        return hypot(wx - t * vx, wy - t * vy)
    }
}

/// Ruler tool. Drag to draw a line, drag an endpoint to adjust it, Shift snaps to 45°, Delete removes the selected
/// line, right-click removes the one under the cursor. Lines are kept per image for the session (not saved to disk).
final class MeasureState: ObservableObject {
    @Published var enabled = false
    @Published private(set) var lines: [MeasureLine] = [] {
        didSet { if let k = currentKey { perImage[k] = lines } }
    }
    @Published var selected: UUID?
    /// The quick measurement: ⌘-drag from any tool. Not stored, not selectable, and it leaves the tool you were on alone.
    /// It stays on screen (so it can be read) until the next click, key press or image change.
    @Published private(set) var quick: MeasureLine?

    private var perImage: [String: [MeasureLine]] = [:]
    private var currentKey: String?
    private enum Drag { case endpoint(UUID, moveA: Bool), fresh(UUID) }
    private var drag: Drag?

    /// Switch to another image (nil = none); that image's earlier lines come back.
    func setImage(key: String?) {
        guard key != currentKey else { return }
        currentKey = key
        lines = key.flatMap { perImage[$0] } ?? []
        selected = nil; drag = nil; quick = nil
    }

    // MARK: quick measurement (⌘-drag)

    func quickBegin(at p: CGPoint) { quick = MeasureLine(a: p, b: p) }
    func quickDrag(to p: CGPoint, constrain: Bool) {
        guard let q = quick else { return }
        quick?.b = constrain ? Self.snapped(anchor: q.a, to: p) : p
    }
    /// A ⌘-click without a drag measures nothing: the line is dropped.
    func quickEnd(minLengthPx: Double = 2) {
        if let q = quick, q.lengthPx < minLengthPx { quick = nil }
    }
    func quickClear() { if quick != nil { quick = nil } }

    /// Endpoint within `radius` image px of `p`, nearest first.
    private func endpoint(near p: CGPoint, radius: Double) -> (UUID, Bool)? {
        var best: (UUID, Bool, Double)?
        for l in lines {
            for isA in [true, false] {
                let q = isA ? l.a : l.b
                let d = hypot(Double(q.x - p.x), Double(q.y - p.y))
                if d <= radius && d < (best?.2 ?? .infinity) { best = (l.id, isA, d) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }
    private func body(near p: CGPoint, radius: Double) -> UUID? {
        lines.filter { $0.distance(to: p) <= radius }.min { $0.distance(to: p) < $1.distance(to: p) }?.id
    }

    /// Snap the direction anchor→p to a multiple of 45° (length unchanged).
    static func snapped(anchor: CGPoint, to p: CGPoint) -> CGPoint {
        let vx = Double(p.x - anchor.x), vy = Double(p.y - anchor.y)
        let len = hypot(vx, vy)
        guard len > 0 else { return p }
        let step = Double.pi / 4
        let ang = (atan2(vy, vx) / step).rounded() * step
        return CGPoint(x: Double(anchor.x) + len * cos(ang), y: Double(anchor.y) + len * sin(ang))
    }

    func mouseDown(at p: CGPoint, radiusPx: Double) {
        if let (id, isA) = endpoint(near: p, radius: radiusPx) {
            selected = id; drag = .endpoint(id, moveA: isA); return
        }
        let l = MeasureLine(a: p, b: p)
        lines.append(l); selected = l.id; drag = .fresh(l.id)
    }

    func mouseDragged(to p: CGPoint, constrain: Bool) {
        guard let drag else { return }
        switch drag {
        case .fresh(let id):
            guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
            lines[i].b = constrain ? Self.snapped(anchor: lines[i].a, to: p) : p
        case .endpoint(let id, let moveA):
            guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
            let anchor = moveA ? lines[i].b : lines[i].a
            let q = constrain ? Self.snapped(anchor: anchor, to: p) : p
            if moveA { lines[i].a = q } else { lines[i].b = q }
        }
    }

    /// A press without a real drag is a click: it selects the line under the cursor (or deselects).
    func mouseUp(at p: CGPoint, radiusPx: Double) {
        defer { drag = nil }
        guard case .fresh(let id)? = drag, let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if lines[i].lengthPx < max(radiusPx * 0.4, 2) {
            lines.remove(at: i)
            selected = body(near: p, radius: radiusPx)
        }
    }

    func rightClick(at p: CGPoint, radiusPx: Double) {
        guard let id = endpoint(near: p, radius: radiusPx)?.0 ?? body(near: p, radius: radiusPx) else { return }
        lines.removeAll { $0.id == id }
        if selected == id { selected = nil }
    }

    func deleteSelected() {
        guard let s = selected else { return }
        lines.removeAll { $0.id == s }; selected = nil
    }
    func clear() { lines = []; selected = nil; drag = nil; quick = nil }

    /// Delete / Escape while the tool is active. Returns true when the key was used.
    func handleKey(keyCode: UInt16) -> Bool {
        guard enabled else { return false }
        switch keyCode {
        case 51, 117: if selected != nil { deleteSelected(); return true }; return false
        case 53: if selected != nil { selected = nil } else { enabled = false }; return true
        default: return false
        }
    }
}

/// Keeps the picker and the ruler from fighting over the left mouse button: turning one on turns the other off. The crop
/// editor is the exception. It stays on while the ruler is used (the ruler gets the mouse until it is turned off), so measuring
/// in the middle of a section-by-section check does not end the check.
enum ToolExclusion {
    static func wire(picks: PickController, measure: MeasureState, into bag: inout Set<AnyCancellable>) {
        picks.$enabled.sink { [weak picks, weak measure] on in if on, picks?.crops.active != true { measure?.enabled = false } }.store(in: &bag)
        measure.$enabled.sink { [weak picks] on in if on, picks?.crops.active != true { picks?.enabled = false } }.store(in: &bag)
    }
}

/// Draws the ruler lines over the micrograph. Hit testing is done by the Metal view; this layer is display only.
struct MeasureOverlay: View {
    @ObservedObject var measure: MeasureState
    @ObservedObject var vs: ViewState
    @ObservedObject var units = UnitSettings.shared
    let pixelSizeA: Double?

    var body: some View {
        Canvas { ctx, size in
            guard !measure.lines.isEmpty || measure.quick != nil, vs.zoom > 0 else { return }
            let bs = vs.backingScale == 0 ? 2 : vs.backingScale
            let g = ViewGeometry(zoom: vs.zoom, center: vs.center,
                                 viewPixels: CGSize(width: size.width * bs, height: size.height * bs), backingScale: bs)
            let ink = Color(red: 1.0, green: 0.84, blue: 0.2)
            let all: [(MeasureLine, Bool)] = measure.lines.map { ($0, false) } + (measure.quick.map { [($0, true)] } ?? [])
            for (l, isQuick) in all {
                let a = g.toView(l.a), b = g.toView(l.b)
                let sel = !isQuick && l.id == measure.selected
                let col: Color = isQuick ? Color(red: 0.45, green: 0.9, blue: 1.0) : (sel ? .white : ink)
                let dash: [CGFloat] = isQuick ? [6, 4] : []
                var seg = Path(); seg.move(to: a); seg.addLine(to: b)
                // end caps perpendicular to the line
                let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
                let nx = -(b.y - a.y) / len * 6, ny = (b.x - a.x) / len * 6
                var caps = Path()
                for p in [a, b] { caps.move(to: CGPoint(x: p.x - nx, y: p.y - ny)); caps.addLine(to: CGPoint(x: p.x + nx, y: p.y + ny)) }
                ctx.stroke(seg, with: .color(.black.opacity(0.6)), lineWidth: 3.4)
                ctx.stroke(caps, with: .color(.black.opacity(0.6)), lineWidth: 3.4)
                ctx.stroke(seg, with: .color(col), style: StrokeStyle(lineWidth: sel ? 1.8 : 1.3, dash: dash))
                ctx.stroke(caps, with: .color(col), lineWidth: sel ? 1.8 : 1.3)
                if sel || measure.enabled || isQuick {
                    for p in [a, b] {
                        let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                        ctx.fill(Path(ellipseIn: r), with: .color(col)); ctx.stroke(Path(ellipseIn: r), with: .color(.black), lineWidth: 1)
                    }
                }
                let text = ctx.resolve(Text(l.label(pixelSizeA: pixelSizeA, useAngstroms: units.angstroms))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(col))
                let ts = text.measure(in: CGSize(width: 400, height: 40))
                // label sits on the side of the line facing up, centered on the midpoint
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let up = ny < 0 || (ny == 0 && nx < 0) ? CGPoint(x: nx, y: ny) : CGPoint(x: -nx, y: -ny)
                let off = (abs(up.x) * ts.width / 2 + abs(up.y) * ts.height / 2) / 6 + 6
                let c = CGPoint(x: mid.x + up.x / 6 * off, y: mid.y + up.y / 6 * off)
                let box = CGRect(x: c.x - ts.width / 2 - 4, y: c.y - ts.height / 2 - 2, width: ts.width + 8, height: ts.height + 4)
                ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.65)))
                ctx.draw(text, at: c)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Measure ▸ menu items (a View so the checkmark follows the tool state).
struct MeasureMenuItems: View {
    @ObservedObject var measure: MeasureState
    var body: some View {
        Toggle("Measure Tool (M)", isOn: $measure.enabled).keyboardShortcut("m", modifiers: [.command, .option])
        Button("Delete Selected Measurement") { measure.deleteSelected() }.disabled(measure.selected == nil)
        Button("Clear All Measurements on This Image") { measure.clear() }.disabled(measure.lines.isEmpty)
        Text("Quick measurement: hold ⌘ and drag, in any tool")
    }
}

/// Toolbar button.
struct MeasureToggle: View {
    @ObservedObject var measure: MeasureState
    var body: some View {
        Toggle(isOn: $measure.enabled) { Label("Measure", systemImage: "ruler") }
            .toggleStyle(.button)
            .help("Measure tool (M): drag to measure, Shift snaps to 45°, Option-drag pans, Delete removes the selected line. For a one-off measurement that leaves your tool alone, hold ⌘ and drag.")
    }
}
