import Foundation

/// Headless tests of the phone API (no sockets): HTTP parsing, pairing token, state / scheme sync, card images, decisions.
/// Run with `Thon --picktest`.

final class PhoneTestHost: PhoneHost {
    let pc = PickController()
    var keys: [String] = [], images: [[Float]] = []
    var index = 0
    var loading = false
    var opened: [Int] = []
    var phoneIsLoading: Bool { loading }
    var phoneMicCount: Int { keys.count }
    var phoneMicIndex: Int? { keys.isEmpty ? nil : index }
    func phoneMicKey(at i: Int) -> String? { keys.indices.contains(i) ? keys[i] : nil }
    func phoneOpenMic(at i: Int) {
        opened.append(i); index = i
        pc.pixels = images[i]; pc.setMicrograph(key: keys[i], width: 1024, height: 1024, pixelSizeA: 5)
    }
}

private func phoneObj(_ r: PhoneResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:] }
private func phoneState(_ o: [String: Any]) -> [String: Any] { (o["state"] as? [String: Any]) ?? o }

func testPhone(_ t: inout TestRun) {
    t.section("phone swiper API")

    // --- HTTP parsing
    func parse(_ s: String) -> PhoneParse { parsePhoneRequest(Data(s.utf8)) }
    if case .incomplete = parse("GET /api/state HTTP/1.1\r\nHost: x\r\n") { t.check(true, "partial headers: incomplete") } else { t.check(false, "partial headers: incomplete") }
    if case .request(let r) = parse("GET /api/card/a%20b/m.mrc@k1.jpg?out=300&t=abc HTTP/1.1\r\nHost: x\r\nCookie: thon_t=zz; other=1\r\n\r\n") {
        t.check(r.method == "GET" && r.path == "/api/card/a b/m.mrc@k1.jpg" && r.query["out"] == "300" && r.query["t"] == "abc" && r.cookies["thon_t"] == "zz", "GET: path decoded, query and cookies parsed")
    } else { t.check(false, "GET parse") }
    let body = #"{"a":1}"#
    if case .incomplete = parse("POST /x HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n{\"a\"") { t.check(true, "POST with partial body: incomplete") } else { t.check(false, "POST partial body") }
    if case .request(let r) = parse("POST /x HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)") {
        t.check(r.method == "POST" && (r.json?["a"] as? Int) == 1, "POST body parsed as JSON")
    } else { t.check(false, "POST parse") }
    if case .failure(let s) = parse("POST /x HTTP/1.1\r\nContent-Length: \(PhoneLimits.maxBody + 1)\r\n\r\n") { t.check(s == 413, "oversized body: 413") } else { t.check(false, "oversized body") }
    if case .failure(let s) = parsePhoneRequest(Data(repeating: 65, count: PhoneLimits.maxHeader + 10)) { t.check(s == 431, "oversized header: 431") } else { t.check(false, "oversized header") }
    if case .failure(let s) = parse("garbage\r\n\r\n") { t.check(s == 400, "bad request line: 400") } else { t.check(false, "bad request line") }
    let ser = String(data: PhoneResponse.json(["ok": true]).serialized(), encoding: .utf8) ?? ""
    t.check(ser.hasPrefix("HTTP/1.1 200 OK\r\n") && ser.contains("Content-Length: 11\r\n") && ser.contains("Connection: close") && ser.hasSuffix("{\"ok\":true}"), "response serialization")
    t.check(phoneTokenEqual("abc", "abc") && !phoneTokenEqual("abc", "abd") && !phoneTokenEqual("abc", "abcd") && !phoneTokenEqual("", "x"), "token comparison")
    t.check(PhoneController.makeToken().count == 32 && PhoneController.makeToken() != PhoneController.makeToken(), "tokens are 128-bit hex and differ")

    // --- fixture: three micrographs (m has candidates, o has none, n has candidates)
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let h = PhoneTestHost(); let c = h.pc
    c.store.saveDelay = 0; c.store.openProject(folder: dir)
    var pr = c.store.project.params; pr.diameterNm = 20; c.store.setParams(pr)
    c.autoParams.zThreshold = 4
    let (imgM, _) = syntheticMicrograph(w: 1024, h: 1024, n: 12, dPx: 40, amp: 12, noise: 8, seed: 41)
    let (imgN, _) = syntheticMicrograph(w: 1024, h: 1024, n: 10, dPx: 40, amp: 12, noise: 8, seed: 77)
    let imgO = [Float](repeating: 0, count: 1024 * 1024)
    h.keys = ["m.mrc", "o.mrc", "n.mrc"]; h.images = [imgM, imgO, imgN]
    for i in [2, 0] { h.phoneOpenMic(at: i); c.runAutoPick(synchronous: true) }      // n, then m (open at the end)
    let k = "m.mrc"
    let nCand = c.store.candidates(k).count
    let api = PhoneAPI(host: h, token: "tok123")
    func req(_ m: String, _ p: String, _ b: [String: Any]? = nil, token: String? = "tok123", query: [String: String] = [:]) -> PhoneResponse {
        var hd: [String: String] = [:]
        if let token { hd["x-thon-token"] = token }
        let body = b.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return api.handle(PhoneRequest(method: m, path: p, query: query, headers: hd, body: body))
    }
    func state() -> [String: Any] { phoneObj(req("GET", "/api/state")) }
    func decide(_ ref: String, _ kind: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var b: [String: Any] = ["ref": ref, "decision": kind]; for (a, v) in extra { b[a] = v }
        return phoneObj(req("POST", "/api/decision", b))
    }
    func curRef(_ s: [String: Any]) -> String { ((s["card"] as? [String: Any])?["ref"] as? String) ?? "" }

    // --- auth and pages
    t.check(req("GET", "/api/state", token: nil).status == 401 && req("GET", "/api/state", token: "nope").status == 401, "no or wrong token: 401")
    t.check(api.handle(PhoneRequest(method: "GET", path: "/api/state", query: ["t": "tok123"])).status == 200, "token as query parameter")
    t.check(api.handle(PhoneRequest(method: "GET", path: "/api/state", headers: ["cookie": "thon_t=tok123"])).status == 200, "token as cookie")
    let page = req("GET", "/")
    t.check(page.status == 200 && page.contentType.hasPrefix("text/html") && page.headers["Set-Cookie"]?.contains("thon_t=tok123") == true, "page load sets the pairing cookie")
    t.check((phoneObj(req("GET", "/manifest.webmanifest"))["start_url"] as? String) == "/?t=tok123", "manifest start_url carries the token")
    t.check(req("GET", "/etc/passwd").status == 404 && req("DELETE", "/api/state").status == 405, "unknown path 404, bad method 405")
    api.token = "other"; t.check(req("GET", "/api/state").status == 401, "reset token locks out the old one"); api.token = "tok123"

    // --- state and label scheme sync
    let s0 = state()
    let lvl = s0["level"] as! [String: Any]
    let scheme0 = s0["scheme"] as! [String: Any]
    let labels0 = scheme0["labels"] as! [[String: Any]]
    t.check((lvl["key"] as? String) == k && (lvl["total"] as? Int) == c.swipe.total && (lvl["total"] as? Int ?? 0) >= nCand && lvl["loading"] as? Bool == false && lvl["count"] as? Int == 3 && lvl["index"] as? Int == 0, "state: level key, deck size, index", "\(lvl)")
    t.check(labels0.map { $0["id"] as? String ?? "" } == c.store.scheme.labels.map { $0.id } && (labels0.first?["color"] as? String) == c.store.scheme.labels.first?.color, "state: scheme labels and colors equal the project's")
    t.check((s0["unsureLabel"] as? String) == "uncertain" && (s0["activeLabel"] as? String) == c.activeLabel, "state: Views scheme unsure label and active label")
    let card0 = s0["card"] as! [String: Any]
    let first = c.swipe.current!
    t.check(curRef(s0) == "\(k)@\(first.id)" && (s0["upcoming"] as? [String])?.count == min(12, c.swipe.queue.count - 1), "state: current card ref and upcoming refs")
    let wp = c.swipe.windowPx
    t.check(abs((card0["diameterFrac"] as! Double) - 200 / 5 / wp) < 1e-9 && abs((card0["boxFrac"] as! Double) - c.boxPx / wp) < 1e-9, "state: marker and box as fractions of the card")
    let r1 = scheme0["rev"] as? String
    c.store.setScheme(.quality)                                       // edit labels on the "Mac"
    let s1 = state()
    let labels1 = (s1["scheme"] as! [String: Any])["labels"] as! [[String: Any]]
    t.check((s1["scheme"] as? [String: Any])?["rev"] as? String != r1 && labels1.map { $0["id"] as? String ?? "" } == ["good", "maybe", "reject"], "scheme edit on the Mac changes scheme rev and labels on the next poll")
    t.check((s1["unsureLabel"] as? String) == "maybe" && (s1["activeLabel"] as? String).map { c.store.scheme.label($0) != nil } == true, "Quality scheme: up-swipe label is 'maybe'; active label still exists")
    c.store.setScheme(.views); c.activeLabel = "ring_top"
    t.check(((state()["scheme"] as? [String: Any])?["rev"] as? String) == r1, "scheme rev is stable for an unchanged scheme")

    // --- card images
    let ref0 = curRef(state())
    let img = req("GET", "/api/card/\(ref0).jpg", query: ["out": "320"])
    let bytes = img.deferred?().body ?? img.body
    t.check(bytes.count > 500 && bytes.count < 120_000 && bytes[0] == 0xFF && bytes[1] == 0xD8, "card image is a JPEG of sensible size", "\(bytes.count) bytes")
    t.check(api.cache.count == 1 && req("GET", "/api/card/\(ref0).jpg", query: ["out": "320"]).deferred == nil, "second request for the same card is served from the cache")
    t.check(req("GET", "/api/card/\(k)@nope.jpg").status == 404 && req("GET", "/api/card/other.mrc@\(first.id).jpg").status == 404, "unknown card or other level: 404")
    if let second = c.swipe.queue.dropFirst().first { t.check(req("GET", "/api/card/\(k)@\(second.id).jpg").deferred != nil, "upcoming cards can be rendered ahead") }

    // --- decisions
    let picksBefore = c.store.picks(k).count
    c.swipe.decoyRate = 0; c.swipe.rebuild()
    let a = c.swipe.current!
    let ref = "\(k)@\(a.id)"
    let resp = decide(ref, "pick", ["label": "side", "u": 0.6, "v": 0.45, "ms": 1234, "cid": "c1"])
    let pa = c.store.pick(a.id, in: k)!
    t.check(resp["applied"] as? Bool == true && pa.status == .accepted && pa.label == "side", "pick applies the chosen label")
    t.check(abs(pa.x - (a.x + 0.1 * wp)) < 1e-6 && abs(pa.y - (a.y - 0.05 * wp)) < 1e-6, "pick with u,v recenters the coordinate", "\(pa.x) vs \(a.x + 0.1 * wp)")
    let dec = c.store.record(k).swipe!.decisions.last!
    t.check(dec.decision == "pick" && dec.recentered && dec.ms == 1234 && dec.label == "side", "decision log records recentering, label and the phone's dwell time")
    t.check(decide(ref, "pick", ["cid": "c1"])["applied"] as? Bool == false && (decide(ref, "pick")["reason"] as? String) == "already decided", "replay: duplicate cid and already-decided cards are not applied twice")
    t.check(c.store.pick(a.id, in: k)?.label == "side" && c.store.record(k).swipe!.decisions.filter { $0.id == a.id }.count == 1, "replay leaves one log entry")
    c.undo()                                                          // undo from the Mac: the phone's accept is a normal edit
    t.check(c.store.pick(a.id, in: k)?.status == .candidate, "Mac undo reverts a phone pick")

    let b = c.swipe.current!
    let rj = decide("\(k)@\(b.id)", "reject")
    t.check(rj["applied"] as? Bool == true && c.store.pick(b.id, in: k)?.status == .dismissed, "reject dismisses the candidate")
    let u = c.swipe.current!
    _ = decide("\(k)@\(u.id)", "unsure")
    t.check(c.store.pick(u.id, in: k)?.label == "uncertain" && c.store.pick(u.id, in: k)?.status == .accepted, "unsure keeps the pick as 'uncertain' (Views)")
    c.store.setScheme(.quality); c.activeLabel = "good"
    let u2 = c.swipe.current!
    _ = decide("\(k)@\(u2.id)", "unsure")
    t.check(c.store.pick(u2.id, in: k)?.label == "maybe" && c.store.record(k).swipe!.decisions.last!.decision == "unsure", "unsure in the Quality scheme keeps the pick as 'maybe'")
    let rc = c.swipe.current!
    let rl = decide("\(k)@\(rc.id)", "pick", ["label": "reject"])
    t.check((rl["reason"] as? String) == "label replaced" && c.store.pick(rc.id, in: k)?.label == "good", "non-exported or unknown label falls back to the active label")
    c.store.setScheme(.views); c.activeLabel = "ring_top"

    let before = c.swipe.queue.map { $0.id }
    let lt = c.swipe.current!
    _ = decide("\(k)@\(lt.id)", "later")
    t.check(c.swipe.queue.map { $0.id } == Array(before.dropFirst()) + [lt.id], "later moves the card to the end without a log entry")
    let un = req("POST", "/api/undo")
    t.check(phoneObj(un)["applied"] as? Bool == true && c.swipe.current?.id == lt.id, "undo brings the card back")
    // out-of-order replay: decide the third card first
    let third = c.swipe.queue[2]
    t.check(decide("\(k)@\(third.id)", "reject")["applied"] as? Bool == true && c.store.pick(third.id, in: k)?.status == .dismissed && c.swipe.current?.id == lt.id, "out-of-order decision is applied to the named card; the deck order is otherwise kept")
    t.check(decide("\(k)@zzzz", "reject")["reason"] as? String == "unknown card", "unknown card id is reported, not applied")
    t.check(req("POST", "/api/decision", ["ref": "bad", "decision": "pick"]).status == 400 && req("POST", "/api/decision", ["ref": "\(k)@x", "decision": "explode"]).status == 400, "malformed decisions: 400")
    let wrong = req("POST", "/api/decision", ["ref": "n.mrc@abc", "decision": "pick"])
    t.check(wrong.status == 409 && (phoneObj(wrong)["reason"] as? String) == "level changed", "decision for another level: 409")

    // decoys are logged only
    c.swipe.decoyRate = 0.5; c.swipe.rebuild()
    if let d = c.swipe.queue.first(where: { $0.decoy }) {
        let n0 = c.store.picks(k).count
        _ = decide("\(k)@\(d.id)", "pick")
        t.check(c.store.picks(k).count == n0 && c.store.record(k).swipe!.decisions.last!.decoy, "decoy 'pick' is logged, never added as a pick")
    } else { t.check(false, "deck has decoys") }
    c.swipe.decoyRate = 0; c.swipe.rebuild()

    // --- labels, stats, autopick
    t.check(req("POST", "/api/label", ["id": "side"]).status == 200 && c.activeLabel == "side" && req("POST", "/api/label", ["id": "reject"]).status == 400 && req("POST", "/api/label", ["id": "zz"]).status == 400, "active label can be set to exported labels only")
    let st = phoneObj(req("GET", "/api/stats"))
    t.check(((st["all"] as? [String: Any])?["cards"] as? Int ?? 0) == c.swipe.stats.cards && ((st["perLevel"] as? [[String: Any]])?.first?["key"] as? String) == k, "stats: totals and per-level rows")

    // --- level navigation
    t.check(h.opened == [2, 0], "fixture opened n then m only", "\(h.opened)")
    let nx = req("POST", "/api/level", ["action": "next"])
    let ns = phoneState(phoneObj(nx))
    t.check(nx.status == 200 && h.opened.last == 2 && ((ns["level"] as? [String: Any])?["key"] as? String) == "n.mrc", "next skips the micrograph without candidates and opens the one with cards", "\(h.opened)")
    t.check(c.swipe.builtKey == "n.mrc" && c.swipe.total > 0 && curRef(ns).hasPrefix("n.mrc@"), "deck is rebuilt for the new micrograph")
    h.loading = true
    let pv = phoneState(phoneObj(req("POST", "/api/level", ["action": "prev"])))
    t.check(((pv["level"] as? [String: Any])?["loading"] as? Bool) == true && pv["card"] is NSNull, "state reports loading and no card while a micrograph loads")
    h.loading = false
    let pv2 = state()
    t.check(((pv2["level"] as? [String: Any])?["key"] as? String) == "m.mrc" && !(pv2["card"] is NSNull) == (c.swipe.total > 0), "after loading, the previous micrograph is current again")
    t.check(req("POST", "/api/level", ["action": "prev"]).status == 409 && req("POST", "/api/level", ["action": "sideways"]).status == 400, "no micrograph before the first: 409; bad action: 400")
    c.pixels = imgO; c.setMicrograph(key: "o.mrc", width: 1024, height: 1024, pixelSizeA: 5); h.index = 1
    let es = state()
    t.check(((es["level"] as? [String: Any])?["empty"] as? Bool) == true && es["card"] is NSNull, "micrograph without candidates: empty, no card")
    t.check(req("POST", "/api/autopick").status == 200, "autopick endpoint accepted")

    // --- assets
    t.check(!PhoneAssets.indexHTML.isEmpty && !PhoneAssets.appJS.isEmpty && !PhoneAssets.appCSS.isEmpty, "phone client assets are embedded")
}
