import Foundation
import Combine
import CoreGraphics

// Sort mode: classification of picks that were already accepted (typically by the grid triage).
// Each swipe direction is assigned a label (or "dismiss" / "later"); the card tints with that label's colour while you drag.
// Statistics for pick / reject rates ignore these decisions (they are logged with mode "sort").

enum SwipeDir: String, CaseIterable, Identifiable {
    case up, right, down, left
    var id: String { rawValue }
    var arrow: String { switch self { case .up: return "↑"; case .right: return "→"; case .down: return "↓"; case .left: return "←" } }
}

enum SortAction: Equatable, Hashable {
    case label(String)
    case dismiss            // not a particle after all: removed from the picks (kept as dismissed, never exported)
    case later              // to the end of the deck, nothing recorded

    var code: String {
        switch self { case .label(let id): return "label:" + id; case .dismiss: return "dismiss"; case .later: return "later" }
    }
    init?(code: String) {
        if code == "dismiss" { self = .dismiss } else if code == "later" { self = .later }
        else if code.hasPrefix("label:") { self = .label(String(code.dropFirst(6))) }
        else { return nil }
    }
}

struct SortMap: Equatable {
    var up: SortAction, right: SortAction, down: SortAction, left: SortAction

    subscript(d: SwipeDir) -> SortAction {
        get { switch d { case .up: return up; case .right: return right; case .down: return down; case .left: return left } }
        set { switch d { case .up: up = newValue; case .right: right = newValue; case .down: down = newValue; case .left: left = newValue } }
    }

    /// Up = first label, right = second, down = third, left = dismiss. With the Views preset: up red, right yellow, down cyan.
    static func defaults(for scheme: LabelScheme) -> SortMap {
        func lab(_ i: Int) -> SortAction { i < scheme.labels.count ? .label(scheme.labels[i].id) : .later }
        return SortMap(up: lab(0), right: lab(1), down: lab(2), left: .dismiss)
    }

    /// Replaces assignments that point at a label the scheme no longer has by the default for that direction.
    func valid(for scheme: LabelScheme) -> SortMap {
        var m = self
        let d = SortMap.defaults(for: scheme)
        for dir in SwipeDir.allCases {
            if case .label(let id) = m[dir], scheme.label(id) == nil { m[dir] = d[dir] }
        }
        return m
    }

    static let defaultsKey = "sort.map"
    func save(_ ud: UserDefaults = .standard) {
        ud.set(Dictionary(uniqueKeysWithValues: SwipeDir.allCases.map { ($0.rawValue, self[$0].code) }), forKey: Self.defaultsKey)
    }
    static func load(scheme: LabelScheme, _ ud: UserDefaults = .standard) -> SortMap {
        var m = SortMap.defaults(for: scheme)
        if let d = ud.dictionary(forKey: defaultsKey) as? [String: String] {
            for dir in SwipeDir.allCases { if let c = d[dir.rawValue], let a = SortAction(code: c) { m[dir] = a } }
        }
        return m.valid(for: scheme)
    }
}

enum SortScope: String, CaseIterable, Identifiable {
    case unsorted = "Not yet sorted", all = "All picks"
    var id: String { rawValue }
}

/// True when `pick` was already classified: by a sort-mode decision, or by an accepting decision of the older candidate-review swipe.
func isSorted(_ pickID: String, in log: SwipeLog?) -> Bool {
    guard let log else { return false }
    return log.decisions.contains { d in
        d.id == pickID && !d.decoy && (d.mode == "sort" || ((d.mode == nil || d.mode == "swipe") && (d.decision == "pick" || d.decision == "unsure")))
    }
}

final class SortSession: ObservableObject {
    struct Card: Equatable { var id: String; var x: Double; var y: Double; var score: Float?; var label: String }

    unowned let pc: PickController
    var sw: SwipeSession { pc.swipe }
    @Published private(set) var queue: [Card] = []
    @Published private(set) var total = 0
    @Published private(set) var reviewed = 0
    @Published var scope = SortScope.unsorted
    @Published var map: SortMap { didSet { if map != oldValue { map.save(defaults) } } }
    private let defaults: UserDefaults
    @Published var override: CGPoint?
    @Published var dragOffset = CGSize.zero
    @Published private(set) var revision = 0
    private(set) var shownAt = Date()
    private var history: [(card: Card, kind: String, key: String, serial: Int?, before: Pick?)] = []

    init(pc: PickController, defaults: UserDefaults = .standard) {
        self.pc = pc; self.defaults = defaults; map = SortMap.load(scheme: pc.store.scheme, defaults)
    }

    var current: Card? { queue.first }
    var done: Bool { queue.isEmpty }
    var currentPoint: CGPoint? { current.map { override ?? CGPoint(x: $0.x, y: $0.y) } }
    var canUndo: Bool { !history.isEmpty }

    func point(atFraction u: Double, _ v: Double) -> CGPoint? {
        guard let c = current else { return nil }
        return CGPoint(x: c.x + (u - 0.5) * sw.windowPx, y: c.y + (v - 0.5) * sw.windowPx)
    }
    func cardImage(out: Int) -> [UInt8]? { current.flatMap { sw.image(id: $0.id, x: $0.x, y: $0.y, out: out) } }

    /// Picks of micrograph `key` that sort mode would offer under `scope`.
    func deckPicks(key: String, scope: SortScope) -> [Pick] {
        let log = pc.store.record(key).swipe
        return pc.store.accepted(key)
            .filter { scope == .all || ($0.source == .auto && !isSorted($0.id, in: log)) }
            .sorted { ($0.score ?? -.infinity) != ($1.score ?? -.infinity) ? ($0.score ?? -.infinity) > ($1.score ?? -.infinity) : $0.id < $1.id }
    }
    /// Number of picks waiting to be sorted on `key`.
    func pendingCount(_ key: String) -> Int { deckPicks(key: key, scope: .unsorted).count }

    func rebuild() {
        map = map.valid(for: pc.store.scheme)
        guard let key = pc.currentKey, pc.imageSize.width > 0 else { queue = []; total = 0; return }
        queue = deckPicks(key: key, scope: scope).map { Card(id: $0.id, x: $0.x, y: $0.y, score: $0.score, label: $0.label) }
        total = queue.count; reviewed = 0; history = []; override = nil
        cardChanged()
    }

    private func cardChanged() { shownAt = Date(); revision += 1; sw.viewChanged() }
    private func advance() { queue.removeFirst(); reviewed += 1; override = nil; cardChanged() }

    private func record(_ c: Card, _ decision: String, label: String?, at p: CGPoint, recentered: Bool) {
        guard let key = pc.currentKey else { return }
        var log = pc.store.record(key).swipe ?? SwipeLog()
        log.decisions.append(SwipeDecision(id: c.id, decision: decision, label: label, x: p.x, y: p.y, decoy: false, recentered: recentered,
                                           ms: Int(Date().timeIntervalSince(shownAt) * 1000), t: Date().timeIntervalSince1970,
                                           view: sw.display.logTag, mode: "sort"))
        pc.store.setSwipe(key, log)
    }

    // MARK: decisions

    func swipe(_ dir: SwipeDir) { perform(map[dir]) }

    func perform(_ a: SortAction) {
        switch a {
        case .label(let id): label(id)
        case .dismiss: dismiss()
        case .later: later()
        }
    }

    /// Classify the current pick as `id` (moves it to the re-centered cross if there is one).
    func label(_ id: String) {
        guard let key = pc.currentKey, let c = current, let p = currentPoint, pc.store.scheme.label(id) != nil else { return }
        let rc = override != nil
        let (x, y) = (min(max(p.x, 0), pc.imageSize.width - 1), min(max(p.y, 0), pc.imageSize.height - 1))
        let before = pc.store.pick(c.id, in: key)
        let changed = pc.store.perform(key, "Sort: label") { l in
            if let i = l.firstIndex(where: { $0.id == c.id }) { l[i].label = id; l[i].x = x; l[i].y = y; l[i].status = .accepted }
        }
        record(c, "pick", label: id, at: p, recentered: rc)
        history.append((c, "label", key, changed ? pc.store.topSerial(key) : nil, before)); advance()
    }

    func dismiss() {
        guard let key = pc.currentKey, let c = current, let p = currentPoint else { return }
        let before = pc.store.pick(c.id, in: key)
        let changed = pc.store.setStatus([c.id], .dismissed, in: key)
        record(c, "reject", label: nil, at: p, recentered: false)
        history.append((c, "dismiss", key, changed ? pc.store.topSerial(key) : nil, before)); advance()
    }

    func later() {
        guard let c = current else { return }
        queue.removeFirst(); queue.append(c); override = nil; cardChanged()
        history.append((c, "later", pc.currentKey ?? "", nil, nil))
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
            queue.insert(h.card, at: 0); reviewed = max(0, reviewed - 1)
        }
        override = nil; cardChanged()
    }

    // MARK: display helpers

    func actionName(_ a: SortAction) -> String {
        switch a {
        case .label(let id): return pc.store.scheme.label(id)?.name ?? id
        case .dismiss: return "Dismiss"
        case .later: return "Later"
        }
    }
    /// Hex colour of an action (label colour; dismiss red-grey, later grey).
    func actionColor(_ a: SortAction) -> String {
        switch a {
        case .label(let id): return pc.store.scheme.label(id)?.color ?? "#ffffff"
        case .dismiss: return "#8a8a8a"
        case .later: return "#5a5a5a"
        }
    }
    /// Direction of a drag translation (dominant axis), nil for tiny drags.
    static func direction(of t: CGSize, minDistance: CGFloat = 20) -> SwipeDir? {
        guard max(abs(t.width), abs(t.height)) >= minDistance else { return nil }
        if abs(t.width) >= abs(t.height) { return t.width > 0 ? .right : .left }
        return t.height < 0 ? .up : .down
    }
}

extension PickController {
    /// Accepted auto-picks of the current micrograph that have not been sorted into a label yet (drawn white in the overlay).
    func unsortedPickIDs() -> Set<String> {
        guard let key = currentKey else { return [] }
        let log = store.record(key).swipe
        return Set(store.accepted(key).filter { $0.source == .auto && !isSorted($0.id, in: log) }.map { $0.id })
    }
}
