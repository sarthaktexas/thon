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
/// pinch (or the size slider, or the up and down keys) to resize it, right-click a circle to change its type, double-click
/// a circle to remove it. A circle is drawn in the colour of its type. Next confirms the crop.
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

    /// Edge of the square canvas; follows the space the sheet gives it (see `body`).
    @State private var side: CGFloat = 600
    @State private var showHelp = false
    @State private var peeking = false          // backtick held: circles and labels are hidden
    @State private var showMoreDisplay = false
    @State private var showOrdering = false
    private let sidebarW: CGFloat = 280
    private let outPx = 960

    var body: some View {
        VStack(spacing: 10) {
            header
            GeometryReader { geo in
                let reserved: CGFloat = cs.done ? 0 : 64                     // footer and hint line under the canvas
                let s = max(320, min(geo.size.height - reserved, geo.size.width - sidebarW - 20)).rounded(.down)
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 8) {
                        if cs.done { finished } else { canvas; footer }
                    }.frame(width: side)
                    sidebar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onAppear { side = s }
                .onChange(of: s) { _, v in side = v }
            }
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 660, idealHeight: 780)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up]) { handle($0) }
        .onChange(of: focused) { _, f in if !f { peeking = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in peeking = false }
        .onDisappear { peeking = false }
        .onAppear { focused = true; cs.rebuild() }
        .onChange(of: pc.currentKey) { _, _ in cs.rebuild() }
        .onChange(of: pc.autoBusy) { _, busy in if !busy { cs.rebuild() } }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(pc.currentKey.map { ($0 as NSString).lastPathComponent } ?? "–").font(.system(.headline, design: .monospaced)).lineLimit(1)
                Spacer()
                if !cs.done { Text("crop \(cs.reviewedCount + 1) / \(cs.tilesTotal)").monospacedDigit().foregroundStyle(.secondary) }
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.borderless).help("How to use the crop editor")
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpText }
                Button("Close") { model.showCrops = false }.keyboardShortcut(.cancelAction)
            }
            ProgressView(value: Double(cs.reviewedCount), total: Double(max(cs.tilesTotal, 1)))
        }
    }

    private var helpText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Crop editor").font(.headline)
            Group {
                Text("Click empty ground to add a circle.")
                Text("Drag a circle to move it.")
                Text("Pinch, ↑ ↓ or the size slider to resize it.")
                Text("Double-click a circle (or Delete) to remove it. Removing a circle the picker found teaches it that it was wrong; removing one you added just takes it away.")
                Text("Right-click a circle to change its type (or press its type's number key; Space steps to the next type).")
                Text("Hold ` (backtick) to hide the circles and see the bare crop. ] zooms out (×2, ×4, ×8, ×16), [ zooms in.")
                Text("A circle is drawn in the colour of its type; dashed = a suggestion nobody has touched.")
                Text("Return confirms the crop and goes on; Z undoes.")
                Text("Circles you leave alone count as confirmed.")
                Text("Display keys: V denoise · , . brightness · - = contrast · I invert · 0 reset.")
            }.font(.callout).foregroundStyle(.secondary)
        }.padding(14).frame(width: 340, alignment: .leading)
    }

    // MARK: sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                circleSection
                Divider()
                cropSection
                Divider()
                displaySection
                Divider()
                orderingSection
            }.padding(.trailing, 6)
        }.frame(width: sidebarW)
    }

    private func sectionTitle(_ t: String) -> some View { Text(t).font(.subheadline.weight(.semibold)) }

    private var circleSection: some View {
        let sel = cs.items.first { $0.id == cs.selected }
        let nm = sel?.diameterNm ?? (cs.penNm > 0 ? cs.penNm : cs.defaultDiameterNm)
        let lo = cs.defaultDiameterNm * 0.2, hi = cs.defaultDiameterNm * 4
        let cur = sel?.label ?? cs.penLabelID
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle(sel == nil ? "Type of new circles" : "Type of selected circle")
            VStack(spacing: 4) { ForEach(cs.typeLabels) { typeRow($0, current: cur == $0.id) } }
            Text("Right-click a circle to change its type.").font(.caption2).foregroundStyle(.tertiary)
            if cs.isViewScheme {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Set type from circle size", isOn: $cs.sizeTyping).toggleStyle(.checkbox)
                        .help("When you resize a circle, its type becomes the view whose typical size is closest. Typical sizes are learned from circles you sized by hand.")
                    if cs.sizeTyping {
                        Text(cs.sizeTyper.map { t in "Learned: " + t.centres.map { c in (store.scheme.label(c.id)?.name ?? c.id) + " ≈ " + LengthUnits.format(nm: c.nm, useAngstroms: units.angstroms) }.joined(separator: " · ") }
                             ?? "Not learned yet: needs \(SizeTyper.minEach) hand-sized circles for each of two views.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Ø " + LengthUnits.format(nm: nm, useAngstroms: units.angstroms)).font(.caption).monospacedDigit()
                }
                Slider(value: Binding(get: { min(max(nm, lo), hi) }, set: { v in
                    if let s = cs.selected { cs.setDiameter(s, nm: v) } else { cs.penNm = v }
                }), in: lo...hi) { editing in if editing, cs.selected != nil { cs.beginEdit() } }
            }
        }
    }

    private func typeRow(_ l: PickLabel, current on: Bool) -> some View {
        let color = swiftUIColor(l.color)
        return Button {
            pc.activeLabel = l.id
            if let s = cs.selected { cs.setLabel(s, l.id) }
            focused = true
        } label: {
            HStack(spacing: 8) {
                Circle().stroke(color, lineWidth: 2.5).frame(width: 14, height: 14)
                Text(l.name).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                if !l.key.isEmpty { Text(l.key).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(on ? color.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? color : Color.secondary.opacity(0.3), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Right-click menu of the circle under the pointer: its type, and remove.
    @ViewBuilder private var circleMenu: some View {
        if let it = hoverItem {
            ForEach(cs.typeLabels) { l in
                Button {
                    cs.selected = it.id; cs.setLabel(it.id, l.id); pc.activeLabel = l.id
                } label: {
                    let name = l.key.isEmpty ? l.name : "\(l.name)   (\(l.key))"
                    if it.label == l.id { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button(role: .destructive) { cs.remove(it.id) } label: { Label("Remove circle", systemImage: "trash") }
        }
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Crops")
            Picker("", selection: $cs.order) { ForEach(CropSession.Order.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Stepper(value: $cs.sideDiameters, in: 2...12, step: 1) { Text(String(format: "Width: %.0f × particle", cs.sideDiameters)).font(.callout) }
            Stepper(value: $cs.zoomLevel, in: 0...cs.maxZoomLevel, step: 1) { Text("Zoom out: \(cs.zoomLabel)").font(.callout) }
                .help("Shows 2, 4, 8 or 16 times the width (up to the micrograph's size), for a particle that does not fit the crop. Circles of the wider window join this crop. Keys: ] zooms out, [ zooms in.")
            Toggle("Include empty crops", isOn: $cs.includeEmpty).toggleStyle(.checkbox)
                .help("Also visit crops without any circle, to add particles the picker missed.")
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Display")
                Spacer()
                Button("Reset") { sw.display.resetTone(); sw.display.denoise = .none }.controlSize(.small).help("Reset display (0)")
            }
            Picker("", selection: Binding(get: { sw.display.denoise }, set: { sw.display.select($0) })) {
                ForEach(SwipeDenoise.allCases) { Text($0.menuName).tag($0) }
            }.labelsHidden()
            if sw.display.isDenoised {
                if sw.display.denoise.usesSize {
                    dSlider(sw.display.denoise == .median ? "Radius" : "Size σ", $sw.display.size, sw.display.denoise.sizeRange,
                            step: sw.display.denoise == .median ? 1 : 0.1,
                            text: sw.display.denoise == .median ? String(format: "%d px", sw.display.medianRadius) : String(format: "%.1f px", sw.display.size))
                }
                if sw.display.denoise.usesH {
                    dSlider(sw.display.denoise == .bilateral ? "Range" : "Strength", $sw.display.h, 0.3...3, step: 0.1, text: String(format: "%.1f σn", sw.display.h))
                }
            }
            dSlider("Brightness", $sw.display.brightness, -1...1, step: 0.01, text: String(format: "%+.2f", sw.display.brightness))
            dSlider("Contrast", Binding(get: { log2(sw.display.contrast) }, set: { sw.display.contrast = pow(2, $0) }), -2...2, step: 0.05,
                    text: String(format: "×%.2f", sw.display.contrast))
            Toggle("Invert", isOn: $sw.display.invert).toggleStyle(.checkbox)
            DisclosureGroup("More", isExpanded: $showMoreDisplay) {
                VStack(alignment: .leading, spacing: 8) {
                    dSlider("Gamma", $sw.display.gamma, 0.4...2.5, step: 0.05, text: String(format: "%.2f", sw.display.gamma))
                    Picker("Window", selection: $sw.display.tone) { ForEach(SwipeTone.allCases) { Text($0.menuName).tag($0) } }
                        .pickerStyle(.menu)
                        .help("Whole micrograph: the same window on every crop, so brightness is comparable. This card: stretch each crop to its own 0.5–99.5 % range.")
                    Toggle("Show true pixels", isOn: $sw.display.pixelated).toggleStyle(.checkbox)
                        .help("Nearest-neighbour: every image pixel is a visible square, nothing interpolated.")
                    Toggle("Keep on next crops", isOn: $sw.pinProcessing).toggleStyle(.checkbox)
                        .help("Off: every new crop starts raw. Brightness and contrast always carry over.")
                    if sw.display.isDenoised, let n = sw.cardNoiseSigma {
                        Text(String(format: "σn ≈ %.3g", n)).font(.caption).foregroundStyle(.secondary)
                            .help("Noise σ estimated from this crop's raw pixels (assumes uncorrelated noise, so it is a lower bound).")
                    }
                }.padding(.top, 6)
            }.font(.callout)
        }
    }

    private func dSlider(_ name: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(name).font(.caption).foregroundStyle(.secondary); Spacer(); Text(text).font(.caption).monospacedDigit() }
            Slider(value: v, in: r, step: step)
        }
    }

    private var orderingSection: some View {
        DisclosureGroup(isExpanded: $showOrdering) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rr.status.summary).font(.caption).foregroundStyle(.secondary)
                Toggle("Core ML model", isOn: $cl.enabled).toggleStyle(.checkbox)
                    .help("Trains Apple's image classifier on the crops you review, in the background, to order the remaining crops. The hand-feature model above is used until it is ready, or when it fails.")
                Text(cl.message).font(.caption).foregroundStyle(.secondary)
                Text("Neither model decides anything: they only choose which crop comes next (uncertain first).").font(.caption).foregroundStyle(.tertiary)
            }.padding(.top, 6)
        } label: { sectionTitle("Learning from your decisions") }
    }

    private var canvas: some View {
        let sig = "\(pc.currentKey ?? "")|\(pc.pixels.count)|\(cs.current?.id ?? -1)|\(cs.windowPx)|\(sw.display)"
        let img = cache.get(sig: sig) { cs.cropImage(out: outPx).flatMap { grayCGImage($0, width: outPx, height: outPx) } }
        return ZStack(alignment: .topLeading) {
            if let img { Image(decorative: img, scale: 1).interpolation(sw.display.pixelated ? .none : .high).resizable().frame(width: side, height: side) }
            else { Rectangle().fill(.quaternary).frame(width: side, height: side) }
            Canvas { ctx, _ in drawCircles(&ctx) }.frame(width: side, height: side).opacity(peeking ? 0 : 1).allowsHitTesting(false)
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
        .contextMenu { if !peeking { circleMenu } }
        .overlay(alignment: .topLeading) { SwipeBadge(sw: sw, pc: pc, compact: true).padding(4).opacity(peeking ? 0 : 1).allowsHitTesting(false) }
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
            let color: Color = store.scheme.label(it.label).map { swiftUIColor($0.color) } ?? .green
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
            let pen = store.scheme.label(cs.penLabelID).map { swiftUIColor($0.color) } ?? .green
            ctx.stroke(p, with: .color(pen.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    private var footer: some View {
        let vis = cs.visibleItems
        let parts = store.scheme.labels.compactMap { l -> String? in let n = vis.filter { $0.label == l.id }.count; return n > 0 ? "\(n) \(l.name)" : nil }
        let text = (parts + ["\(cs.counts.removed) removed"]).joined(separator: " · ")
        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button { cs.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!cs.canUndo).controlSize(.small).help("Undo (Z)")
                Button("Skip") { cs.skip() }.disabled(cs.remaining < 2).controlSize(.small)
                Button { cs.commit() } label: { Text("Next crop  ↵") }.buttonStyle(.borderedProminent)
            }
            Text("Click to add · drag to move · pinch or ↑ ↓ to resize · right-click to change type · double-click to remove · hold ` to hide · [ ] zoom")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.7)
        }
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
        if peeking { return }                                  // circles are hidden: do not edit what you cannot see
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
        if peeking { return }
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
        if peeking { return }
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
        // hold ` to hide the circles; key repeat keeps it hidden, release shows them again
        if OverlayPeek.isCropPeekCharacter(p.characters), !p.modifiers.contains(.command) {
            peeking = p.phase != .up
            return .handled
        }
        if p.phase != .down { return .ignored }                // everything else acts once per press, as before
        if p.modifiers.contains(.command) { if c == "z" { cs.undo(); return .handled }; return .ignored }
        switch p.key {
        case .return: if !cs.done { cs.commit() }; return .handled
        case .escape: model.showCrops = false; return .handled
        case .delete, .deleteForward: if let s = cs.selected { cs.remove(s) }; return .handled
        case .space:
            if let s = cs.selected { cs.cycleLabel(s) }
            else if let i = cs.typeLabels.firstIndex(where: { $0.id == cs.penLabelID }) { pc.activeLabel = cs.typeLabels[(i + 1) % cs.typeLabels.count].id }
            return .handled
        case .upArrow, .downArrow:
            guard let s = cs.selected, let it = cs.items.first(where: { $0.id == s }) else { return .handled }
            cs.beginEdit(); cs.setDiameter(s, nm: it.diameterNm * (p.key == .upArrow ? 1.06 : 1 / 1.06)); return .handled
        default: break
        }
        if let l = store.scheme.label(forKey: c), l.exported { pc.activeLabel = l.id; if let s = cs.selected { cs.setLabel(s, l.id) }; return .handled }
        if c == "]" { cs.zoomLevel += 1; return .handled }
        if c == "[" { cs.zoomLevel -= 1; return .handled }
        if sw.handleDisplayKey(c) { return .handled }
        if c == "z" { cs.undo(); return .handled }
        return .ignored
    }
}
