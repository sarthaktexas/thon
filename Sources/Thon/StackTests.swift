import Foundation
import CoreGraphics

/// Frames of a stack (keys, averaging, SerialEM detection, export names) and the auto-picker size sweep.
func testStacksAndSweep(_ t: inout TestRun) {
    t.section("stack frames")
    let fm = FileManager.default

    // --- frame keys
    t.check(FrameKey.split("a/b.mrcs#f3").base == "a/b.mrcs" && FrameKey.split("a/b.mrcs#f3").frame == 2 && FrameKey.split("a/b.mrcs").frame == nil, "frame key split")
    t.check(FrameKey.split("a.mrcs#f0").frame == nil && FrameKey.split("a.mrcs#f").frame == nil && FrameKey.split("a.mrcs#fx").frame == nil, "malformed frame suffix is not a frame")
    t.check(FrameKey.make("a.mrcs", frame: 11) == "a.mrcs#f12" && FrameKey.make("a.mrcs", frame: nil) == "a.mrcs" && FrameKey.base("a.mrcs#f12") == "a.mrcs", "frame key make / base")
    t.check(PickImporter.stem("d/x.mrcs#f12") == "x_f012" && PickImporter.stem("d/x.mrcs") == "x", "frame stem is unique per frame")
    t.check(PickImporter.splitStackName("000003@d/x.mrcs").path == "d/x.mrcs" && PickImporter.splitStackName("000003@d/x.mrcs").frame == 2
            && PickImporter.splitStackName("d/x.mrcs").frame == nil && PickImporter.splitStackName("a@b").frame == nil, "RELION N@name")
    let known = ["g/a.mrcs", "g/b.mrcs"]
    t.check(PickImporter.resolveKey("000002@g/a.mrcs", known: known) == "g/a.mrcs#f2" && PickImporter.resolveKey("g/a.mrcs", known: known) == "g/a.mrcs", "import resolves a frame name")

    // --- averaging
    let frames: [[Float]] = [[1, 2], [3, 4], [5, 9]]
    t.check((try? LoadedExposure.read(depth: 3, frame: -1) { frames[$0] }) == [3, 5], "average of the frames")
    t.check((try? LoadedExposure.read(depth: 3, frame: 1) { frames[$0] }) == [3, 4], "one frame")
    t.check((try? LoadedExposure.read(depth: 1, frame: -1) { frames[$0] }) == [1, 2], "a single image is its own average")
    let dir = testTempDir(); defer { try? fm.removeItem(at: dir) }
    let stack: [Float] = [1, 2, 3, 4,  2, 4, 6, 8,  6, 6, 6, 6]       // mean = [3, 4, 5, 6]
    var raw = buildMRC(mode: 2, le: true, nx: 2, ny: 2, nz: 3, body: stack.flatMap { v in withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } })
    let su = dir.appendingPathComponent("s.mrcs")
    try? raw.write(to: su)
    let avg = AppModel.loadPixels(root: nil, key: su.path), f2 = AppModel.loadPixels(root: nil, key: su.path + "#f2")
    t.check(avg?.pixels == [3, 4, 5, 6], "loader: plain key = average", "\(String(describing: avg?.pixels))")
    t.check(f2?.pixels == [2, 4, 6, 8], "loader: #f2 = second frame", "\(String(describing: f2?.pixels))")
    // --- SerialEM detection
    t.check(!((try? LoadedExposure(url: su, frame: -1))?.isSerialEM ?? true), "plain MRC is not SerialEM")
    raw.replaceSubrange(104..<108, with: Array("SERI".utf8))
    let su2 = dir.appendingPathComponent("serial.mrcs"); try? raw.write(to: su2)
    let le = try? LoadedExposure(url: su2, frame: -1)
    t.check(le?.isSerialEM == true && le?.pixels == [3, 4, 5, 6] && le?.entry.depth == 3, "extended header type SERI = SerialEM; opens as the average")
    t.check(LoadedExposure.mentionsSerialEM(TagRow(id: 0, path: "label 1", value: "SerialEM: Acquired on Jan 1")) && !LoadedExposure.mentionsSerialEM(TagRow(id: 1, path: "a", value: "b")), "SerialEM in a tag")

    // --- keys, sessions, store
    let root = testTempDir(); defer { try? fm.removeItem(at: root) }
    let km = PickKeyMap(root: root)
    let u = root.appendingPathComponent("g/a.mrcs")
    t.check(km.key(for: u, frame: 1) == "g/a.mrcs#f2" && km.key(for: u, frame: nil) == "g/a.mrcs" && km.url(forKey: "g/a.mrcs#f2").path == u.standardizedFileURL.path, "key map: frame keys point at the file")
    let s = PickStore(); s.saveDelay = 0; s.openProject(folder: root)
    t.check(!s.hasFramePicks(base: "g/a.mrcs"), "no frame picks yet")
    s.add(Pick(id: "w", x: 1, y: 2, label: "side"), to: "g/a.mrcs")
    t.check(!s.hasFramePicks(base: "g/a.mrcs"), "picks on the average are not frame picks")
    s.add(Pick(id: "f", x: 5, y: 6, label: "side"), to: "g/a.mrcs#f2")
    t.check(s.hasFramePicks(base: "g/a.mrcs") && !s.hasFramePicks(base: "g/a") && s.picks("g/a.mrcs").count == 1 && s.picks("g/a.mrcs#f2").count == 1, "frames keep their own picks")
    s.setMicInfo("g/a.mrcs#f2", width: 100, height: 100, angpix: 2)
    t.check(s.record("g/a.mrcs#f2").angpix == 2 && s.record("g/a.mrcs").angpix == nil, "pixel size recorded per frame record")

    // --- export: one coordinate file per frame, N@ names, per-pick box
    let ex = root.appendingPathComponent("out")
    var pr = s.project.params; pr.boxNm = 30; s.setParams(pr)
    s.setMicInfo("g/a.mrcs", width: 100, height: 100, angpix: 2)
    s.add(Pick(id: "big", x: 40, y: 50, label: "side", boxNm: 60), to: "g/a.mrcs#f2")
    do {
        let sum = try PickExporter.export(project: s.project, root: root, outDir: ex, options: { var o = ExportOptions(); o.formats.insert(.eman); return o }())
        let csv = (try? String(contentsOf: ex.appendingPathComponent("all_picks.csv"), encoding: .utf8)) ?? ""
        let rows = PickImporter.csvRows(csv)
        t.check(sum.total == 3 && sum.micrographs == 2, "export counts frames as separate micrographs", "\(sum.total) / \(sum.micrographs)")
        t.check(csv.contains(",a_f002,") && csv.contains("000002@g/a.mrcs") && csv.contains(",g/a.mrcs,"), "csv names: a, a_f002 and 000002@ raw name", csv)
        t.check(csv.contains(",side,60.0,300.0,") && csv.contains(",side,30.0,150.0,") && rows.count >= 3, "csv box follows the pick (60 nm = 300 px, project 30 nm = 150 px)", csv)
        let list = (try? String(contentsOf: ex.appendingPathComponent(fm.subpathsOfDirectoryOrEmpty(ex).first { $0.hasSuffix("coords_list_side.star") } ?? "x"), encoding: .utf8)) ?? ""
        t.check(list.contains("000002@g/a.mrcs ") && list.contains("/a_f002.star"), "coords_list: frame entry", list)
        let box = fm.subpathsOfDirectoryOrEmpty(ex).first { $0.hasSuffix("a_f002.box") }.flatMap { try? String(contentsOf: ex.appendingPathComponent($0), encoding: .utf8) } ?? ""
        t.check(box.contains("\t300\t300") && box.contains("\t150\t150"), "eman box size per pick", box)
    } catch { t.check(false, "export with frames threw", "\(error)") }

    // --- size sweep
    t.section("size sweep")
    t.check(SweepSpec.parse("12, 16 20") == [12, 16, 20] && SweepSpec.parse("10:30:5") == [10, 15, 20, 25, 30] && SweepSpec.parse("") == [] && SweepSpec.parse("20,10,20") == [10, 20], "sweep text: lists, ranges, blank, duplicates")
    t.check(SweepSpec.parse("x") == nil && SweepSpec.parse("0") == nil && SweepSpec.parse("10:5:1") == nil && SweepSpec.parse("1:2") == nil && SweepSpec.parse("-3") == nil, "sweep text: bad input is rejected")
    t.check(AutoPicker.sweepScales(diameters: [10, 20], boxes: [], boxPerDiameter: 1.5) == [SweepScale(diameterNm: 10, boxNm: 15), SweepScale(diameterNm: 20, boxNm: 30)], "no boxes: box follows diameter")
    t.check(AutoPicker.sweepScales(diameters: [10, 20], boxes: [40], boxPerDiameter: 1.5)?.map { $0.boxNm } == [40, 40] && AutoPicker.sweepScales(diameters: [10, 20], boxes: [25, 35], boxPerDiameter: 1.5)?.map { $0.boxNm } == [25, 35], "one box for all, or one per diameter")
    t.check(AutoPicker.sweepScales(diameters: [10, 20, 30], boxes: [25, 35], boxPerDiameter: 1.5) == nil && AutoPicker.sweepScales(diameters: [], boxes: [], boxPerDiameter: 1) == nil, "box list that does not fit is refused")
    // merging: best score wins; a centre inside a better, larger candidate goes; separate particles stay
    let m = AutoPicker.mergeScales([AutoCandidate(x: 100, y: 100, score: 5, diameterNm: 20, boxNm: 30), AutoCandidate(x: 102, y: 100, score: 4, diameterNm: 30, boxNm: 45),
                                    AutoCandidate(x: 300, y: 100, score: 3, diameterNm: 20, boxNm: 30), AutoCandidate(x: 315, y: 100, score: 2, diameterNm: 10, boxNm: 15),
                                    AutoCandidate(x: 500, y: 100, score: 6, diameterNm: 40, boxNm: 60), AutoCandidate(x: 515, y: 100, score: 3, diameterNm: 10, boxNm: 15)], angpix: 10, maxPicks: 100)
    t.check(m.count == 4 && m.first?.score == 6 && m.contains { $0.x == 100 } && !m.contains { $0.x == 102 } && m.contains { $0.x == 315 } && !m.contains { $0.x == 515 }, "scale merge", "\(m.map { ($0.x, $0.diameterNm ?? 0) })")
    t.check(AutoPicker.mergeScales(m, angpix: 10, maxPicks: 2).count == 2, "scale merge respects max picks")
    // two sizes of flat, soft-edged particles on one micrograph (20 nm and 60 nm at 10 A/px = 1 nm per px)
    let angpix = 10.0, W = 640, H = 640
    let bigC: [(Double, Double)] = [(150, 150), (450, 170), (300, 450), (520, 500)]
    let small: [(Double, Double)] = [(60, 60), (250, 70), (380, 60), (580, 60), (60, 300), (580, 320), (150, 600), (420, 600)]
    var disc = [Float](repeating: 0, count: W * H)
    for (pts, d) in [(bigC, 60.0), (small, 20.0)] { for (cx, cy) in pts {
        for y in Int(cy - d)...Int(cy + d) { for x in Int(cx - d)...Int(cx + d) where hypot(Double(x) - cx, Double(y) - cy) <= d / 2 { disc[y * W + x] = 25 } }
    } }
    disc = AutoPicker.gaussianBlur(disc, W, H, sigma: 2)
    var nr = LCG(s: 99)
    let img: [Float] = disc.map { 100 + $0 + Float(6 * nr.gauss()) }
    var ap = AutoParams(); ap.zThreshold = 5; ap.diameterNm = 20
    func sweepRun(_ ds: [Double]) -> [AutoCandidate] {
        AutoPicker.sweep(scales: AutoPicker.sweepScales(diameters: ds, boxes: [], boxPerDiameter: 1.5)!, params: ap, angpix: angpix, pixels: img, width: W, height: H) {
            AutoPicker.scoreMap(pixels: img, width: W, height: H, angpix: angpix, params: $0)
        }
    }
    func found(_ cs: [AutoCandidate], _ truth: [(Double, Double)], _ d: Double, tol: Double) -> Int {
        truth.filter { c in cs.contains { $0.diameterNm == d && hypot($0.x - c.0, $0.y - c.1) < tol } }.count
    }
    let cands = sweepRun([20, 60])
    t.check(found(cands, small, 20, tol: 5) == small.count, "sweep finds every 20 nm particle at 20 nm", "\(found(cands, small, 20, tol: 5))/\(small.count)")
    t.check(found(cands, bigC, 60, tol: 10) == bigC.count, "sweep finds every 60 nm particle at 60 nm", "\(found(cands, bigC, 60, tol: 10))/\(bigC.count)")
    t.check(cands.count == small.count + bigC.count, "no extra candidates from the edges of the big particles", "\(cands.count)")
    t.check(cands.allSatisfy { ($0.diameterNm == 20 && $0.boxNm == 30) || ($0.diameterNm == 60 && $0.boxNm == 90) }, "every candidate carries its size and box")
    t.check(cands.allSatisfy { a in cands.allSatisfy { b in a == b || hypot(a.x - b.x, a.y - b.y) >= 0.5 * max(a.diameterNm ?? 0, b.diameterNm ?? 0) } }, "no candidate sits inside a bigger one (1 nm = 1 px here)")
    // sizing: the half-maximum diameter of a soft disc, bright or dark, and nothing on a flat field
    var one = [Float](repeating: 0, count: 200 * 200)
    for y in 0..<200 { for x in 0..<200 where hypot(Double(x) - 100, Double(y) - 100) <= 20 { one[y * 200 + x] = 25 } }
    one = AutoPicker.gaussianBlur(one, 200, 200, sigma: 2)
    let hm = AutoPicker.halfMaxDiameter(pixels: one.map { 100 + $0 }, width: 200, height: 200, cx: 100, cy: 100, coreR: 4, outerR: 30)
    let hmDark = AutoPicker.halfMaxDiameter(pixels: one.map { 100 - $0 }, width: 200, height: 200, cx: 100, cy: 100, coreR: 4, outerR: 30)
    t.check(hm != nil && abs(hm! - 40) < 2 && hmDark != nil && abs(hmDark! - 40) < 2, "half-maximum diameter of a 40 px disc (bright and dark)", "\(String(describing: hm)) \(String(describing: hmDark))")
    t.check(AutoPicker.halfMaxDiameter(pixels: [Float](repeating: 100, count: 200 * 200), width: 200, height: 200, cx: 100, cy: 100, coreR: 4, outerR: 30) == nil, "flat field has no size")
    // merge: between sizes at one place the one closest to the measured diameter (log scale) wins; without a measurement the best score does
    let pair = [AutoCandidate(x: 100, y: 100, score: 50, diameterNm: 40, boxNm: 60), AutoCandidate(x: 101, y: 100, score: 40, diameterNm: 60, boxNm: 90)]
    let near60 = AutoPicker.mergeScales(pair, angpix: 10, maxPicks: 10) { _, _, _, _ in 55 }
    let near40 = AutoPicker.mergeScales(pair, angpix: 10, maxPicks: 10) { _, _, _, _ in 41 }
    let unsized = AutoPicker.mergeScales(pair, angpix: 10, maxPicks: 10)
    t.check(near60.count == 1 && near60[0].diameterNm == 60 && near40.count == 1 && near40[0].diameterNm == 40 && unsized.count == 1 && unsized[0].diameterNm == 40, "size choice follows the measured diameter",
            "\(near60.map { $0.diameterNm ?? 0 }) \(near40.map { $0.diameterNm ?? 0 }) \(unsized.map { $0.diameterNm ?? 0 })")
    let three = sweepRun([20, 40, 60])
    t.check(found(three, bigC, 60, tol: 10) == bigC.count && found(three, small, 20, tol: 5) == small.count && three.count == small.count + bigC.count,
            "with a 40 nm step in between, each particle still gets its own size", "60 nm: \(found(three, bigC, 60, tol: 10))/\(bigC.count), 20 nm: \(found(three, small, 20, tol: 5))/\(small.count), total \(three.count)")

    // --- controller: sweep -> picks with their own size and box
    let cdir = testTempDir(); defer { try? fm.removeItem(at: cdir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: cdir)
    c.pixels = img
    c.setMicrograph(key: "m.mrc", width: W, height: H, pixelSizeA: angpix)
    c.enabled = true
    var pp = c.store.project.params; pp.diameterNm = 20; pp.boxNm = 30; c.store.setParams(pp)
    c.autoParams.zThreshold = 5
    c.sweepOn = true; c.sweepDiameterText = "20, 60"; c.sweepBoxText = ""
    c.applySweepText()
    t.check(c.sweepError == nil && c.autoParams.sweepDiametersNm == [20, 60] && c.autoParams.sweepBoxesNm.isEmpty, "sweep text reaches the auto-picker settings")
    c.runAutoPick(synchronous: true)
    let picks = c.store.candidates("m.mrc")
    t.check(picks.count >= 12 && picks.allSatisfy { $0.diameterNm != nil && $0.boxNm != nil }, "sweep candidates carry diameter and box", "\(picks.count)")
    t.check(picks.contains { $0.diameterNm == 60 && $0.boxNm == 90 } && picks.contains { $0.diameterNm == 20 && c.boxPx($0) == 30 }, "per-pick box in px (60 nm -> 90 nm box = 90 px at 10 A/px)")
    t.check(c.store.record("m.mrc").auto?.sweepDiametersNm == [20, 60], "sweep sizes stored with the run")
    t.check(c.autoMessage?.contains("by diameter") == true, "message lists candidates per diameter", c.autoMessage ?? "")
    c.sweepBoxText = "40, 50, 60"; c.applySweepText()
    t.check(c.sweepError != nil && c.autoParams.sweepDiametersNm.isEmpty, "a box list that does not fit turns the sweep off with an error")
    c.sweepBoxText = ""; c.sweepDiameterText = "nonsense"; c.applySweepText()
    t.check(c.sweepError != nil && c.autoParams.sweepDiametersNm.isEmpty, "unreadable sizes turn the sweep off with an error")
    c.sweepOn = false; c.applySweepText()
    c.runAutoPick(synchronous: true)
    t.check(c.store.candidates("m.mrc").allSatisfy { $0.diameterNm == nil && $0.boxNm == nil }, "sweep off: the normal picker runs, picks use the project size")
    // clean-up and the older file format
    let old = try? JSONDecoder().decode(Pick.self, from: Data("{\"id\":\"a\",\"x\":1,\"y\":2,\"label\":\"side\"}".utf8))
    t.check(old?.boxNm == nil && old?.diameterNm == nil, "picks without a box still load")
    let ap0 = try? JSONDecoder().decode(AutoParams.self, from: Data("{\"zThreshold\":4}".utf8))
    t.check(ap0?.sweepDiametersNm.isEmpty == true, "auto params without a sweep still load")
}

private extension FileManager {
    func subpathsOfDirectoryOrEmpty(_ u: URL) -> [String] { (try? subpathsOfDirectory(atPath: u.path)) ?? [] }
}
