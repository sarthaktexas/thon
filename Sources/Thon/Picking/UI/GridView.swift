import SwiftUI

/// Rendered tiles of the current page; cleared whenever anything that changes pixels changes.
final class GridTileCache {
    private var sig = ""
    private var images: [String: CGImage] = [:]
    func image(id: String, sig s: String, make: () -> CGImage?) -> CGImage? {
        if s != sig { sig = s; images = [:] }
        if let i = images[id] { return i }
        let i = make(); if let i { images[id] = i }
        return i
    }
}

/// Grid triage: click the real particles on an n x n page of candidate crops, Enter commits the page.
struct GridView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var sw: SwipeSession
    @ObservedObject var gr: GridSession
    @ObservedObject var store: PickStore
    @FocusState private var focused: Bool
    @State private var cache = GridTileCache()
    @AppStorage("swipe.showDisplay") private var showDisplay = true

    init(model: AppModel) {
        self.model = model; self.pc = model.picks; self.sw = model.picks.swipe; self.gr = model.picks.grid; self.store = model.picks.store
    }

    private let gridSide: CGFloat = 600
    private let gap: CGFloat = 6

    private var tile: CGFloat { (gridSide - gap * CGFloat(gr.n - 1)) / CGFloat(gr.n) }

    var body: some View {
        VStack(spacing: 8) {
            header
            if gr.done { finished } else {
                grid
                SwipeCaption(sw: sw, pc: pc, out: Int(tile), width: gridSide)
                controls
            }
            DisplayPanel(sw: sw, keysHint: "V denoise · , . brightness · - = contrast · I invert · 0 reset")
            Text(helpText).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(minWidth: 660, minHeight: showDisplay ? 880 : 760)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0) }
        .onAppear { focused = true; gr.rebuild() }
        .onChange(of: pc.currentKey) { _, _ in gr.rebuild() }
        .onChange(of: pc.autoBusy) { _, busy in if !busy { gr.rebuild() } }
        .onChange(of: gr.depth) { _, _ in gr.rebuild() }
        .onChange(of: sw.decoyRate) { _, _ in gr.rebuild() }
    }

    private var helpText: String {
        let what = gr.junkMode ? "Click tiles that are NOT particles; unmarked tiles are accepted." : "Click the real particles; unmarked tiles are rejected."
        return "\(what) Right-click or U = unsure (stays a candidate). Arrows + Space move and toggle · A mark all · C clear · Enter commit page · Z undo page. About \(Int((sw.decoyRate * 100).rounded())) % of tiles are random spots (control); they are never exported."
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text(pc.currentKey.map { ($0 as NSString).lastPathComponent } ?? "–").font(.system(.headline, design: .monospaced))
                Spacer()
                if !gr.done { Text("page \(gr.pageIndex + 1) / \(gr.pageCount)").monospacedDigit() }
                Button("Close") { model.showGrid = false }.keyboardShortcut(.cancelAction)
            }
            ProgressView(value: Double(min(gr.start, gr.deck.count)), total: Double(max(gr.deck.count, 1)))
            HStack {
                let c = gr.levelCounts
                Text("this micrograph: \(c.particles) particles · \(c.rejected) rejected · \(c.unsure) unsure").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let r = gr.decoyRate {
                    Text(String(format: "random-spot control: %.0f %% marked (%d spots)", r * 100, gr.decoySeen)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var grid: some View {
        let cards = gr.page
        let cols = Array(repeating: GridItem(.fixed(tile), spacing: gap), count: gr.n)
        let t = tile
        return LazyVGrid(columns: cols, spacing: gap) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, c in
                tileView(c, index: idx, size: t)
            }
        }
        .frame(width: gridSide, alignment: .topLeading)
    }

    private func tileView(_ c: SwipeSession.Card, index: Int, size: CGFloat) -> some View {
        let px = Int(size)
        let sig = "\(pc.currentKey ?? "")|\(pc.pixels.count)|\(sw.windowPx)|\(px)|\(sw.display)"
        let img = cache.image(id: c.id, sig: sig) {
            sw.image(id: c.id, x: c.x, y: c.y, out: px).flatMap { grayCGImage($0, width: px, height: px) }
        }
        let isUnsure = gr.unsure.contains(c.id)
        let isP = gr.isParticle(c)
        let marked = gr.clicked.contains(c.id)
        let d = CGFloat(pc.diameterPx(Pick(x: 0, y: 0, label: pc.activeLabel))) * size / CGFloat(sw.windowPx)
        return ZStack {
            if let img { Image(decorative: img, scale: 1).interpolation(sw.display.pixelated ? .none : .high).resizable().frame(width: size, height: size) }
            else { Rectangle().fill(.quaternary) }
            if gr.showCircle {
                Circle().stroke(.black.opacity(0.5), lineWidth: 2.5).frame(width: d, height: d)
                Circle().stroke(.white.opacity(0.75), lineWidth: 1).frame(width: d, height: d)
            }
            if sw.display.isDenoised {
                Rectangle().strokeBorder(Color.orange.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).padding(3)
            }
            Rectangle().fill(markColor(isP: isP, isUnsure: isUnsure).opacity(isUnsure || marked ? 0.12 : 0))
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) { markBadge(isP: isP, isUnsure: isUnsure, marked: marked) }
        .overlay(alignment: .topLeading) { if index == 0 { SwipeBadge(sw: sw, pc: pc, compact: true).padding(4) } }
        .overlay(Rectangle().strokeBorder(markColor(isP: isP, isUnsure: isUnsure), lineWidth: isUnsure || isP || marked ? 4 : 0))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(gr.cursor == index ? 0.9 : 0), lineWidth: 2).padding(1))
        .contentShape(Rectangle())
        .onTapGesture { gr.cursor = index; gr.toggle(c.id) }
        .contextMenu {
            Button(isUnsure ? "Clear unsure" : "Mark unsure (U)") { gr.toggleUnsure(c.id) }
            Button("Clear mark") { if gr.clicked.contains(c.id) { gr.toggle(c.id) }; if gr.unsure.contains(c.id) { gr.toggleUnsure(c.id) } }
        }
    }

    /// Green = will be accepted, yellow = unsure, red = will be rejected because it is marked as junk.
    private func markColor(isP: Bool, isUnsure: Bool) -> Color {
        if isUnsure { return .yellow }
        return isP ? .green : .red
    }

    @ViewBuilder private func markBadge(isP: Bool, isUnsure: Bool, marked: Bool) -> some View {
        if isUnsure {
            Text("?").font(.system(size: 16, weight: .bold)).foregroundStyle(.black).frame(width: 24, height: 24).background(Color.yellow, in: Circle()).padding(5)
        } else if isP {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 24, height: 24).background(Color.green, in: Circle()).padding(5)
        } else if marked {                // junk mode: a marked tile is not a particle
            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 24, height: 24).background(Color.red, in: Circle()).padding(5)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $gr.n) { Text("3×3").tag(3); Text("4×4").tag(4) }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
            Picker("", selection: $gr.junkMode) { Text("Click particles").tag(false); Text("Click junk").tag(true) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Toggle("Circle", isOn: $gr.showCircle).toggleStyle(.checkbox).font(.caption)
            Button("Mark all (A)") { gr.markAll() }.controlSize(.small)
            Button("Clear (C)") { gr.clearPage() }.controlSize(.small)
            Spacer()
            Button { gr.undo() } label: { Label("Undo page (Z)", systemImage: "arrow.uturn.backward") }.disabled(!gr.canUndo).controlSize(.small)
            let p = gr.particleCount, u = gr.unsureCount, r = gr.page.count - p - u
            Button { gr.commit() } label: { Text("Commit  ✓\(p)  ✗\(r)\(u > 0 ? "  ?\(u)" : "")  ↵") }
                .buttonStyle(.borderedProminent).controlSize(.regular)
        }
    }

    private var finished: some View {
        let c = gr.levelCounts
        let pending = pc.currentKey.map { pc.sort.pendingCount($0) } ?? 0
        return VStack(spacing: 12) {
            Spacer().frame(height: 10)
            Image(systemName: gr.deck.isEmpty ? "magnifyingglass" : "checkmark.circle").font(.system(size: 44)).foregroundStyle(.secondary)
            if gr.deck.isEmpty {
                Text("No candidates on this micrograph").font(.title3)
                Text("Run the auto-picker to generate candidates (Picks tab settings apply).").foregroundStyle(.secondary)
                Button { pc.runAutoPick() } label: { Label(pc.autoBusy ? "Working…" : "Find particles", systemImage: "sparkles") }.disabled(pc.autoBusy)
            } else {
                Text("Micrograph triaged").font(.title3)
                Text("\(c.particles) particles · \(c.rejected) rejected · \(c.unsure) unsure")
                if pending > 0 { Text("\(pending) accepted picks are waiting to be sorted into labels").foregroundStyle(.secondary) }
            }
            HStack {
                if pending > 0 {
                    Button("Sort these particles →") { model.showGrid = false; UserDefaults.standard.set("sort", forKey: "swipe.deck"); model.showSwipe = true }
                        .buttonStyle(.borderedProminent)
                }
                Button("Next micrograph") { model.step(1) }.disabled((model.selectedIndex ?? 0) >= model.items.count - 1).keyboardShortcut(.defaultAction)
                Button("Undo last page") { gr.undo() }.disabled(!gr.canUndo)
            }
            Spacer()
        }.frame(width: gridSide, height: gridSide)
    }

    // MARK: keys

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        if p.modifiers.contains(.command) { return .ignored }
        switch p.key {
        case .leftArrow: gr.moveCursor(dx: -1, dy: 0); return .handled
        case .rightArrow: gr.moveCursor(dx: 1, dy: 0); return .handled
        case .upArrow: gr.moveCursor(dx: 0, dy: -1); return .handled
        case .downArrow: gr.moveCursor(dx: 0, dy: 1); return .handled
        case .return: if !gr.done { gr.commit() }; return .handled
        case .space: if gr.cursor < gr.page.count { gr.toggle(gr.page[gr.cursor].id) }; return .handled
        case .escape: model.showGrid = false; return .handled
        default: break
        }
        let c = p.characters.lowercased()
        if sw.handleDisplayKey(c) { return .handled }
        switch c {
        case "u": if gr.cursor < gr.page.count { gr.toggleUnsure(gr.page[gr.cursor].id) }; return .handled
        case "a": gr.markAll(); return .handled
        case "c": gr.clearPage(); return .handled
        case "z": gr.undo(); return .handled
        default: return .ignored
        }
    }
}
