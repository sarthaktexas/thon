import SwiftUI

/// Rendered image of the crop on screen; rebuilt only when something that changes pixels changes.
final class CropImageCache {
    private var sig = ""
    private var image: CGImage?
    func get(sig s: String, make: () -> CGImage?) -> CGImage? {
        if s != sig || image == nil { sig = s; image = make() }
        return image
    }
}

/// Crop editor: one crop of the micrograph with its circles. Click empty ground to add a circle, drag a circle to move it,
/// pinch (or the size slider, or the up and down keys) to resize it, double-click a circle to remove it. Next confirms the crop.
struct CropView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var sw: SwipeSession
    @ObservedObject var cs: CropSession
    @ObservedObject var cl: CropClassifier
    @ObservedObject var rr: Reranker
    @ObservedObject var store: PickStore
    @ObservedObject var units = UnitSettings.shared
    @FocusState private var focused: Bool
    @State private var cache = CropImageCache()
    @State private var hover: CGPoint?
    @State private var dragID: String?
    @State private var dragActive = false
    @State private var dragMoved = false
    @State private var dragOrigin = CGPoint.zero
    @State private var lastClick: (id: String, at: Date)?
    @State private var pinch: (id: String?, start: Double)?
    @AppStorage("swipe.showDisplay") private var showDisplay = true

    init(model: AppModel) {
        self.model = model; self.pc = model.picks; self.sw = model.picks.swipe; self.cs = model.picks.crops
        self.cl = model.picks.crops.classifier; self.rr = model.picks.swipe.reranker; self.store = model.picks.store
    }

    private let side: CGFloat = 640
    private let outPx = 960

    var body: some View {
        VStack(spacing: 8) {
            header
            if cs.done { finished } else {
                tools
                canvas
                footer
            }
            assist
            DisplayPanel(sw: sw, keysHint: "V denoise · , . brightness · - = contrast · I invert · 0 reset")
            Text("Click empty ground to add a circle · drag a circle to move it · pinch, ↑ ↓ or the slider to resize · double-click a circle to remove it · Space switches green / yellow · Return confirms the crop and goes on · Z undoes. Circles you leave alone count as confirmed.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: side)
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: showDisplay ? 960 : 840)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0) }
        .onAppear { focused = true; cs.rebuild() }
        .onChange(of: pc.currentKey) { _, _ in cs.rebuild() }
        .onChange(of: pc.autoBusy) { _, busy in if !busy { cs.rebuild() } }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text(pc.currentKey.map { ($0 as NSString).lastPathComponent } ?? "–").font(.system(.headline, design: .monospaced))
                Spacer()
                if !cs.done { Text("crop \(cs.reviewedCount + 1) / \(cs.tilesTotal)").monospacedDigit() }
                Button("Close") { model.showCrops = false }.keyboardShortcut(.cancelAction)
            }
            ProgressView(value: Double(cs.reviewedCount), total: Double(max(cs.tilesTotal, 1)))
        }.frame(width: side)
    }

    private var tools: some View {
        let sel = cs.items.first { $0.id == cs.selected }
        let nm = sel?.diameterNm ?? (cs.penNm > 0 ? cs.penNm : cs.defaultDiameterNm)
        let lo = cs.defaultDiameterNm * 0.2, hi = cs.defaultDiameterNm * 4
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text("Circle").font(.caption.weight(.semibold))
                levelButton(.sure, color: .green, title: "Sure")
                levelButton(.maybe, color: .yellow, title: "Maybe")
                if store.scheme.labels.count > 1 {
                    Picker("", selection: Binding(get: { sel?.label ?? pc.activeLabel }, set: { l in pc.activeLabel = l; if let s = cs.selected { cs.setLabel(s, l) } })) {
                        ForEach(store.scheme.labels) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 130)
                }
                Spacer()
                Text(sel == nil ? "new circles" : "selected").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { min(max(nm, lo), hi) }, set: { v in
                    if let s = cs.selected { cs.setDiameter(s, nm: v) } else { cs.penNm = v }
                }), in: lo...hi) { editing in if editing, cs.selected != nil { cs.beginEdit() } }.frame(width: 160)
                Text("Ø " + LengthUnits.format(nm: nm, useAngstroms: units.angstroms)).font(.caption).monospacedDigit().frame(width: 84, alignment: .leading)
            }
            HStack(spacing: 12) {
                Toggle("Zoom out ×2", isOn: $cs.zoomOut).toggleStyle(.checkbox).font(.caption)
                    .help("Shows twice the width, for a particle that does not fit the crop. Circles of the wider window join this crop.")
                Stepper(value: $cs.sideDiameters, in: 2...12, step: 1) { Text(String(format: "Crop %.0f × particle width", cs.sideDiameters)).font(.caption) }.fixedSize()
                Picker("", selection: $cs.order) { ForEach(CropSession.Order.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Toggle("Empty crops too", isOn: $cs.includeEmpty).toggleStyle(.checkbox).font(.caption)
                    .help("Also visit crops without any circle, to add particles the picker missed.")
                Spacer()
            }
        }.frame(width: side)
    }

    private func levelButton(_ l: CropSession.Level, color: Color, title: String) -> some View {
        let on = cs.level == l
        return Button { cs.level = l } label: {
            HStack(spacing: 5) {
                Circle().stroke(color, lineWidth: 2.5).frame(width: 16, height: 16)
                Text(title).font(.caption)
            }.padding(.horizontal, 8).padding(.vertical, 3)
                .background(on ? color.opacity(0.22) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(on ? color : Color.secondary.opacity(0.4), lineWidth: on ? 1.5 : 1))
        }.buttonStyle(.plain)
    }

    private var canvas: some View {
        let sig = "\(pc.currentKey ?? "")|\(pc.pixels.count)|\(cs.current?.id ?? -1)|\(cs.windowPx)|\(sw.display)"
        let img = cache.get(sig: sig) { cs.cropImage(out: outPx).flatMap { grayCGImage($0, width: outPx, height: outPx) } }
        return ZStack(alignment: .topLeading) {
            if let img { Image(decorative: img, scale: 1).interpolation(sw.display.pixelated ? .none : .high).resizable().frame(width: side, height: side) }
            else { Rectangle().fill(.quaternary).frame(width: side, height: side) }
            Canvas { ctx, _ in drawCircles(&ctx) }.frame(width: side, height: side).allowsHitTesting(false)
            if sw.display.isDenoised {
                Rectangle().strokeBorder(Color.orange.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).padding(3).allowsHitTesting(false)
            }
            Color.clear.frame(width: side, height: side).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { dragChanged($0) }.onEnded { dragEnded($0) })
                .simultaneousGesture(MagnifyGesture().onChanged { magnify($0.magnification) }.onEnded { _ in pinch = nil })
                .onContinuousHover { phase in
                    switch phase { case .active(let p): hover = p; case .ended: hover = nil }
                }
        }
        .frame(width: side, height: side).clipped()
        .overlay(alignment: .topLeading) { SwipeBadge(sw: sw, pc: pc, compact: true).padding(4).allowsHitTesting(false) }
        .overlay(alignment: .bottomTrailing) {
            Text(LengthUnits.format(angstroms: cs.windowPx * pc.effectiveAngpix, useAngstroms: units.angstroms) + " wide")
                .font(.caption2).padding(3).background(.black.opacity(0.5)).foregroundStyle(.white).padding(4).allowsHitTesting(false)
        }
        .border(Color.secondary.opacity(0.4))
    }

    private func drawCircles(_ ctx: inout GraphicsContext) {
        let k = side / CGFloat(cs.windowPx)
        guard let t = cs.current else { return }
        func view(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - t.cx) * k + side / 2, y: (y - t.cy) * k + side / 2) }
        for it in cs.visibleItems {
            let c = view(it.x, it.y), r = cs.px(it.diameterNm) * k / 2
            let color: Color = it.level == .sure ? .green : .yellow
            var path = Path(); path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let dash: [CGFloat] = it.untouched ? [5, 4] : []
            if it.id == cs.selected {
                ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 5.5))
            } else {
                ctx.stroke(path, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 4, dash: dash))
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, dash: dash))
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 4, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 4, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - 4)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 4))
            ctx.stroke(cross, with: .color(.black.opacity(0.6)), lineWidth: 3); ctx.stroke(cross, with: .color(color), lineWidth: 1.2)
            if it.level == .maybe {
                ctx.draw(Text("?").font(.system(size: max(11, min(20, r * 0.8)), weight: .bold, design: .monospaced)).foregroundColor(.yellow), at: CGPoint(x: c.x, y: c.y - 11))
            }
            if store.scheme.labels.count > 1, let l = store.scheme.label(it.label) {
                ctx.draw(Text(l.name).font(.system(size: 10, design: .monospaced)).foregroundColor(swiftUIColor(l.color)), at: CGPoint(x: c.x, y: c.y + r + 8))
            }
        }
        // preview of the circle that a click would add
        if let h = hover, cs.selected == nil, hoverItem == nil {
            let r = cs.px(cs.penNm > 0 ? cs.penNm : cs.defaultDiameterNm) * k / 2
            var p = Path(); p.addEllipse(in: CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r))
            ctx.stroke(p, with: .color((cs.level == .sure ? Color.green : Color.yellow).opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    private var footer: some View {
        let c = cs.counts
        return HStack(spacing: 12) {
            Text("this crop:  \(c.sure) sure · \(c.maybe) maybe · \(c.removed) removed").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { cs.undo() } label: { Label("Undo (Z)", systemImage: "arrow.uturn.backward") }.disabled(!cs.canUndo).controlSize(.small)
            Button("Skip") { cs.skip() }.disabled(cs.remaining < 2).controlSize(.small)
            Button { cs.commit() } label: { Text("Next crop  ↵") }.buttonStyle(.borderedProminent)
        }.frame(width: side)
    }

    private var assist: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rr.status.summary).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Toggle("Core ML model", isOn: $cl.enabled).toggleStyle(.checkbox).font(.caption2)
                    .help("Trains Apple's image classifier on the crops you review, in the background, to order the remaining crops. The hand-feature model above is used until it is ready, or when it fails.")
                Text(cl.message).font(.caption2).foregroundStyle(.secondary)
            }
            Text("Neither model decides anything: they only choose which crop comes next (uncertain first).").font(.caption2).foregroundStyle(.tertiary)
        }.frame(width: side, alignment: .leading)
    }

    private var finished: some View {
        let accepted = pc.currentKey.map { store.accepted($0).count } ?? 0
        return VStack(spacing: 12) {
            Spacer().frame(height: 10)
            Image(systemName: cs.tilesTotal == 0 ? "magnifyingglass" : "checkmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            if cs.tilesTotal == 0 {
                Text("No candidates on this micrograph").font(.title3)
                Text("Run the auto-picker to generate candidates, or tick “Empty crops too” and add circles by hand.").foregroundStyle(.secondary)
                Button { pc.runAutoPick() } label: { Label(pc.autoBusy ? "Working…" : "Find particles", systemImage: "sparkles") }.disabled(pc.autoBusy)
                Toggle("Empty crops too", isOn: $cs.includeEmpty).toggleStyle(.checkbox)
            } else {
                Text("All crops of this micrograph reviewed").font(.title3)
                Text("\(accepted) picks on this micrograph")
            }
            HStack {
                Button("Next micrograph") { model.step(1) }.disabled((model.selectedIndex ?? 0) >= model.items.count - 1).keyboardShortcut(.defaultAction)
                Button("Undo last crop") { cs.undo() }.disabled(!cs.canUndo)
            }
            Spacer()
        }.frame(width: side, height: side)
    }

    // MARK: pointer

    private func toPick(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (cs.current?.cx ?? 0) + (p.x / side - 0.5) * cs.windowPx, y: (cs.current?.cy ?? 0) + (p.y / side - 0.5) * cs.windowPx)
    }
    private var tolPx: Double { 9 / Double(side) * cs.windowPx }
    private var hoverItem: CropSession.Item? { hover.flatMap { h in let p = toPick(h); return cs.hit(x: p.x, y: p.y, tolerancePx: tolPx) } }

    private func dragChanged(_ v: DragGesture.Value) {
        if !dragActive {
            dragActive = true; dragMoved = false; dragID = nil
            let p = toPick(v.startLocation)
            if let it = cs.hit(x: p.x, y: p.y, tolerancePx: tolPx) { dragID = it.id; dragOrigin = CGPoint(x: it.x, y: it.y); cs.selected = it.id; focused = true }
        }
        guard let id = dragID else { return }
        let moved = hypot(v.translation.width, v.translation.height)
        if moved > 3 {
            if !dragMoved { dragMoved = true; cs.beginEdit() }
            let k = cs.windowPx / Double(side)
            cs.move(id, to: CGPoint(x: dragOrigin.x + v.translation.width * k, y: dragOrigin.y + v.translation.height * k))
        }
    }

    private func dragEnded(_ v: DragGesture.Value) {
        defer { dragActive = false; dragMoved = false; dragID = nil }
        if dragMoved { lastClick = nil; return }
        let now = Date()
        if let id = dragID {
            if let l = lastClick, l.id == id, now.timeIntervalSince(l.at) < 0.45 { cs.remove(id); lastClick = nil }      // double click: remove
            else { lastClick = (id, now) }
        } else {
            let p = toPick(v.startLocation)
            if let id = cs.add(x: p.x, y: p.y) { lastClick = (id, now) }
        }
    }

    private func magnify(_ m: CGFloat) {
        let target = cs.selected ?? hoverItem?.id
        if pinch == nil {
            let base = target.flatMap { id in cs.items.first { $0.id == id }?.diameterNm } ?? (cs.penNm > 0 ? cs.penNm : cs.defaultDiameterNm)
            pinch = (target, base)
            if target != nil { cs.beginEdit() }
        }
        guard let p = pinch else { return }
        let nm = p.start * Double(m)
        if let id = p.id { cs.setDiameter(id, nm: nm) } else { cs.penNm = min(max(nm, cs.defaultDiameterNm * 0.2), cs.defaultDiameterNm * 6) }
    }

    // MARK: keys

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        let c = p.characters.lowercased()
        if p.modifiers.contains(.command) { if c == "z" { cs.undo(); return .handled }; return .ignored }
        switch p.key {
        case .return: if !cs.done { cs.commit() }; return .handled
        case .escape: model.showCrops = false; return .handled
        case .delete, .deleteForward: if let s = cs.selected { cs.remove(s) }; return .handled
        case .space: if let s = cs.selected { cs.toggleLevel(s); if let it = cs.items.first(where: { $0.id == s }) { cs.level = it.level } } else { cs.level = cs.level == .sure ? .maybe : .sure }; return .handled
        case .upArrow, .downArrow:
            guard let s = cs.selected, let it = cs.items.first(where: { $0.id == s }) else { return .handled }
            cs.beginEdit(); cs.setDiameter(s, nm: it.diameterNm * (p.key == .upArrow ? 1.06 : 1 / 1.06)); return .handled
        default: break
        }
        if let l = store.scheme.label(forKey: c) { pc.activeLabel = l.id; if let s = cs.selected { cs.setLabel(s, l.id) }; return .handled }
        if sw.handleDisplayKey(c) { return .handled }
        if c == "z" { cs.undo(); return .handled }
        return .ignored
    }
}
