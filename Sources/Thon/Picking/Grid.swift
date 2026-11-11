import Foundation
import Combine
import CoreGraphics

// Grid triage: a page of n x n candidate crops, click the real particles, Enter to commit the page.
// This is the first pass (particle or not). Classification into labels happens afterwards in sort mode.
// Unmarked tiles are rejected on commit; tiles marked "unsure" stay undecided candidates.
// Blind decoys (random spots) are mixed in like in swipe mode and only logged.

final class GridSession: ObservableObject {
    typealias Card = SwipeSession.Card

    unowned let pc: PickController
    var sw: SwipeSession { pc.swipe }

    @Published var n = 3 { didSet { if n != oldValue { n = min(max(n, 2), 5); cursor = 0; clearMarks(); revision += 1 } } }
    @Published private(set) var deck: [Card] = []
    @Published private(set) var start = 0                       // index of the first tile of the current page
    @Published private(set) var clicked = Set<String>()
    @Published private(set) var unsure = Set<String>()
    /// false: clicking marks particles (unmarked = not a particle). true: clicking marks junk (unmarked = particle).
    @Published var junkMode = false { didSet { if junkMode != oldValue { revision += 1 } } }
    @Published var cursor = 0
    @Published var showCircle = true
    @Published var depth = 400
    @Published private(set) var revision = 0
    private(set) var shownAt = Date()
    private var key: String?

    private struct PageRecord { var start: Int; var ids: [String]; var serial: Int?; var logged: Int; var clicked: Set<String>; var unsure: Set<String>; var key: String }
    private var history: [PageRecord] = []

    init(pc: PickController) { self.pc = pc }

    var tiles: Int { n * n }
    var page: [Card] { start < deck.count ? Array(deck[start..<min(deck.count, start + tiles)]) : [] }
    var pageIndex: Int { start / max(tiles, 1) }
    var pageCount: Int { max(1, (deck.count + tiles - 1) / tiles) }
    var done: Bool { start >= deck.count }
    var canUndo: Bool { !history.isEmpty }
    var remaining: Int { max(0, deck.count - start) }

    func isParticle(_ c: Card) -> Bool {
        if unsure.contains(c.id) { return false }
        return junkMode ? !clicked.contains(c.id) : clicked.contains(c.id)
    }
    var particleCount: Int { page.filter { isParticle($0) }.count }
    var unsureCount: Int { page.filter { unsure.contains($0.id) }.count }

    // MARK: deck

    func rebuild() {
        guard let k = pc.currentKey, pc.imageSize.width > 0 else { deck = []; start = 0; key = nil; return }
        deck = sw.makeDeck(key: k, depth: depth)
        key = k; start = 0; history = []; cursor = 0; clearMarks(); cardChanged()
    }

    private func clearMarks() { clicked = []; unsure = [] }
    private func cardChanged() { shownAt = Date(); revision += 1; sw.viewChanged() }

    // MARK: marking

    func toggle(_ id: String) {
        if unsure.contains(id) { unsure.remove(id) }
        if clicked.contains(id) { clicked.remove(id) } else { clicked.insert(id) }
    }
    func toggleUnsure(_ id: String) {
        if unsure.contains(id) { unsure.remove(id) } else { unsure.insert(id); clicked.remove(id) }
    }
    /// Mark every tile of the page (as particles, or as junk in junk mode).
    func markAll() { clicked = Set(page.filter { !unsure.contains($0.id) }.map { $0.id }) }
    func clearPage() { clearMarks() }

    func moveCursor(dx: Int, dy: Int) {
        let count = page.count
        guard count > 0 else { return }
        var cx = cursor % n + dx, cy = cursor / n + dy
        cx = min(max(cx, 0), n - 1); cy = min(max(cy, 0), (count - 1) / n)
        cursor = min(cy * n + cx, count - 1)
    }

    // MARK: commit / undo

    /// Applies the page: particles are accepted (with the active label until sorted), the rest dismissed, unsure tiles stay candidates.
    func commit() {
        guard let k = key ?? pc.currentKey, !done else { return }
        let cards = page
        var accept = Set<String>(), dismiss = Set<String>()
        for c in cards where !c.decoy {
            if unsure.contains(c.id) { continue }
            if isParticle(c) { accept.insert(c.id) } else { dismiss.insert(c.id) }
        }
        let lab = pc.activeLabel
        let changed = pc.store.perform(k, "Grid: page \(pageIndex + 1)") { l in
            for i in l.indices {
                if accept.contains(l[i].id) { l[i].status = .accepted; l[i].label = lab }
                else if dismiss.contains(l[i].id) { l[i].status = .dismissed }
            }
        }
        let serial = changed ? pc.store.topSerial(k) : nil
        let dwell = Int(Date().timeIntervalSince(shownAt) * 1000)
        var log = pc.store.record(k).swipe ?? SwipeLog()
        for c in cards {
            let dec = unsure.contains(c.id) ? "unsure" : (isParticle(c) ? "pick" : "reject")
            log.decisions.append(SwipeDecision(id: c.id, decision: dec, label: dec == "pick" ? lab : nil, x: c.x, y: c.y, decoy: c.decoy, recentered: false,
                                               ms: dwell, t: Date().timeIntervalSince1970, view: sw.display.logTag, mode: "grid"))
        }
        pc.store.setSwipe(k, log)
        history.append(PageRecord(start: start, ids: cards.map { $0.id }, serial: serial, logged: cards.count, clicked: clicked, unsure: unsure, key: k))
        start += cards.count; cursor = 0; clearMarks(); cardChanged()
    }

    /// Takes back the last committed page (picks, log and marks).
    func undo() {
        guard let h = history.popLast() else { return }
        if h.serial != nil, pc.store.topSerial(h.key) == h.serial { pc.store.undo(h.key) }
        var log = pc.store.record(h.key).swipe ?? SwipeLog()
        log.decisions.removeLast(min(h.logged, log.decisions.count))
        pc.store.setSwipe(h.key, log)
        start = h.start; clicked = h.clicked; unsure = h.unsure; cursor = 0; cardChanged()
    }

    // MARK: stats

    /// Grid decisions on the current micrograph (real tiles only).
    var levelCounts: (particles: Int, rejected: Int, unsure: Int) {
        guard let k = pc.currentKey else { return (0, 0, 0) }
        let d = (pc.store.record(k).swipe?.decisions ?? []).filter { $0.mode == "grid" && !$0.decoy }
        return (d.filter { $0.decision == "pick" }.count, d.filter { $0.decision == "reject" }.count, d.filter { $0.decision == "unsure" }.count)
    }
    /// Fraction of random-spot tiles marked as particles over all micrographs (grid mode); nil without decoys.
    var decoyRate: Double? {
        let d = pc.store.project.mics.values.flatMap { $0.swipe?.decisions ?? [] }.filter { $0.mode == "grid" && $0.decoy }
        return d.isEmpty ? nil : Double(d.filter { $0.decision == "pick" }.count) / Double(d.count)
    }
    var decoySeen: Int { pc.store.project.mics.values.flatMap { $0.swipe?.decisions ?? [] }.filter { $0.mode == "grid" && $0.decoy }.count }
}
