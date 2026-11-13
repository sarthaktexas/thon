import XCTest
@testable import ThonSwipe

final class OutboxTests: XCTestCase {
    private func state(card: String?, upcoming: [String]) -> PhoneState {
        let json = """
        {"v":1,"rev":3,"project":{"name":"p"},"scheme":{"rev":"a","labels":[{"id":"good","name":"Good","key":"1","color":"#4dff6a","shape":"circle","exported":true},
        {"id":"reject","name":"Reject","key":"0","color":"#f00","shape":"cross","exported":false}]},
        "activeLabel":"good","unsureLabel":null,
        "level":{"key":"g/m.mrc","name":"m.mrc","index":0,"count":2,"total":5,"reviewed":1,"done":false,"empty":false,"loading":false,"autoBusy":false,"candidates":5},
        "card":\(card.map { "{\"ref\":\"\($0)\",\"diameterFrac\":0.2,\"boxFrac\":0.5,\"cross\":[0.5,0.5],\"windowNm\":45,\"view\":\"raw\"}" } ?? "null"),
        "upcoming":[\(upcoming.map { "\"\($0)\"" }.joined(separator: ","))],"canUndo":true,
        "stats":{"level":{"cards":1,"pick":1,"reject":0,"unsure":0},"all":{"cards":9,"pick":3,"reject":5,"unsure":1,"pickRateReal":0.4,"pickRateDecoy":0.0,"decoySeen":2}}}
        """
        return try! JSONDecoder().decode(PhoneState.self, from: Data(json.utf8))
    }

    func testStateDecodes() {
        let s = state(card: "g/m.mrc@a", upcoming: ["g/m.mrc@b"])
        XCTAssertNil(s.unsureLabel)
        XCTAssertEqual(s.exportedLabels.map { $0.id }, ["good"])
        XCTAssertEqual(s.card?.ref, "g/m.mrc@a")
    }

    func testDeckSkipsPendingAndNilCard() {
        var o = Outbox()
        let s = state(card: "g/m.mrc@a", upcoming: ["g/m.mrc@b", "g/m.mrc@c"])
        XCTAssertEqual(o.deck(from: s), ["g/m.mrc@a", "g/m.mrc@b", "g/m.mrc@c"])
        o.enqueue(Outbox.decision(ref: "g/m.mrc@a", kind: .reject, label: nil, cross: (0.5, 0.5), dwellMs: 10))
        XCTAssertEqual(o.deck(from: s), ["g/m.mrc@b", "g/m.mrc@c"])
        XCTAssertEqual(o.deck(from: state(card: nil, upcoming: [])), [])
    }

    func testDecisionBodyRules() {
        let a = Outbox.decision(ref: "r", kind: .pick, label: "good", cross: (0.5, 0.5), dwellMs: 5)
        XCTAssertEqual(a.label, "good"); XCTAssertNil(a.u)
        let b = Outbox.decision(ref: "r", kind: .reject, label: "good", cross: (0.3, 0.6), dwellMs: 5)
        XCTAssertNil(b.label); XCTAssertNil(b.u)
        let c = Outbox.decision(ref: "r", kind: .unsure, label: nil, cross: (0.3, 0.6), dwellMs: -4)
        XCTAssertEqual(c.u, 0.3); XCTAssertEqual(c.v, 0.6); XCTAssertEqual(c.ms, 0)
        XCTAssertNotEqual(a.cid, b.cid)
    }

    func testCompleteKeepsOrderAndRecordsDrops() {
        var o = Outbox()
        for r in ["a", "b", "c"] { o.enqueue(Outbox.decision(ref: r, kind: .pick, label: "good", cross: (0.5, 0.5), dwellMs: 1)) }
        o.complete(status: 200, reason: nil)
        XCTAssertEqual(o.items.map { $0.ref }, ["b", "c"])
        o.complete(status: 409, reason: "level changed")
        XCTAssertEqual(o.items.map { $0.ref }, ["c"])
        XCTAssertEqual(o.dropped.first?.reason, "level changed")
        o.complete(status: 200, reason: "already decided")
        XCTAssertTrue(o.items.isEmpty); XCTAssertEqual(o.dropped.count, 1)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var o = Outbox()
        o.enqueue(Outbox.decision(ref: "a", kind: .later, label: nil, cross: (0.5, 0.5), dwellMs: 7, cid: "c1"))
        o.save(to: url)
        XCTAssertEqual(Outbox.load(from: url), o)
        XCTAssertEqual(Outbox.load(from: url.appendingPathExtension("missing")), Outbox())
    }
}
