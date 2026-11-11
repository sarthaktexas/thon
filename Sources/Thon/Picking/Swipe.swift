import Foundation
import Combine
import CoreGraphics

/// One reviewed card, kept per micrograph for statistics and the exported `swipe_decisions.csv`.
struct SwipeDecision: Codable, Equatable {
    var id: String                    // pick id for real cards, "d<n>" for decoys
    var decision: String              // pick | reject | unsure
    var label: String?
    var x: Double, y: Double
    var decoy = false
    var recentered = false
    var ms: Int?                      // dwell time
    var t: Double?                    // epoch seconds
    var view: String?                 // what the card looked like when decided (SwipeDisplay.logTag), nil in older logs
    var mode: String?                 // nil / "swipe": candidate review; "grid": old grid triage; "sort": classification of accepted picks; "crop": crop editor

    enum CodingKeys: String, CodingKey { case id, decision, label, x, y, decoy, recentered, ms, t, view, mode }
}

/// Optional keys (`decoy`, `recentered`, `ms`, `t`, `view`, `mode`) may be absent when decoding.
/// (Encoding is synthesized.)
extension SwipeDecision {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        decision = try c.decode(String.self, forKey: .decision)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        decoy = try c.decodeIfPresent(Bool.self, forKey: .decoy) ?? false
        recentered = try c.decodeIfPresent(Bool.self, forKey: .recentered) ?? false
        ms = try c.decodeIfPresent(Int.self, forKey: .ms)
        t = try c.decodeIfPresent(Double.self, forKey: .t)
        view = try c.decodeIfPresent(String.self, forKey: .view)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
    }
}

struct SwipeLog: Codable, Equatable {
    var decisions: [SwipeDecision] = []
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        decisions = try c.decodeIfPresent([SwipeDecision].self, forKey: .decisions) ?? []
    }
}

struct SwipeStats: Equatable {
    var cards = 0, pick = 0, reject = 0, unsure = 0
    var decoySeen = 0, decoyPick = 0, realSeen = 0, realPick = 0, recentered = 0
    var sorted = 0                        // picks classified in sort mode (not part of the pick / reject statistics)
    var pickRateReal: Double? { realSeen > 0 ? Double(realPick) / Double(realSeen) : nil }
    var pickRateDecoy: Double? { decoySeen > 0 ? Double(decoyPick) / Double(decoySeen) : nil }

    static func compute(_ logs: [SwipeLog]) -> SwipeStats {
        var s = SwipeStats()
        for l in logs { for d in l.decisions {
            if d.mode == "crop" { continue }                       // crop-editor decisions are confirmations of circles, not candidate reviews
            if d.mode == "sort" { s.sorted += 1; continue }       // classification of already accepted picks says nothing about pick rates
            s.cards += 1
            switch d.decision { case "pick": s.pick += 1; case "reject": s.reject += 1; default: s.unsure += 1 }
            if d.recentered { s.recentered += 1 }
            if d.decoy { s.decoySeen += 1; if d.decision == "pick" { s.decoyPick += 1 } }
            else { s.realSeen += 1; if d.decision == "pick" { s.realPick += 1 } }
        } }
        return s
    }
}

/// FNV-1a: a stable hash (Swift's hashValue changes between runs) used to seed the decoy generator.
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// Card-deck review of auto-picked candidates, one micrograph at a time ("level").
final class SwipeSession: ObservableObject {
    struct Card: Equatable { var id: String; var x: Double; var y: Double; var score: Float?; var decoy: Bool }

    unowned let pc: PickController
    @Published private(set) var queue: [Card] = []
    @Published private(set) var total = 0                      // cards in this level (when built)
    @Published private(set) var reviewed = 0                   // cards decided in this level (this session)
    @Published var windowNm = 45.0
    @Published var zoomedOut = false
    @Published var showBox = true
    @Published var override: CGPoint?                          // re-centered position of the current card
    @Published var decoyRate = 0.08
    @Published var depth = 100
    @Published private(set) var revision = 0
    /// Micrograph key the current deck was built for (nil = no deck); the phone server rebuilds when it differs from the open micrograph.
    private(set) var builtKey: String?
    /// Brightness / contrast / denoise of the card image. Display only: never changes picks or exports.
    @Published var display = SwipeDisplay() { didSet { if display.denoise != .none { lastMethod = display.denoise } } }
    /// When off (default), denoising reverts to raw on every new card; brightness / contrast settings always stay.
    @Published var pinProcessing = false
    private(set) var lastMethod = SwipeDenoise.gaussian
    private var plateCache: [String: CardPlate] = [:]
    private var lastPlate: CardPlate?
    @Published var dragOffset = CGSize.zero                    // live card offset while dragging (UI)
    private var windowCache: (key: String, count: Int, lo: Float, hi: Float)?
    private(set) var shownAt = Date()
    private var history: [(card: Card, kind: String, key: String, serial: Int?, wasRecentered: Bool)] = []
    private var bag = Set<AnyCancellable>()
    /// Learns from decisions and reorders the waiting cards (see Assist/).
    let reranker = Reranker()
    var assistReordered = false

    init(pc: PickController) { self.pc = pc; reranker.onChange = { [weak self] in self?.assistReorder() } }

    var current: Card? { queue.first }
    var done: Bool { queue.isEmpty }
    var effectiveWindowNm: Double { windowNm * (zoomedOut ? 2.6 : 1) }
    var windowPx: Double { effectiveWindowNm * 10 / pc.effectiveAngpix }
    /// Where the cross is drawn / what will be exported if the card is accepted.
    var currentPoint: CGPoint? { current.map { override ?? CGPoint(x: $0.x, y: $0.y) } }

    /// Robust display window of the current micrograph (cached).
    func displayWindow() -> (lo: Float, hi: Float) {
        let k = pc.currentKey ?? ""
        if let w = windowCache, w.key == k, w.count == pc.pixels.count { return (w.lo, w.hi) }
        let w = pc.pixels.isEmpty ? (lo: Float(0), hi: Float(1)) : robustWindow(pc.pixels)
        windowCache = (k, pc.pixels.count, w.lo, w.hi)
        return w
    }

    /// Card image (8-bit gray, `out` x `out`) for the current card, with the current `display` settings.
    /// The crop is centered on the card, not on the re-centered cross.
    func cardImage(out: Int) -> [UInt8]? {
        guard let c = current else { return nil }
        return image(id: c.id, x: c.x, y: c.y, out: out)
    }

    /// Image of the crop around (x, y) with the current display settings, for any deck (review, grid, sort).
    /// Denoised crops are cached per card id and denoise settings (up to 48 at a time).
    func image(id: String, x: Double, y: Double, out: Int) -> [UInt8]? {
        guard !pc.pixels.isEmpty else { return nil }
        let d = display
        let w = Int(pc.imageSize.width), h = Int(pc.imageSize.height)
        let sig = "\(pc.currentKey ?? "")|\(pc.pixels.count)|\(id)|\(x),\(y)|\(windowPx)|\(out)|\(d.denoise.rawValue)|\(d.size)|\(d.h)"
        let plate: CardPlate
        if let hit = plateCache[sig] { plate = hit }
        else {
            plate = CardPlate.make(pixels: pc.pixels, width: w, height: h, cx: x, cy: y, boxPx: windowPx, out: out,
                                   denoise: d.denoise, size: d.size, h: d.h)
            if plateCache.count >= 48 { plateCache.removeAll() }
            plateCache[sig] = plate
        }
        lastPlate = plate
        let win = d.window(base: d.tone == .micrograph ? displayWindow() : plate.localWindow())
        return plate.render(out: out, lo: win.lo, hi: win.hi, gamma: Float(d.gamma), invert: d.invert, nearest: d.pixelated)
    }

    /// A new page or deck is on screen: drop temporary denoising unless pinned.
    func viewChanged() { if !pinProcessing { display.denoise = .none } }

    /// Shared display keys for every swipe-like view: V denoise on/off, `,` `.` brightness, `-` `=` contrast, I invert, 0 reset.
    func handleDisplayKey(_ c: String) -> Bool {
        switch c {
        case "v": toggleDenoise()
        case "i": display.invert.toggle()
        case ",": display.brightness = max(-1, display.brightness - 0.05)
        case ".": display.brightness = min(1, display.brightness + 0.05)
        case "-": display.contrast = max(0.25, display.contrast / 1.15)
        case "=", "+": display.contrast = min(4, display.contrast * 1.15)
        case "0": display.resetTone(); display.denoise = .none
        default: return false
        }
        return true
    }

    /// Turn denoising off, or back on with the method used last (settings kept).
    func toggleDenoise() {
        if display.denoise == .none { display.denoise = lastMethod } else { display.denoise = .none }
    }
    /// Noise σ estimated from the current card's crop (raw pixels), in image units; nil when no crop is cached.
    var cardNoiseSigma: Float? { lastPlate?.noiseSigma }

    /// Pick coordinates for a click at fraction (u, v) of the card (0...1, origin top-left).
    func point(atFraction u: Double, _ v: Double) -> CGPoint? {
        guard let c = current else { return nil }
        return CGPoint(x: c.x + (u - 0.5) * windowPx, y: c.y + (v - 0.5) * windowPx)
    }

    // MARK: deck

    /// Candidates of micrograph `key` (best score first, at most `depth`) with blind decoys mixed in.
    /// Deterministic per micrograph; decoys already decided are not offered again.
    func makeDeck(key: String, depth: Int) -> [Card] {
        var cards = pc.store.candidates(key).filter { ($0.score ?? .infinity) >= pc.scoreCutoff }
            .sorted { ($0.score ?? -.infinity) != ($1.score ?? -.infinity) ? ($0.score ?? -.infinity) > ($1.score ?? -.infinity) : $0.id < $1.id }
            .prefix(depth).map { Card(id: $0.id, x: $0.x, y: $0.y, score: $0.score, decoy: false) }
        // blind decoys: random positions away from every existing pick; deterministic per micrograph
        let decided = Set(pc.store.record(key).swipe?.decisions.filter { $0.decoy }.map { $0.id } ?? [])
        let nDecoy = Int((Double(cards.count) * decoyRate).rounded())
        var rng = LCG(s: stableHash(key) | 1)
        let margin = max(windowPx / 2, 4), w = pc.imageSize.width, h = pc.imageSize.height
        let avoid = pc.store.picks(key).filter { $0.status != .dismissed }
        let minD = 0.8 * pc.diameterPx(Pick(x: 0, y: 0, label: pc.activeLabel))
        var decoys: [Card] = []
        var idx = 0, tries = 0
        while decoys.count < nDecoy && tries < 5000, w > 2 * margin, h > 2 * margin {
            tries += 1
            let x = margin + rng.next() * (w - 2 * margin), y = margin + rng.next() * (h - 2 * margin)
            if avoid.contains(where: { hypot($0.x - x, $0.y - y) < minD }) || decoys.contains(where: { hypot($0.x - x, $0.y - y) < minD }) { continue }
            let id = "d\(idx)"; idx += 1
            if !decided.contains(id) { decoys.append(Card(id: id, x: x, y: y, score: nil, decoy: true)) }
        }
        for d in decoys where !cards.isEmpty {
            cards.insert(d, at: 1 + Int(rng.next() * Double(cards.count)))              // never the very first card
        }
        if cards.isEmpty { cards = decoys }
        return cards
    }

    func rebuild() {
        guard let key = pc.currentKey, pc.imageSize.width > 0 else { queue = []; total = 0; builtKey = nil; return }
        let cards = makeDeck(key: key, depth: depth)
        queue = cards; total = cards.count; reviewed = 0; history = []; override = nil; builtKey = key; assistReordered = false
        cardChanged()
        reranker.use(store: pc.store)
        assistReorder()
    }

    // MARK: decisions

    private func record(_ c: Card, _ decision: String, label: String?, at p: CGPoint, recentered: Bool) {
        guard let key = pc.currentKey else { return }
        var log = pc.store.record(key).swipe ?? SwipeLog()
        log.decisions.append(SwipeDecision(id: c.id, decision: decision, label: label, x: p.x, y: p.y, decoy: c.decoy, recentered: recentered,
                                           ms: Int(Date().timeIntervalSince(shownAt) * 1000), t: Date().timeIntervalSince1970, view: display.logTag))
        pc.store.setSwipe(key, log)
        assistObserve(c, decision: decision, key: key)
    }

    /// A different card (or deck) is on screen: restart the dwell timer and drop temporary denoising unless pinned.
    private func cardChanged() {
        shownAt = Date(); revision += 1
        if !pinProcessing { display.denoise = .none }
    }

    private func advance() { queue.removeFirst(); reviewed += 1; override = nil; cardChanged() }

    /// Accept the current card with `label` (default: the active label). Decoys are only logged.
    func accept(label: String? = nil) {
        guard let key = pc.currentKey, let c = current, let p = currentPoint else { return }
        let lab = label ?? pc.activeLabel
        let rc = override != nil
        var serial: Int?
        if !c.decoy {
            let (x, y) = (min(max(p.x, 0), pc.imageSize.width - 1), min(max(p.y, 0), pc.imageSize.height - 1))
            pc.store.perform(key, "Swipe: accept") { l in
                if let i = l.firstIndex(where: { $0.id == c.id }) { l[i].status = .accepted; l[i].label = lab; l[i].x = x; l[i].y = y }
            }
            serial = pc.store.topSerial(key)
        }
        record(c, "pick", label: lab, at: p, recentered: rc)
        history.append((c, "pick", key, serial, rc)); advance()
    }

    func reject() {
        guard let key = pc.currentKey, let c = current, let p = currentPoint else { return }
        var serial: Int?
        if !c.decoy { pc.store.setStatus([c.id], .dismissed, in: key); serial = pc.store.topSerial(key) }
        record(c, "reject", label: nil, at: p, recentered: false)
        history.append((c, "reject", key, serial, false)); advance()
    }

    /// "Unsure": kept as a pick with the `unsureLabel` ("uncertain" in the Views scheme, "maybe" in Quality), or skipped to the end if the scheme has neither.
    var unsureLabel: String? { (pc.store.scheme.label("uncertain") ?? pc.store.scheme.label("maybe"))?.id }
    func unsure() {
        guard let lab = unsureLabel else { later(); return }
        guard let key = pc.currentKey, let c = current, let p = currentPoint else { return }
        var serial: Int?
        let rc = override != nil
        if !c.decoy {
            pc.store.perform(key, "Swipe: unsure") { l in
                if let i = l.firstIndex(where: { $0.id == c.id }) { l[i].status = .accepted; l[i].label = lab; l[i].x = p.x; l[i].y = p.y }
            }
            serial = pc.store.topSerial(key)
        }
        record(c, "unsure", label: lab, at: p, recentered: rc)
        history.append((c, "unsure", key, serial, rc)); advance()
    }

    /// Move the card to the end of the deck without deciding.
    func later() {
        guard let c = current else { return }
        queue.removeFirst(); queue.append(c); override = nil; cardChanged()
        history.append((c, "later", pc.currentKey ?? "", nil, false))
    }

    /// Make the undecided card `id` the current one (used by the phone when decisions are replayed out of order). False if it is not in the deck.
    @discardableResult func promote(_ id: String) -> Bool {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return false }
        if i == 0 { return true }
        let c = queue.remove(at: i); queue.insert(c, at: 0); override = nil; cardChanged()
        return true
    }

    /// Puts the waiting cards in the order of `ids` (the card on screen stays first; cards not listed keep their relative order at the end).
    func applyOrder(_ ids: [String]) {
        guard queue.count > 1 else { return }
        let first = queue[0]
        let rest = Dictionary(uniqueKeysWithValues: queue.dropFirst().map { ($0.id, $0) })
        var out = [first], used = Set<String>()
        for id in ids where id != first.id { if let c = rest[id], used.insert(id).inserted { out.append(c) } }
        for c in queue.dropFirst() where !used.contains(c.id) { out.append(c) }
        queue = out
    }

    func recenter(to p: CGPoint) { if current != nil { override = p; revision += 1 } }

    func undo() {
        guard let h = history.popLast() else { return }
        if h.kind == "later" {
            if let i = queue.lastIndex(of: h.card) { queue.remove(at: i) }
            queue.insert(h.card, at: 0)
        } else {
            if h.serial != nil, pc.store.topSerial(h.key) == h.serial { pc.store.undo(h.key) }
            var log = pc.store.record(h.key).swipe ?? SwipeLog()
            if !log.decisions.isEmpty { log.decisions.removeLast() }
            pc.store.setSwipe(h.key, log)
            reranker.forget(key: h.key, id: h.card.id)
            queue.insert(h.card, at: 0); reviewed = max(0, reviewed - 1)
        }
        override = nil; cardChanged()
    }
    var canUndo: Bool { !history.isEmpty }

    // MARK: stats

    var stats: SwipeStats { SwipeStats.compute(pc.store.project.mics.values.compactMap { $0.swipe }) }
    var levelStats: SwipeStats { SwipeStats.compute([pc.currentKey.flatMap { pc.store.record($0).swipe } ?? SwipeLog()]) }
}

extension PickExporter {
    /// `swipe_decisions.csv` (same columns as the web swipe picker) and `swipe_stats.json`; returns the relative file names written.
    static func swipeFiles(project: PickProject) -> [(name: String, text: String)] {
        let logs = project.mics.sorted(by: { $0.key < $1.key }).compactMap { k, r in r.swipe.map { (k, $0) } }
        guard logs.contains(where: { !$0.1.decisions.isEmpty }) else { return [] }
        var lines = ["card_id,decision,label,x_px,y_px,recentered,decoy,dwell_ms,time,display,mode"]
        for (k, l) in logs { for d in l.decisions {
            lines.append([csvField("\(k)@\(d.id)"), d.decision, d.label ?? "", fmt1(d.x), fmt1(d.y), d.recentered ? "1" : "0", d.decoy ? "1" : "0",
                          d.ms.map(String.init) ?? "", d.t.map { String(Int($0)) } ?? "", csvField(d.view ?? ""), d.mode ?? "swipe"].joined(separator: ","))
        } }
        let s = SwipeStats.compute(logs.map { $0.1 })
        func r(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "null" }
        let json = "{\n \"cards\": \(s.cards),\n \"pick\": \(s.pick),\n \"reject\": \(s.reject),\n \"unsure\": \(s.unsure),\n \"decoy_seen\": \(s.decoySeen),\n \"decoy_pick\": \(s.decoyPick),\n \"real_seen\": \(s.realSeen),\n \"real_pick\": \(s.realPick),\n \"recentered\": \(s.recentered),\n \"pick_rate_real\": \(r(s.pickRateReal)),\n \"pick_rate_decoy\": \(r(s.pickRateDecoy))\n}\n"
        return [("swipe_decisions.csv", lines.joined(separator: "\n") + "\n"), ("swipe_stats.json", json)]
    }
}
