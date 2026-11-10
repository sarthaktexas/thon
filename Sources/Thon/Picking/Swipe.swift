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
    var recentred = false
    var ms: Int?                      // dwell time
    var t: Double?                    // epoch seconds
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
    var decoySeen = 0, decoyPick = 0, realSeen = 0, realPick = 0, recentred = 0
    var pickRateReal: Double? { realSeen > 0 ? Double(realPick) / Double(realSeen) : nil }
    var pickRateDecoy: Double? { decoySeen > 0 ? Double(decoyPick) / Double(decoySeen) : nil }

    static func compute(_ logs: [SwipeLog]) -> SwipeStats {
        var s = SwipeStats()
        for l in logs { for d in l.decisions {
            s.cards += 1
            switch d.decision { case "pick": s.pick += 1; case "reject": s.reject += 1; default: s.unsure += 1 }
            if d.recentred { s.recentred += 1 }
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
    @Published var override: CGPoint?                          // re-centred position of the current card
    @Published var decoyRate = 0.08
    @Published var depth = 100
    @Published private(set) var revision = 0
    @Published var dragOffset = CGSize.zero                    // live card offset while dragging (UI)
    private var windowCache: (key: String, count: Int, lo: Float, hi: Float)?
    private(set) var shownAt = Date()
    private var history: [(card: Card, kind: String, key: String, serial: Int?, wasRecentred: Bool)] = []
    private var bag = Set<AnyCancellable>()

    init(pc: PickController) { self.pc = pc }

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

    /// Card thumbnail (8-bit gray, `out` x `out`) for the current card; the crop is centred on the card, not on the re-centred cross.
    func cardImage(out: Int, smooth: Double = 1) -> [UInt8]? {
        guard let c = current, !pc.pixels.isEmpty else { return nil }
        let w = displayWindow()
        return renderThumb(pixels: pc.pixels, width: Int(pc.imageSize.width), height: Int(pc.imageSize.height), cx: c.x, cy: c.y,
                           boxPx: windowPx, out: out, lo: w.lo, hi: w.hi, smoothSigma: smooth)
    }
    /// Pick coordinates for a click at fraction (u, v) of the card (0...1, origin top-left).
    func point(atFraction u: Double, _ v: Double) -> CGPoint? {
        guard let c = current else { return nil }
        return CGPoint(x: c.x + (u - 0.5) * windowPx, y: c.y + (v - 0.5) * windowPx)
    }

    // MARK: deck

    func rebuild() {
        guard let key = pc.currentKey, pc.imageSize.width > 0 else { queue = []; total = 0; return }
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
        queue = cards; total = cards.count; reviewed = 0; history = []; override = nil
        shownAt = Date(); revision += 1
    }

    // MARK: decisions

    private func record(_ c: Card, _ decision: String, label: String?, at p: CGPoint, recentred: Bool) {
        guard let key = pc.currentKey else { return }
        var log = pc.store.record(key).swipe ?? SwipeLog()
        log.decisions.append(SwipeDecision(id: c.id, decision: decision, label: label, x: p.x, y: p.y, decoy: c.decoy, recentred: recentred,
                                           ms: Int(Date().timeIntervalSince(shownAt) * 1000), t: Date().timeIntervalSince1970))
        pc.store.setSwipe(key, log)
    }

    private func advance() { queue.removeFirst(); reviewed += 1; override = nil; shownAt = Date(); revision += 1 }

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
        record(c, "pick", label: lab, at: p, recentred: rc)
        history.append((c, "pick", key, serial, rc)); advance()
    }

    func reject() {
        guard let key = pc.currentKey, let c = current, let p = currentPoint else { return }
        var serial: Int?
        if !c.decoy { pc.store.setStatus([c.id], .dismissed, in: key); serial = pc.store.topSerial(key) }
        record(c, "reject", label: nil, at: p, recentred: false)
        history.append((c, "reject", key, serial, false)); advance()
    }

    /// "Unsure": kept as a pick with the `unsureLabel` (default "uncertain"), or skipped to the end if the scheme has no such label.
    var unsureLabel: String? { pc.store.scheme.label("uncertain")?.id }
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
        record(c, "unsure", label: lab, at: p, recentred: rc)
        history.append((c, "unsure", key, serial, rc)); advance()
    }

    /// Move the card to the end of the deck without deciding.
    func later() {
        guard let c = current else { return }
        queue.removeFirst(); queue.append(c); override = nil; shownAt = Date(); revision += 1
        history.append((c, "later", pc.currentKey ?? "", nil, false))
    }

    func recentre(to p: CGPoint) { if current != nil { override = p; revision += 1 } }

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
            queue.insert(h.card, at: 0); reviewed = max(0, reviewed - 1)
        }
        override = nil; shownAt = Date(); revision += 1
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
        var lines = ["card_id,decision,label,x_px,y_px,recentred,decoy,dwell_ms,time"]
        for (k, l) in logs { for d in l.decisions {
            lines.append([csvField("\(k)@\(d.id)"), d.decision, d.label ?? "", fmt1(d.x), fmt1(d.y), d.recentred ? "1" : "0", d.decoy ? "1" : "0",
                          d.ms.map(String.init) ?? "", d.t.map { String(Int($0)) } ?? ""].joined(separator: ","))
        } }
        let s = SwipeStats.compute(logs.map { $0.1 })
        func r(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "null" }
        let json = "{\n \"cards\": \(s.cards),\n \"pick\": \(s.pick),\n \"reject\": \(s.reject),\n \"unsure\": \(s.unsure),\n \"decoy_seen\": \(s.decoySeen),\n \"decoy_pick\": \(s.decoyPick),\n \"real_seen\": \(s.realSeen),\n \"real_pick\": \(s.realPick),\n \"recentred\": \(s.recentred),\n \"pick_rate_real\": \(r(s.pickRateReal)),\n \"pick_rate_decoy\": \(r(s.pickRateDecoy))\n}\n"
        return [("swipe_decisions.csv", lines.joined(separator: "\n") + "\n"), ("swipe_stats.json", json)]
    }
}
