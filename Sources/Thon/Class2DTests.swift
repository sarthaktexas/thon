import Foundation

// Headless tests of the size histogram and of 2D classification (`Thon --picktest`).
// The last suite runs RELION for real on synthetic micrographs when RELION is found (it takes a few seconds); otherwise it says so and skips.

/// Soft disc (or ring) on a flat background with noise, one particle at (cx, cy). `outer` is the radius where the profile is half way down.
private func softParticle(into a: inout [Float], w: Int, h: Int, cx: Double, cy: Double, outer: Double, inner: Double = 0, amp: Double, edge: Double = 1.2) {
    let R = Int(outer + 8 * edge)
    for y in max(0, Int(cy) - R)...min(h - 1, Int(cy) + R) { for x in max(0, Int(cx) - R)...min(w - 1, Int(cx) + R) {
        let r = hypot(Double(x) - cx, Double(y) - cy)
        let o = 1 / (1 + exp((r - outer) / edge))
        let i = inner > 0 ? 1 / (1 + exp((r - inner) / edge)) : 0
        a[y * w + x] += Float(amp * (o - i))
    } }
}

func testSizes(_ t: inout TestRun) {
    t.section("particle sizes")
    // statistics
    let s = SizeStats.summary([1, 2, 3, 4, 100])
    t.check(s.n == 5 && s.median == 3 && s.min == 1 && s.max == 100 && abs(s.mean - 22) < 1e-9, "summary", "\(s)")
    t.check(SizeStats.quantile([0, 10], 0.25) == 2.5 && SizeStats.quantile([], 0.5) == 0, "quantile interpolates")
    t.check(SizeStats.niceWidth(0.8) == 1 && SizeStats.niceWidth(1.3) == 2 && SizeStats.niceWidth(2.2) == 2.5 && SizeStats.niceWidth(3.1) == 5 && SizeStats.niceWidth(7) == 10 && SizeStats.niceWidth(0.021) == 0.025, "nice widths")
    var g = LCG(s: 3)
    let vals = (0..<400).map { _ in 20 + 3 * g.gauss() }
    let bw = SizeStats.autoBinWidth(vals)
    t.check(bw >= 0.5 && bw <= 2.5, "automatic bin width for sd 3 nm, n 400 is about 1-2 nm", "\(bw)")
    t.check(SizeStats.autoBinWidth([20, 20, 20, 20]) > 0 && SizeStats.autoBinWidth([5]) == 1, "degenerate samples still give a width")
    let smp = vals.enumerated().map { SizeSample(key: "m", id: "p\($0.offset)", label: $0.offset % 2 == 0 ? "a" : "b", cls: nil, nm: $0.element) }
    let hb = SizeStats.bins(smp, width: 1)
    t.check(hb.bins.reduce(0) { $0 + $1.count } == 400 && hb.bins.allSatisfy { $0.lo >= hb.lo - 1e-9 && abs($0.hi - $0.lo - hb.width) < 1e-9 }, "every sample is in exactly one bin")
    t.check(abs(hb.lo - hb.lo.rounded()) < 1e-9, "bins are aligned to multiples of the width", "\(hb.lo)")
    let hg = SizeStats.bins(smp, width: 1, group: { $0.label })
    t.check(hg.bins.reduce(0) { $0 + $1.count } == 400 && Set(hg.bins.map { $0.group }) == ["a", "b"], "grouped bins add up")
    t.check(Dictionary(grouping: hg.bins, by: { $0.lo }).values.allSatisfy { col in
        let sorted = col.sorted { $0.below < $1.below }
        return sorted.first?.below == 0 && zip(sorted, sorted.dropFirst()).allSatisfy { $0.below + $0.count == $1.below }
    }, "grouped bars stack without gaps or overlaps")
    let capped = SizeStats.bins(smp, width: 0.001, maxBins: 50)
    t.check(capped.count <= 50 && capped.bins.reduce(0) { $0 + $1.count } == 400, "a tiny bin width is widened to the bin cap", "\(capped.count) bins")
    t.check(SizeStats.bins([], width: 1).bins.isEmpty, "no samples, no bins")

    // samples from a project
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    var pr = c.store.project.params; pr.diameterNm = 20; c.store.setParams(pr)
    let ids = c.store.scheme.labels.map { $0.id }
    c.store.add(Pick(id: "a1", x: 100, y: 100, label: ids[0]), to: "m1.mrc")
    c.store.add(Pick(id: "a2", x: 200, y: 100, label: ids[1], diameterNm: 12), to: "m1.mrc")
    c.store.add(Pick(id: "a3", x: 300, y: 100, label: ids[0], status: .candidate, diameterNm: 15), to: "m1.mrc")
    c.store.add(Pick(id: "a4", x: 400, y: 100, label: ids[0], status: .dismissed), to: "m1.mrc")
    c.store.add(Pick(id: "b1", x: 100, y: 100, label: ids[0], diameterNm: 30), to: "m2.mrc")
    let all = SizeStats.samples(project: c.store.project, classes: nil, source: .set, measured: [:])
    t.check(all.map { $0.id }.sorted() == ["a1", "a2", "b1"] && all.first { $0.id == "a1" }?.nm == 20 && all.first { $0.id == "a2" }?.nm == 12, "set sizes: accepted picks, project default when none is stored")
    t.check(SizeStats.samples(project: c.store.project, classes: nil, source: .set, measured: [:], includeCandidates: true).count == 4, "candidates on request; dismissed never")
    t.check(SizeStats.samples(project: c.store.project, classes: nil, source: .set, measured: [:], keys: ["m2.mrc"]).map { $0.id } == ["b1"], "one micrograph")
    t.check(SizeStats.samples(project: c.store.project, classes: nil, source: .set, measured: [:], labels: [ids[1]]).map { $0.id } == ["a2"], "label filter")
    let ms = SizeStats.samples(project: c.store.project, classes: nil, source: .measured, measured: ["a1": 22.5])
    t.check(ms.count == 1 && ms[0].id == "a1" && ms[0].nm == 22.5, "measured sizes: picks without a measurement are left out")
    var cm = ClassMapping(source: "x", tolerancePx: 2); cm.pickClass = ["a1": 1, "a2": 2, "b1": 2]
    let cs = SizeStats.samples(project: c.store.project, classes: cm, source: .set, measured: [:], hiddenClasses: [2])
    t.check(cs.map { $0.id } == ["a1"] && cs[0].cls == 1, "classes carried; hidden classes left out")
    let csv = SizeStats.csv(all, source: .set)
    t.check(csv.hasPrefix("micrograph,pick,label,class,diameter_nm,source\n") && csv.split(separator: "\n").count == 4 && csv.contains("m1.mrc,a2,\(ids[1]),,12.00,set"), "csv", csv)

    // measuring on synthetic particles
    let W = 400, H = 400
    func measure(outer: Double, inner: Double = 0, amp: Double, noise: Double, nominal: Double, seed: UInt64, at: (Double, Double) = (200, 200), neighbour: Bool = false) -> Double? {
        var r = LCG(s: seed)
        var a = (0..<(W * H)).map { _ in Float(100 + noise * r.gauss()) }
        softParticle(into: &a, w: W, h: H, cx: 200, cy: 200, outer: outer, inner: inner, amp: amp)
        if neighbour { softParticle(into: &a, w: W, h: H, cx: 200 + 2.6 * nominal, cy: 200, outer: outer, amp: amp) }
        return SizeMeasure.diameterPx(pixels: a, width: W, height: H, cx: at.0, cy: at.1, nominalDiameterPx: nominal)
    }
    for (d, nom) in [(20.0, 20.0), (30, 30), (44, 44), (30, 24), (30, 40)] {
        for amp in [60.0, -60.0] {
            let m = measure(outer: d / 2, amp: amp, noise: 8, nominal: nom, seed: 11)
            t.check(m.map { abs($0 - d) < 1.6 } ?? false, "disc of \(Int(d)) px (set \(Int(nom)), \(amp > 0 ? "bright" : "dark")) is measured within 1.6 px", "\(String(describing: m))")
        }
    }
    let ring = measure(outer: 14, inner: 8, amp: 60, noise: 8, nominal: 28, seed: 5)
    t.check(ring.map { abs($0 - 28) < 1.8 } ?? false, "a ring-shaped particle is measured at its outer edge", "\(String(describing: ring))")
    let nb = measure(outer: 15, amp: 60, noise: 8, nominal: 30, seed: 9, neighbour: true)
    t.check(nb.map { abs($0 - 30) < 2 } ?? false, "a neighbouring particle outside the window does not change the size", "\(String(describing: nb))")
    t.check(measure(outer: 15, amp: 60, noise: 8, nominal: 30, seed: 2, at: (20, 200)) == nil, "too near the border: no size")
    t.check(measure(outer: 15, amp: 0, noise: 8, nominal: 30, seed: 2) == nil, "no contrast: no size")
    t.check(measure(outer: 15, amp: 2, noise: 30, nominal: 30, seed: 2) == nil, "contrast buried in noise: no size")
    t.check(SizeMeasure.diameterPx(pixels: [1, 2, 3], width: 10, height: 10, cx: 5, cy: 5, nominalDiameterPx: 4) == nil, "short pixel array is refused, not read past the end")

    // the model, measuring through its own queue
    let d2 = testTempDir(); defer { try? FileManager.default.removeItem(at: d2) }
    let mc = PickController(); mc.store.saveDelay = 0; mc.store.openProject(folder: d2)
    var p2 = mc.store.project.params; p2.diameterNm = 12; mc.store.setParams(p2)     // 12 nm at 5 Å = 24 px
    let lab = mc.store.scheme.labels[0].id
    var rr = LCG(s: 21)
    var img = (0..<(W * H)).map { _ in Float(100 + 8 * rr.gauss()) }
    let truthPx: [Double] = [20, 26, 32]
    for (i, d) in truthPx.enumerated() { softParticle(into: &img, w: W, h: H, cx: 100 + 100 * Double(i), cy: 200, outer: d / 2, amp: 60) }
    for i in 0..<3 { mc.store.add(Pick(id: "q\(i)", x: 100 + 100 * Double(i), y: 200, label: lab), to: "s.mrc") }
    mc.store.add(Pick(id: "edge", x: 5, y: 5, label: lab), to: "s.mrc")
    mc.store.setMicInfo("s.mrc", width: W, height: H, angpix: 5)
    mc.sizes.loader = { _, _ in (img, W, H) }
    mc.sizes.source = .measured
    t.check(mc.sizes.samples().isEmpty && mc.sizes.unmeasuredCount() == 4, "nothing measured yet")
    mc.sizes.measure()
    var spins = 0
    while mc.sizes.busy && spins < 100 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); spins += 1 }
    let got = mc.sizes.samples().sorted { $0.id < $1.id }
    t.check(got.count == 3 && zip(got, truthPx).allSatisfy { abs($0.nm - $1 * 5 / 10) < 0.35 }, "the model measures the picks in nm (px × 5 Å / 10)", "\(got.map { $0.nm })")
    t.check(mc.sizes.message?.contains("1 skipped") == true && mc.sizes.unmeasuredCount() == 1, "the pick at the border is reported as skipped", mc.sizes.message ?? "")
    mc.store.perform("s.mrc", "move") { l in if let i = l.firstIndex(where: { $0.id == "q0" }) { l[i].x += 3 } }
    t.check(mc.sizes.samples().count == 2, "a pick that was moved loses its measurement")
    mc.sizes.colorBy = .label
    let hh = mc.sizes.histogram(mc.sizes.samples())
    t.check(hh.bins.allSatisfy { $0.group == lab }, "colour by label groups by the label id")
}

func testClass2D(_ t: inout TestRun) {
    t.section("2D classification")
    // geometry reproduces the settings used by hand on the F2_B1 data (1.8999 Å/px, 196 px box scaled to 64, 280 Å mask, background radius 24)
    var p = Class2DParams(); p.targetBoxPx = 64
    let g = Class2DGeometry.make(angpix: 1.8999, boxNm: 37.24, diameterNm: 28, params: p)
    t.check(g.extractPx == 196 && g.scaledPx == 64 && abs(g.scaledAngpix - 5.818) < 0.01 && g.diameterA == 280 && g.bgRadiusPx == 24 && g.warnings.isEmpty, "geometry of the F2_B1 settings", "\(g)")
    var q = p
    t.check(Class2DGeometry.make(angpix: 1.8999, boxNm: 37.24, diameterNm: 40, params: q).warnings.count == 1 && Class2DGeometry.make(angpix: 1.8999, boxNm: 37.24, diameterNm: 40, params: q).diameterA < 400, "a mask larger than the box is reduced, with a warning")
    q.targetBoxPx = 400
    let g3 = Class2DGeometry.make(angpix: 1.8999, boxNm: 37.24, diameterNm: 30, params: q)
    var qm = p; qm.maskMargin = 1.1; qm.boxScale = 1.2
    let gm = Class2DGeometry.make(angpix: 1.8999, boxNm: 30, diameterNm: 20, params: qm)
    t.check(abs(gm.diameterA - 220) < 1e-6 && gm.extractPx == 190, "mask margin and box scale", "\(gm)")
    t.check(g3.scaledPx == g3.extractPx && g3.extractPx % 2 == 0, "the scaled box never exceeds the extracted one")
    t.check(Class2DGeometry.make(angpix: 20, boxNm: 1, diameterNm: 0.5, params: p).extractPx >= 16, "tiny boxes are lifted to 16 px")

    // log parsing
    let log = " Gradient optimisation iteration 7 of 100 (Step size 0.3)\n000/??? sec ~~(,_,\">      [oo]\r   0/   0 sec ......~~(,_,\"> yum!\n Maximization...\n Gradient optimisation iteration 8 of 100 (Step size 0.3)\r 1/ 2 sec ..."
    t.check(Class2DBuilder.progress(in: log)! == (8, 100) && Class2DBuilder.progress(in: "nothing here") == nil, "progress is read from the last iteration line")
    t.check(Class2DBuilder.progress(in: " Expectation iteration 3 of 25\n")! == (3, 25), "EM-style iteration lines too")
    t.check(Class2DBuilder.errorLines(in: "a\n ERROR: bad things\n b").first == "ERROR: bad things", "error lines are picked out of the log")

    // inventory and files
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let lab = c.store.scheme.labels[0].id, rej = c.store.scheme.labels.first { !$0.exported }?.id
    let W = 300, H = 260
    var rnd = LCG(s: 4)
    func img() -> [Float] { (0..<(W * H)).map { _ in Float(100 + rnd.gauss()) } }
    let mrcA = dir.appendingPathComponent("A one.mrc"), mrcB = dir.appendingPathComponent("B.mrc"), dm = dir.appendingPathComponent("C.dm4")
    try? writeMRC(url: mrcA, pixels: img(), width: W, height: H, pixelSizeA: 5)
    try? writeMRC(url: mrcB, pixels: img(), width: W, height: H, pixelSizeA: 5.01)
    try? Data("fake".utf8).write(to: dm)
    let stackF = dir.appendingPathComponent("D.mrcs"), noPx = dir.appendingPathComponent("E.mrc"), mixed = dir.appendingPathComponent("F.mrc")
    try? Data("x".utf8).write(to: stackF); try? Data("x".utf8).write(to: noPx); try? Data("x".utf8).write(to: mixed)
    let kA = c.store.key(for: mrcA), kB = c.store.key(for: mrcB), kC = c.store.key(for: dm), kD = c.store.key(for: stackF), kE = c.store.key(for: noPx), kF = c.store.key(for: mixed)
    for (i, k) in [kA, kB, kC, kD, kE, kF].enumerated() {
        for j in 0..<3 { c.store.add(Pick(id: "\(i)_\(j)", x: 60 + 50 * Double(j), y: 100, label: lab), to: k) }
    }
    if let rej { c.store.add(Pick(id: "rejected", x: 20, y: 20, label: rej), to: kA) }
    c.store.add(Pick(id: "cand", x: 20, y: 30, label: lab, status: .candidate), to: kA)
    let kG = c.store.key(for: dir.appendingPathComponent("G.mrc"))
    c.store.add(Pick(id: "fr", x: 20, y: 40, label: lab), to: FrameKey.make(kG, frame: 1))          // a pick on a frame of an unpacked stack
    c.store.setMicInfo(kC, width: W, height: H, angpix: 2.5)            // the DM file's pixel size comes from the project record
    c.store.setMicInfo(kF, width: W, height: H, angpix: 2.5)
    let fakeInfo: (URL) -> SourceInfo? = { u in
        switch u.lastPathComponent {
        case "A one.mrc", "B.mrc": return SourceInfo(width: W, height: H, depth: 1, angpix: u.lastPathComponent == "B.mrc" ? 5.01 : 5)
        case "C.dm4", "F.mrc": return SourceInfo(width: W, height: H, depth: 1, angpix: nil)
        case "D.mrcs": return SourceInfo(width: W, height: H, depth: 8, angpix: 5)
        default: return SourceInfo(width: W, height: H, depth: 1, angpix: nil)          // E.mrc: no pixel size anywhere
        }
    }
    let inv = Class2DInventory.build(project: c.store.project, keyMap: c.store.keyResolver(), params: Class2DParams(), info: fakeInfo)
    let g5 = inv.groups.first { abs($0.angpix - 5) < 0.05 }, g25 = inv.groups.first { abs($0.angpix - 2.5) < 0.01 }
    t.check(inv.groups.count == 2 && g5?.mics.count == 2 && g5?.pickCount == 6 && g25?.mics.count == 2 && g25?.pickCount == 6, "two pixel-size groups (5 and 5.01 Å/px agree within 0.5 %)", "\(inv.groups.map { ($0.angpix, $0.mics.count) })")
    t.check(inv.skippedStackPicks == 3 && inv.skippedNoPixelSize == 3 && inv.skippedFramePicks == 1, "stacks, missing pixel size and frame picks are counted and left out", "\(inv.skippedStackPicks) \(inv.skippedNoPixelSize) \(inv.skippedFramePicks)")
    t.check(inv.skippedText?.contains("multi-frame") == true, "the skipped picks are explained")
    t.check(inv.group(angpix: nil, sizeNm: nil)?.pickCount == 6 && abs(inv.group(angpix: 2.5, sizeNm: nil)!.angpix - 2.5) < 0.01, "group choice")
    var onlyLab = Class2DParams(); onlyLab.labels = [lab]
    t.check(Class2DInventory.build(project: c.store.project, keyMap: c.store.keyResolver(), params: onlyLab, info: fakeInfo).totalPicks == 12, "rejected and candidate picks are not classified")

    // candidates: off by default, optional, with a score cutoff; dismissed ones never
    c.store.add(Pick(id: "cand_lo", x: 30, y: 30, label: lab, score: 0.5, status: .candidate), to: kB)
    c.store.add(Pick(id: "cand_hi", x: 40, y: 30, label: lab, score: 3.0, status: .candidate), to: kB)
    c.store.add(Pick(id: "cand_gone", x: 50, y: 30, label: lab, score: 5.0, status: .dismissed), to: kB)
    var withC = onlyLab; withC.includeCandidates = true
    let invC = Class2DInventory.build(project: c.store.project, keyMap: c.store.keyResolver(), params: withC, info: fakeInfo)
    let off = Class2DInventory.build(project: c.store.project, keyMap: c.store.keyResolver(), params: onlyLab, info: fakeInfo)
    t.check(off.groups.reduce(0) { $0 + $1.candidateCount } == 0, "candidates are not classified unless asked")
    t.check(invC.totalPicks == off.totalPicks + 3 && invC.groups.reduce(0) { $0 + $1.candidateCount } == 3, "with candidates on: the three live candidates join (score-less, 0.5, 3.0); dismissed ones never", "\(invC.totalPicks) vs \(off.totalPicks)")
    withC.minScore = 1
    let invHi = Class2DInventory.build(project: c.store.project, keyMap: c.store.keyResolver(), params: withC, info: fakeInfo)
    t.check(invHi.groups.reduce(0) { $0 + $1.candidateCount } == 2 && !invHi.groups.flatMap({ $0.mics.flatMap { $0.picks.map { $0.id } } }).contains("cand_lo"), "the score cutoff leaves out weak candidates (score-less ones stay)")

    // lengths follow the nm / Å display setting; stored values stay in nm
    let gA = ClassGroup(angpix: 5, sizeNm: 11, minNm: 10, maxNm: 12, boxNm: 20, mics: [])
    let g1 = ClassGroup(angpix: 5, sizeNm: 20, minNm: 20, maxNm: 20, boxNm: 30, mics: [])
    t.check(g1.sizeText(angstroms: false) == "20 nm" && g1.sizeText(angstroms: true) == "200 Å" && gA.sizeText(angstroms: false) == "10–12 nm (median 11)" && gA.sizeText(angstroms: true) == "100–120 Å (median 110)", "size groups are named in nm or Å", "\(gA.sizeText(angstroms: true)) \(g1.sizeText(angstroms: true))")
    let tight = Class2DGeometry.make(angpix: 1.8999, boxNm: 37.24, diameterNm: 40, params: Class2DParams(), angstroms: true).warnings.joined()
    let tightNm = Class2DGeometry.make(angpix: 1.8999, boxNm: 37.24, diameterNm: 40, params: Class2DParams(), angstroms: false).warnings.joined()
    t.check(tight.contains(" Å") && !tight.contains(" nm") && tightNm.contains(" nm") && !tightNm.contains(" Å"), "geometry warnings use the display unit", "\(tight) | \(tightNm)")

    // particles of different sizes are never classified together
    let dz = testTempDir(); defer { try? FileManager.default.removeItem(at: dz) }
    let z = PickController(); z.store.saveDelay = 0; z.store.openProject(folder: dz)
    var zp = z.store.project.params; zp.diameterNm = 20; zp.boxNm = 30; z.store.setParams(zp)
    let zl = z.store.scheme.labels[0].id
    let zU = dz.appendingPathComponent("z1.mrc"), zV = dz.appendingPathComponent("z2.mrc")
    try? writeMRC(url: zU, pixels: img(), width: W, height: H, pixelSizeA: 5); try? writeMRC(url: zV, pixels: img(), width: W, height: H, pixelSizeA: 5)
    let zkU = z.store.key(for: zU), zkV = z.store.key(for: zV)
    let sizes: [Double] = [10, 10.5, 11, 20, 21, 22, 40]
    for (i, d) in sizes.enumerated() {
        z.store.add(Pick(id: "u\(i)", x: 40 + 30 * Double(i), y: 60, label: zl, diameterNm: d), to: zkU)
        z.store.add(Pick(id: "v\(i)", x: 40 + 30 * Double(i), y: 120, label: zl, diameterNm: d), to: zkV)
    }
    z.store.add(Pick(id: "dflt", x: 20, y: 200, label: zl), to: zkU)                      // no size of its own: the project's 20 nm
    let zi = Class2DInventory.build(project: z.store.project, keyMap: z.store.keyResolver(), params: Class2DParams(), info: { _ in SourceInfo(width: W, height: H, depth: 1, angpix: 5) })
    t.check(zi.groups.count == 3 && zi.groups.map({ $0.pickCount }) == [6, 7, 2], "picks split into size groups of ±20 % (10–11, 20–22 and the default, 40)", "\(zi.groups.map { ($0.sizeText, $0.pickCount) })")
    t.check(zi.groups.allSatisfy { g in g.maxNm <= g.minNm * 1.5 + 1e-9 }, "no group spans more than the tolerance")
    t.check(Set(zi.groups.flatMap { $0.mics.flatMap { $0.picks.map { $0.id } } }).count == 15, "every pick is in exactly one group")
    t.check(abs(zi.groups[0].boxNm - 16.5) < 1.5 && abs(zi.groups[2].boxNm - 60) < 1e-6, "box follows the diameter (project box : diameter = 30 : 20)", "\(zi.groups.map { $0.boxNm })")
    t.check(zi.group(angpix: nil, sizeNm: nil)?.pickCount == 7 && zi.group(angpix: 5, sizeNm: 11)?.pickCount == 6 && zi.group(angpix: nil, sizeNm: 37)?.pickCount == 2, "the group is chosen by particle size")
    var wide = Class2DParams(); wide.sizeTolerance = 0.5
    t.check(Class2DInventory.build(project: z.store.project, keyMap: z.store.keyResolver(), params: wide, info: { _ in SourceInfo(width: W, height: H, depth: 1, angpix: 5) }).groups.count == 2, "a wider tolerance merges neighbouring sizes")
    var fixedBox = zp; fixedBox.boxCustom = true; z.store.setParams(fixedBox)
    let zf = Class2DInventory.build(project: z.store.project, keyMap: z.store.keyResolver(), params: Class2DParams(), info: { _ in SourceInfo(width: W, height: H, depth: 1, angpix: 5) })
    t.check(zf.groups.allSatisfy { abs($0.boxNm - 30) < 1e-6 }, "a box typed into the project is kept for every size")
    t.check(Class2DSession.classes(requested: 12, picks: 40) == 2 && Class2DSession.classes(requested: 12, picks: 600) == 12 && Class2DSession.classes(requested: 12, picks: 100) == 6, "few particles get few classes")
    // a job written for one group holds only that group's picks
    do {
        let small = zi.groups[0]
        let jb = try Class2DBuilder.prepare(base: dz.appendingPathComponent(".thon-relion"), number: 1, group: small, params: Class2DParams(), geometry: Class2DGeometry.make(angpix: 5, boxNm: small.boxNm, diameterNm: small.sizeNm, params: Class2DParams()), readPixels: { _ in nil })
        let cf = (try? String(contentsOf: dz.appendingPathComponent(".thon-relion/Coords/job001/z1.star"), encoding: .utf8)) ?? ""
        t.check(jb.picks == 6 && jb.sizeNm == small.sizeNm && jb.sizeRangeNm == [10, 11] && cf.split(separator: "\n").filter { $0.first?.isNumber == true }.count == 3, "a job file lists only the picks of its size group", cf)
    } catch { t.check(false, "prepare for a size group threw", "\(error)") }

    let base = dir.appendingPathComponent(".thon-relion")
    var cp = Class2DParams(); cp.targetBoxPx = 48
    let grp = inv.group(angpix: 2.5, sizeNm: nil)!
    let geo = Class2DGeometry.make(angpix: grp.angpix, boxNm: 24, diameterNm: 12, params: cp)
    var convertedFrom: [String] = []
    let reader: (URL) -> (pixels: [Float], width: Int, height: Int)? = { u in convertedFrom.append(u.lastPathComponent); return (img(), W, H) }
    do {
        let job = try Class2DBuilder.prepare(base: base, number: 1, group: grp, params: cp, geometry: geo, readPixels: reader)
        let fm = FileManager.default
        let names = job.names.keys.sorted()
        t.check(names.count == 2 && job.picks == 6 && job.names.values.contains(kC) && job.names.values.contains(kF), "job covers the micrographs of the group", "\(names)")
        let link = base.appendingPathComponent("Micrographs/F.mrc")
        t.check(((try? fm.destinationOfSymbolicLink(atPath: link.path)) ?? "") == mixed.path, "an MRC micrograph is linked, not copied")
        let conv = base.appendingPathComponent("Micrographs/C.mrc")
        t.check(convertedFrom == ["C.dm4"] && ((try? fm.attributesOfItem(atPath: conv.path)[.size] as? Int) ?? 0) == 1024 + 4 * W * H, "a DM file is converted to MRC once")
        if let m = try? MRCFile(url: conv) { t.check(m.header.pixelSizeA.map { abs($0 - 2.5) < 1e-4 } ?? false, "the converted MRC carries the pixel size") }
        let coords = (try? String(contentsOf: base.appendingPathComponent("Coords/job001/C.star"), encoding: .utf8)) ?? ""
        t.check(coords.contains("_rlnCoordinateX #1") && coords.contains("60.0 100.0") && coords.split(separator: "\n").filter { $0.first?.isNumber == true }.count == 3, "coordinates in native pixels", coords)
        let list = (try? String(contentsOf: base.appendingPathComponent("Coords/job001/coords_list.star"), encoding: .utf8)) ?? ""
        t.check(list.contains("Micrographs/C.mrc Coords/job001/C.star") && list.contains("data_coordinate_files"), "coords_list.star", list)
        let ms = (try? String(contentsOf: base.appendingPathComponent("Coords/job001/micrographs.star"), encoding: .utf8)) ?? ""
        t.check(ms.contains("data_optics") && ms.contains("2.5 2.5 120.0") && ms.contains("Micrographs/F.mrc 1"), "micrographs.star with optics group", ms)
        _ = try Class2DBuilder.prepare(base: base, number: 2, group: grp, params: cp, geometry: geo, readPixels: reader)
        t.check(convertedFrom == ["C.dm4"], "the converted file is reused by the next job")
        // clashing names get a suffix
        let dup = ClassGroup(angpix: 5, sizeNm: 12, minNm: 12, maxNm: 12, boxNm: 24, mics: [Class2DMic(key: "x/a.mrc", url: mrcA, width: W, height: H, picks: grp.mics[0].picks), Class2DMic(key: "y/a.mrc", url: mrcB, width: W, height: H, picks: grp.mics[0].picks)])
        let jd = try Class2DBuilder.prepare(base: base, number: 3, group: dup, params: cp, geometry: geo, readPixels: reader)
        t.check(Set(jd.names.keys) == ["Micrographs/a.mrc", "Micrographs/a_2.mrc"], "two micrographs called a.mrc get different names", "\(jd.names.keys.sorted())")
        // arguments
        let pa = Class2DBuilder.preprocessArguments(job)
        t.check(pa.contains("--extract") && pa.joined(separator: " ").contains("--extract_size \(geo.extractPx) --scale \(geo.scaledPx)") && pa.contains("--norm") && !pa.contains("--invert_contrast") &&
                pa.joined(separator: " ").contains("--part_dir Extract/job001/"), "relion_preprocess arguments", pa.joined(separator: " "))
        var inv2 = job; inv2.params.invertContrast = true
        t.check(Class2DBuilder.preprocessArguments(inv2).contains("--invert_contrast"), "invert contrast on request")
        let ra = Class2DBuilder.refineArguments(job).joined(separator: " ")
        t.check(ra.contains("--grad") && ra.contains("--K 12") && ra.contains("--iter 100") && ra.contains("--o Class2D/job001/run") && ra.contains("--j 3") && !ra.contains("--ctf") && ra.contains("--particle_diameter 120"), "relion_refine arguments", ra)
        // job files
        t.check(Class2DJobs.nextNumber(base: base) == 4, "next job number follows the folders")
        var back = Class2DJobs.read(Class2DJobs.jobDir(base, 1).appendingPathComponent(Class2DJobs.fileName))
        t.check(back == job && back?.names == job.names, "the job file round-trips")
        back?.finalIteration = 7; if let b = back { Class2DJobs.write(b, base: base) }
        t.check(Class2DJobs.all(base: base).map { $0.number } == [3, 2, 1] && Class2DJobs.all(base: base).last?.finalIteration == 7, "jobs are listed newest first")
        let dir1 = Class2DJobs.jobDir(base, 1)
        for n in [1, 2, 10] { try? Data("x".utf8).write(to: dir1.appendingPathComponent(String(format: "run_it%03d_data.star", n))) }
        t.check(Class2DJobs.latestIteration(in: dir1)?.n == 10, "latest iteration is a number, not a string sort")
        let model = "\ndata_model_general\n\n_rlnReferenceDimensionality 2\n\ndata_model_classes\n\nloop_\n_rlnReferenceImage #1\n_rlnClassDistribution #2\n000001@a.mrcs 0.25\n000002@a.mrcs 0.75\n\n"
        let mf = dir1.appendingPathComponent("m.star"); try? Data(model.utf8).write(to: mf)
        t.check(Class2DJobs.classCounts(model: mf, particles: 40) == [1: 10, 2: 30], "class sizes from the model star")
        // a star written in a job folder maps through the job's names, not by file name
        let star = "\ndata_particles\n\nloop_\n_rlnCoordinateX #1\n_rlnCoordinateY #2\n_rlnImageName #3\n_rlnMicrographName #4\n_rlnClassNumber #5\n60.0 100.0 000001@x.mrcs Micrographs/C.mrc 2\n110.0 100.0 000002@x.mrcs Micrographs/C.mrc 1\n"
        let sf = dir1.appendingPathComponent("run_it010_data.star"); try? Data(star.utf8).write(to: sf)
        c.loadClasses(star: sf)
        t.check(c.classes?.matchedRows == 2 && c.classes?.pickClass["2_0"] == 2 && c.classes?.pickClass["2_1"] == 1, "classes of a Thon job map onto the picks through the job's name table", c.ioMessage ?? "")
        let known = ClassMapping.build(rows: ClassMapping.rows(fromStar: star), picks: ["x/C.mrc": []], source: "s", tolerancePx: 2)
        t.check(known.matchedRows == 0, "without the name table the same star would not match")
        // candidates are mapped too, and a class of candidates can be accepted or dismissed as a whole
        c.store.add(Pick(id: "cand_c", x: 230, y: 100, label: lab, score: 2, status: .candidate), to: kC)
        c.store.add(Pick(id: "cand_d", x: 240, y: 100, label: lab, score: 2, status: .candidate), to: kC)
        let star2 = star + "230.0 100.0 000003@x.mrcs Micrographs/C.mrc 3\n240.0 100.0 000004@x.mrcs Micrographs/C.mrc 3\n"
        try? Data(star2.utf8).write(to: sf)
        c.loadClasses(star: sf)
        t.check(c.classes?.pickClass["cand_c"] == 3 && c.classes?.pickClass["cand_d"] == 3 && c.classes?.matchedRows == 4, "candidates take part in the class mapping", c.ioMessage ?? "")
        t.check(c.picks(inClass: 3).isEmpty && c.picks(inClass: 3, status: .candidate)[kC]?.count == 2, "accepted and candidate picks of a class are told apart")
        t.check(c.acceptClassCandidates(3) == 2 && c.store.pick("cand_c", in: kC)?.status == .accepted, "accepting the candidates of a class")
        c.store.add(Pick(id: "cand_e", x: 250, y: 100, label: lab, score: 2, status: .candidate), to: kC)
        let star3 = star2 + "250.0 100.0 000005@x.mrcs Micrographs/C.mrc 4\n"
        try? Data(star3.utf8).write(to: sf)
        c.loadClasses(star: sf)
        t.check(c.removeClass(4) == 1 && c.store.pick("cand_e", in: kC)?.status == .dismissed, "removing a class dismisses its candidates (they do not come back)")
    } catch { t.check(false, "prepare threw", "\(error)") }
    t.check(PickStore().relionDirectory(root: URL(fileURLWithPath: "/p")).lastPathComponent == ".thon-relion", "the work folder is hidden")
    t.check(RelionLocator.problems("").count == 1 && RelionLocator.problems("/nonexistent").count == 1, "missing RELION folder is reported")

    // the whole thing with RELION, on synthetic particles
    guard let bin = RelionLocator.detect() else { print("  (RELION not found: end-to-end run skipped)"); return }
    let d2 = testTempDir(); defer { try? FileManager.default.removeItem(at: d2) }
    let e = PickController(); e.store.saveDelay = 0; e.store.openProject(folder: d2)
    let lab2 = e.store.scheme.labels[0].id
    var ep = e.store.project.params; ep.boxNm = 24; ep.diameterNm = 12; e.store.setParams(ep)
    let EW = 640, EH = 640
    var truth: [String: (Double, Double, Int)] = [:]
    for m in 0..<3 {
        var r = LCG(s: UInt64(100 + m))
        var a = (0..<(EW * EH)).map { _ in Float(100 + 6 * r.gauss()) }
        let url = d2.appendingPathComponent("syn\(m).mrc")
        var pts: [(Double, Double, Int)] = []
        for i in 0..<5 { for j in 0..<5 {
            let x = 70 + 120 * Double(i) + 6 * r.gauss(), y = 70 + 120 * Double(j) + 6 * r.gauss()
            let kind = (i + j) % 2                      // two kinds of particle: a disc and a ring
            if kind == 0 { softParticle(into: &a, w: EW, h: EH, cx: x, cy: y, outer: 12, amp: 50) } else { softParticle(into: &a, w: EW, h: EH, cx: x, cy: y, outer: 14, inner: 7, amp: 50) }
            pts.append((x, y, kind))
        } }
        try? writeMRC(url: url, pixels: a, width: EW, height: EH, pixelSizeA: 5)
        let k = e.store.key(for: url)
        e.store.setMicInfo(k, width: EW, height: EH, angpix: 5)
        for (n, p) in pts.enumerated() { let id = "s\(m)_\(n)"; e.store.add(Pick(id: id, x: p.0, y: p.1, label: lab2), to: k); truth[id] = p }
    }
    let s = e.class2D
    s.settings = RelionSettings(defaults: UserDefaults(suiteName: "thon.test.relion.\(UUID().uuidString)")!)
    s.settings.config.binFolder = bin
    s.seedParameters()
    s.params.classes = 2; s.params.iterations = 12; s.params.threads = 2; s.params.targetBoxPx = 48
    s.scan()
    var n = 0
    while s.scanning && n < 200 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); n += 1 }
    t.check(s.inventory?.totalPicks == 75 && s.canStart, "end-to-end: 75 picks found, ready to run", "\(String(describing: s.inventory?.totalPicks)) \(s.relionProblems)")
    guard s.canStart else { return }
    s.start()
    n = 0
    while s.running && n < 1200 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); n += 1 }
    t.check(s.phase == .finished, "end-to-end: RELION preprocess + refine finished", "\(s.phase) \(s.message ?? "")")
    guard s.phase == .finished else { return }
    t.check((s.currentJob?.particles ?? 0) >= 60 && s.currentJob?.finalIteration == 12, "end-to-end: particles extracted and the last iteration used", "\(String(describing: s.currentJob?.particles)) \(String(describing: s.currentJob?.finalIteration))")
    t.check(e.classes != nil && (e.classes?.matchedRows ?? 0) >= 60 && (e.classes?.classes.count ?? 0) >= 1 && !(e.classes?.averages.isEmpty ?? true), "end-to-end: classes were mapped back onto the picks", e.ioMessage ?? "")
    // coordinates must be right: the picks are centred on the particles, so the class average is bright in the middle and dark at the edge
    var contrasts: [Int] = []
    for (_, a) in e.classes?.averages ?? [:] {
        let n = a.size
        var core = 0, nc = 0, edge = 0, ne = 0
        for y in 0..<n { for x in 0..<n {
            let r = hypot(Double(x) - Double(n) / 2 + 0.5, Double(y) - Double(n) / 2 + 0.5) / Double(n)
            if r < 0.12 { core += Int(a.bytes[y * n + x]); nc += 1 } else if r > 0.42 { edge += Int(a.bytes[y * n + x]); ne += 1 }
        } }
        let c = core / max(nc, 1) - edge / max(ne, 1)
        contrasts.append(c)
    }
    t.check((contrasts.max() ?? 0) >= 100, "end-to-end: the best class average is centred on a bright particle (picks and extraction agree)", "\(contrasts)")
    t.check(s.warning == nil, "end-to-end: bright particles raise no polarity warning", s.warning ?? "")
    t.check(FileManager.default.fileExists(atPath: s.base!.appendingPathComponent("Class2D/job001/run_it012_data.star").path) && !FileManager.default.fileExists(atPath: d2.appendingPathComponent("Extract").path), "end-to-end: everything is inside the hidden folder")
    t.check((s.jobs.first?.status ?? "") == "finished", "end-to-end: the job is listed as finished")
    // two particle sizes: every group becomes its own job, and sizes are never mixed
    let keys = e.store.project.mics.keys.sorted()
    if let last = keys.last { e.store.setDiameter(Set(e.store.picks(last).map { $0.id }), nm: 24, in: last) }
    s.params.iterations = 6; s.params.classes = 3
    s.scan()
    n = 0
    while s.scanning && n < 200 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); n += 1 }
    t.check(s.inventory?.groups.count == 2 && s.inventory?.groups.map({ $0.pickCount }) == [50, 25] && s.canStartAll, "end-to-end: two sizes make two groups", "\(s.inventory?.groups.map { ($0.sizeText, $0.pickCount) } ?? [])")
    let before = s.jobs.count
    s.startAll()
    n = 0
    while (s.running || s.sequenceTotal > 0) && n < 2400 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); n += 1 }
    let fresh = Array(s.jobs.prefix(s.jobs.count - before)).sorted { $0.number < $1.number }
    t.check(fresh.count == 2 && fresh.allSatisfy { $0.status == "finished" } && fresh.map({ $0.picks }) == [50, 25] && Set(fresh.map { $0.sizeNm }).count == 2, "end-to-end: run every group makes one finished job per size", "\(fresh.map { ($0.number, $0.sizeNm, $0.picks, $0.status) }) \(s.message ?? "")")
    t.check(fresh.count == 2 && fresh[0].boxNm * 2 - fresh[1].boxNm < 1 && fresh[0].diameterA * 2 == fresh[1].diameterA, "end-to-end: each size has its own box and mask", "\(fresh.map { ($0.boxNm, $0.diameterA) })")
    t.check(fresh.count == 2 && !(e.classes?.source ?? "").isEmpty && e.classes?.matchedRows == 25, "end-to-end: the classes on screen are those of the last job only", "\(String(describing: e.classes?.matchedRows))")
    // stopping
    s.params.iterations = 400
    s.start()
    n = 0
    while s.phase != .classifying && s.running && n < 300 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); n += 1 }
    s.cancel()
    n = 0
    while s.running && n < 200 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); n += 1 }
    t.check(s.phase == .cancelled || s.phase == .finished, "end-to-end: a run can be stopped", "\(s.phase) \(s.message ?? "")")
}

/// `Thon --picktest --class2d-only --data <RELION project>`: the same pipeline on real micrographs. Reads Micrographs_raw/*.mrc and
/// coords/Micrographs_raw/*_topaz.star (score >= 1.5) of a RELION project folder, in a throwaway project (nothing is written to <RELION project>).
func testClass2DRealData(_ t: inout TestRun, project: String) {
    t.section("2D classification and size histogram on real micrographs (\(project))")
    let fm = FileManager.default
    let src = URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
    let mics = ((try? fm.contentsOfDirectory(atPath: src.appendingPathComponent("Micrographs_raw").path)) ?? []).filter { $0.hasSuffix(".mrc") }.sorted()
    guard !mics.isEmpty, let bin = RelionLocator.detect() else { print("  (no micrographs, or RELION not found: skipped)"); return }
    let dir = testTempDir()
    defer { if ProcessInfo.processInfo.environment["THON_KEEP"] == nil { try? fm.removeItem(at: dir) } else { print("  kept \(dir.path)") } }
    let e = PickController(); e.store.saveDelay = 0; e.store.openProject(folder: dir)
    let lab = e.store.scheme.labels[0].id
    var total = 0
    for m in mics {
        let url = dir.appendingPathComponent(m)
        try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: src.appendingPathComponent("Micrographs_raw/" + m).path)
        let stem = String(m.dropLast(4))
        let cf = src.appendingPathComponent("coords/Micrographs_raw/\(stem)_topaz.star")
        guard let text = try? String(contentsOf: cf, encoding: .utf8), let f = try? MRCFile(url: url) else { continue }
        let key = e.store.key(for: url)
        e.store.setMicInfo(key, width: f.width, height: f.height, angpix: f.header.pixelSizeA)
        for (i, p) in PickImporter.coordinates(fromStar: text).enumerated() where (p.score ?? 0) >= 1.5 {
            e.store.add(Pick(id: "r\(total)_\(i)", x: p.x, y: p.y, label: lab, score: p.score), to: key); total += 1
        }
    }
    print("  \(total) picks on \(mics.count) micrographs")
    var pr = e.store.project.params; pr.diameterNm = 28; pr.boxNm = 37.2; e.store.setParams(pr)
    // sizes
    e.sizes.loader = { _, k in AppModel.loadPixels(root: dir, key: k) }
    e.sizes.source = .measured
    e.sizes.measure()
    var n = 0
    while e.sizes.busy && n < 6000 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); n += 1 }
    let ss = e.sizes.samples()
    let sm = SizeStats.summary(ss.map { $0.nm })
    print(String(format: "  measured %d of %d picks: median %.1f nm, mean %.1f ± %.1f, 5-95%% %.1f–%.1f  (set diameter %.0f nm)", sm.n, total, sm.median, sm.mean, sm.sd, sm.p5, sm.p95, pr.diameterNm))
    let h = e.sizes.histogram(ss)
    for b in h.bins { print(String(format: "    %5.1f–%5.1f nm %@ %d", b.lo, b.hi, String(repeating: "#", count: min(b.count / 2, 60)), b.count)) }
    t.check(sm.n > total / 4, "real data: sizes are measured for a good part of the picks", "\(sm)")
    // classification
    let s = e.class2D
    s.settings = RelionSettings(defaults: UserDefaults(suiteName: "thon.test.relion.\(UUID().uuidString)")!)
    s.settings.config.binFolder = bin
    s.seedParameters()
    s.params.classes = 12; s.params.iterations = 40; s.params.threads = 3
    s.scan()
    n = 0
    while s.scanning && n < 600 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); n += 1 }
    print("  inventory: \(s.inventory?.groups.map { String(format: "%.4f Å/px × %d picks", $0.angpix, $0.pickCount) } ?? []) · \(s.geometry.map { "\($0.extractPx)→\($0.scaledPx) px, bg \($0.bgRadiusPx)" } ?? "")")
    t.check(s.canStart, "real data: ready to run", "\(s.relionProblems)")
    guard s.canStart else { return }
    let t0 = Date()
    s.start()
    n = 0
    while s.running && n < 6000 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); n += 1 }
    print(String(format: "  %@ in %.0f s · %@", "\(s.phase)", Date().timeIntervalSince(t0), s.message ?? ""))
    t.check(s.phase == .finished, "real data: classification finished", s.message ?? "")
    if let m = e.classes {
        print("  class sizes: " + m.classes.map { "\($0): \(m.counts[$0] ?? 0)" }.joined(separator: ", ") + " · unclassified picks \(m.unclassifiedPicks)")
        t.check(m.matchedRows >= m.rows * 9 / 10, "real data: nearly every particle maps back onto a pick", "\(m.matchedRows)/\(m.rows)")
    }
    if let j = s.currentJob, let b = s.base { print("  result: \(Class2DJobs.jobDir(b, j.number).path)") }
}
