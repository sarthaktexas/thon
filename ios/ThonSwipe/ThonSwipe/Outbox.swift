import Foundation

/// Decisions the Mac has not confirmed yet. Same rules as the web client (Resources/phone/app.js):
/// decisions are kept in order, replayed after a drop, and never silently lost; items the Mac rejects (409 level changed) are listed.
struct Outbox: Codable, Equatable {
    var items: [DecisionBody] = []
    var dropped: [DroppedDecision] = []

    var pendingRefs: Set<String> { Set(items.map { $0.ref }) }

    mutating func enqueue(_ b: DecisionBody) { items.append(b) }

    /// The Mac answered the first item with `status`. 2xx (including "already decided") removes it; 4xx is recorded as dropped; both remove it.
    mutating func complete(status: Int, reason: String?, now: Date = Date()) {
        guard let it = items.first else { return }
        if status >= 400 { dropped.append(DroppedDecision(ref: it.ref, decision: it.decision, reason: reason ?? "error \(status)", at: now)) }
        items.removeFirst()
        if dropped.count > 100 { dropped.removeFirst(dropped.count - 100) }
    }

    /// Cards still to show: the current one and the upcoming ones, minus those already decided on this phone.
    func deck(from s: PhoneState) -> [String] {
        guard let c = s.card else { return [] }
        let p = pendingRefs
        return ([c.ref] + s.upcoming).filter { !p.contains($0) }
    }

    static func decision(ref: String, kind: Decision, label: String?, cross: (u: Double, v: Double), dwellMs: Int, cid: String = UUID().uuidString) -> DecisionBody {
        var b = DecisionBody(ref: ref, decision: kind, label: kind == .pick ? label : nil, u: nil, v: nil, ms: max(0, dwellMs), cid: cid)
        let moved = abs(cross.u - 0.5) > 1e-6 || abs(cross.v - 0.5) > 1e-6
        if moved && (kind == .pick || kind == .unsure) { b.u = cross.u; b.v = cross.v }
        return b
    }

    // MARK: persistence (Application Support/outbox.json)

    static var fileURL: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("outbox.json")
    }

    static func load(from url: URL = Outbox.fileURL) -> Outbox {
        guard let d = try? Data(contentsOf: url), let o = try? JSONDecoder().decode(Outbox.self, from: d) else { return Outbox() }
        return o
    }

    func save(to url: URL = Outbox.fileURL) {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: url, options: .atomic) }
    }
}
