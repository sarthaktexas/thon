import SwiftUI

struct SwipeView: View {
    @ObservedObject var model: AppModel
    @State private var drag: CGSize = .zero
    @State private var showStats = false

    private let threshold: CGFloat = 100

    var body: some View {
        VStack(spacing: 10) {
            topBar
            content
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: $showStats) { StatsView(model: model) }
        .overlay(alignment: .bottom) {
            if let t = model.toast { Text(t).padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 90) }
        }
    }

    // MARK: pieces

    private var topBar: some View {
        let L = model.state?.level
        let done = min((L?.reviewed ?? 0) + 0, L?.total ?? 0)
        return VStack(spacing: 4) {
            HStack {
                Text(L?.name ?? "Thon").font(.headline).lineLimit(1)
                if !model.online { Image(systemName: "wifi.slash").foregroundStyle(.orange) }
                if !model.outbox.items.isEmpty { Text("\(model.outbox.items.count) to sync").font(.caption).padding(.horizontal, 6).background(.orange.opacity(0.3), in: Capsule()) }
                Spacer()
                if let t = L?.total, t > 0 { Text("\(done + model.outbox.items.count) / \(t)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                Button { showStats = true } label: { Image(systemName: "line.3.horizontal") }.padding(.leading, 6)
            }
            ProgressView(value: Double(done + model.outbox.items.count), total: Double(max(L?.total ?? 1, 1)))
        }
        .padding(.top, 6)
    }

    @ViewBuilder private var content: some View {
        if model.authBad {
            message("Not paired", "The Mac does not accept this phone. Reset pairing in Thon, then connect again.", [("Disconnect", { model.disconnect(forget: true) })])
        } else if let s = model.state {
            let L = s.level
            if L.loading == true { message("Opening micrograph…", "The Mac is loading it.", []) }
            else if L.key == nil { message("No micrograph open", "Open a micrograph in Thon, then run Find particles.", []) }
            else if L.empty == true {
                message("No candidates here", L.autoBusy == true ? "Finding particles on the Mac…" : "Run the auto-picker on this micrograph, or skip it.",
                        [("Find particles", { Task { await model.autopick() } }), ("Next micrograph", { Task { await model.level("next") } }), ("Previous", { Task { await model.level("prev") } })])
            } else if model.deck.isEmpty {
                if !model.outbox.items.isEmpty { message("Syncing…", "\(model.outbox.items.count) decisions waiting for the Mac.", []) }
                else {
                    let l = s.stats.level
                    message("Micrograph finished", "\(l.pick ?? 0) picked, \(l.reject ?? 0) rejected, \(l.unsure ?? 0) unsure (\(l.cards ?? 0) cards).",
                            [("Next micrograph", { Task { await model.level("next") } }), ("Stats", { showStats = true })])
                }
            } else { deckView(s) }
        } else { message("Connecting…", model.online ? "" : "Waiting for the Mac.", []) }
    }

    private func message(_ title: String, _ detail: String, _ buttons: [(String, () -> Void)]) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in Button(b.0, action: b.1).buttonStyle(.bordered) }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func deckView(_ s: PhoneState) -> some View {
        let refs = model.deck
        let sel = s.exportedLabels.first { $0.id == model.selectedLabel }
        return VStack(spacing: 10) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ZStack {
                    if refs.count > 1 { cardImage(refs[1], side: side).opacity(0.6).scaleEffect(0.96) }
                    ZStack {
                        cardImage(refs[0], side: side)
                        Canvas { ctx, size in drawMarker(&ctx, size: size, card: s.card, color: Color(hex: sel?.color ?? "#ffffff")) }
                            .allowsHitTesting(false)
                        Rectangle().fill(tint).allowsHitTesting(false)
                    }
                    .frame(width: side, height: side)
                    .offset(drag).rotationEffect(.degrees(Double(drag.width) / 25))
                    .gesture(DragGesture(minimumDistance: 8)
                        .onChanged { if !model.animating { drag = $0.translation } }
                        .onEnded { end($0.translation) })
                    .simultaneousGesture(SpatialTapGesture().onEnded { t in
                        let u = t.location.x / side, v = t.location.y / side
                        if (0...1).contains(u) && (0...1).contains(v) { model.cross = CGPoint(x: u, y: v) }
                    })
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            chips(s)
            buttons(s)
        }
    }

    private func cardImage(_ ref: String, side: CGFloat) -> some View {
        Group {
            if let img = model.images[ref] { Image(uiImage: img).resizable().interpolation(.high).scaledToFit() }
            else { Rectangle().fill(.black).overlay(ProgressView()) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func drawMarker(_ ctx: inout GraphicsContext, size: CGSize, card: CardInfo?, color: Color) {
        guard let c = card else { return }
        let w = size.width
        let cx = model.cross.x * w, cy = model.cross.y * size.height
        let r = c.diameterFrac * w / 2, b = c.boxFrac * w / 2
        let circle = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        ctx.stroke(circle, with: .color(.black.opacity(0.6)), lineWidth: 3.5)
        ctx.stroke(circle, with: .color(color), lineWidth: 2)
        ctx.stroke(Path(CGRect(x: cx - b, y: cy - b, width: 2 * b, height: 2 * b)), with: .color(.white.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        var cross = Path(); let k: CGFloat = 8
        cross.move(to: CGPoint(x: cx - k, y: cy)); cross.addLine(to: CGPoint(x: cx + k, y: cy))
        cross.move(to: CGPoint(x: cx, y: cy - k)); cross.addLine(to: CGPoint(x: cx, y: cy + k))
        ctx.stroke(cross, with: .color(Color(red: 1, green: 0.3, blue: 0.3)), lineWidth: 1.6)
    }

    private var tint: Color {
        let dx = drag.width, dy = drag.height
        let horiz = abs(dx) >= abs(dy)
        let c: Color = horiz ? (dx > 0 ? .green : .red) : (dy < 0 ? .yellow : .gray)
        return c.opacity(0.35 * min(1, Double(max(abs(dx), abs(dy))) / 140))
    }

    private func end(_ t: CGSize) {
        guard !model.animating else { return }
        if abs(t.width) > threshold && abs(t.width) >= abs(t.height) { fly(t.width > 0 ? .pick : .reject) }
        else if t.height < -threshold { fly(.unsure) }
        else if t.height > threshold { fly(.later) }
        else { withAnimation(.easeOut(duration: 0.15)) { drag = .zero } }
    }

    private func fly(_ kind: Decision) {
        guard !model.animating else { return }
        model.animating = true
        let to: CGSize = { switch kind { case .pick: return CGSize(width: 600, height: 0); case .reject: return CGSize(width: -600, height: 0)
                                          case .unsure: return CGSize(width: 0, height: -700); case .later: return CGSize(width: 0, height: 700) } }()
        withAnimation(.easeOut(duration: 0.17)) { drag = to }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { drag = .zero }
            model.animating = false
            model.decide(kind)
        }
    }

    private func chips(_ s: PhoneState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(s.exportedLabels) { l in
                    Button { model.chooseLabel(l.id) } label: {
                        HStack(spacing: 4) { Circle().fill(Color(hex: l.color)).frame(width: 9, height: 9); Text("\(l.key) \(l.name)") }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(model.selectedLabel == l.id ? Color.white.opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func buttons(_ s: PhoneState) -> some View {
        HStack(spacing: 14) {
            roundButton("arrow.uturn.backward", .gray, enabled: model.outbox.items.isEmpty && s.canUndo) { Task { await model.undo() } }
            roundButton("xmark", .red, enabled: true) { fly(.reject) }
            roundButton("arrow.down", .gray, enabled: true) { fly(.later) }
            roundButton("questionmark", .yellow, enabled: true) { fly(.unsure) }
            roundButton("checkmark", .green, enabled: true) { fly(.pick) }
        }.padding(.bottom, 8)
    }

    private func roundButton(_ icon: String, _ color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.bold()).frame(width: 54, height: 54)
                .background(color.opacity(enabled ? 0.28 : 0.1), in: Circle())
        }.disabled(!enabled)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0xFFFFFF
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}
