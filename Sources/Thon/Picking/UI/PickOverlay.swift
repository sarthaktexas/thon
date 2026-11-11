import SwiftUI

func swiftUIColor(_ hex: String) -> Color {
    guard let c = parseHexColor(hex) else { return .white }
    return Color(red: c.0, green: c.1, blue: c.2)
}
func hexString(_ color: Color) -> String {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
    return String(format: "#%02x%02x%02x", Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
}

/// Draws picks over the micrograph. Hit testing is done by the Metal view; this layer is display only.
struct PickOverlay: View {
    @ObservedObject var pc: PickController
    @ObservedObject var vs: ViewState
    @ObservedObject var store: PickStore

    var body: some View {
        Canvas { ctx, size in
            guard pc.showMarkers, pc.currentKey != nil, vs.zoom > 0 else { return }
            let bs = vs.backingScale == 0 ? 2 : vs.backingScale
            let g = ViewGeometry(zoom: vs.zoom, center: vs.center,
                                 viewPixels: CGSize(width: size.width * bs, height: size.height * bs), backingScale: bs)
            let ppp = g.pointsPerPixel
            let sel = pc.selection
            let boxPts = pc.boxPx * ppp
            let visibleRect = CGRect(x: -40, y: -40, width: size.width + 80, height: size.height + 80)
            let unsorted = pc.unsortedPickIDs()
            for p in pc.visiblePicks {
                let c = g.pickToView(x: p.x, y: p.y)
                let r = pc.diameterPx(p) * ppp / 2
                guard visibleRect.insetBy(dx: -r, dy: -r).contains(c) else { continue }
                Self.drawPick(&ctx, p, at: c, radius: r, pc: pc, store: store, selected: sel.contains(p.id), boxPts: boxPts, unsorted: unsorted.contains(p.id))
            }
            if let b = pc.boxRect {
                let a = g.pickToView(x: b.minX, y: b.minY), z = g.pickToView(x: b.maxX, y: b.maxY)
                let rect = CGRect(x: min(a.x, z.x), y: min(a.y, z.y), width: abs(z.x - a.x), height: abs(z.y - a.y))
                ctx.fill(Path(rect), with: .color(.white.opacity(0.08)))
                ctx.stroke(Path(rect), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    /// Draws one pick (shape, candidate dash, selection halo, box, "?" and score) at view point `c` with radius `r` in points.
    /// Shared by the main overlay and the loupe so both look identical.
    static func drawPick(_ ctx: inout GraphicsContext, _ p: Pick, at c: CGPoint, radius r: Double,
                         pc: PickController, store: PickStore, selected: Bool, boxPts: Double, unsorted: Bool = false) {
        let lab = store.scheme.label(p.label)
        let color = unsorted ? Color.white : (pc.showClassColors ? pc.classColor(of: p).map { swiftUIColor($0) } : nil) ?? lab.map { swiftUIColor($0.color) } ?? .gray
        let shape = lab?.shape ?? .circle
        let isCand = p.status == .candidate
        let style = isCand ? StrokeStyle(lineWidth: 1.5, dash: [4, 3]) : StrokeStyle(lineWidth: 1.6)
        let shapePath = path(shape, c, r)
        if selected {
            ctx.stroke(shapePath, with: .color(.white), style: StrokeStyle(lineWidth: 4.5))
            ctx.stroke(Path(CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(.white), lineWidth: 1)
        } else {
            ctx.stroke(shapePath, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 3.2, dash: style.dash))
        }
        ctx.stroke(shapePath, with: .color(color.opacity(isCand ? 0.85 : 1)), style: style)
        if pc.showBoxes {
            ctx.stroke(Path(CGRect(x: c.x - boxPts / 2, y: c.y - boxPts / 2, width: boxPts, height: boxPts)),
                       with: .color(color.opacity(0.55)), lineWidth: 1)
        }
        if p.isMaybe && store.project.params.maybeFlag {
            ctx.draw(Text("?").font(.system(size: max(10, min(18, r * 0.9)), weight: .bold, design: .monospaced)).foregroundColor(color),
                     at: CGPoint(x: c.x, y: c.y))
        }
        if pc.showScores, let sc = p.score {
            ctx.draw(Text(String(format: "%.1f", sc)).font(.system(size: 10, design: .monospaced)).foregroundColor(.white),
                     at: CGPoint(x: c.x, y: c.y - r - 7))
        }
    }

    static func path(_ shape: MarkerShape, _ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        switch shape {
        case .circle:
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .ring:
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let q = max(1.5, r * 0.12)
            p.addEllipse(in: CGRect(x: c.x - q, y: c.y - q, width: 2 * q, height: 2 * q))
        case .box:
            p.addRect(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .cross:
            let a = max(r, 6)
            p.move(to: CGPoint(x: c.x - a, y: c.y)); p.addLine(to: CGPoint(x: c.x + a, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - a)); p.addLine(to: CGPoint(x: c.x, y: c.y + a))
        }
        return p
    }
}
