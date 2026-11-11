import SwiftUI

/// Sort mode: classify accepted picks by swiping. Each direction is assigned a label (colour-coded legend on the right).
struct SortView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var sw: SwipeSession
    @ObservedObject var so: SortSession
    @ObservedObject var store: PickStore
    @ObservedObject var units = UnitSettings.shared
    @FocusState private var focused: Bool
    @AppStorage("swipe.showDisplay") private var showDisplay = true

    init(model: AppModel) {
        self.model = model; self.pc = model.picks; self.sw = model.picks.swipe; self.so = model.picks.sort; self.store = model.picks.store
    }

    private let side: CGFloat = 460

    var body: some View {
        VStack(spacing: 8) {
            header
            if so.done { finished } else {
                HStack(alignment: .top, spacing: 16) { card; legend }
                SwipeCaption(sw: sw, pc: pc, out: Int(side), width: side + 60)
            }
            DisplayPanel(sw: sw)
            settings
        }
        .padding(16)
        .frame(minWidth: 740, minHeight: showDisplay ? 860 : 740)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0) }
        .onAppear { focused = true; so.rebuild() }
        .onChange(of: pc.currentKey) { _, _ in so.rebuild() }
        .onChange(of: so.scope) { _, _ in so.rebuild() }
        .onChange(of: pc.autoBusy) { _, busy in if !busy { so.rebuild() } }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text(pc.currentKey.map { ($0 as NSString).lastPathComponent } ?? "–").font(.system(.headline, design: .monospaced))
                Spacer()
                Picker("", selection: $so.scope) { ForEach(SortScope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Text("\(min(so.reviewed, so.total)) / \(so.total)").monospacedDigit()
                Button("Close") { model.showSwipe = false }.keyboardShortcut(.cancelAction)
            }
            ProgressView(value: Double(so.reviewed), total: Double(max(so.total, 1)))
            HStack(spacing: 10) {
                let counts = pc.currentKey.map { store.counts($0) } ?? [:]
                ForEach(store.scheme.labels) { l in
                    HStack(spacing: 4) {
                        Circle().fill(swiftUIColor(l.color)).frame(width: 9, height: 9)
                        Text("\(l.name) \(counts[l.id] ?? 0)").lineLimit(1)
                    }.font(.caption)
                }
                Spacer()
            }
        }
    }

    private var card: some View {
        let drag = so.dragOffset
        let dir = SortSession.direction(of: drag)
        let action = dir.map { so.map[$0] }
        let tint: Color = action.map { swiftUIColor(so.actionColor($0)) } ?? .clear
        let strength = min(1, max(abs(drag.width), abs(drag.height)) / 140)
        return ZStack {
            if let c = so.current {
                if let bytes = so.cardImage(out: Int(side)), let img = grayCGImage(bytes, width: Int(side), height: Int(side)) {
                    Image(decorative: img, scale: 1).interpolation(sw.display.pixelated ? .none : .high).resizable().frame(width: side, height: side)
                } else { Rectangle().fill(.quaternary).frame(width: side, height: side) }
                markers(c)
                if sw.display.isDenoised {
                    RoundedRectangle(cornerRadius: 8).inset(by: 5).strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .frame(width: side, height: side).allowsHitTesting(false)
                }
                SwipeBadge(sw: sw, pc: pc).frame(width: side, height: side, alignment: .topLeading)
                SwipeEdgeHints(hints: Dictionary(uniqueKeysWithValues: SwipeDir.allCases.map { ($0, SwipeEdgeHints.Hint(text: so.actionName(so.map[$0]), colorHex: so.actionColor(so.map[$0]))) }),
                               active: dir, side: side)
            }
            Rectangle().fill(tint.opacity(0.35 * strength)).frame(width: side, height: side).allowsHitTesting(false)
            if let a = action, strength > 0.25 {        // name of what releasing the card will do
                Text(so.actionName(a)).font(.title2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(tint.opacity(0.9), in: Capsule())
                    .frame(width: side, height: side, alignment: .top).padding(.top, 14).allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(action != nil ? tint.opacity(0.3 + 0.7 * strength) : Color.secondary.opacity(0.3), lineWidth: 3))
        .offset(drag).rotationEffect(.degrees(Double(drag.width) / 25))
        .gesture(SpatialTapGesture().onEnded { v in
            if let p = so.point(atFraction: Double(v.location.x / side), Double(v.location.y / side)) { so.recenter(to: p) }
        })
        .simultaneousGesture(DragGesture(minimumDistance: 14)
            .onChanged { so.dragOffset = $0.translation }
            .onEnded { v in
                let t = v.translation
                withAnimation(.easeOut(duration: 0.15)) { so.dragOffset = .zero }
                if max(abs(t.width), abs(t.height)) > 120, let d = SortSession.direction(of: t) { so.swipe(d) }
            })
    }

    /// Circle in the pick's current label colour (white while it is still unsorted), cross at the pick position, extraction box.
    private func markers(_ c: SortSession.Card) -> some View {
        let scale = side / CGFloat(sw.windowPx)
        let p = so.currentPoint ?? CGPoint(x: c.x, y: c.y)
        let cx = side / 2 + CGFloat(p.x - c.x) * scale, cy = side / 2 + CGFloat(p.y - c.y) * scale
        let d = CGFloat(pc.diameterPx(Pick(x: 0, y: 0, label: c.label))) * scale
        let box = CGFloat(pc.boxPx) * scale
        let sorted = isSorted(c.id, in: store.record(pc.currentKey ?? "").swipe)
        let col = sorted ? swiftUIColor(store.scheme.label(c.label)?.color ?? "#ffffff") : Color.white
        return ZStack {
            Circle().stroke(.black.opacity(0.6), lineWidth: 3.5).frame(width: d, height: d).position(x: cx, y: cy)
            Circle().stroke(col, lineWidth: 1.6).frame(width: d, height: d).position(x: cx, y: cy)
            if sw.showBox {
                Rectangle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4])).frame(width: box, height: box).position(x: cx, y: cy)
            }
            Path { q in
                q.move(to: CGPoint(x: cx - 9, y: cy)); q.addLine(to: CGPoint(x: cx + 9, y: cy))
                q.move(to: CGPoint(x: cx, y: cy - 9)); q.addLine(to: CGPoint(x: cx, y: cy + 9))
            }.stroke(.red, lineWidth: 1.5)
        }.frame(width: side, height: side).allowsHitTesting(false)
    }

    // MARK: legend + direction setup

    private var legend: some View {
        let active = SortSession.direction(of: so.dragOffset)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Swipe or press an arrow").font(.caption).foregroundStyle(.secondary)
            ForEach([SwipeDir.up, .right, .down, .left]) { d in
                let a = so.map[d]
                Button { so.swipe(d) } label: {
                    HStack(spacing: 8) {
                        Text(d.arrow).font(.system(size: 17, weight: .bold)).frame(width: 22)
                        Text(so.actionName(a)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).frame(width: 214)
                    .background(swiftUIColor(so.actionColor(a)).opacity(active == d ? 0.95 : 0.55), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.white)
                    .scaleEffect(active == d ? 1.05 : 1)
                }.buttonStyle(.plain)
            }
            let assigned = Set([SwipeDir.up, .right, .down, .left].compactMap { d -> String? in if case .label(let id) = so.map[d] { return id } else { return nil } })
            let others = store.scheme.labels.filter { !assigned.contains($0.id) }
            if !others.isEmpty {
                Text("Other labels (click or key)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(others) { l in
                    Button { so.label(l.id) } label: {
                        HStack(spacing: 8) {
                            Text(l.key).font(.system(.caption, design: .monospaced).bold()).frame(width: 22)
                            Text(l.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).frame(width: 214)
                        .background(swiftUIColor(l.color).opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Button { so.dismiss() } label: { Label("Dismiss (X)", systemImage: "xmark") }
                Button { so.later() } label: { Label("Later (L)", systemImage: "arrow.down.to.line") }
            }.controlSize(.small).padding(.top, 4)
            Button { so.undo() } label: { Label("Undo (Z)", systemImage: "arrow.uturn.backward") }.controlSize(.small).disabled(!so.canUndo)
            DisclosureGroup("Change directions") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([SwipeDir.up, .right, .down, .left]) { d in
                        HStack {
                            Text(d.arrow).frame(width: 18)
                            Picker("", selection: actionBinding(d)) {
                                ForEach(store.scheme.labels) { l in Text(l.name).tag("label:" + l.id) }
                                Divider()
                                Text("Dismiss (not a particle)").tag("dismiss")
                                Text("Later").tag("later")
                            }.labelsHidden().controlSize(.small)
                        }
                    }
                    Button("Reset to defaults") { so.resetMap() }.controlSize(.small)
                }.padding(.top, 2)
            }.font(.caption).frame(width: 214)
            Spacer(minLength: 0)
        }.frame(width: 214, height: side, alignment: .top)
    }

    private func actionBinding(_ d: SwipeDir) -> Binding<String> {
        Binding(get: { so.map[d].code }, set: { if let a = SortAction(code: $0) { so.map[d] = a } })
    }

    private var finished: some View {
        let key = pc.currentKey ?? ""
        let counts = store.counts(key)
        let pending = so.pendingCount(key)
        return VStack(spacing: 12) {
            Spacer().frame(height: 10)
            if so.total == 0 && so.reviewed == 0 {
                Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(so.scope == .unsorted ? "Nothing left to sort on this micrograph" : "No accepted picks on this micrograph").font(.title3)
                Text("Accepted auto-picks that have not been sorted yet show up here. Accept candidates first in the grid triage.").foregroundStyle(.secondary)
                HStack {
                    Button("Open crop editor") { model.showSwipe = false; model.showCrops = true }
                    if so.scope == .unsorted { Button("Show all picks") { so.scope = .all } }
                }
            } else {
                Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Micrograph sorted").font(.title3)
                Text(store.scheme.labels.compactMap { l in counts[l.id].map { "\($0) \(l.name)" } }.joined(separator: " · "))
                if pending > 0 { Text("\(pending) still unsorted (sent to later)").foregroundStyle(.secondary) }
            }
            HStack {
                Button("Next micrograph") { model.step(1) }.disabled((model.selectedIndex ?? 0) >= model.items.count - 1).keyboardShortcut(.defaultAction)
                Button("Undo last") { so.undo() }.disabled(!so.canUndo)
            }
            Spacer()
        }.frame(width: side + 230, height: side)
    }

    private var settings: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Window").font(.caption); Slider(value: $sw.windowNm, in: 20...120).frame(width: 140)
                Text(String(format: units.angstroms ? "%.0f Å" : "%.0f nm", LengthUnits.fromNm(sw.windowNm * (sw.zoomedOut ? 2.6 : 1), angstroms: units.angstroms)))
                    .font(.caption).monospacedDigit().frame(width: 58, alignment: .leading)
                Toggle("Box (B)", isOn: $sw.showBox).toggleStyle(.checkbox).font(.caption)
                Spacer()
            }
            Text("Arrows or drag: label of that direction · 1–9 any label · X dismiss · L later · Z undo · Space zoom out · click the card to move the cross onto the true center. Circle is white until a pick is sorted.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: keys

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        if p.modifiers.contains(.command) { return .ignored }
        switch p.key {
        case .upArrow: so.swipe(.up); return .handled
        case .rightArrow: so.swipe(.right); return .handled
        case .downArrow: so.swipe(.down); return .handled
        case .leftArrow: so.swipe(.left); return .handled
        case .escape: model.showSwipe = false; return .handled
        case .space: sw.zoomedOut.toggle(); return .handled
        default: break
        }
        let c = p.characters.lowercased()
        if sw.handleDisplayKey(c) { return .handled }
        switch c {
        case "x": so.dismiss(); return .handled
        case "l": so.later(); return .handled
        case "z": so.undo(); return .handled
        case "b": sw.showBox.toggle(); return .handled
        default: break
        }
        if let l = store.scheme.label(forKey: c) { so.label(l.id); return .handled }
        return .ignored
    }
}
