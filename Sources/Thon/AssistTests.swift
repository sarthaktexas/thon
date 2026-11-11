import Foundation

private func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return cond()
}

/// Synthetic micrograph: gaussian noise plus a slow gradient, with round bright particles (the thing a user accepts) and
/// the usual false candidates: dark puddles, merged clumps and particles sitting off-centre in their box.
private struct SynthMic {
    let w = 768, h = 768, diam = 22.0
    var px: [Float]
    var cands: [(x: Double, y: Double, yes: Bool)] = []

    init(seed: UInt64, n: Int = 140) {
        var rng = AssistRNG(seed)
        func gauss() -> Float { var s: Float = 0; for _ in 0..<6 { s += Float(rng.unit()) }; return (s - 3) * 1.414 }
        px = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { px[y * w + x] = 100 + 8 * Float(x) / Float(w) + gauss() } }
        func blob(_ cx: Double, _ cy: Double, _ r: Double, _ amp: Float) {
            let R = Int(r * 3) + 1
            for y in max(0, Int(cy) - R)..<min(h, Int(cy) + R + 1) { for x in max(0, Int(cx) - R)..<min(w, Int(cx) + R + 1) {
                let d2 = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
                px[y * w + x] += amp * Float(exp(-d2 / (2 * r * r)))
            } }
        }
        let m = 40.0
        for i in 0..<n {
            let x = m + rng.unit() * (Double(w) - 2 * m), y = m + rng.unit() * (Double(h) - 2 * m)
            switch i % 5 {
            case 0, 1:      // true particle: round, centred, 3 to 7 sigma tall
                blob(x, y, diam / 4 * (0.85 + 0.3 * rng.unit()), Float(3 + 4 * rng.unit())); cands.append((x, y, true))
            case 2:         // dark puddle
                blob(x, y, diam / 3, -Float(3 + 3 * rng.unit())); cands.append((x, y, false))
            case 3:         // clump of three blobs, candidate at the middle
                for k in 0..<3 { let a = Double(k) * 2.1 + rng.unit(); blob(x + 9 * cos(a), y + 9 * sin(a), diam / 5, Float(3 + 3 * rng.unit())) }
                cands.append((x, y, false))
            default:        // particle, but the candidate sits half a diameter away from it
                blob(x + 0.5 * diam, y, diam / 4, Float(3 + 4 * rng.unit())); cands.append((x, y, false))
            }
        }
    }
    func hand(_ c: (x: Double, y: Double, yes: Bool)) -> [Float]? { CardFeatures.hand(pixels: px, width: w, height: h, cx: c.x, cy: c.y, diameterPx: diam) }
}

func testAssist(_ t: inout TestRun) {
    t.section("swipe assistant: features")
    let m = SynthMic(seed: 1)
    let yes = m.cands.first { $0.yes }!
    let f1 = m.hand(yes), f2 = m.hand(yes)
    t.check(f1?.count == CardFeatures.handLength && f1 == f2 && f1!.allSatisfy { $0.isFinite }, "features have fixed length, are finite and deterministic")
    let scaled = CardFeatures.hand(pixels: m.px.map { 3 * $0 + 500 }, width: m.w, height: m.h, cx: yes.x, cy: yes.y, diameterPx: m.diam)!
    t.check(zip(scaled, f1!).allSatisfy { abs($0 - $1) < 2e-3 }, "features ignore gain and offset of the micrograph")
    let sumIdx = CardFeatures.radialBins           // summary block: core, ring, out, contrast, coreStd, std, sectorSpread, offset, peak
    t.check(f1![sumIdx + 3] > 2, "a particle has a bright core against its surround", "\(f1![sumIdx + 3])")
    let off = m.cands.enumerated().filter { !$0.element.yes && $0.offset % 5 == 4 }.compactMap { m.hand($0.element) }
    let ctr = m.cands.enumerated().filter { $0.element.yes }.compactMap { m.hand($0.element) }
    let mo = off.map { $0[sumIdx + 7] }.reduce(0, +) / Float(off.count), mc = ctr.map { $0[sumIdx + 7] }.reduce(0, +) / Float(ctr.count)
    t.check(mo > mc + 0.2, "an off-centre particle has a larger centroid offset than a centred one", "off \(mo) vs centred \(mc)")
    let edge = CardFeatures.hand(pixels: m.px, width: m.w, height: m.h, cx: 2, cy: 3, diameterPx: m.diam)
    t.check(edge?.allSatisfy { $0.isFinite } == true, "a candidate at the image corner still gives finite features")
    t.check(CardFeatures.hand(pixels: [1, 2, 3], width: 768, height: 768, cx: 5, cy: 5, diameterPx: 20) == nil, "too few pixels -> nil")
    let constant = CardFeatures.hand(pixels: [Float](repeating: 7, count: 100 * 100), width: 100, height: 100, cx: 50, cy: 50, diameterPx: 20)
    t.check(constant?.allSatisfy { $0.isFinite } == true, "a flat image does not produce NaN")

    t.section("swipe assistant: classifier")
    var rng = AssistRNG(7)
    func cluster(_ n: Int, shift: Float, d: Int = 6) -> ([[Float]], [Float]) {
        var X: [[Float]] = [], y: [Float] = []
        for i in 0..<n { let c: Float = i % 2 == 0 ? shift : -shift; X.append((0..<d).map { _ in c + Float(rng.unit() + rng.unit() - 1) * 1.5 }); y.append(i % 2 == 0 ? 1 : 0) }
        return (X, y)
    }
    let (Xs, ys) = cluster(120, shift: 1.2)
    let ms = Logistic.fit(Xs, ys, lambda: 1)
    t.check(ms != nil && (Logistic.auc(scores: Xs.map { ms!.probability($0) }, labels: ys) ?? 0) > 0.97, "separable clusters are learned")
    t.check(Logistic.fit(Xs, [Float](repeating: 1, count: Xs.count), lambda: 1) == nil, "one class only -> no model")
    t.check(ms?.probability([1, 2]) == 0.5, "wrong feature length -> neutral probability")
    t.check(Logistic.auc(scores: [0.1, 0.9, 0.5, 0.5], labels: [0, 1, 0, 1]) == 0.875, "AUC with ties counts half")
    let cv = Logistic.crossValidate(Xs, ys)
    t.check((cv?.auc ?? 0) > 0.95 && (cv?.accuracy ?? 0) > 0.85, "cross-validation sees the signal", "\(String(describing: cv))")
    var noise: [[Float]] = [], nl: [Float] = []
    for i in 0..<120 { noise.append((0..<40).map { _ in Float(rng.unit() - 0.5) }); nl.append(i % 2 == 0 ? 1 : 0) }
    let cvn = Logistic.crossValidate(noise, nl)
    t.check((cvn?.auc ?? 0.5) > 0.3 && (cvn?.auc ?? 0.5) < 0.68, "labels with no signal do not look learnable", "\(String(describing: cvn))")

    t.section("swipe assistant: ordering")
    let decoy = [false, false, true, false, false, false, false, true, false, false, false, false]
    let p: [Float?] = [0.5, 0.2, nil, 0.9, 0.1, 0.8, 0.3, nil, 0.7, 0.6, 0.4, 0.95]
    let perm = Reranker.order(decoy: decoy, p: p, mode: .likely, seed: 3)
    t.check(Set(perm) == Set(0..<decoy.count) && perm.count == decoy.count, "ordering is a permutation")
    t.check(perm[0] == 0 && perm[2] == 2 && perm[7] == 7, "the card on screen and the decoys keep their positions")
    let slots = (1..<decoy.count).filter { !decoy[$0] }
    t.check(perm[slots[0]] == 11, "most likely card comes first", "\(perm)")
    t.check(perm == Reranker.order(decoy: decoy, p: p, mode: .likely, seed: 3), "ordering is deterministic for a seed")
    t.check(Reranker.order(decoy: decoy, p: p, mode: .off, seed: 3) == Array(0..<decoy.count), "mode off leaves the deck alone")
    let unc = Reranker.order(decoy: decoy, p: p, mode: .uncertain, seed: 3)
    t.check(p[unc[slots[0]]].map({ abs($0 - 0.5) <= 0.1 + 1e-6 }) == true, "uncertain-first starts with a card near 0.5", "\(unc)")

    t.section("swipe assistant: end to end on a synthetic micrograph")
    let train = SynthMic(seed: 11), test = SynthMic(seed: 12)
    let rr = Reranker()
    var fired = 0
    rr.onChange = { fired += 1 }
    for (i, c) in train.cands.enumerated() { rr.observe(key: "m1", id: "c\(i)", decision: c.yes ? "pick" : "reject", decoy: false, hand: train.hand(c), embedding: nil) }
    t.check(rr.status.positives == train.cands.filter { $0.yes }.count, "counts follow the decisions", "\(rr.status)")
    t.check(waitUntil(20) { rr.status.ready && rr.model != nil }, "a model appears once there are enough yes and no decisions")
    _ = waitUntil(30) { rr.status.trainedOn == rr.samples.count }          // the first fit (10 yes, 10 no) lands early; the last one has seen every decision
    t.check(fired > 0, "the owner is told when the model changes")
    t.check((rr.status.auc ?? 0) > 0.9 && (rr.status.accuracy ?? 0) > 0.8, "held-out accuracy reported to the user is high on separable data", "\(rr.status.summary)")
    let probs = test.cands.map { rr.probability(hand: test.hand($0), embedding: nil) }
    let auc = Logistic.auc(scores: probs.map { $0 ?? 0 }, labels: test.cands.map { $0.yes ? 1 : 0 })
    t.check((auc ?? 0) > 0.9, "it ranks particles of an unseen micrograph above puddles, clumps and off-centre boxes", "AUC \(String(describing: auc))")
    var order = Array(0..<test.cands.count); var r2 = AssistRNG(5)
    for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, r2.int(below: i + 1)) }
    let perm2 = Reranker.order(decoy: [Bool](repeating: false, count: order.count), p: order.map { probs[$0] }, mode: .likely, seed: 9)
    let topK = perm2.prefix(20).filter { test.cands[order[$0]].yes }.count
    t.check(topK >= 16, "at least 16 of the first 20 cards are real particles after re-ranking", "\(topK)/20")
    let before = rr.status.positives + rr.status.negatives
    rr.forget(key: "m1", id: "c0"); rr.observe(key: "m1", id: "c1", decision: "unsure", decoy: false, hand: train.hand(train.cands[1]), embedding: nil)
    t.check(rr.status.positives + rr.status.negatives == before - 2, "undo and 'unsure' remove a sample")
    t.check(Reranker.decoyNegativeWeight < 1, "decoy negatives are down-weighted")

    t.section("swipe assistant: persistence and Core ML fallback")
    let dir = testTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let proj = dir.appendingPathComponent("p.thon")
    let store = PickStore(); store.saveDelay = 0; store.openProject(file: proj)
    let a = Reranker(); a.use(store: store)
    for (i, c) in train.cands.enumerated() { a.observe(key: "m1", id: "c\(i)", decision: c.yes ? "pick" : "reject", decoy: false, hand: train.hand(c), embedding: [1, 2, 3]) }
    _ = waitUntil(20) { a.status.ready }
    a.save(); store.save()
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    t.check(!names.contains { $0.hasSuffix(".assist.json") } && names.contains("p.thon"), "samples are saved inside the project, no separate file", "\(names)")
    let store2 = PickStore(); store2.openProject(file: proj)
    t.check(store2.project.assist != nil, "the .thon file carries the samples")
    let b = Reranker(); b.use(store: store2)
    t.check(b.samples.values.allSatisfy { $0.e == nil }, "embeddings are not written to the project")
    t.check(b.samples.count == a.samples.count && b.status.positives == a.status.positives, "samples load again")
    t.check(waitUntil(20) { b.status.ready }, "a reloaded project retrains by itself")
    b.reset()
    t.check(b.model == nil && b.samples.isEmpty && !b.status.ready, "reset forgets everything")
    // a sidecar from an older version is imported once, and a reset is not undone by it
    let dir2 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
    let p2 = dir2.appendingPathComponent("q.thon")
    if let d = store.project.assist { try? d.write(to: dir2.appendingPathComponent("q.assist.json")) }
    let s3 = PickStore(); s3.saveDelay = 0; s3.openProject(file: p2)
    let c3 = Reranker(); c3.use(store: s3)
    t.check(c3.samples.count == a.samples.count, "an older <name>.assist.json is imported", "\(c3.samples.count) vs \(a.samples.count)")
    c3.reset(); s3.save()
    let s4 = PickStore(); s4.openProject(file: p2)
    let c4 = Reranker(); c4.use(store: s4)
    t.check(c4.samples.isEmpty, "after reset the old sidecar does not come back")
    // visible backup folders from older versions move into the hidden one
    let dir3 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir3) }
    let old3 = dir3.appendingPathComponent("r_backups"); try? FileManager.default.createDirectory(at: old3, withIntermediateDirectories: true)
    try? Data("{}".utf8).write(to: old3.appendingPathComponent("r_20200101_000000_000.thon"))
    let s5 = PickStore(); s5.saveDelay = 0; s5.openProject(file: dir3.appendingPathComponent("r.thon")); _ = s5.save(forceBackup: true)
    let hid = s5.backupDirectory(root: dir3)
    let moved = (try? FileManager.default.contentsOfDirectory(atPath: hid.path)) ?? []
    t.check(hid.lastPathComponent == ".r_backups" && moved.contains("r_20200101_000000_000.thon") && moved.count == 2 && !FileManager.default.fileExists(atPath: old3.path), "old visible backups are moved into the hidden folder", "\(moved)")
    t.check(CoreMLEmbedding.embed(gray: [1, 2, 3], size: 64) == nil, "embedding refuses malformed input")
    _ = CoreMLEmbedding.embed(gray: [UInt8](repeating: 128, count: 64 * 64), size: 64)       // nil or a vector; must not crash
    let e = Reranker(); e.useEmbedding = true
    for (i, c) in train.cands.enumerated() { e.observe(key: "m1", id: "c\(i)", decision: c.yes ? "pick" : "reject", decoy: false, hand: train.hand(c), embedding: nil) }
    t.check(waitUntil(20) { e.status.ready }, "with Core ML features switched on but unavailable it still trains")
    t.check(!e.status.usingEmbedding && e.status.note != nil, "and says that it fell back to hand-made features", "\(e.status.summary)")
}
