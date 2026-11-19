import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Options and state

/// What goes into a saved picture and at what size.
struct SnapshotOptions: Equatable {
    var markers = true          // pick shapes
    var boxes = false           // extraction boxes
    var scores = false
    var measurements = true     // ruler lines and the quick measurement, with their labels
    var scaleBar = true
    var fileName = false        // file name and pixel size in the corner
    var factor = 2              // output pixels per screen pixel
}

/// The "take a picture" mode: a draggable frame over the viewer. Everything inside the frame is saved; the frame is in
/// points of the image pane (the same space the overlays draw in).
final class SnapshotState: ObservableObject {
    static let maxSide = 8192            // longest side of a saved picture, px
    static let minSide: CGFloat = 24
    static let factors = [1, 2, 4]

    @Published var active = false
    @Published var rect = CGRect.zero
    @Published var paneSize = CGSize.zero
    @Published var options = SnapshotOptions() {
        didSet { if options.scaleBar != oldValue.scaleBar || options.fileName != oldValue.fileName || options.factor != oldValue.factor { remember() } }
    }
    @Published var message: String?

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "snap.scaleBar") != nil { options.scaleBar = d.bool(forKey: "snap.scaleBar") }
        options.fileName = d.bool(forKey: "snap.fileName")
        if let f = d.object(forKey: "snap.factor") as? Int, Self.factors.contains(f) { options.factor = f }
    }
    private func remember() {
        let d = UserDefaults.standard
        d.set(options.scaleBar, forKey: "snap.scaleBar"); d.set(options.fileName, forKey: "snap.fileName"); d.set(options.factor, forKey: "snap.factor")
    }

    /// Turn the mode on. The tick boxes start from what is switched on in the viewer right now.
    func begin(markers: Bool, boxes: Bool, scores: Bool, hasMeasurements: Bool) {
        options.markers = markers; options.boxes = boxes; options.scores = scores; options.measurements = hasMeasurements
        message = nil
        if rect.width < Self.minSide || rect.height < Self.minSide { resetRect() }
        active = true
    }
    func end() { active = false; message = nil }

    /// The whole pane, a little inset so the frame's edges can be grabbed.
    func resetRect() {
        guard paneSize.width > 0 else { rect = .zero; return }
        rect = CGRect(origin: .zero, size: paneSize).insetBy(dx: 24, dy: 24)
    }
    func clampToPane() {
        guard paneSize.width > 0, rect.width > 0 else { return }
        rect = SnapshotGeometry.clamp(rect, to: paneSize)
    }
}

// MARK: - Geometry (pure, tested)

enum SnapshotGeometry {
    /// Output size for a frame of `rect` points on a display with `backingScale` px per point: the factor is reduced when
    /// the longest side would pass `maxSide`. `pxPerScreenPx` is the factor actually used.
    static func outputSize(rect: CGRect, backingScale: Double, factor: Int, maxSide: Int = SnapshotState.maxSide) -> (w: Int, h: Int, pxPerScreenPx: Double) {
        let sw = Double(rect.width) * backingScale, sh = Double(rect.height) * backingScale
        var k = Double(max(factor, 1))
        let longest = max(sw, sh) * k
        if longest > Double(maxSide) { k *= Double(maxSide) / longest }
        return (max(1, Int((sw * k).rounded())), max(1, Int((sh * k).rounded())), k)
    }

    static func clamp(_ r: CGRect, to size: CGSize, minSide: CGFloat = SnapshotState.minSide) -> CGRect {
        var x0 = max(0, r.minX), y0 = max(0, r.minY), x1 = min(size.width, r.maxX), y1 = min(size.height, r.maxY)
        if x1 - x0 < minSide { if x0 + minSide <= size.width { x1 = x0 + minSide } else { x1 = size.width; x0 = max(0, x1 - minSide) } }
        if y1 - y0 < minSide { if y0 + minSide <= size.height { y1 = y0 + minSide } else { y1 = size.height; y0 = max(0, y1 - minSide) } }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Which edges a press at `p` grabs: within `slop` of an edge of the frame (and of its extent along that edge).
    static func edges(at p: CGPoint, in r: CGRect, slop: CGFloat = 10) -> (l: Bool, r: Bool, t: Bool, b: Bool) {
        let inX = p.x >= r.minX - slop && p.x <= r.maxX + slop, inY = p.y >= r.minY - slop && p.y <= r.maxY + slop
        // when the frame is tiny the nearer edge wins
        let l = inY && abs(p.x - r.minX) <= slop, rr = inY && abs(p.x - r.maxX) <= slop
        let t = inX && abs(p.y - r.minY) <= slop, b = inX && abs(p.y - r.maxY) <= slop
        return (l && !(rr && abs(p.x - r.maxX) < abs(p.x - r.minX)), rr && !(l && abs(p.x - r.minX) <= abs(p.x - r.maxX)),
                t && !(b && abs(p.y - r.maxY) < abs(p.y - r.minY)), b && !(t && abs(p.y - r.minY) <= abs(p.y - r.maxY)))
    }
}

// MARK: - The picture itself

/// The picked frame drawn as a picture: the micrograph part is rendered by the Metal renderer at the output size (so a 2× picture
/// has twice the detail of the screen, not an enlarged screenshot), the markers, rulers and scale bar are drawn on top by the very
/// same views the viewer uses.
enum SnapshotRenderer {
    @MainActor
    static func compose(renderer: MicrographRenderer, screen: ViewState, rect: CGRect, options o: SnapshotOptions,
                        picks pc: PickController, measure: MeasureState, pixelSizeA: Double?, caption: String?) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1, screen.zoom > 0 else { return nil }
        let bs = screen.backingScale == 0 ? 2 : screen.backingScale
        let out = SnapshotGeometry.outputSize(rect: rect, backingScale: bs, factor: o.factor)
        let g = ViewGeometry(zoom: screen.zoom, center: screen.center, viewPixels: screen.viewPixels, backingScale: bs)
        let centre = g.toImage(CGPoint(x: rect.midX, y: rect.midY))
        let zoomOut = screen.zoom * Double(out.w) / (Double(rect.width) * bs)       // output px per image px
        guard let bgra = renderer.renderRegion(width: out.w, height: out.h, center: centre, zoom: zoomOut),
              let prov = CGDataProvider(data: Data(bgra) as CFData),
              let base = CGImage(width: out.w, height: out.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: out.w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                 provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return decorate(base: base, rect: rect, centre: centre, zoom: screen.zoom, backingScale: bs, imageSize: screen.imageSize,
                        options: o, picks: pc, measure: measure, pixelSizeA: pixelSizeA, caption: caption)
    }

    /// Draws the markers, rulers, scale bar and caption onto the rendered micrograph `base` (which shows the frame `rect`, in
    /// points, of a view at `zoom` / `backingScale` whose frame centre sits at image position `centre`).
    @MainActor
    static func decorate(base: CGImage, rect: CGRect, centre: CGPoint, zoom: Double, backingScale bs: Double, imageSize: CGSize,
                         options o: SnapshotOptions, picks pc: PickController, measure: MeasureState, pixelSizeA: Double?, caption: String?) -> CGImage? {
        let drawsPicks = o.markers || o.boxes || o.scores
        if !drawsPicks && !o.measurements && !o.scaleBar && !(o.fileName && caption != nil) { return base }

        // the overlays are laid out exactly as on screen: same zoom, same points-per-pixel, the frame's centre as the view centre
        let vs = ViewState()
        vs.zoom = zoom; vs.center = centre; vs.backingScale = bs
        vs.viewPixels = CGSize(width: Double(rect.width) * bs, height: Double(rect.height) * bs)
        vs.imageSize = imageSize
        let view = SnapshotComposite(base: base, size: rect.size, vs: vs, options: o, pc: pc, store: pc.store, cs: pc.crops,
                                     measure: measure, pixelSizeA: pixelSizeA, caption: caption)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = Double(base.width) / Double(rect.width)
        r.isOpaque = true
        return r.cgImage
    }

    static func pngData(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

struct SnapshotComposite: View {
    let base: CGImage
    let size: CGSize
    let vs: ViewState
    let options: SnapshotOptions
    let pc: PickController
    let store: PickStore
    let cs: CropSession
    let measure: MeasureState
    let pixelSizeA: Double?
    let caption: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: base, scale: 1).resizable().interpolation(.none).frame(width: size.width, height: size.height)
            if options.markers || options.boxes || options.scores {
                PickOverlay(pc: pc, vs: vs, store: store, cs: cs, export: PickExportStyle(markers: options.markers, boxes: options.boxes, scores: options.scores))
                    .frame(width: size.width, height: size.height)
            }
            if options.measurements {
                MeasureOverlay(measure: measure, vs: vs, pixelSizeA: pixelSizeA, export: true).frame(width: size.width, height: size.height)
            }
            if options.scaleBar {
                ScaleBar(vs: vs, pixelSizeA: pixelSizeA, targetPts: max(30, min(130, Double(size.width) * 0.35)))
                    .padding(12)
                    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            }
            if options.fileName, let c = caption {
                Text(c).font(.system(.caption, design: .monospaced).weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - AppModel

extension AppModel {
    func toggleSnapshot() {
        if snapshot.active { snapshot.end(); return }
        guard doc != nil else { return }
        snapshot.begin(markers: picks.showMarkers, boxes: picks.showBoxes, scores: picks.showScores,
                       hasMeasurements: !measure.lines.isEmpty || measure.quick != nil)
    }

    private var snapshotCaption: String? {
        guard let d = doc else { return nil }
        var s = d.url.lastPathComponent
        if d.entry.depth > 1 { s += d.frame >= 0 ? "  ·  frame \(d.frame + 1)/\(d.entry.depth)" : "  ·  average of \(d.entry.depth) frames" }
        if let p = d.entry.pixelSizeA { s += String(format: "  ·  %.4g Å/px", p) }
        return s
    }

    func makeSnapshot() -> CGImage? {
        guard doc != nil, let renderer else { return nil }
        return SnapshotRenderer.compose(renderer: renderer, screen: view, rect: snapshot.rect, options: snapshot.options,
                                        picks: picks, measure: measure, pixelSizeA: doc?.entry.pixelSizeA, caption: snapshotCaption)
    }

    func saveSnapshot() {
        guard let img = makeSnapshot(), let png = SnapshotRenderer.pngData(img) else { snapshot.message = "Could not make the picture."; return }
        let sp = NSSavePanel(); sp.allowedContentTypes = [.png]
        sp.nameFieldStringValue = (doc?.url.deletingPathExtension().lastPathComponent ?? "micrograph") + "_picture.png"
        guard sp.runModal() == .OK, let url = sp.url else { return }
        do { try png.write(to: url); snapshot.message = "Saved \(url.lastPathComponent) (\(img.width) × \(img.height) px)" }
        catch { snapshot.message = "Could not write the file: \(error.localizedDescription)" }
    }

    func copySnapshot() {
        guard let img = makeSnapshot(), let png = SnapshotRenderer.pngData(img) else { snapshot.message = "Could not make the picture."; return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        if let tiff = ns.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        snapshot.message = "Copied (\(img.width) × \(img.height) px)"
    }
}

// MARK: - Frame over the image

struct SnapshotOverlay: View {
    @ObservedObject var snap: SnapshotState
    private enum Drag { case fresh(CGPoint), move(CGRect), resize(CGRect, l: Bool, r: Bool, t: Bool, b: Bool) }
    @State private var drag: Drag?

    var body: some View {
        if snap.active {
            GeometryReader { geo in
                ZStack {
                    Canvas { ctx, size in
                        let r = snap.rect
                        var dim = Path(CGRect(origin: .zero, size: size)); dim.addRect(r)
                        ctx.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                        ctx.stroke(Path(r), with: .color(.black.opacity(0.7)), lineWidth: 3)
                        ctx.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                        for p in handles(r) {
                            let h = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                            ctx.fill(Path(h), with: .color(.white)); ctx.stroke(Path(h), with: .color(.black), lineWidth: 1)
                        }
                    }
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in change(v) }.onEnded { _ in drag = nil; snap.clampToPane() })
                }
                .onAppear { sync(geo.size) }
                .onChange(of: geo.size) { _, s in sync(s) }
            }
        }
    }

    private func sync(_ s: CGSize) {
        let first = snap.paneSize == .zero
        snap.paneSize = s
        if first || snap.rect.width < SnapshotState.minSide { snap.resetRect() } else { snap.clampToPane() }
    }

    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func change(_ v: DragGesture.Value) {
        if drag == nil {
            let e = SnapshotGeometry.edges(at: v.startLocation, in: snap.rect)
            if e.l || e.r || e.t || e.b { drag = .resize(snap.rect, l: e.l, r: e.r, t: e.t, b: e.b) }
            else if snap.rect.contains(v.startLocation) { drag = .move(snap.rect) }
            else { drag = .fresh(v.startLocation) }
        }
        let dx = v.location.x - v.startLocation.x, dy = v.location.y - v.startLocation.y
        let pane = snap.paneSize
        switch drag! {
        case .fresh(let s):
            let a = CGPoint(x: min(max(s.x, 0), pane.width), y: min(max(s.y, 0), pane.height))
            let b = CGPoint(x: min(max(v.location.x, 0), pane.width), y: min(max(v.location.y, 0), pane.height))
            snap.rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .move(let r0):
            let x = min(max(r0.minX + dx, 0), pane.width - r0.width), y = min(max(r0.minY + dy, 0), pane.height - r0.height)
            snap.rect = CGRect(x: x, y: y, width: r0.width, height: r0.height)
        case .resize(let r0, let l, let r, let t, let b):
            var x0 = r0.minX, x1 = r0.maxX, y0 = r0.minY, y1 = r0.maxY
            if l { x0 = min(max(x0 + dx, 0), x1 - 1) }
            if r { x1 = max(min(x1 + dx, pane.width), x0 + 1) }
            if t { y0 = min(max(y0 + dy, 0), y1 - 1) }
            if b { y1 = max(min(y1 + dy, pane.height), y0 + 1) }
            snap.rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}

// MARK: - Bar with the options

struct SnapshotHUD: View {
    @ObservedObject var model: AppModel
    @ObservedObject var snap: SnapshotState
    @ObservedObject var pc: PickController
    @ObservedObject var measure: MeasureState
    @ObservedObject var vs: ViewState

    var body: some View {
        if snap.active { bar }
    }

    private var sizeText: String {
        let bs = vs.backingScale == 0 ? 2 : vs.backingScale
        let o = SnapshotGeometry.outputSize(rect: snap.rect, backingScale: bs, factor: snap.options.factor)
        return "\(o.w) × \(o.h) px"
    }

    private var bar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Toggle("Markers", isOn: $snap.options.markers).help("Particle markers (circles, rings, boxes, crosses)")
                Toggle("Extraction boxes", isOn: $snap.options.boxes)
                Toggle("Scores", isOn: $snap.options.scores)
                Divider().frame(height: 16)
                Toggle("Measurements", isOn: $snap.options.measurements).help("Ruler lines and their lengths")
                Toggle("Scale bar", isOn: $snap.options.scaleBar)
                Toggle("File name", isOn: $snap.options.fileName)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Picker("Detail", selection: $snap.options.factor) {
                    ForEach(SnapshotState.factors, id: \.self) { Text("\($0)×") }
                }
                .pickerStyle(.segmented).frame(width: 150).help("Output pixels per screen pixel. Higher gives a larger, sharper picture.")
                Text(sizeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Whole view") { snap.resetRect() }.controlSize(.small)
                Spacer(minLength: 8)
                if let m = snap.message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Button("Copy") { model.copySnapshot() }.keyboardShortcut("c", modifiers: [.command]).help("Copy the picture to the clipboard (⌘C)")
                Button("Save…") { model.saveSnapshot() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
                Button("Close") { snap.end() }.keyboardShortcut(.cancelAction)
            }
            Text("Drag to draw a frame, drag inside to move it, drag its edges to resize. Zoom and pan first; markers and rulers follow the frame.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}
