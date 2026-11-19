import Foundation

// Headless tests of the pattern suggestions (`Thon --picktest`): the neighbour grid, the random comparison, the statistics on
// synthetic arrangements (a pattern planted, and arrangements with nothing in them), pooling and correction, and the model.

private let pW = 6000.0, pH = 4500.0, pD = 100.0          // image px, particle diameter px; 10 Å/px, so a particle is 100 nm

private func gauss(_ r: inout PatternRNG) -> Double { let u = max(r.uniform(), 1e-12), v = r.uniform(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) }
private func uniformPts(_ n: Int, _ r: inout PatternRNG) -> [(Double, Double)] { (0..<n).map { _ in (100 + r.uniform() * (pW - 200), 100 + r.uniform() * (pH - 200)) } }
private func hardCorePts(_ n: Int, _ sep: Double, _ r: inout PatternRNG) -> [(Double, Double)] {
    var out: [(Double, Double)] = []; var tries = 0
    while out.count < n && tries < 200000 {
        tries += 1
        let p = (100 + r.uniform() * (pW - 200), 100 + r.uniform() * (pH - 200))
        if !out.contains(where: { hypot($0.0 - p.0, $0.1 - p.1) < sep }) { out.append(p) }
    }
    return out
}
private func pin(_ key: String, _ pts: [(Double, Double)], groups: [String]? = nil, w: Double = pW, h: Double = pH) -> PatternInput {
    PatternInput(key: key, x: pts.map { $0.0 }, y: pts.map { $0.1 }, group: groups, width: w, height: h, diameterPx: pD, angpix: 10)
}
private func hexPatch(_ cols: Int, _ rows: Int, at o: (Double, Double), jitter: Double, _ r: inout PatternRNG) -> [(Double, Double)] {
    let a = 1.25 * pD
    var out: [(Double, Double)] = []
    for i in 0..<cols { for j in 0..<rows {
        out.append((o.0 + Double(i) * a + (j % 2 == 1 ? a / 2 : 0) + jitter * pD * gauss(&r), o.1 + Double(j) * a * 0.866 + jitter * pD * gauss(&r)))
    } }
    return out
}

func testPatterns(_ t: inout TestRun) {
    t.section("pattern suggestions")
    var fast = PatternParams(); fast.nSim = 299

    // random numbers: streams started a fixed stride apart must not be shifted copies of each other
    var a = PatternRNG(seed: 5), b = PatternRNG(seed: 5 &+ 0x9E3779B97F4A7C15)
    let sa = (0..<8).map { _ in a.next() }, sb = (0..<8).map { _ in b.next() }
    t.check(Set(sa).isDisjoint(with: Set(sb)), "seeds a fixed stride apart give unrelated streams")
    var u1 = PatternRNG(seed: 9), u2 = PatternRNG(seed: 9)
    t.check((0..<20).allSatisfy { _ in u1.next() == u2.next() }, "same seed, same numbers")
    var us = PatternRNG(seed: 3); let uv = (0..<5000).map { _ in us.uniform() }
    t.check(uv.allSatisfy { $0 >= 0 && $0 < 1 } && abs(uv.reduce(0, +) / 5000 - 0.5) < 0.02, "uniform numbers are in [0, 1) with mean 1/2")

    // neighbour grid against brute force
    var g = PatternRNG(seed: 1)
    let gp = uniformPts(300, &g)
    let grid = PointGrid(xs: gp.map { $0.0 }, ys: gp.map { $0.1 }, cell: 250)
    var gridOK = true, nearOK = true
    for i in stride(from: 0, to: 300, by: 17) {
        var fast: [Int] = []
        grid.within(gp[i].0, gp[i].1, 600) { j, _ in fast.append(j) }
        let brute = (0..<300).filter { hypot(gp[$0].0 - gp[i].0, gp[$0].1 - gp[i].1) <= 600 }
        if Set(fast) != Set(brute) { gridOK = false }
        let k6 = grid.nearest(of: i, k: 6)
        let bk = (0..<300).filter { $0 != i }.sorted { hypot(gp[$0].0 - gp[i].0, gp[$0].1 - gp[i].1) < hypot(gp[$1].0 - gp[i].0, gp[$1].1 - gp[i].1) }.prefix(6)
        if k6 != Array(bk) { nearOK = false }
    }
    t.check(gridOK, "radius search matches brute force")
    t.check(nearOK, "six nearest neighbours match brute force")
    t.check(PointGrid(xs: [1], ys: [1], cell: 5).nearest(of: 0, k: 3).isEmpty, "a single point has no neighbours")

    // the random comparison
    let win = PatternWindow(x0: 100, y0: 100, x1: 5900, y1: 4400)
    var nr = PatternRNG(seed: 4)
    let np = PatternEngine.nullPoints(n: 250, win: win, d0: 150, rng: &nr)
    var minD = Double.infinity
    for i in 0..<250 { for j in (i + 1)..<250 { minD = min(minD, hypot(np.x[i] - np.x[j], np.y[i] - np.y[j])) } }
    t.check(np.x.count == 250 && np.hard && minD >= 150 - 1e-9 && np.x.allSatisfy { $0 >= 100 && $0 <= 5900 } && np.y.allSatisfy { $0 >= 100 && $0 <= 4400 }, "random positions: right count, inside the window, never closer than the minimum spacing", "min \(minD)")
    let crowded = PatternEngine.nullPoints(n: 400, win: PatternWindow(x0: 0, y0: 0, x1: 1000, y1: 1000), d0: 150, rng: &nr)
    t.check(crowded.x.count == 400 && !crowded.hard, "an impossible spacing falls back and says so")
    let dense = (0..<80).map { _ in (1000 + 150 * gauss(&nr), 1000 + 150 * gauss(&nr)) }
    let inh = PatternEngine.intensity(x: dense.map { $0.0 }, y: dense.map { $0.1 }, win: win, sigma: 300, cell: 100)
    var near = 0
    for _ in 0..<2000 { let q = inh.sample(&nr); if hypot(q.0 - 1000, q.1 - 1000) < 900 { near += 1 } }
    t.check(near > 1500, "positions drawn from a smooth density follow where the picks are", "\(near) of 2000 near the cluster")
    // edge correction: uniform picks must give a flat density right up to the border
    var er = PatternRNG(seed: 12)
    let uni = uniformPts(600, &er)
    let flat = PatternEngine.intensity(x: uni.map { $0.0 }, y: uni.map { $0.1 }, win: win, sigma: 600, cell: 150)
    var edgeShare = 0, total = 6000
    for _ in 0..<total { let q = flat.sample(&nr); if q.0 < 600 || q.0 > 5300 || q.1 < 600 || q.1 > 3900 { edgeShare += 1 } }
    let expectedEdge = 1 - (4700.0 * 3300.0) / (5800.0 * 4300.0)
    t.check(abs(Double(edgeShare) / Double(total) - expectedEdge) < 0.05, "the smooth density is not thinned near the border", "\(Double(edgeShare) / Double(total)) vs \(expectedEdge)")

    // combining and correcting
    t.check(abs(PatternEngine.chiSquareTail2m(4.605170186, m: 1) - 0.1) < 1e-6, "chi-square tail, 2 degrees of freedom")
    t.check(abs(PatternEngine.fisher([0.01, 0.01]) - 0.00102103) < 1e-6 && PatternEngine.fisher([0.3]) == 0.3 && PatternEngine.fisher([]) == 1, "Fisher's method")
    t.check(PatternEngine.holm([0.01, 0.04, 0.03, 0.5]) == [0.04, 0.09, 0.09, 0.5], "Holm adjustment", "\(PatternEngine.holm([0.01, 0.04, 0.03, 0.5]))")
    t.check(PatternEngine.mcP(10, [1, 2, 3, 10, 11]) == 3.0 / 6.0 && PatternEngine.mcP(100, [1, 2]) == 1.0 / 3.0, "Monte-Carlo p counts ties and never reaches 0")

    // planted patterns
    var r = PatternRNG(seed: 11)
    func rep(_ i: PatternInput, _ p: PatternParams? = nil) -> PatternReport { PatternEngine.run([i], params: p ?? fast) }
    func pOf(_ rp: PatternReport, _ k: PatternKind) -> Double { rp.rows.first { $0.kind == k }?.p ?? 1 }
    let hex = hexPatch(14, 10, at: (800, 800), jitter: 0.06, &r) + uniformPts(60, &r)
    let rh = rep(pin("hex", hex))
    t.check(pOf(rh, .hexagonal) <= 0.01 && pOf(rh, .spacing) <= 0.01, "a jittered hexagonal lattice is found as hexagonal packing with a preferred spacing", "\(rh.rows.prefix(4).map { "\($0.kind.rawValue) \($0.p)" })")
    if let m = rh.micrographs.first, let sp = m.desc[.hexagonal]?["spacingNm"] {
        t.check(abs(sp - 125) < 12, "the lattice spacing comes out near the planted 125 nm", "\(sp)")
        t.check(!(m.geometry[.hexagonal]?.isEmpty ?? true), "the hexagonal patches come with something to draw")
    } else { t.check(false, "hexagonal description exists") }

    var rows: [(Double, Double)] = []
    for k in 0..<4 { let y0 = 700 + Double(k) * 900; for i in 0..<12 { rows.append((900 + Double(i) * 1.15 * pD, y0 + 0.08 * pD * gauss(&r))) } }
    rows += hardCorePts(90, pD, &r)
    let rr = rep(pin("rows", rows))
    t.check(pOf(rr, .lines) <= 0.01, "four rows of twelve are found as straight rows", "\(pOf(rr, .lines))")
    if let m = rr.micrographs.first {
        let n = Int(m.desc[.lines]?["rows"] ?? 0)
        t.check(n >= 3 && n <= 6, "about four rows are listed", "\(n)")
        t.check(abs((m.desc[.lines]?["angle"] ?? 99) - 0) < 5 || abs((m.desc[.lines]?["angle"] ?? 99) - 180) < 5, "the rows are reported as parallel and horizontal", "\(String(describing: m.desc[.lines]))")
    }

    var rings: [(Double, Double)] = []
    for (cx, cy) in [(1500.0, 1500.0), (4200.0, 2000.0), (2500.0, 3500.0)] { for k in 0..<12 { let th = Double(k) / 12 * 2 * .pi; rings.append((cx + 3 * pD * cos(th) + 0.05 * pD * gauss(&r), cy + 3 * pD * sin(th) + 0.05 * pD * gauss(&r))) } }
    rings += hardCorePts(100, pD, &r)
    let rg = rep(pin("rings", rings))
    t.check(pOf(rg, .rings) <= 0.01, "three rings of twelve are found as rings", "\(pOf(rg, .rings))")
    if let m = rg.micrographs.first, let rad = m.desc[.rings]?["radiusNm"] { t.check(abs(rad - 300) < 40, "the ring radius comes out near the planted 300 nm", "\(rad)") } else { t.check(false, "ring radius reported") }

    var cl: [(Double, Double)] = []
    for _ in 0..<10 { let cx = 500 + r.uniform() * 5000, cy = 500 + r.uniform() * 3500; for _ in 0..<6 { cl.append((cx + 0.7 * pD * gauss(&r), cy + 0.7 * pD * gauss(&r))) } }
    cl += uniformPts(80, &r)
    let rc = rep(pin("cl", cl))
    t.check(pOf(rc, .aggregates) <= 0.01 && pOf(rc, .clustering) <= 0.01, "ten tight clusters are found as aggregates and as closeness", "\(pOf(rc, .aggregates)) \(pOf(rc, .clustering))")

    let seg = uniformPts(160, &r)
    let rs = rep(pin("seg", seg, groups: seg.map { $0.0 < pW / 2 ? "A" : "B" }))
    t.check(pOf(rs, .segregation) <= 0.01 && pOf(rs, .mixing) > 0.5, "two types on opposite halves sit together, not alternating", "\(pOf(rs, .segregation)) \(pOf(rs, .mixing))")
    var alt: [(Double, Double)] = [], altG: [String] = []
    // alternating types on a loose grid: neighbours are almost always the other type
    for i in 0..<14 { for j in 0..<10 { alt.append((500 + Double(i) * 1.8 * pD * 3, 500 + Double(j) * 1.8 * pD * 3)); altG.append((i + j) % 2 == 0 ? "A" : "B") } }
    let ra = rep(pin("alt", alt, groups: altG))
    t.check(pOf(ra, .mixing) <= 0.01 && pOf(ra, .segregation) > 0.5, "types in a chessboard alternate", "\(pOf(ra, .mixing))")

    var gr: [(Double, Double)] = []
    while gr.count < 200 { gr.append((100 + (pW - 200) * pow(r.uniform(), 1.8), 100 + r.uniform() * (pH - 200))) }
    let rgr = rep(pin("gr", gr))
    t.check(pOf(rgr, .gradient) <= 0.01 && pOf(rgr, .patchiness) <= 0.01, "a density that falls off along x is found as drift and as uneven density", "\(pOf(rgr, .gradient)) \(pOf(rgr, .patchiness))")
    t.check(pOf(rgr, .clustering) > 0.01 && pOf(rgr, .aggregates) > 0.01, "uneven density alone is not reported as clustering or aggregates", "\(pOf(rgr, .clustering)) \(pOf(rgr, .aggregates))")
    var flatP = fast; flatP.useDensity = false
    let rflat = rep(pin("gr", gr), flatP)
    t.check(pOf(rflat, .clustering) < pOf(rgr, .clustering), "with the density allowance off the same picks do look clustered")
    t.check(rgr.notes.contains { $0.contains("own smooth density") } && !rflat.notes.contains { $0.contains("own smooth density") }, "the report says which comparison was used")

    if let m = rep(pin("plain", uniformPts(60, &r))).micrographs.first {
        t.check((m.desc[.lines]?["longest"] ?? 0) >= 2 && (m.desc[.rings]?["largest"] ?? -1) >= 0, "the longest row and largest ring are the observed ones, not zero when none qualifies", "\(String(describing: m.desc[.lines]))")
    }

    // nothing planted: the picker's spacing rule and plain randomness are not patterns
    var worst = 1.0, runs = 0, below01 = 0
    for s in 0..<5 {
        var rs2 = PatternRNG(seed: UInt64(100 + s))
        for pts in [uniformPts(150, &rs2), hardCorePts(250, pD, &rs2), hardCorePts(250, 1.6 * pD, &rs2)] {
            let q = rep(pin("n\(s)\(runs)", pts)); runs += 1
            worst = min(worst, q.rows.map { $0.pAdj }.min() ?? 1)
            below01 += q.rows.filter { $0.p <= 0.01 }.count
        }
    }
    t.check(worst >= 0.05, "15 arrangements with nothing planted give no corrected finding", "smallest corrected p \(worst)")
    t.check(below01 <= 5, "tests that fire at p <= 0.01 are rare when nothing is planted (180 tests, about 2 expected)", "\(below01)")

    // pooling: a small lattice patch in each of eight micrographs
    var mics: [PatternInput] = []
    var pr = PatternRNG(seed: 77)
    for m in 0..<8 { mics.append(pin("m\(m)", uniformPts(120, &pr) + hexPatch(5, 4, at: (1000, 1000), jitter: 0.05, &pr))) }
    let rp = PatternEngine.run(mics, params: fast)
    let hexRow = rp.rows.first { $0.kind == .hexagonal }
    t.check(hexRow.map { $0.level >= .likely && $0.micrographs == 8 } ?? false, "a weak lattice patch seen in eight micrographs is a finding once they are combined", "\(String(describing: hexRow?.pAdj))")
    t.check(rp.rows.allSatisfy { $0.pAdj >= $0.p - 1e-12 && $0.pAdj <= 1 }, "corrected p is never smaller than p")
    t.check(zip(rp.rows, rp.rows.dropFirst()).allSatisfy { $0.p <= $1.p }, "rows are ordered by p")

    // awkward input
    var ep = PatternParams(); ep.nSim = 30
    let dup = PatternEngine.analyze(pin("dup", Array(repeating: (3000, 2000), count: 30)), params: ep)
    t.check(dup.status == .ok && dup.tests.values.allSatisfy { $0.p.isFinite && $0.obs.isFinite }, "30 picks on one spot do not break anything")
    t.check(PatternEngine.analyze(pin("few", uniformPts(10, &r)), params: ep).status == .tooFew, "fewer than 15 picks are left out")
    let col = PatternEngine.analyze(pin("col", (0..<40).map { (500 + Double($0) * 120, 2000) }), params: ep)
    t.check(col.status == .ok && (col.tests[.lines]?.p ?? 1).isFinite, "picks on a single line are handled")
    t.check(PatternEngine.analyze(PatternInput(key: "ns", x: [1, 2], y: [1, 2], width: 10, height: 10, diameterPx: 0, angpix: 1), params: ep).status == .noScale, "no pixel size or diameter: left out, not guessed")
    var tiny = PatternRNG(seed: 8)
    let small = (0..<30).map { _ in (500 + tiny.uniform() * 300, 500 + tiny.uniform() * 300) }
    t.check(PatternEngine.analyze(pin("small", small, w: 0, h: 0), params: ep).status == .smallWindow, "unknown image size and picks spanning a few diameters: left out")
    let corner = PatternEngine.analyze(pin("corner", small), params: ep)
    t.check(corner.status == .ok, "with the image size known, picks packed in one corner are still analysed")
    let nowin = PatternEngine.analyze(PatternInput(key: "nw", x: uniformPts(60, &r).map { $0.0 }, y: uniformPts(60, &r).map { $0.1 }, width: 0, height: 0, diameterPx: pD, angpix: 10), params: ep)
    t.check(nowin.status == .ok && nowin.tests.count >= 8, "unknown image size: the picks' bounding box is the window")
    let again1 = PatternEngine.analyze(pin("det", hex), params: ep), again2 = PatternEngine.analyze(pin("det", hex), params: ep)
    t.check(again1.tests.mapValues { $0.p } == again2.tests.mapValues { $0.p }, "the same picks always give the same answer")
    var cancelled = 0
    let cr = PatternEngine.run([pin("c", hex)], params: fast, cancel: { cancelled += 1; return cancelled > 5 })
    t.check(cr.micrographs.isEmpty && cr.rows.isEmpty, "stopping part-way returns nothing half-done")

    // the model on a real store
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    var prm = c.store.project.params; prm.diameterNm = 10; c.store.setParams(prm)          // 10 nm at 1 Å/px: the same 100 px particle
    let lab = c.store.scheme.labels.first { $0.exported }!.id, rej = c.store.scheme.labels.first { !$0.exported }?.id
    var mr = PatternRNG(seed: 31)
    for (i, q) in (hexPatch(12, 8, at: (800, 800), jitter: 0.05, &mr) + uniformPts(50, &mr)).enumerated() { c.store.add(Pick(id: "h\(i)", x: q.0, y: q.1, label: lab), to: "a.mrc") }
    for i in 0..<30 { c.store.add(Pick(id: "k\(i)", x: 100 + Double(i) * 60, y: 50, label: lab, status: .candidate), to: "a.mrc") }
    if let rej { for i in 0..<30 { c.store.add(Pick(id: "r\(i)", x: 3000 + Double(i) * 10, y: 4000, label: rej), to: "a.mrc") } }
    c.store.setMicInfo("a.mrc", width: Int(pW), height: Int(pH), angpix: 1)
    c.setMicrograph(key: "a.mrc", width: Int(pW), height: Int(pH), pixelSizeA: 1)
    let inputs = c.patterns.buildInputs(keys: ["a.mrc"])
    t.check(inputs.count == 1 && inputs[0].x.count == 146 && abs(inputs[0].diameterPx - 100) < 1e-9, "only accepted, exported picks are analysed; diameter converted with the pixel size", "\(inputs.first?.x.count ?? -1) \(inputs.first?.diameterPx ?? -1)")
    c.patterns.includeCandidates = true
    let withCands = c.patterns.buildInputs(keys: ["a.mrc"])
    t.check(withCands.first?.x.count == 176, "candidates are added only when asked", "\(withCands.first?.x.count ?? -1)")
    for i in 0..<5 { c.store.add(Pick(id: "w\(i)", x: 200 + Double(i) * 70, y: 100, label: lab, score: 0.1, source: .auto, status: .candidate), to: "a.mrc") }
    let savedCutoff = c.scoreCutoff
    c.scoreCutoff = 5
    t.check(c.patterns.buildInputs(keys: ["a.mrc"]).first?.x.count == 176, "candidates below the score cutoff are left out")
    c.scoreCutoff = savedCutoff
    c.patterns.includeCandidates = false
    c.patterns.nSimOverride = 299
    c.patterns.run()
    var spins = 0
    while c.patterns.busy && spins < 400 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); spins += 1 }
    t.check(!c.patterns.busy && c.patterns.report != nil && c.patterns.reportScope == "This micrograph", "the model runs on its own queue and delivers a report")
    t.check(c.patterns.report?.rows.first { $0.kind == .hexagonal }.map { $0.p <= 0.01 } ?? false, "the lattice in the saved picks is found through the model")
    t.check(c.patterns.shown.contains(.hexagonal) || c.patterns.report?.findings.isEmpty == true, "found patterns are ticked for drawing")
    c.patterns.shown = [.hexagonal]
    t.check(!c.patterns.overlay(forKey: "a.mrc").isEmpty && c.patterns.overlay(forKey: "other.mrc").isEmpty, "the overlay has shapes for this micrograph and none for another")
    t.check(!c.patterns.isStale(), "a fresh result is not stale")
    c.store.add(Pick(id: "late", x: 3000, y: 3000, label: lab), to: "a.mrc")
    t.check(c.patterns.isStale(), "adding a pick makes the result stale")
    let csv = c.patterns.csvText()
    t.check(csv.hasPrefix("pattern,scope,p_value") && csv.split(separator: "\n").count == (c.patterns.report?.rows.count ?? 0) + 1, "csv: header and one line per question", csv.prefix(120).description)
    c.patterns.includeCandidates = true
    c.patterns.run()
    spins = 0
    while c.patterns.busy && spins < 400 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); spins += 1 }
    t.check(c.patterns.report?.notes.contains { $0.contains("unreviewed") } == true, "a result that used candidates says they are unreviewed")
    c.patterns.includeCandidates = false
    c.patterns.clear()
    t.check(c.patterns.report == nil && c.patterns.shown.isEmpty, "clear forgets the result")
    c.patterns.scopeAll = true; c.patterns.run()
    spins = 0
    while c.patterns.busy && spins < 400 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); spins += 1 }
    t.check(c.patterns.reportScope.hasPrefix("All micrographs") && c.patterns.report?.micrographs.count == 1, "all-micrographs scope runs on every micrograph that has picks")
}
