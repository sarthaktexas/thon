import SwiftUI

// The crop editor inside the main viewer: the image is the viewer's own; these layers sit on top of it.

/// Tint of finished sections, dimming of everything outside the section on screen, the circles being edited, and the
/// rubber band of a region being dragged. Display only: the Metal view takes the mouse and calls `CropSession`.
struct CropOverlay: View {
    @ObservedObject var cs: CropSession
    @ObservedObject var pc: PickController
    @ObservedObject var vs: ViewState
    @ObservedObject var store: PickStore

    var body: some View {
        Canvas { ctx, size in
            guard cs.active, pc.currentKey != nil, vs.zoom > 0 else { return }
            let bs = vs.backingScale == 0 ? 2 : vs.backingScale
            let g = ViewGeometry(zoom: vs.zoom, center: vs.center,
                                 viewPixels: CGSize(width: size.width * bs, height: size.height * bs), backingScale: bs)
            let ppp = g.pointsPerPixel
            func box(_ r: CGRect) -> CGRect {
                let a = g.pickToView(x: r.minX, y: r.minY), z = g.pickToView(x: r.maxX, y: r.maxY)
                return CGRect(x: min(a.x, z.x), y: min(a.y, z.y), width: abs(z.x - a.x), height: abs(z.y - a.y))
            }
            // finished sections: one path, so overlapping sections are tinted once
            var done = Path()
            for r in cs.sections { done.addRect(box(r.rect)) }
            ctx.fill(done, with: .color(.green.opacity(0.2)))
            // dim everything but the section on screen
            if let cur = cs.currentRect {
                let hole = box(cur)
                var dim = Path(CGRect(origin: .zero, size: size)); dim.addRect(hole)
                ctx.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(hole), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5))
            }
            // circles being edited
            for it in cs.visibleItems {
                let c = g.pickToView(x: it.x, y: it.y), r = cs.px(it.diameterNm) * ppp / 2
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
            // region being dragged
            if let rr = cs.regionRect {
                let b = box(rr)
                ctx.fill(Path(b), with: .color(.green.opacity(0.25)))
                ctx.stroke(Path(b), with: .color(.green), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dashed preview of the circle a click would add (size and type of the pen). Kept apart so mouse moves redraw only this layer.
struct CropPenPreview: View {
    @ObservedObject var cs: CropSession
    @ObservedObject var pc: PickController
    @ObservedObject var vs: ViewState
    @ObservedObject var store: PickStore
    @ObservedObject var cursor: CursorState

    var body: some View {
        Canvas { ctx, size in
            guard cs.active, !cs.regionTool, cs.selected == nil, let x = cursor.x, let y = cursor.y, vs.zoom > 0 else { return }
            let p = CGPoint(x: Double(x), y: Double(y))
            guard cs.currentRect?.contains(p) == true, cs.hit(x: p.x, y: p.y, tolerancePx: 10 * (vs.backingScale == 0 ? 2 : vs.backingScale) / vs.zoom) == nil else { return }
            let bs = vs.backingScale == 0 ? 2 : vs.backingScale
            let g = ViewGeometry(zoom: vs.zoom, center: vs.center, viewPixels: CGSize(width: size.width * bs, height: size.height * bs), backingScale: bs)
            let c = g.pickToView(x: p.x, y: p.y), r = cs.px(cs.penNm > 0 ? cs.penNm : cs.defaultDiameterNm) * g.pointsPerPixel / 2
            var path = Path(); path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let pen = store.scheme.label(cs.penLabelID).map { swiftUIColor($0.color) } ?? .green
            ctx.stroke(path, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 3, dash: [3, 3]))
            ctx.stroke(path, with: .color(pen.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
        .allowsHitTesting(false)
    }
}

/// Bar at the bottom of the image: where you are, and the button that marks the section done.
struct CropHUD: View {
    @ObservedObject var model: AppModel
    @ObservedObject var cs: CropSession
    @ObservedObject var pc: PickController
    @ObservedObject var store: PickStore

    var body: some View {
        if cs.active { bar }
    }

    private var bar: some View {
        let vis = cs.visibleItems
        let removed = cs.counts.removed
        return HStack(spacing: 12) {
            if cs.tilesTotal == 0 {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("No candidates on this micrograph").font(.callout)
                Button { pc.runAutoPick() } label: { Label(pc.autoBusy ? "Working…" : "Find particles", systemImage: "sparkles") }.disabled(pc.autoBusy)
                Toggle("Empty sections too", isOn: $cs.includeEmpty).toggleStyle(.checkbox)
            } else if cs.done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("All \(cs.tilesTotal) sections done").font(.callout)
                Button("Mark micrograph done") { if let k = pc.currentKey { store.setDone(k, true) } }
                    .disabled(pc.currentKey.map { store.record($0).done } ?? true)
                Button(model.nextTitle) { model.step(1) }.buttonStyle(.borderedProminent)
                    .disabled(!model.canStep(1)).keyboardShortcut(.defaultAction)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Section \(cs.reviewedCount + 1) of \(cs.tilesTotal)").font(.callout.weight(.semibold)).monospacedDigit()
                    ProgressView(value: Double(cs.reviewedCount), total: Double(max(cs.tilesTotal, 1))).frame(width: 130)
                }
                Text("\(vis.count) circles" + (removed > 0 ? " · \(removed) removed" : "")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 4)
                Toggle(isOn: $cs.regionTool) { Label("Mark region", systemImage: "rectangle.dashed") }.toggleStyle(.button).controlSize(.small)
                    .help("Drag over ground you already know is finished to mark it done (or hold ⌥ and drag).")
                Button { cs.skip() } label: { Text("Skip") }.disabled(cs.remaining < 2).controlSize(.small).help("Put this section at the end (S)")
                Button(action: { cs.commit() }) { Text("Done  ↵") }.buttonStyle(.borderedProminent)
                    .help("Mark this section done: circles you left alone count as confirmed")
            }
            Button { cs.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!cs.canUndo).controlSize(.small).help("Undo (Z)")
            Button { cs.active = false } label: { Image(systemName: "xmark") }.controlSize(.small).help("Leave the crop editor (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 640)
        .padding(.horizontal, 14)
    }
}

/// Inspector card of the crop editor: circle type and size, how the sections are cut, and the assistant.
struct CropPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var cs: CropSession
    @ObservedObject var store: PickStore
    @ObservedObject var cl: CropClassifier
    @ObservedObject var rr: Reranker
    @ObservedObject var units = UnitSettings.shared
    @State private var showOrdering = false
    /// Inside the workflow's check step: no card around it.
    var embedded = false

    init(model: AppModel, pc: PickController, cs: CropSession, store: PickStore, embedded: Bool = false) {
        self.model = model; self.pc = pc; self.cs = cs; self.store = store; self.embedded = embedded
        self.cl = cs.classifier; self.rr = cs.rr
    }

    var body: some View {
        if embedded { content } else { Card(title: "Crop editor") { content } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            help
            Divider()
            circleSection
            Divider()
            sectionSection
            Divider()
            orderingSection
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                Text("Click empty ground to add a circle · drag a circle to move it · pinch, ↑ ↓ or the slider to resize.")
                Text("Double-click or right-click a circle (or Delete) to remove it. Removing one the picker found teaches it that it was wrong.")
                Text("Done (↵) confirms the section: circles you left alone count as confirmed, and the section turns green.")
                Text("To skip ground you already know is finished, drag over it with ⌥ held (or turn on Mark region).")
                Text("Hold ` or Space to see the bare image. Z undoes. Esc leaves.")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ t: String) -> some View { Text(t).font(.subheadline.weight(.semibold)) }

    private var circleSection: some View {
        let sel = cs.items.first { $0.id == cs.selected }
        let nm = sel?.diameterNm ?? (cs.penNm > 0 ? cs.penNm : cs.defaultDiameterNm)
        let lo = cs.defaultDiameterNm * 0.2, hi = cs.defaultDiameterNm * 4
        let cur = sel?.label ?? cs.penLabelID
        return VStack(alignment: .leading, spacing: 8) {
            title(sel == nil ? "Type of new circles" : "Type of selected circle")
            VStack(spacing: 4) { ForEach(cs.typeLabels) { typeRow($0, current: cur == $0.id) } }
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

    private var sectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Sections")
            Picker("", selection: $cs.order) { ForEach(CropSession.Order.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Stepper(value: $cs.sideDiameters, in: 2...12, step: 1) { Text(String(format: "Width: %.0f × particle", cs.sideDiameters)).font(.callout) }
                .help("Size of a section in particle diameters. Wider sections suit large particles.")
            Toggle("Include empty sections", isOn: $cs.includeEmpty).toggleStyle(.checkbox)
                .help("Also visit sections without any circle, to add particles the picker missed.")
            HStack {
                Text("\(cs.sections.count) done on this micrograph").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear marks") { cs.clearSections() }.controlSize(.small).disabled(cs.sections.isEmpty)
                    .help("Forget which sections are done. The picks stay as they are.")
            }
        }
    }

    private var orderingSection: some View {
        DisclosureGroup(isExpanded: $showOrdering) {
            VStack(alignment: .leading, spacing: 6) {
                Text(rr.status.summary).font(.caption).foregroundStyle(.secondary)
                Toggle("Core ML model", isOn: $cl.enabled).toggleStyle(.checkbox)
                    .help("Trains Apple's image classifier on the sections you finish, in the background, to order the remaining ones. The hand-feature model is used until it is ready, or when it fails.")
                Text(cl.message).font(.caption).foregroundStyle(.secondary)
                Text("Neither model decides anything: they only choose which section comes next (uncertain first).").font(.caption).foregroundStyle(.tertiary)
            }.padding(.top, 6)
        } label: { title("Learning from your decisions") }
    }
}
