import Foundation
import UIKit

/// A stand-in for Thon with made-up cards, so the app can be tried (and screenshotted in the Simulator) without a Mac.
/// Speaks the same API as the Mac (docs/PHONE_API.md) but keeps everything in memory. The images are synthetic, not real micrographs.
final class DemoLink: ThonLink {
    private struct Card { var id: String; var kind: Int }
    private struct Done { var card: Card; var decision: Decision }

    private let lock = NSLock()
    private let key = "demo/F4_017.mrc"
    private var queue: [Card]
    private var done: [Done] = []
    private var active = "good"
    private let total = 24

    init() { queue = (0..<24).map { Card(id: String(format: "d%02d", $0), kind: $0 % 4) } }

    private var labels: [SchemeLabel] {
        [SchemeLabel(id: "good", name: "Good", key: "1", color: "#4dff6a", shape: "circle", exported: true),
         SchemeLabel(id: "maybe", name: "Maybe", key: "2", color: "#ffd400", shape: "circle", exported: true),
         SchemeLabel(id: "reject", name: "Reject", key: "3", color: "#ff5a52", shape: "cross", exported: true)]
    }

    private func ref(_ c: Card) -> String { "\(key)@\(c.id)" }

    private func stats() -> StatsPair {
        func count(_ d: Decision) -> Int { done.filter { $0.decision == d }.count }
        let c = CountStats(cards: done.count, pick: count(.pick), reject: count(.reject), unsure: count(.unsure), pickRateReal: 0.38, pickRateDecoy: 0.05, decoySeen: 2)
        return StatsPair(level: c, all: c)
    }

    private func state() -> PhoneState {
        let first = queue.first
        let card = first.map { CardInfo(ref: ref($0), diameterFrac: 0.21, boxFrac: 0.56, cross: [0.5, 0.5], windowNm: 45, view: "raw") }
        let finished = done.filter { $0.decision != .later }.count
        let lvl = LevelInfo(key: key, name: "F4_017.mrc (demo)", index: 0, count: 1, total: total, reviewed: finished, candidates: total,
                            done: queue.isEmpty, empty: false, loading: false, autoBusy: false)
        return PhoneState(v: 1, rev: done.count, project: .init(name: "Demo"), scheme: Scheme(rev: "demo", labels: labels), activeLabel: active,
                          unsureLabel: "maybe", level: lvl, card: card, upcoming: queue.dropFirst().prefix(12).map(ref), canUndo: !done.isEmpty, stats: stats())
    }

    private func json<T: Encodable>(_ v: T, status: Int = 200) -> LinkResponse { LinkResponse(status: status, body: (try? JSONEncoder().encode(v)) ?? Data()) }

    private struct Reply: Encodable { var applied: Bool; var reason: String?; var state: PhoneState }

    func request(_ method: String, _ path: String, query: [String: String], body: Data?) async throws -> LinkResponse {
        try await Task.sleep(nanoseconds: 40_000_000)             // a little latency, like a real link
        return handle(method, path, body)
    }

    private func handle(_ method: String, _ path: String, _ body: Data?) -> LinkResponse {
        lock.lock(); defer { lock.unlock() }
        switch (method, path) {
        case ("GET", "/api/state"): return json(state())
        case ("POST", "/api/decision"):
            guard let b = body.flatMap({ try? JSONDecoder().decode(DecisionBody.self, from: $0) }) else { return json(["error": "bad request"], status: 400) }
            guard let i = queue.firstIndex(where: { ref($0) == b.ref }) else { return json(Reply(applied: false, reason: "already decided", state: state())) }
            let c = queue.remove(at: i)
            if b.decision == .later { queue.append(c) }
            done.append(Done(card: c, decision: b.decision))
            return json(Reply(applied: true, reason: nil, state: state()))
        case ("POST", "/api/undo"):
            guard let last = done.popLast() else { return json(Reply(applied: false, reason: nil, state: state())) }
            queue.removeAll { $0.id == last.card.id }; queue.insert(last.card, at: 0)
            return json(Reply(applied: true, reason: nil, state: state()))
        case ("POST", "/api/label"):
            if let b = body, let o = try? JSONSerialization.jsonObject(with: b) as? [String: Any], let id = o["id"] as? String, labels.contains(where: { $0.id == id }) { active = id }
            return json(["state": state()])
        case ("POST", "/api/level"), ("POST", "/api/autopick"):
            queue = (0..<total).map { Card(id: String(format: "d%02d", $0), kind: $0 % 4) }; done = []
            return json(["state": state()])
        default:
            if method == "GET", path.hasPrefix("/api/card/"), path.hasSuffix(".jpg") {
                let r = String(path.dropFirst("/api/card/".count).dropLast(".jpg".count))
                guard let id = r.split(separator: "@").last.map(String.init), let c = (queue + done.map { $0.card }).first(where: { $0.id == id }) else { return LinkResponse(status: 404, body: Data()) }
                return LinkResponse(status: 200, body: Self.jpeg(kind: c.kind, seed: UInt64(id.dropFirst()) ?? 1))
            }
            return LinkResponse(status: 404, body: Data())
        }
    }

    // MARK: synthetic cards

    private struct RNG { var s: UInt64
        mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) }
    }

    static func jpeg(kind: Int, seed: UInt64) -> Data {
        var rng = RNG(s: seed &* 7919 &+ 13)
        let n: CGFloat = 480
        let img = UIGraphicsImageRenderer(size: CGSize(width: n, height: n), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            let g = ctx.cgContext
            UIColor(white: 0.62, alpha: 1).setFill(); g.fill(CGRect(x: 0, y: 0, width: n, height: n))
            for _ in 0..<2600 {                                       // stain grain
                let x = rng.next() * Double(n), y = rng.next() * Double(n), r = 2 + rng.next() * 7
                UIColor(white: rng.next() < 0.5 ? 0.45 : 0.78, alpha: 0.10).setFill()
                g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            let cx = n / 2 + CGFloat(rng.next() * 10 - 5), cy = n / 2 + CGFloat(rng.next() * 10 - 5)
            func blob(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ w: CGFloat, _ a: CGFloat) {
                g.saveGState(); g.translateBy(x: x, y: y); g.rotate(by: a)
                for i in stride(from: 1.0, to: 0.0, by: -0.12) {
                    UIColor(white: w, alpha: 0.12).setFill()
                    g.fillEllipse(in: CGRect(x: -rx * i, y: -ry * i, width: 2 * rx * i, height: 2 * ry * i))
                }
                g.restoreGState()
            }
            switch kind {
            case 0: blob(cx, cy, 58, 58, 0.12, 0); blob(cx, cy, 30, 30, 0.85, 0)       // top view: dark ring, light centre
            case 1: blob(cx, cy, 70, 30, 0.12, 0.5); blob(cx + 34, cy - 16, 20, 18, 0.2, 0.2)   // side view
            case 2: blob(cx, cy, 56, 56, 0.14, 0); blob(cx, cy, 26, 26, 0.8, 0)
            default: blob(cx - 60, cy + 40, 80, 26, 0.2, 1.2); blob(cx + 90, cy - 70, 32, 32, 0.15, 0)   // junk
            }
        }
        return img.jpegData(compressionQuality: 0.82) ?? Data()
    }
}
