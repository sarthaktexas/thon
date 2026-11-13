import Foundation
import CoreGraphics

func jsonOpt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

/// What the phone API needs from the app. `AppModel` conforms; tests use a stub around a bare `PickController`.
protocol PhoneHost: AnyObject {
    var pc: PickController { get }
    var phoneIsLoading: Bool { get }
    var phoneMicCount: Int { get }
    var phoneMicIndex: Int? { get }
    func phoneMicKey(at i: Int) -> String?
    func phoneOpenMic(at i: Int)
}

// `AppModel` is @MainActor and `PhoneAPI` only ever calls the host on the main thread (see PhoneAPI's doc comment),
// so the conformance is `@preconcurrency`: the compiler inserts a main-actor check at runtime instead of a static error.
extension AppModel: @preconcurrency PhoneHost {
    var pc: PickController { picks }
    var phoneIsLoading: Bool { isLoading }
    var phoneMicCount: Int { items.count }
    var phoneMicIndex: Int? { selectedIndex }
    func phoneMicKey(at i: Int) -> String? { items.indices.contains(i) ? picks.store.key(for: items[i].url) : nil }
    func phoneOpenMic(at i: Int) { if items.indices.contains(i) { selection = items[i].url } }
}

/// Small thread-safe LRU of encoded card images (rendering runs off the main thread).
final class PhoneJPEGCache {
    private var map: [String: Data] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    let capacity: Int
    init(capacity: Int = 40) { self.capacity = capacity }
    func get(_ k: String) -> Data? { lock.lock(); defer { lock.unlock() }; return map[k] }
    func put(_ k: String, _ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if map[k] == nil { order.append(k) }
        map[k] = d
        while order.count > capacity { map[order.removeFirst()] = nil }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }
}

/// The phone API. Every method must run on the main thread (it reads and mutates `PickStore` / `SwipeSession`);
/// JPEG rendering is returned as `PhoneResponse.deferred` so the server can run it elsewhere.
final class PhoneAPI {
    static let version = 1
    unowned let host: PhoneHost
    var token: String
    var iconPNG: () -> Data? = { nil }
    let cache = PhoneJPEGCache()

    private var rev = 0
    private var fingerprint = ""
    private var pendingKey: String?
    private var pendingSince = Date.distantPast
    private var sawAutoBusy = false
    private var seenCids: [String] = []
    private var seenSet = Set<String>()

    init(host: PhoneHost, token: String) { self.host = host; self.token = token }

    private var pc: PickController { host.pc }
    private var sw: SwipeSession { host.pc.swipe }
    private var store: PickStore { host.pc.store }

    // MARK: routing

    func authorized(_ r: PhoneRequest) -> Bool {
        let given = r.query["t"] ?? r.headers["x-thon-token"] ?? r.cookies["thon_t"] ?? ""
        return !token.isEmpty && phoneTokenEqual(given, token)
    }

    func handle(_ r: PhoneRequest) -> PhoneResponse {
        guard authorized(r) else { return .unauthorized }
        let p = r.path
        if r.method == "GET" {
            switch p {
            case "/", "/index.html":
                var resp = PhoneResponse.text(PhoneAssets.indexHTML, type: "text/html; charset=utf-8")
                resp.headers["Set-Cookie"] = "thon_t=\(token); Path=/; SameSite=Strict; Max-Age=31536000"
                return resp
            case "/app.js": return .text(PhoneAssets.appJS, type: "text/javascript; charset=utf-8")
            case "/app.css": return .text(PhoneAssets.appCSS, type: "text/css; charset=utf-8")
            case "/manifest.webmanifest": return manifest()
            case "/icon.png":
                guard let d = iconPNG() else { return .error(404, "no icon") }
                return PhoneResponse(status: 200, contentType: "image/png", body: d, headers: ["Cache-Control": "max-age=3600"])
            case "/api/state": ensureDeck(); return .json(stateObject())
            case "/api/stats": ensureDeck(); return .json(statsObject())
            default:
                if p.hasPrefix("/api/card/"), p.hasSuffix(".jpg") {
                    return cardImage(String(p.dropFirst("/api/card/".count).dropLast(".jpg".count)), out: Int(r.query["out"] ?? "") ?? 480)
                }
                return .error(404, "not found")
            }
        }
        if r.method == "POST" {
            let body = r.json ?? [:]
            switch p {
            case "/api/decision": return decision(body)
            case "/api/undo": return undo()
            case "/api/label": return setLabel(body)
            case "/api/level": return level(body)
            case "/api/autopick": return autopick()
            default: return .error(404, "not found")
            }
        }
        return .error(405, "method not allowed")
    }

    private func manifest() -> PhoneResponse {
        let m: [String: Any] = [
            "name": "Thon swipe", "short_name": "Thon", "start_url": "/?t=\(token)", "scope": "/",
            "display": "standalone", "orientation": "portrait", "background_color": "#000000", "theme_color": "#000000",
            "icons": [["src": "/icon.png", "sizes": "180x180", "type": "image/png"]],
        ]
        var resp = PhoneResponse.json(m)
        resp.contentType = "application/manifest+json"
        return resp
    }

    // MARK: deck and state

    /// Keeps the swipe deck in step with the micrograph that is open in Thon (the Mac's swipe sheet may be closed).
    func ensureDeck() {
        if let p = pendingKey {
            if pc.currentKey.map(FrameKey.base) == p && !host.phoneIsLoading { pendingKey = nil }
            else if Date().timeIntervalSince(pendingSince) > 30 { pendingKey = nil }
        }
        if store.scheme.label(pc.activeLabel) == nil { pc.activeLabel = store.scheme.firstID }     // the scheme was edited on the Mac
        let busy = pc.autoBusy
        let justFinished = sawAutoBusy && !busy
        sawAutoBusy = busy
        guard pc.currentKey != nil, pendingKey == nil, !host.phoneIsLoading, !busy else { return }
        if justFinished || sw.builtKey != pc.currentKey { sw.rebuild() }
    }

    var schemeRev: String {
        let s = store.scheme.labels.map { "\($0.id)|\($0.name)|\($0.key)|\($0.color)|\($0.shape.rawValue)|\($0.exported)" }.joined(separator: ";")
        return String(format: "%08x", UInt32(truncatingIfNeeded: stableHash(s)))
    }

    private func statsDict(_ s: SwipeStats) -> [String: Any] {
        ["cards": s.cards, "pick": s.pick, "reject": s.reject, "unsure": s.unsure, "decoySeen": s.decoySeen, "decoyPick": s.decoyPick,
         "realSeen": s.realSeen, "realPick": s.realPick,
         "pickRateReal": jsonOpt(s.pickRateReal), "pickRateDecoy": jsonOpt(s.pickRateDecoy)]
    }

    func stateObject() -> [String: Any] {
        let key = pc.currentKey
        let loading = host.phoneIsLoading || pendingKey != nil
        var level: [String: Any] = [
            "key": jsonOpt(key), "name": jsonOpt(key.map { ($0 as NSString).lastPathComponent }),
            "index": jsonOpt(host.phoneMicIndex), "count": host.phoneMicCount,
            "total": sw.total, "reviewed": min(sw.reviewed, sw.total), "done": sw.done && sw.total > 0, "empty": sw.total == 0,
            "loading": loading, "autoBusy": pc.autoBusy,
            "candidates": key.map { store.candidates($0).count } ?? 0,
        ]
        var card: Any = NSNull()
        var upcoming: [String] = []
        if let key, !loading, sw.builtKey == key, let c = sw.current {
            let wp = max(sw.windowPx, 1e-9)
            let dia = pc.diameterPx(Pick(x: 0, y: 0, label: pc.activeLabel)) / wp
            var cross = [0.5, 0.5]
            if let o = sw.override { cross = [(o.x - c.x) / wp + 0.5, (o.y - c.y) / wp + 0.5] }
            card = ["ref": "\(key)@\(c.id)", "diameterFrac": dia, "boxFrac": pc.boxPx / wp,
                    "cross": cross, "windowNm": sw.effectiveWindowNm, "view": sw.display.logTag] as [String: Any]
            upcoming = sw.queue.dropFirst().prefix(12).map { "\(key)@\($0.id)" }
        } else if sw.builtKey != key || loading {
            level["done"] = false; level["empty"] = false
        }
        let labels: [[String: Any]] = store.scheme.labels.map {
            ["id": $0.id, "name": $0.name, "key": $0.key, "color": $0.color, "shape": $0.shape.rawValue, "exported": $0.exported]
        }
        let fp = "\(sw.revision)|\(sw.reviewed)|\(sw.total)|\(key ?? "-")|\(pc.activeLabel)|\(schemeRev)|\(loading)|\(pc.autoBusy)|\(sw.canUndo)|\(sw.queue.count)|\(sw.override.map { "\($0.x),\($0.y)" } ?? "")"
        if fp != fingerprint { fingerprint = fp; rev += 1 }
        return [
            "v": PhoneAPI.version, "rev": rev, "project": ["name": store.projectTitle],
            "scheme": ["rev": schemeRev, "labels": labels] as [String: Any],
            "activeLabel": pc.activeLabel, "unsureLabel": jsonOpt(sw.unsureLabel),
            "level": level, "card": card, "upcoming": upcoming, "canUndo": sw.canUndo,
            "stats": ["level": statsDict(sw.levelStats), "all": statsDict(sw.stats)] as [String: Any],
        ]
    }

    func statsObject() -> [String: Any] {
        var per: [[String: Any]] = []
        for (k, r) in store.project.mics.sorted(by: { $0.key < $1.key }) {
            guard let log = r.swipe, !log.decisions.isEmpty else { continue }
            let s = SwipeStats.compute([log])
            per.append(["key": k, "cards": s.cards, "pick": s.pick, "reject": s.reject, "unsure": s.unsure])
        }
        return ["level": statsDict(sw.levelStats), "all": statsDict(sw.stats), "perLevel": per]
    }

    private func withState(_ extra: [String: Any], status: Int = 200) -> PhoneResponse {
        ensureDeck()
        var o = extra; o["state"] = stateObject()
        return .json(o, status: status)
    }

    // MARK: card image

    static func splitRef(_ ref: String) -> (key: String, id: String)? {
        guard let i = ref.lastIndex(of: "@") else { return nil }
        let key = String(ref[ref.startIndex..<i]), id = String(ref[ref.index(after: i)...])
        return key.isEmpty || id.isEmpty ? nil : (key, id)
    }

    private func cardImage(_ ref: String, out requested: Int) -> PhoneResponse {
        ensureDeck()
        guard let (key, id) = PhoneAPI.splitRef(ref), key == pc.currentKey, sw.builtKey == key,
              let c = sw.queue.first(where: { $0.id == id }), !pc.pixels.isEmpty else { return .error(404, "card not in deck") }
        let out = min(max(requested, 128), 800)
        let d = sw.display
        let base = sw.displayWindow()
        let wp = sw.windowPx
        let sig = "\(key)|\(pc.pixels.count)|\(id)|\(c.x),\(c.y)|\(wp)|\(out)|\(d.denoise.rawValue)|\(d.size)|\(d.h)|\(d.tone.rawValue)|\(d.brightness)|\(d.contrast)|\(d.gamma)|\(d.invert)|\(d.pixelated)|\(base.lo)|\(base.hi)"
        let headers = ["Cache-Control": "no-store"]
        if let hit = cache.get(sig) { return PhoneResponse(status: 200, contentType: "image/jpeg", body: hit, headers: headers) }
        let pixels = pc.pixels, w = Int(pc.imageSize.width), h = Int(pc.imageSize.height)
        let cache = self.cache
        var resp = PhoneResponse(status: 200, contentType: "image/jpeg", body: Data(), headers: headers)
        resp.deferred = {
            let plate = CardPlate.make(pixels: pixels, width: w, height: h, cx: c.x, cy: c.y, boxPx: wp, out: out,
                                       denoise: d.denoise, size: d.size, h: d.h)
            let win = d.window(base: d.tone == .micrograph ? base : plate.localWindow())
            let bytes = plate.render(out: out, lo: win.lo, hi: win.hi, gamma: Float(d.gamma), invert: d.invert, nearest: d.pixelated)
            guard let jpg = phoneJPEG(gray: bytes, size: out) else { return .error(500, "encode failed") }
            cache.put(sig, jpg)
            return PhoneResponse(status: 200, contentType: "image/jpeg", body: jpg, headers: headers)
        }
        return resp
    }

    // MARK: actions

    private func decision(_ b: [String: Any]) -> PhoneResponse {
        guard let ref = b["ref"] as? String, let (key, id) = PhoneAPI.splitRef(ref),
              let kind = b["decision"] as? String, ["pick", "reject", "unsure", "later"].contains(kind) else { return .error(400, "bad decision") }
        if let cid = b["cid"] as? String {
            if seenSet.contains(cid) { return withState(["applied": false, "reason": "duplicate"]) }
            seenSet.insert(cid); seenCids.append(cid)
            if seenCids.count > 500 { seenSet.remove(seenCids.removeFirst()) }
        }
        ensureDeck()
        guard key == pc.currentKey, pendingKey == nil else { return withState(["applied": false, "reason": "level changed"], status: 409) }
        if sw.current?.id != id {
            if !sw.promote(id) {
                let decided = store.record(key).swipe?.decisions.contains { $0.id == id } ?? false
                return withState(["applied": false, "reason": decided ? "already decided" : "unknown card"])
            }
        }
        var reason: String?
        if let u = (b["u"] as? NSNumber)?.doubleValue, let v = (b["v"] as? NSNumber)?.doubleValue,
           (0...1).contains(u), (0...1).contains(v), let p = sw.point(atFraction: u, v) { sw.recenter(to: p) }
        let ms = (b["ms"] as? NSNumber).map { min(max($0.intValue, 0), 600_000) }
        switch kind {
        case "pick":
            var lab = pc.activeLabel
            if let l = b["label"] as? String {
                if store.scheme.label(l)?.exported == true { lab = l } else { reason = "label replaced" }
            }
            sw.accept(label: lab)
        case "reject": sw.reject()
        case "unsure":
            if sw.unsureLabel == nil { reason = "no unsure label; moved to end" }
            sw.unsure()
        default: sw.later()
        }
        if let ms, kind != "later", var log = store.record(key).swipe, let i = log.decisions.lastIndex(where: { $0.id == id }) {
            log.decisions[i].ms = ms; store.setSwipe(key, log)
        }
        var extra: [String: Any] = ["applied": true]
        if let reason { extra["reason"] = reason }
        return withState(extra)
    }

    private func undo() -> PhoneResponse {
        ensureDeck()
        guard sw.canUndo else { return withState(["applied": false, "reason": "nothing to undo"]) }
        sw.undo()
        return withState(["applied": true])
    }

    private func setLabel(_ b: [String: Any]) -> PhoneResponse {
        guard let id = b["id"] as? String, store.scheme.label(id)?.exported == true else { return .error(400, "unknown or non-exported label") }
        pc.activeLabel = id
        return withState(["applied": true])
    }

    private func level(_ b: [String: Any]) -> PhoneResponse {
        let action = b["action"] as? String ?? ""
        switch action {
        case "rebuild":
            sw.rebuild()
        case "next", "prev":
            guard let cur = host.phoneMicIndex else { return withState(["applied": false, "reason": "no micrograph open"], status: 409) }
            let step = action == "next" ? 1 : -1
            var target: Int?
            var i = cur + step
            while i >= 0 && i < host.phoneMicCount {
                if let k = host.phoneMicKey(at: i), !store.candidates(k).isEmpty { target = i; break }
                i += step
            }
            if target == nil, (0..<host.phoneMicCount).contains(cur + step) { target = cur + step }
            guard let t = target, let k = host.phoneMicKey(at: t) else { return withState(["applied": false, "reason": "no further micrograph"], status: 409) }
            pendingKey = k; pendingSince = Date()
            host.phoneOpenMic(at: t)
        default:
            return .error(400, "bad action")
        }
        return withState(["applied": true])
    }

    private func autopick() -> PhoneResponse {
        guard pc.currentKey != nil, !pc.pixels.isEmpty else { return withState(["applied": false, "reason": "no micrograph open"], status: 409) }
        if !pc.autoBusy { pc.runAutoPick() }
        return withState(["applied": true])
    }
}
