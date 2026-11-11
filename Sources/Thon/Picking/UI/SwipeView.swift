import SwiftUI

struct SwipeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var sw: SwipeSession
    @ObservedObject var store: PickStore
    @ObservedObject var units = UnitSettings.shared
    @FocusState private var focused: Bool
    @AppStorage("swipe.showDisplay") private var showDisplay = true
    @AppStorage("swipe.deck") private var deckKind = "sort"

    init(model: AppModel) {
        self.model = model; self.pc = model.picks; self.sw = model.picks.swipe; self.store = model.picks.store
    }

    private let side: CGFloat = 460

    /// Sort (classify accepted picks, swipe direction = label) or Review (accept / reject auto candidates).
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $deckKind) {
                Text("Sort particles").tag("sort")
                Text("Review candidates").tag("review")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 320).padding(.top, 10)
            if deckKind == "sort" { SortView(model: model) } else { reviewBody }
        }
    }

    private var reviewBody: some View {
        VStack(spacing: 10) {
            header
            if sw.done { finished } else { card; SwipeCaption(sw: sw, pc: pc, out: Int(side), width: side + 60) }
            if !sw.done { buttons }
            DisplayPanel(sw: sw)
            settings
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: showDisplay ? 880 : 760)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0) }
        .onAppear { focused = true; sw.rebuild() }
        .onChange(of: pc.currentKey) { _, _ in sw.rebuild() }
        .onChange(of: pc.autoBusy) { _, busy in if !busy { sw.rebuild() } }
        .onChange(of: sw.depth) { _, _ in sw.rebuild() }
        .onChange(of: sw.decoyRate) { _, _ in sw.rebuild() }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text(pc.currentKey.map { ($0 as NSString).lastPathComponent } ?? "–").font(.system(.headline, design: .monospaced))
                Spacer()
                Text("\(min(sw.reviewed, sw.total)) / \(sw.total)").monospacedDigit()
                Button("Close") { model.showSwipe = false }.keyboardShortcut(.cancelAction)
            }
            ProgressView(value: Double(sw.reviewed), total: Double(max(sw.total, 1)))
            HStack(spacing: 6) {
                ForEach(store.scheme.labels.filter { $0.exported }) { l in
                    Button { pc.activeLabel = l.id } label: {
                        HStack(spacing: 4) { Circle().fill(swiftUIColor(l.color)).frame(width: 9, height: 9); Text("\(l.key) \(l.name)").lineLimit(1) }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(pc.activeLabel == l.id ? Color.accentColor.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
                Spacer()
                let s = sw.levelStats
                Text("picks \(s.pick) · rejected \(s.reject) · unsure \(s.unsure)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var card: some View {
        let drag = sw.dragOffset
        let tint: Color = abs(drag.width) >= abs(drag.height) ? (drag.width > 0 ? .green : .red) : (drag.height < 0 ? .yellow : .gray)
        let strength = min(1, max(abs(drag.width), abs(drag.height)) / 140)
        return ZStack {
            if let c = sw.current {
                if let bytes = sw.cardImage(out: Int(side)), let img = grayCGImage(bytes, width: Int(side), height: Int(side)) {
                    Image(decorative: img, scale: 1).interpolation(sw.display.pixelated ? .none : .high).resizable().frame(width: side, height: side)
                } else { Rectangle().fill(.quaternary).frame(width: side, height: side) }
                markers(c)
                if sw.display.isDenoised {      // dashed orange frame: this is not the raw image
                    RoundedRectangle(cornerRadius: 8).inset(by: 5).strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .frame(width: side, height: side).allowsHitTesting(false)
                }
                SwipeBadge(sw: sw, pc: pc).frame(width: side, height: side, alignment: .topLeading)
            }
            Rectangle().fill(tint.opacity(0.35 * strength)).frame(width: side, height: side).allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.2 + 0.8 * strength), lineWidth: 3))
        .offset(drag).rotationEffect(.degrees(Double(drag.width) / 25))
        .gesture(SpatialTapGesture().onEnded { v in
            if let p = sw.point(atFraction: Double(v.location.x / side), Double(v.location.y / side)) { sw.recenter(to: p) }
        })
        .simultaneousGesture(DragGesture(minimumDistance: 14)
            .onChanged { sw.dragOffset = $0.translation }
            .onEnded { v in
                let t = v.translation
                withAnimation(.easeOut(duration: 0.15)) { sw.dragOffset = .zero }
                if abs(t.width) > 120 && abs(t.width) >= abs(t.height) { t.width > 0 ? sw.accept() : sw.reject() }
                else if t.height < -120 { sw.unsure() }
                else if t.height > 120 { sw.later() }
            })
    }

    /// Marker circle, cross at the pick position (drawn identically for real cards and decoys) and the extraction box.
    private func markers(_ c: SwipeSession.Card) -> some View {
        let scale = side / CGFloat(sw.windowPx)
        let p = sw.currentPoint ?? CGPoint(x: c.x, y: c.y)
        let cx = side / 2 + CGFloat(p.x - c.x) * scale, cy = side / 2 + CGFloat(p.y - c.y) * scale
        let d = CGFloat(pc.diameterPx(Pick(x: 0, y: 0, label: pc.activeLabel))) * scale
        let box = CGFloat(pc.boxPx) * scale
        let col = swiftUIColor(store.scheme.label(pc.activeLabel)?.color ?? "#ffffff")
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

    private var buttons: some View {
        HStack(spacing: 14) {
            Button { sw.reject() } label: { Label("Reject", systemImage: "xmark").frame(width: 90) }.tint(.red)
            Button { sw.later() } label: { Label("Later", systemImage: "arrow.down").frame(width: 70) }
            Button { sw.unsure() } label: { Label("Unsure", systemImage: "questionmark").frame(width: 80) }.tint(.yellow)
            Button { sw.accept() } label: { Label("Particle", systemImage: "checkmark").frame(width: 90) }.tint(.green)
            Spacer().frame(width: 20)
            Button { sw.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!sw.canUndo)
        }.buttonStyle(.bordered).controlSize(.large)
    }

    private var finished: some View {
        let l = sw.levelStats, all = sw.stats
        return VStack(spacing: 12) {
            Spacer().frame(height: 10)
            Image(systemName: sw.total == 0 ? "magnifyingglass" : "checkmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            if sw.total == 0 && l.cards == 0 {
                Text("No candidates on this micrograph").font(.title3)
                Text("Run the auto-picker to generate cards (Picks tab settings apply).").foregroundStyle(.secondary)
                Button { pc.runFind() } label: { Label(pc.autoBusy ? "Working…" : "Find particles", systemImage: "sparkles") }.disabled(pc.autoBusy)
            } else {
                Text("Micrograph finished").font(.title3)
                Text("\(l.pick) particles · \(l.reject) rejected · \(l.unsure) unsure (\(l.cards) cards)")
                if let r = all.pickRateReal { Text(String(format: "All micrographs: %.0f%% of real candidates picked", r * 100)).foregroundStyle(.secondary) }
                if let d = all.pickRateDecoy {
                    Text(String(format: "Random-spot control: %.0f%% picked (%d of %d decoys)", d * 100, all.decoyPick, all.decoySeen)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Next micrograph") { model.step(1) }.disabled((model.selectedIndex ?? 0) >= model.items.count - 1).keyboardShortcut(.defaultAction)
                Button("Undo last") { sw.undo() }.disabled(!sw.canUndo)
            }
            Spacer()
        }.frame(width: side, height: side)
    }

    private var settings: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Window").font(.caption); Slider(value: $sw.windowNm, in: 20...120).frame(width: 140)
                Text(String(format: units.angstroms ? "%.0f Å" : "%.0f nm", LengthUnits.fromNm(sw.windowNm * (sw.zoomedOut ? 2.6 : 1), angstroms: units.angstroms)))
                    .font(.caption).monospacedDigit().frame(width: 58, alignment: .leading)
                Toggle("Box (B)", isOn: $sw.showBox).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Stepper("Cards/micrograph \(sw.depth)", value: $sw.depth, in: 20...1000, step: 20).font(.caption)
                HStack { Text("Decoys").font(.caption); Slider(value: $sw.decoyRate, in: 0...0.2, step: 0.02).frame(width: 70) }
            }
            AssistView(rr: sw.reranker)
            Text("→ / Enter particle · 1–9 particle with that label · ← / X reject · ↑ / U unsure · ↓ / L later · Z undo · Space zoom out · V / , . - = I 0 display (see above) · click the card to move the cross onto the true center. About 8% of cards are random spots (control); they are never exported.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: keys

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        if p.modifiers.contains(.command) { return .ignored }
        switch p.key {
        case .rightArrow, .return: sw.accept(); return .handled
        case .leftArrow: sw.reject(); return .handled
        case .upArrow: sw.unsure(); return .handled
        case .downArrow: sw.later(); return .handled
        case .escape: model.showSwipe = false; return .handled
        case .space: sw.zoomedOut.toggle(); return .handled
        default: break
        }
        let c = p.characters.lowercased()
        if sw.handleDisplayKey(c) { return .handled }
        switch c {
        case "x": sw.reject(); return .handled
        case "u": sw.unsure(); return .handled
        case "l": sw.later(); return .handled
        case "z": sw.undo(); return .handled
        case "b": sw.showBox.toggle(); return .handled
        default: break
        }
        if let l = store.scheme.label(forKey: c), l.exported { sw.accept(label: l.id); return .handled }
        return .ignored
    }
}
