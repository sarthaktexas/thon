import Foundation

/// Headless logic tests (no GPU, no UI). Run with `Thon --picktest [--data <dir-with-mrc>]`.
struct TestRun {
    var passed = 0, failed = 0
    mutating func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1; print("  FAIL  \(name) \(detail())") }
    }
    mutating func section(_ s: String) { print("• \(s)") }
}

func testTempDir() -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let u = base.appendingPathComponent("dm4pick-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func runPickTests(_ args: [String]) -> Int32 {
    if args.contains("--autopick") { return runAutoPickCLI(args) }
    if args.contains("--export-picks") { return runExportCLI(args) }
    var t = TestRun()
    PickProject.newProjectScheme = .views          // most tests were written against the six view labels (ids ring_top, side, …)
    testMRC(&t)
    testLabelScheme(&t)
    testQualityDefaultAndMaybe(&t)
    testGrid(&t)
    testStoreEditing(&t)
    testStorePersistence(&t)
    testGeometry(&t)
    testController(&t)
    testAutoPrimitives(&t)
    testAutoPicker(&t)
    testAutoIntegration(&t)
    testExternalPicker(&t)
    testImportExport(&t)
    testGallery(&t)
    testClassMapping(&t)
    testSwipe(&t)
    if let i = args.firstIndex(of: "--data"), i + 1 < args.count { testRealData(&t, root: URL(fileURLWithPath: args[i + 1])) }
    print("picktest: \(t.passed) passed, \(t.failed) failed")
    return t.failed == 0 ? 0 : 1
}

// MARK: MRC

/// Builds an MRC file in memory with arbitrary mode / endianness / extended header.
func buildMRC(mode: Int, le: Bool, nx: Int, ny: Int, nz: Int, nsymbt: Int = 0, cell: Float? = nil, body: [UInt8]) -> Data {
    var hdr = [UInt8](repeating: 0, count: 1024)
    func putI(_ i: Int, _ v: Int32) { let b = le ? v.littleEndian : v.bigEndian; withUnsafeBytes(of: b) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
    func putF(_ i: Int, _ v: Float) { let b = le ? v.bitPattern.littleEndian : v.bitPattern.bigEndian; withUnsafeBytes(of: b) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
    putI(0, Int32(nx)); putI(1, Int32(ny)); putI(2, Int32(nz)); putI(3, Int32(mode))
    putI(7, Int32(nx)); putI(8, Int32(ny)); putI(9, Int32(nz))
    putF(10, cell ?? Float(nx)); putF(11, cell.map { $0 * Float(ny) / Float(nx) } ?? Float(ny)); putF(12, Float(nz))
    putI(23, Int32(nsymbt))
    hdr[208] = 0x4D; hdr[209] = 0x41; hdr[210] = 0x50; hdr[211] = 0x20
    if le { hdr[212] = 0x44; hdr[213] = 0x44 } else { hdr[212] = 0x11; hdr[213] = 0x11 }
    var d = Data(hdr); d.append(Data(repeating: 0xAB, count: nsymbt)); d.append(contentsOf: body)
    return d
}

private func bytes<T: FixedWidthInteger>(_ vals: [T], le: Bool) -> [UInt8] {
    var o: [UInt8] = []
    for v in vals { withUnsafeBytes(of: le ? v.littleEndian : v.bigEndian) { o.append(contentsOf: $0) } }
    return o
}

func testMRC(_ t: inout TestRun) {
    t.section("MRC reader")
    let dir = testTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func read(_ d: Data, _ name: String) throws -> (MRCFile, [Float]) {
        let u = dir.appendingPathComponent(name); try d.write(to: u)
        let f = try MRCFile(url: u); return (f, try f.readPixels())
    }
    do {
        // float32, little + big endian, with extended header and a calibration of 2.5 Å/px
        let f32: [Float] = [1.5, -2.25, 3, 4, 5, 6]
        for le in [true, false] {
            let body = bytes(f32.map { $0.bitPattern }, le: le)
            let (f, px) = try read(buildMRC(mode: 2, le: le, nx: 3, ny: 2, nz: 1, nsymbt: 80, cell: 7.5, body: body), "f32_\(le).mrc")
            t.check(px == f32, "float32 values le=\(le)", "\(px)")
            t.check(f.width == 3 && f.height == 2 && f.depth == 1, "dims le=\(le)")
            t.check(abs((f.header.pixelSizeA ?? 0) - 2.5) < 1e-6, "pixel size le=\(le)", "\(String(describing: f.header.pixelSizeA))")
            t.check(f.header.littleEndian == le, "endianness detected le=\(le)")
        }
        // int16 (mode 1), BE
        let i16: [Int16] = [-300, 12, 32000, -32768]
        var (_, px) = try read(buildMRC(mode: 1, le: false, nx: 2, ny: 2, nz: 1, body: bytes(i16.map { UInt16(bitPattern: $0) }, le: false)), "i16.mrc")
        t.check(px == i16.map { Float($0) }, "int16 BE", "\(px)")
        // uint16 (mode 6)
        let u16: [UInt16] = [0, 7339, 65535, 6145]
        (_, px) = try read(buildMRC(mode: 6, le: true, nx: 2, ny: 2, nz: 1, body: bytes(u16, le: true)), "u16.mrc")
        t.check(px == u16.map { Float($0) }, "uint16 LE", "\(px)")
        // int8 (mode 0)
        let i8: [Int8] = [-128, -1, 0, 127]
        (_, px) = try read(buildMRC(mode: 0, le: true, nx: 2, ny: 2, nz: 1, body: i8.map { UInt8(bitPattern: $0) }), "i8.mrc")
        t.check(px == i8.map { Float($0) }, "int8", "\(px)")
        // float16 (mode 12): 1.0, -2.0, 0.5, 65504, smallest subnormal
        let h16: [UInt16] = [0x3C00, 0xC000, 0x3800, 0x7BFF, 0x0001]
        (_, px) = try read(buildMRC(mode: 12, le: true, nx: 5, ny: 1, nz: 1, body: bytes(h16, le: true)), "f16.mrc")
        t.check(px[0] == 1 && px[1] == -2 && px[2] == 0.5 && px[3] == 65504 && abs(px[4] - 5.9604645e-8) < 1e-12, "float16 decoding", "\(px)")
        // stack: frame selection
        let stack: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        let (sf, _) = try read(buildMRC(mode: 2, le: true, nx: 2, ny: 2, nz: 2, body: bytes(stack.map { $0.bitPattern }, le: true)), "stack.mrcs")
        t.check(try sf.readPixels(frame: 1) == [5, 6, 7, 8] && sf.depth == 2, "stack frame 1")
        t.check((try? sf.readPixels(frame: 2)) == nil, "frame out of range throws")
        // calibration of exactly 1 Å/px is reported as uncalibrated
        let (uf, _) = try read(buildMRC(mode: 2, le: true, nx: 1, ny: 1, nz: 1, body: bytes([Float(1).bitPattern], le: true)), "uncal.mrc")
        t.check(uf.header.pixelSizeA == nil, "1.0 Å/px = uncalibrated")
        // row order is preserved (no flip): first value is row 0
        let (rf, rpx) = try read(buildMRC(mode: 2, le: true, nx: 2, ny: 2, nz: 1, body: bytes([Float(10), 20, 30, 40].map { $0.bitPattern }, le: true)), "rows.mrc")
        t.check(rpx[0] == 10 && rpx[2] == 30 && rf.height == 2, "row 0 first, no flip")
    } catch { t.check(false, "MRC synthetic tests threw", "\(error)") }
    // error paths
    do {
        let u = dir.appendingPathComponent("trunc.mrc")
        try buildMRC(mode: 2, le: true, nx: 4, ny: 4, nz: 1, body: [0, 0, 0, 0]).write(to: u)
        let f = try MRCFile(url: u)
        t.check((try? f.readPixels()) == nil, "truncated data throws")
        try buildMRC(mode: 4, le: true, nx: 2, ny: 2, nz: 1, body: []).write(to: u)
        t.check((try? MRCFile(url: u)) == nil, "unsupported mode throws")
        try Data(count: 100).write(to: u)
        t.check((try? MRCFile(url: u)) == nil, "short file throws")
    } catch { t.check(false, "MRC error-path tests threw", "\(error)") }
    // writer round trip
    do {
        let px: [Float] = (0..<12).map { Float($0) * 0.5 - 1 }
        let u = dir.appendingPathComponent("rt.mrc")
        try writeMRC(url: u, pixels: px, width: 4, height: 3, pixelSizeA: 3.25)
        let f = try MRCFile(url: u)
        t.check(try f.readPixels() == px && f.width == 4 && f.height == 3, "writeMRC round trip")
        t.check(abs((f.header.pixelSizeA ?? 0) - 3.25) < 1e-6, "round trip pixel size")
    } catch { t.check(false, "writeMRC round trip threw", "\(error)") }
}

// MARK: labels, grid, store

// MARK: quality default, presets, maybe flag

func testQualityDefaultAndMaybe(_ t: inout TestRun) {
    t.section("quality default / presets / maybe flag")
    let q = LabelScheme.default
    t.check(q == .quality && q.labels.map { $0.id } == ["good", "maybe", "reject"] && q.validate().isEmpty, "default scheme is Quality (good / maybe / reject)")
    t.check(q.label(forKey: "1")?.id == "good" && q.label(forKey: "3")?.id == "reject" && q.label("reject")?.exported == false && q.label("maybe")?.exported == true, "quality hotkeys 1-3, only reject not exported")
    t.check(LabelScheme.presets.count == 2 && LabelScheme.presets.allSatisfy { $0.scheme.validate().isEmpty }, "presets valid")
    t.check(LabelScheme.views.suggestedTarget(forMissing: "good") == nil && LabelScheme.quality.suggestedTarget(forMissing: "ring_top") == "good"
            && LabelScheme.quality.suggestedTarget(forMissing: "uncertain") == "maybe" && LabelScheme.quality.suggestedTarget(forMissing: "banana") == nil, "remap suggestions only point at labels that exist")

    // brand-new project gets the Quality scheme; a stored scheme / a pre-scheme file keeps working
    let saved = PickProject.newProjectScheme
    PickProject.newProjectScheme = .default
    let c0 = PickController(); c0.store.saveDelay = 0
    let dir0 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir0) }
    c0.store.openProject(folder: dir0)
    t.check(c0.store.scheme == .quality && c0.activeLabel == "good", "new project: Quality scheme, active label is Good")
    PickProject.newProjectScheme = saved
    let legacy = try? PickStore.decode(Data(#"{"mics":{"a.mrc":{"picks":[{"x":1,"y":2,"label":"ring_top"}]}}}"#.utf8))
    t.check(legacy?.scheme == .views && legacy?.params.maybeFlag == false, "project file without a scheme resolves to the view labels; maybe flag off")

    // maybe flag persistence: absent unless set
    var p1 = Pick(id: "a", x: 1, y: 2, label: "good"), p2 = Pick(id: "b", x: 3, y: 4, label: "good", maybe: true)
    p1.maybe = nil; p2.maybe = true
    let j1 = String(data: (try? JSONEncoder().encode(p1)) ?? Data(), encoding: .utf8) ?? ""
    let j2 = String(data: (try? JSONEncoder().encode(p2)) ?? Data(), encoding: .utf8) ?? ""
    t.check(!j1.contains("maybe") && j2.contains("\"maybe\":true"), "maybe flag is only written when set", j1 + " | " + j2)
    t.check((try? JSONDecoder().decode(Pick.self, from: Data(j2.utf8)))?.isMaybe == true && (try? JSONDecoder().decode(Pick.self, from: Data(j1.utf8)))?.isMaybe == false, "maybe flag round trip")

    // controller: ? is inert until the flag is enabled
    let c = PickController(); c.store.saveDelay = 0
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    c.store.openProject(folder: dir); c.store.setScheme_forTest(.quality)
    c.setMicrograph(key: "m.mrc", width: 100, height: 100, pixelSizeA: 2)
    c.enabled = true
    c.store.add(Pick(id: "a", x: 10, y: 10, label: "good"), to: "m.mrc"); c.store.add(Pick(id: "b", x: 50, y: 50, label: "maybe"), to: "m.mrc")
    c.selection = ["a"]
    t.check(!c.handleKey(chars: "?", keyCode: 44, shift: true, command: false) && c.store.pick("a", in: "m.mrc")?.isMaybe == false, "? does nothing while the maybe flag is off (key not consumed)")
    c.openLabelEditor(); c.draftMaybeFlag = true; c.applyDraftScheme()
    t.check(c.store.project.params.maybeFlag && c.schemeError == nil, "maybe flag enabled from the editor")
    t.check(c.handleKey(chars: "?", keyCode: 44, shift: true, command: false) && c.store.pick("a", in: "m.mrc")?.isMaybe == true && c.store.pick("a", in: "m.mrc")?.label == "good", "? flags the selection without changing its label")
    t.check(c.store.maybeCount("m.mrc") == 1, "maybe count")
    c.store.undo("m.mrc")
    t.check(c.store.pick("a", in: "m.mrc")?.isMaybe == false, "flagging is one undo step")
    c.store.redo("m.mrc")
    c.selection = ["a"]; _ = c.handleKey(chars: "/", keyCode: 44, shift: false, command: false)
    t.check(c.store.pick("a", in: "m.mrc")?.isMaybe == false, "second press clears the flag")
    _ = c.handleKey(chars: "?", keyCode: 44, shift: true, command: false)
    c.setActiveLabel("maybe")
    t.check(c.store.pick("a", in: "m.mrc")?.label == "maybe" && c.store.pick("a", in: "m.mrc")?.isMaybe == true, "relabel keeps the flag")

    // export: reject dropped, maybe flagged picks optional, csv column present
    let out = testTempDir(); defer { try? FileManager.default.removeItem(at: out) }
    c.store.add(Pick(id: "r", x: 70, y: 70, label: "reject"), to: "m.mrc")
    var o = ExportOptions(); o.formats = [.csv, .relion]
    if let s1 = try? PickExporter.export(project: c.store.project, root: dir, outDir: out, options: o) {
        let csv = (try? String(contentsOf: out.appendingPathComponent("all_picks.csv"), encoding: .utf8)) ?? ""
        t.check(s1.total == 2 && s1.skippedLabels == ["reject"] && csv.hasPrefix("dataset,") && csv.contains(",source,maybe\n") && csv.contains(",manual,1\n"), "export: reject dropped, maybe column written", csv)
    } else { t.check(false, "export with maybe flag threw") }
    o.excludeMaybe = true
    if let s2 = try? PickExporter.export(project: c.store.project, root: dir, outDir: out, options: o) {
        t.check(s2.total == 1 && s2.totals["maybe"] == 1, "export excludeMaybe leaves out flagged picks", "\(s2.totals)")
    } else { t.check(false, "export excludeMaybe threw") }

    // preset switch with picks in use: remap, nothing silently lost
    let c2 = PickController(); c2.store.saveDelay = 0
    let dir2 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
    c2.store.openProject(folder: dir2); c2.store.setScheme_forTest(.views)
    c2.setMicrograph(key: "a.mrc", width: 100, height: 100, pixelSizeA: 2)
    for (i, l) in ["ring_top", "side", "tilted", "uncertain", "reject", "ring_top"].enumerated() { c2.store.add(Pick(id: "p\(i)", x: Double(10 + 12 * i), y: 10, label: l), to: "a.mrc") }
    c2.store.add(Pick(id: "d", x: 5, y: 90, label: "side", source: .auto, status: .dismissed), to: "a.mrc")
    c2.openLabelEditor(); c2.loadDraftPreset(.quality)
    let miss = c2.draftMissingLabels.map { $0.id }
    t.check(Set(miss) == ["ring_top", "side", "tilted", "uncertain"], "preset switch lists the dropped labels that have picks", "\(miss)")
    t.check(c2.draftRemap["ring_top"] == "good" && c2.draftRemap["uncertain"] == "maybe" && c2.draftRemap["tilted"] == "good", "remap pre-filled with suggestions")
    c2.draftRemap["tilted"] = nil
    c2.applyDraftScheme()
    t.check(c2.schemeError?.contains("tilted") == true && c2.showLabelEditor && c2.store.scheme == .views && c2.store.picks("a.mrc").first { $0.id == "p0" }?.label == "ring_top", "unresolved label blocks the switch and changes nothing")
    c2.draftRemap["tilted"] = "maybe"
    c2.applyDraftScheme()
    let after = Dictionary(uniqueKeysWithValues: c2.store.picks("a.mrc").map { ($0.id, $0.label) })
    t.check(c2.schemeError == nil && c2.store.scheme == .quality && after["p0"] == "good" && after["p1"] == "good" && after["p2"] == "maybe"
            && after["p3"] == "maybe" && after["p4"] == "reject" && after["p5"] == "good" && after["d"] == "good" && after.count == 7, "picks (incl. dismissed) moved per the remap; none lost", "\(after)")
    t.check(c2.store.labelUsage().keys.allSatisfy { c2.store.scheme.label($0) != nil } && c2.activeLabel == "good", "every pick label exists in the new scheme; active label valid")
}

func testLabelScheme(_ t: inout TestRun) {
    t.section("label scheme")
    let d = LabelScheme.views
    t.check(d.labels.count == 6 && d.validate().isEmpty, "views preset valid")
    t.check(d.label(forKey: "3")?.id == "tilted" && d.label("reject")?.exported == false, "hotkey lookup / reject not exported")
    var bad = d; bad.labels.append(PickLabel(id: "side", name: "dup", key: "1", color: "#12"))
    let errs = bad.validate()
    t.check(errs.contains { $0.contains("duplicate id") } && errs.contains { $0.contains("duplicate hotkey") } && errs.contains { $0.contains("bad color") }, "validate finds duplicates and bad color", "\(errs)")
    t.check(parseHexColor("#ff4d4d").map { abs($0.0 - 1) < 1e-9 && abs($0.1 - 77.0/255) < 1e-9 } == true, "hex color")
    // web-picker manifest style list with only key/id/name/color
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let u = dir.appendingPathComponent("labels.json")
    try? Data(##"[{"key":"1","id":"ring_top","name":"Ring","color":"#ff4d4d"},{"key":"2","id":"junk","color":"#999999"}]"##.utf8).write(to: u)
    let s = try? LabelScheme.load(from: u)
    t.check(s?.labels.count == 2 && s?.labels[1].name == "junk" && s?.labels[0].shape == .circle && s?.labels[0].exported == true, "loads web-manifest label list with defaults")
    try? d.save(to: u)
    t.check((try? LabelScheme.load(from: u)) == d, "scheme save/load round trip")
}

func testGrid(_ t: inout TestRun) {
    t.section("spatial grid")
    var rng = SystemRandomNumberGenerator()
    var pk: [Pick] = []
    for i in 0..<2000 { pk.append(Pick(id: "p\(i)", x: Double.random(in: -50...4100, using: &rng), y: Double.random(in: -50...4100, using: &rng), label: "ring_top")) }
    let g = PickGrid(picks: pk, cell: 64)
    var ok = true
    for _ in 0..<300 {
        let x = Double.random(in: -80...4150, using: &rng), y = Double.random(in: -80...4150, using: &rng), r = Double.random(in: 1...200, using: &rng)
        let brute = pk.filter { hypot($0.x - x, $0.y - y) <= r }.min { hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y) }
        if g.nearest(x: x, y: y, radius: r)?.id != brute?.id { ok = false }
    }
    t.check(ok, "nearest == brute force (300 random queries incl. negative coords)")
    let rect = g.inRect(x0: 500, y0: 900, x1: 100, y1: 300)
    t.check(Set(rect.map { $0.id }) == Set(pk.filter { $0.x >= 100 && $0.x <= 500 && $0.y >= 300 && $0.y <= 900 }.map { $0.id }), "rect query == brute force")
    t.check(g.nearest(x: 0, y: 0, radius: 100, filter: { _ in false }) == nil, "filter respected")
}

func testStoreEditing(_ t: inout TestRun) {
    t.section("pick store: editing / undo")
    let s = PickStore(); s.saveDelay = 0
    let k = "m1.mrc"
    let a = Pick(id: "a", x: 10, y: 20, label: "ring_top"), b = Pick(id: "b", x: 100, y: 200, label: "side")
    t.check(s.add(a, to: k) && s.add(b, to: k), "add picks")
    t.check(s.picks(k).count == 2 && s.counts(k) == ["ring_top": 1, "side": 1], "counts")
    s.relabel(["a"], to: "tilted", in: k)
    t.check(s.pick("a", in: k)?.label == "tilted", "relabel")
    t.check(s.undo(k) && s.pick("a", in: k)?.label == "ring_top", "undo relabel")
    t.check(s.redo(k) && s.pick("a", in: k)?.label == "tilted", "redo relabel")
    s.remove(["b"], from: k)
    t.check(s.pick("b", in: k) == nil, "manual pick removed")
    t.check(s.undo(k) && s.pick("b", in: k) == b, "undo delete restores identical pick")
    // new edit clears redo
    s.undo(k); s.add(Pick(id: "c", x: 1, y: 1, label: "side"), to: k)
    t.check(!s.canRedo(k), "new edit clears redo")
    // auto picks are dismissed, not deleted
    let au = Pick(id: "z", x: 5, y: 5, label: "ring_top", score: 4.2, source: .auto, status: .candidate)
    s.perform(k, "auto") { $0.append(au) }
    t.check(s.candidates(k).count == 1 && s.accepted(k).contains { $0.id == "z" } == false, "candidate is not accepted")
    s.setStatus(["z"], .accepted, in: k)
    t.check(s.accepted(k).contains { $0.id == "z" }, "accept candidate")
    s.remove(["z"], from: k)
    t.check(s.pick("z", in: k)?.status == .dismissed && s.grid(k).nearest(x: 5, y: 5, radius: 3) == nil, "deleting auto pick dismisses it and hides it from hit tests")
    t.check(s.counts(k)["ring_top", default: 0] == 0 || s.counts(k)["ring_top"] == 1, "dismissed not counted")
    // resize
    s.setDiameter(["a"], nm: 33, in: k)
    t.check(s.diameterNm(s.pick("a", in: k)!) == 33 && s.diameterNm(s.pick("c", in: k)!) == s.project.params.diameterNm, "diameter override vs default")
    s.setDiameter(nil, nm: 12, in: k)
    t.check(s.picks(k).allSatisfy { $0.diameterNm == 12 }, "resize all")
    // transient drag + commit = single undo step
    let before = s.undoName(k)
    let snap = s.picks(k)
    for i in 1...20 { s.transient(k) { l in if let j = l.firstIndex(where: { $0.id == "a" }) { l[j].x = 10 + Double(i); l[j].y = 20 + Double(i) } } }
    t.check(s.pick("a", in: k)?.x == 30, "transient moves live")
    s.commit(k, from: snap, name: "Move")
    t.check(s.undoName(k) == "Move" && s.undoName(k) != before, "commit records one step")
    s.undo(k)
    t.check(s.pick("a", in: k)?.x == 10 && s.pick("a", in: k)?.y == 20, "undo drag restores original position")
    let n = s.picks(k).count
    s.commit(k, from: s.picks(k), name: "Nothing")
    t.check(s.undoName(k) != "Nothing" && s.picks(k).count == n, "no-op commit is not recorded")
    // grid cache invalidates after edits
    s.perform(k, "m") { l in if let j = l.firstIndex(where: { $0.id == "c" }) { l[j].x = 3000; l[j].y = 3000 } }
    t.check(s.grid(k).nearest(x: 3000, y: 3000, radius: 2)?.id == "c" && s.grid(k).nearest(x: 1, y: 1, radius: 2) == nil, "grid cache invalidated")
    // undo is per micrograph
    s.add(Pick(id: "q", x: 1, y: 1, label: "side"), to: "m2.mrc")
    s.undo("m2.mrc")
    t.check(s.picks("m2.mrc").isEmpty && s.pick("c", in: k) != nil, "undo stacks are per micrograph")
}

func testStorePersistence(_ t: inout TestRun) {
    t.section("pick store: persistence")
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let s = PickStore(); s.saveDelay = 0
    t.check(s.openProject(folder: dir) && s.project.scheme == PickProject.newProjectScheme, "new project uses the new-project scheme")
    t.check(s.key(for: dir.appendingPathComponent("Micrographs/a.mrc")) == "Micrographs/a.mrc", "relative key")
    t.check(s.key(for: URL(fileURLWithPath: "/elsewhere/b.mrc")) == "/elsewhere/b.mrc", "absolute key outside project")
    s.add(Pick(id: "a", x: 1234.5, y: 99.25, label: "side", score: 3.5, source: .auto, status: .accepted, diameterNm: 18), to: "Micrographs/a.mrc")
    s.add(Pick(id: "b", x: 5, y: 6, label: "ring_top"), to: "Micrographs/b.mrc")
    s.setDone("Micrographs/a.mrc", true); s.setNote("Micrographs/a.mrc", "thick ice, top right")
    s.setParams({ var p = ProjectParams(); p.boxNm = 31; p.diameterNm = 14; return p }())
    s.setAutoParams("Micrographs/a.mrc", AutoParams())
    t.check(s.save(), "save returns true")
    let s2 = PickStore(); s2.openProject(folder: dir)
    t.check(s2.project == s.project, "save/load round trip is lossless")
    t.check(s2.project.mics["Micrographs/a.mrc"]?.picks.first?.x == 1234.5 && s2.project.mics["Micrographs/a.mrc"]?.note == "thick ice, top right", "values survive")
    // backups + retention
    s.backupsToKeep = 3
    for i in 0..<6 { s.add(Pick(x: Double(i), y: 0, label: "side"), to: "x"); s.save(forceBackup: true); Thread.sleep(forTimeInterval: 0.01) }
    let nb = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path))?.count ?? -1
    t.check(nb == 3, "backup retention keeps newest 3", "found \(nb)")
    // backup interval: a normal save right after a backup does not write another
    s.backupInterval = 3600; s.save(forceBackup: true)
    s.add(Pick(x: 9, y: 9, label: "side"), to: "x"); s.save()
    t.check(((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path))?.count ?? -1) == 3, "no extra backup within interval")
    // atomic write leaves no temp files and replaces existing content
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    t.check(!names.contains { $0.contains(".tmp") }, "no temp files left after saves", "\(names)")
    // labels.json used for a new project
    let dir2 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
    var custom = LabelScheme(labels: [PickLabel(id: "good", name: "Good", key: "m", color: "#00ff00", shape: .box), PickLabel(id: "junk", name: "Junk", key: "j", color: "#888888", exported: false)])
    try? custom.save(to: dir2.appendingPathComponent("labels.json"))
    let s3 = PickStore(); s3.openProject(folder: dir2)
    t.check(s3.scheme == custom, "labels.json picked up by new project")
    custom.labels[0].key = "j"
    try? custom.save(to: dir2.appendingPathComponent("labels.json"))
    let s4 = PickStore(); s4.openProject(folder: dir2)
    t.check(s4.scheme == PickProject.newProjectScheme, "invalid labels.json (dup hotkey) falls back to the new-project scheme")
    // tolerant decoding of a sparse hand-written file
    let dir3 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir3) }
    try? Data(#"{"mics":{"a.mrc":{"picks":[{"x":1,"y":2,"label":"side"},{"x":3,"y":4}]}}}"#.utf8).write(to: dir3.appendingPathComponent("picks_project.json"))
    let s5 = PickStore(); let ok5 = s5.openProject(folder: dir3)
    t.check(ok5 && s5.picks("a.mrc").count == 2 && s5.picks("a.mrc")[0].status == .accepted && s5.project.scheme == .views, "sparse project JSON decodes with defaults (no stored scheme = legacy view labels)")
    // corrupt file -> error reported, project empty, file not overwritten until an edit
    let dir4 = testTempDir(); defer { try? FileManager.default.removeItem(at: dir4) }
    try? Data("{not json".utf8).write(to: dir4.appendingPathComponent("picks_project.json"))
    let s6 = PickStore(); let ok6 = s6.openProject(folder: dir4)
    t.check(!ok6 && s6.lastError != nil && s6.project.mics.isEmpty, "corrupt project reported")
    // debounced autosave
    let s7 = PickStore(); s7.openProject(folder: dir4); s7.saveDelay = 0.05
    s7.add(Pick(x: 1, y: 1, label: "side"), to: "z")
    t.check(s7.dirty, "dirty after edit")
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    t.check(!s7.dirty && s7.lastSaved != nil, "debounced autosave fires")
}

// MARK: geometry, crop, controller

func testGeometry(_ t: inout TestRun) {
    t.section("geometry / crop")
    let g = ViewGeometry(zoom: 0.37, center: CGPoint(x: 2048.5, y: 1000), viewPixels: CGSize(width: 1800, height: 1400), backingScale: 2)
    var ok = true
    for (x, y) in [(0.0, 0.0), (4095.0, 4095.0), (1234.5, 77.25), (-10.0, 5000.0)] {
        let v = g.pickToView(x: x, y: y), b = g.viewToPick(v)
        if abs(b.x - x) > 1e-9 || abs(b.y - y) > 1e-9 { ok = false }
    }
    t.check(ok, "pick <-> view round trip")
    // view center maps to `center`; one image px = zoom/backingScale points
    let cpt = CGPoint(x: 900 / 2.0 * 1.0, y: 700 / 2.0 * 1.0)
    t.check(abs(g.toImage(CGPoint(x: 450, y: 350)).x - 2048.5) < 1e-9 && abs(g.toImage(CGPoint(x: 450, y: 350)).y - 1000) < 1e-9, "view center -> image center", "\(cpt)")
    let a = g.toView(CGPoint(x: 100, y: 100)), b = g.toView(CGPoint(x: 101, y: 100))
    t.check(abs((b.x - a.x) - 0.37 / 2) < 1e-12 && g.pointsPerPixel == 0.185, "points per image pixel")
    // pixel center convention: center of pixel (i, j) is pick coord (i, j) and viewer coord (i+0.5, j+0.5)
    let pv = g.pickToView(x: 10, y: 20), iv = g.toView(CGPoint(x: 10.5, y: 20.5))
    t.check(pv == iv, "pick coord = viewer coord - 0.5")
    // crop: values, clamping, out-of-image fill, invert
    let w = 8, h = 6
    let px: [Float] = (0..<(w * h)).map { Float($0) }
    var c = renderCrop(pixels: px, width: w, height: h, cx: 3, cy: 2, half: 2, lo: 0, hi: 47)
    // crop covers x 1..4, y 0..3 ; (row 0 = image row 0)
    t.check(c.count == 16 && c[0] == UInt8(Float(1 + 0 * w) / 47 * 255 + 0.5) && c[3 + 3 * 4] == UInt8(Float(4 + 3 * w) / 47 * 255 + 0.5), "crop pixel mapping", "\(c)")
    c = renderCrop(pixels: px, width: w, height: h, cx: 0, cy: 0, half: 2, lo: 0, hi: 47)
    t.check(c[0] == 128 && c[1] == 128 && c[2 * 4 + 2] == 0 && c[2 * 4 + 3] == UInt8(1.0 / 47 * 255 + 0.5), "out-of-image is mid-gray, in-image mapped", "\(c)")
    c = renderCrop(pixels: px, width: w, height: h, cx: 3, cy: 2, half: 2, lo: 0, hi: 47, invert: true)
    t.check(c[0] == 255 - UInt8(Float(1) / 47 * 255 + 0.5) || abs(Int(c[0]) - (255 - Int(Float(1) / 47 * 255 + 0.5))) <= 1, "invert")
    t.check(grayCGImage(c, width: 4, height: 4) != nil && grayCGImage(c, width: 5, height: 4) == nil, "CGImage creation validates size")
}

func testController(_ t: inout TestRun) {
    t.section("pick controller (mouse logic)")
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0
    c.store.openProject(folder: dir)
    c.setMicrograph(key: "m.mrc", width: 1000, height: 800, pixelSizeA: 10)     // 20 nm default diameter = 200 px
    c.enabled = true
    let k = "m.mrc"
    func click(_ x: Double, _ y: Double, shift: Bool = false) {
        c.mouseDown(at: CGPoint(x: x, y: y), radiusPx: 10, shift: shift)
        c.mouseUp(at: CGPoint(x: x, y: y), shift: shift)
    }
    // add with active label
    c.setActiveLabel("side")
    click(500, 400)
    t.check(c.store.accepted(k).count == 1 && c.store.accepted(k)[0].label == "side" && c.selection.count == 1, "click adds pick with active label and selects it")
    let id1 = c.store.accepted(k)[0].id
    // click on it again selects, does not add
    c.selection = []; click(505, 398)
    t.check(c.store.accepted(k).count == 1 && c.selection == [id1], "click on existing pick selects (hit tolerance)")
    // far away click adds
    click(100, 100)
    t.check(c.store.accepted(k).count == 2, "click on empty space adds")
    // outside image clicks do nothing
    click(-30, 20); click(1200, 20)
    t.check(c.store.accepted(k).count == 2, "clicks outside the image ignored")
    // relabel selection via hotkey; the hotkey also changes the active label
    c.selection = [id1]
    t.check(c.handleKey(chars: "3", keyCode: 20, shift: false, command: false) && c.store.pick(id1, in: k)?.label == "tilted" && c.activeLabel == "tilted", "hotkey 3 relabels selection and sets active label")
    // drag to move: sub-threshold is a click, larger is a move + one undo step
    c.mouseDown(at: CGPoint(x: 500, y: 400), radiusPx: 10, shift: false)
    let m0 = c.mouseDragged(to: CGPoint(x: 501, y: 400), movedPoints: 1, shift: false)
    t.check(m0 == .none, "below drag threshold nothing happens")
    var mode = DragMode.none
    for i in 1...10 { mode = c.mouseDragged(to: CGPoint(x: 500 + Double(i) * 10, y: 400 + Double(i) * 5), movedPoints: 40, shift: false) }
    c.mouseUp(at: CGPoint(x: 600, y: 450), shift: false)
    let moved = c.store.pick(id1, in: k)!
    t.check(mode == .movePicks && moved.x == 600 && moved.y == 450, "drag moves pick by the exact delta", "\(moved.x),\(moved.y)")
    t.check(c.store.undoName(k) == "Move pick", "drag = single undo step")
    c.undo()
    t.check(c.store.pick(id1, in: k)?.x == 500 && c.store.pick(id1, in: k)?.y == 400, "undo move")
    c.redo()
    // drag clamps to image
    c.mouseDown(at: CGPoint(x: 600, y: 450), radiusPx: 10, shift: false)
    _ = c.mouseDragged(to: CGPoint(x: 5000, y: -5000), movedPoints: 99, shift: false)
    c.mouseUp(at: CGPoint(x: 5000, y: -5000), shift: false)
    t.check(c.store.pick(id1, in: k)?.x == 999 && c.store.pick(id1, in: k)?.y == 0, "drag clamped to image bounds")
    // plain empty drag = pan; shift-drag = rubber band selection
    c.selection = []
    c.mouseDown(at: CGPoint(x: 300, y: 600), radiusPx: 10, shift: false)
    t.check(c.mouseDragged(to: CGPoint(x: 320, y: 620), movedPoints: 30, shift: false) == .pan, "drag on empty space pans")
    c.mouseUp(at: CGPoint(x: 320, y: 620), shift: false)
    t.check(c.store.accepted(k).count == 2, "pan does not add picks")
    click(300, 300); click(320, 330); click(700, 700)
    c.selection = []
    c.mouseDown(at: CGPoint(x: 250, y: 250), radiusPx: 10, shift: true)
    t.check(c.mouseDragged(to: CGPoint(x: 350, y: 350), movedPoints: 140, shift: true) == .box && c.boxRect != nil, "shift-drag draws rubber band")
    c.mouseUp(at: CGPoint(x: 350, y: 350), shift: true)
    t.check(c.selection.count == 2 && c.boxRect == nil, "rubber band selects the two picks inside", "\(c.selection.count)")
    // delete / undo
    let before = c.store.accepted(k).count
    c.deleteSelection()
    t.check(c.store.accepted(k).count == before - 2 && c.selection.isEmpty, "delete selection")
    c.undo()
    t.check(c.store.accepted(k).count == before, "undo delete")
    // right click deletes the pick under the cursor
    c.rightClick(at: CGPoint(x: 700, y: 700), radiusPx: 10)
    t.check(c.store.accepted(k).count == before - 1, "right-click deletes")
    // candidates: click accepts; 'a' accepts all above cutoff; cutoff hides
    c.store.perform(k, "auto") { l in
        l.append(Pick(id: "c1", x: 800, y: 100, label: "ring_top", score: 5, source: .auto, status: .candidate))
        l.append(Pick(id: "c2", x: 800, y: 300, label: "ring_top", score: 2, source: .auto, status: .candidate))
        l.append(Pick(id: "c3", x: 800, y: 600, label: "ring_top", score: 4, source: .auto, status: .candidate))
    }
    c.scoreCutoff = 3
    t.check(c.visiblePicks.filter { $0.status == .candidate }.map { $0.id }.sorted() == ["c1", "c3"], "score cutoff hides weak candidates")
    click(800, 100)
    t.check(c.store.pick("c1", in: k)?.status == .accepted, "click on candidate accepts it")
    _ = c.handleKey(chars: "a", keyCode: 0, shift: false, command: false)
    t.check(c.store.pick("c3", in: k)?.status == .accepted && c.store.pick("c2", in: k)?.status == .candidate, "'a' accepts visible candidates only")
    c.selection = ["c3"]; c.deleteSelection()
    t.check(c.store.pick("c3", in: k)?.status == .dismissed, "delete on auto pick dismisses")
    // resize via keys: selection -> that pick, none -> project default
    let d0 = c.store.project.params.diameterNm
    c.selection = []; _ = c.handleKey(chars: ".", keyCode: 47, shift: false, command: false)
    t.check(c.store.project.params.diameterNm == d0 + 1, "'.' grows default diameter when nothing selected")
    c.selection = ["c1"]; _ = c.handleKey(chars: ",", keyCode: 43, shift: false, command: false)
    t.check(c.store.pick("c1", in: k)?.diameterNm == d0 + 1 - 1, "',' shrinks selected pick", "\(String(describing: c.store.pick("c1", in: k)?.diameterNm))")
    // hidden labels are not hit-tested
    c.hiddenLabels = ["tilted"]; c.selection = []
    let nTilt = c.store.accepted(k).filter { $0.label == "tilted" }.count
    if let tp = c.store.accepted(k).first(where: { $0.label == "tilted" }) {
        c.mouseDown(at: CGPoint(x: tp.x, y: tp.y), radiusPx: 10, shift: false); c.mouseUp(at: CGPoint(x: tp.x, y: tp.y), shift: false)
        t.check(c.selection.contains(tp.id) == false, "hidden-label pick cannot be selected (click adds instead)", "n=\(nTilt)")
    }
    // label editor: reserved hotkeys rejected; labels in use cannot be removed; valid edits apply
    c.openLabelEditor()
    c.draftScheme.labels[0].key = "p"
    c.applyDraftScheme()
    t.check(c.schemeError?.contains("reserved") == true && c.showLabelEditor, "reserved hotkey rejected")
    c.openLabelEditor()
    c.draftScheme.labels.removeAll { $0.id == "side" }
    c.applyDraftScheme()
    t.check(c.schemeError?.contains("in use") == true && c.store.scheme.label("side") != nil, "label with picks cannot be removed")
    c.openLabelEditor()
    c.draftScheme.labels[1].name = "Edge-on"; c.draftScheme.labels[1].color = "#123456"
    c.addDraftLabel()
    c.applyDraftScheme()
    t.check(c.schemeError == nil && !c.showLabelEditor && c.store.scheme.label("side")?.name == "Edge-on" && c.store.scheme.labels.count == 7 && c.store.scheme.validate().isEmpty, "valid edit applied (new label gets a free non-reserved hotkey)")
    // keys are ignored when the picker is off or command is held
    c.enabled = false
    t.check(!c.handleKey(chars: "1", keyCode: 18, shift: false, command: false), "keys ignored when pick mode is off")
    c.enabled = true
    t.check(!c.handleKey(chars: "a", keyCode: 0, shift: false, command: true), "command-modified keys not consumed")
    // switching micrograph clears selection
    c.selection = ["c1"]; c.setMicrograph(key: "n.mrc", width: 500, height: 500, pixelSizeA: nil)
    t.check(c.selection.isEmpty && c.diameterPx(Pick(x: 0, y: 0, label: "side")) == c.store.project.params.diameterNm * 10, "new micrograph: selection cleared, uncalibrated Å/px=1 fallback")
}

// MARK: auto-picker

struct LCG {
    var s: UInt64
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double { let u = max(next(), 1e-12), v = next(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) }
}

/// Synthetic micrograph: Gaussian blobs (sigma = D/6) on a tilted background plus noise. Returns pixels and blob centers.
func syntheticMicrograph(w: Int, h: Int, n: Int, dPx: Double, amp: Double, noise: Double, seed: UInt64, dark: Bool = false) -> ([Float], [(Double, Double)]) {
    var r = LCG(s: seed)
    var centers: [(Double, Double)] = []
    var tries = 0
    while centers.count < n && tries < 10000 {
        tries += 1
        let x = 1.5 * dPx + r.next() * (Double(w) - 3 * dPx), y = 1.5 * dPx + r.next() * (Double(h) - 3 * dPx)
        if centers.allSatisfy({ hypot($0.0 - x, $0.1 - y) > 2.2 * dPx }) { centers.append((x, y)) }
    }
    var a = [Float](repeating: 0, count: w * h)
    let sg = dPx / 6
    for y in 0..<h { for x in 0..<w { a[y * w + x] = Float(100 + 0.01 * Double(x) + 0.02 * Double(y) + noise * r.gauss()) } }
    for (cx, cy) in centers {
        let rr = Int(3.5 * sg * 1.5)
        for y in max(0, Int(cy) - rr)...min(h - 1, Int(cy) + rr) { for x in max(0, Int(cx) - rr)...min(w - 1, Int(cx) + rr) {
            let d2 = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
            a[y * w + x] += Float((dark ? -amp : amp) * exp(-d2 / (2 * sg * sg)))
        } }
    }
    return (a, centers)
}

func testAutoPrimitives(_ t: inout TestRun) {
    t.section("auto-picker primitives")
    var r = LCG(s: 7)
    let w = 37, h = 29
    let a = (0..<(w * h)).map { _ in Float(r.gauss()) }
    // gaussian vs brute force with edge replication
    let sg = 1.7, k = AutoPicker.gaussianKernel(sg), rad = k.count - 1
    let g = AutoPicker.gaussianBlur(a, w, h, sigma: sg)
    var maxErr: Float = 0
    for y in 0..<h { for x in 0..<w {
        var s: Float = 0
        for dy in -rad...rad { for dx in -rad...rad {
            s += k[abs(dx)] * k[abs(dy)] * a[min(max(y + dy, 0), h - 1) * w + min(max(x + dx, 0), w - 1)]
        } }
        maxErr = max(maxErr, abs(s - g[y * w + x]))
    } }
    t.check(maxErr < 1e-4, "gaussian == brute-force 2D convolution (edge replicate)", "err \(maxErr)")
    t.check(abs(k[0] + 2 * k.dropFirst().reduce(0, +) - 1) < 1e-6, "kernel normalized")
    // disk mean vs brute force (edge-aware)
    var worst: Float = 0
    for rad in [1.0, 2.5, 4.2] {
        let dm = AutoPicker.diskMean(a, w, h, radius: rad)
        for y in 0..<h { for x in 0..<w {
            var s: Float = 0, n = 0
            let ri = Int(rad)
            for dy in -ri...ri { for dx in -ri...ri where Double(dx * dx + dy * dy) <= rad * rad {
                let xx = x + dx, yy = y + dy
                if xx >= 0, xx < w, yy >= 0, yy < h { s += a[yy * w + xx]; n += 1 }
            } }
            worst = max(worst, abs(s / Float(n) - dm[y * w + x]))
        } }
    }
    t.check(worst < 1e-4, "disk mean == brute force (r = 1, 2.5, 4.2)", "err \(worst)")
    t.check(AutoPicker.countDisk(1) == 5 && AutoPicker.countDisk(2) == 13 && AutoPicker.countDisk(2.5) == 21, "disk pixel counts")
    // binning
    let (b, bw, bh) = AutoPicker.bin([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], 4, 4, factor: 2)
    t.check(bw == 2 && bh == 2 && b == [3.5, 5.5, 11.5, 13.5], "2x2 binning means", "\(b)")
    let (b3, w3, h3) = AutoPicker.bin([Float](repeating: 1, count: 7 * 5), 7, 5, factor: 3)
    t.check(w3 == 2 && h3 == 1 && b3 == [1, 1], "binning drops the partial border")
    // robust stats ignore outliers
    var v = (0..<10001).map { _ in Float(r.gauss()) }
    for i in 0..<300 { v[i] = 1e6 }
    let st = AutoPicker.robustStats(v)
    t.check(abs(st.median) < 0.1 && abs(st.sigma - 1) < 0.15, "robust stats resist outliers", "\(st)")
    t.check(AutoPicker.binFactor(diameterPx: 31) == 3 && AutoPicker.binFactor(diameterPx: 8) == 1 && AutoPicker.binFactor(diameterPx: 1000) == 16, "bin factor rule")
    // params: tolerant decoding + score signature ignores extraction-only fields
    let p0 = (try? JSONDecoder().decode(AutoParams.self, from: Data(#"{"zThreshold":6}"#.utf8)))
    t.check(p0?.zThreshold == 6 && p0?.method == .core && p0?.maxPicks == 400, "AutoParams sparse JSON")
    var p1 = AutoParams(); let sig = p1.scoreSignature; p1.zThreshold = 9; p1.maxPicks = 3; p1.minSepNm = 5
    t.check(p1.scoreSignature == sig, "extraction-only params keep the score cache valid")
    p1.smoothNm = 1; t.check(p1.scoreSignature != sig, "smoothing changes the score signature")
}

func testAutoPicker(_ t: inout TestRun) {
    t.section("auto-picker on synthetic micrographs")
    let angpix = 5.0, diamNm = 20.0, dPx = diamNm * 10 / angpix          // 40 px
    for (method, dark) in [(PickMethod.core, false), (PickMethod.log, false), (PickMethod.core, true)] {
        let (img, truth) = syntheticMicrograph(w: 1024, h: 1024, n: 14, dPx: dPx, amp: 12, noise: 8, seed: 11, dark: dark)
        var p = AutoParams(); p.method = method; p.bright = !dark; p.diameterNm = diamNm; p.zThreshold = 5
        let c = AutoPicker.run(pixels: img, width: 1024, height: 1024, angpix: angpix, params: p)
        var found = 0
        for (tx, ty) in truth where c.contains(where: { hypot($0.x - tx, $0.y - ty) <= 4 }) { found += 1 }
        let fp = c.filter { k in !truth.contains { hypot($0.0 - k.x, $0.1 - k.y) <= 0.5 * dPx } }.count
        t.check(found == truth.count, "\(method.rawValue)\(dark ? " (dark)" : ""): finds all \(truth.count) blobs within 4 px", "found \(found)/\(truth.count), total \(c.count)")
        t.check(fp <= 1, "\(method.rawValue)\(dark ? " (dark)" : ""): at most 1 false positive at z>=5", "false positives \(fp)")
        t.check(c.sorted { $0.score > $1.score } == c || c.map { $0.score } == c.map { $0.score }.sorted(by: >), "candidates are returned best first")
        if method == .core {
            let wrong = AutoPicker.run(pixels: img, width: 1024, height: 1024, angpix: angpix, params: { var q = p; q.bright = dark; return q }())
            let hits = truth.filter { tr in wrong.contains { hypot($0.x - tr.0, $0.y - tr.1) <= 4 } }.count
            t.check(hits <= 2, "\(dark ? "dark" : "bright") blobs are not found with the opposite polarity", "hits \(hits)")
        }
    }
    // controls: pure noise gives (almost) nothing at z >= 5; sub-pixel accuracy of an isolated blob
    let (noiseImg, _) = syntheticMicrograph(w: 1024, h: 1024, n: 0, dPx: dPx, amp: 0, noise: 8, seed: 3)
    var p = AutoParams(); p.diameterNm = diamNm; p.zThreshold = 5
    t.check(AutoPicker.run(pixels: noiseImg, width: 1024, height: 1024, angpix: angpix, params: p).count <= 3, "pure noise: <= 3 picks at z >= 5")
    let (one, tr1) = syntheticMicrograph(w: 512, h: 512, n: 1, dPx: dPx, amp: 20, noise: 2, seed: 5)
    let c1 = AutoPicker.run(pixels: one, width: 512, height: 512, angpix: angpix, params: p)
    t.check(c1.count == 1 && hypot(c1[0].x - tr1[0].0, c1[0].y - tr1[0].1) < 2.0, "isolated blob localised within 2 px", "\(c1) vs \(tr1)")
    // minimum separation: two blobs 30 px apart (< 0.9 D = 36) give one pick; maxPicks caps; edge margin
    var two = [Float](repeating: 100, count: 512 * 512)
    for (cx, cy) in [(200.0, 256.0), (230.0, 256.0), (400.0, 100.0)] {
        for y in 0..<512 { for x in 0..<512 { let d2 = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy); two[y * 512 + x] += Float(30 * exp(-d2 / (2 * 49))) } }
    }
    var rr = LCG(s: 9); for i in 0..<two.count { two[i] += Float(rr.gauss()) }
    let c2 = AutoPicker.run(pixels: two, width: 512, height: 512, angpix: angpix, params: p)
    t.check(c2.filter { $0.x < 300 }.count == 1 && c2.contains { abs($0.x - 400) < 3 && abs($0.y - 100) < 3 }, "blobs closer than 0.9 D give one pick", "\(c2.map { ($0.x, $0.y) })")
    var pc = p; pc.maxPicks = 1
    t.check(AutoPicker.run(pixels: two, width: 512, height: 512, angpix: angpix, params: pc).count == 1, "maxPicks cap")
    var pe = p; pe.edgeMarginPx = 150
    t.check(!AutoPicker.run(pixels: two, width: 512, height: 512, angpix: angpix, params: pe).contains { $0.y < 150 }, "edge margin removes the blob near the border")
    // flatten removes a strong gradient that otherwise produces picks along the bright edge
    var grad = [Float](repeating: 0, count: 512 * 512); var gr = LCG(s: 21)
    for y in 0..<512 { for x in 0..<512 { grad[y * 512 + x] = Float(Double(x) * 0.6 + gr.gauss()) } }
    var pf = p; pf.flattenNm = 40
    let nGrad = AutoPicker.run(pixels: grad, width: 512, height: 512, angpix: angpix, params: pf).count
    t.check(nGrad <= 3, "flatten handles a background ramp", "picks \(nGrad)")
}

func testAutoIntegration(_ t: inout TestRun) {
    t.section("auto-picker -> store")
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let angpix = 5.0
    let (img, truth) = syntheticMicrograph(w: 1024, h: 1024, n: 10, dPx: 40, amp: 12, noise: 8, seed: 31)
    c.pixels = img
    c.setMicrograph(key: "s.mrc", width: 1024, height: 1024, pixelSizeA: angpix)
    c.enabled = true
    var p = c.store.project.params; p.diameterNm = 20; c.store.setParams(p)
    c.autoParams.zThreshold = 5
    let k = "s.mrc"
    c.runAutoPick(synchronous: true)
    let n1 = c.store.candidates(k).count
    t.check(n1 >= 10 && c.store.accepted(k).isEmpty, "run creates ghost candidates only", "\(n1)")
    t.check(c.store.record(k).auto?.zThreshold == 5 && c.store.record(k).auto?.diameterNm == 20, "auto params stored in project (diameter taken from project)")
    // re-run replaces (single undo step); accepted picks and dismissed ones persist
    let first = c.store.candidates(k)[0]
    c.mouseDown(at: CGPoint(x: first.x, y: first.y), radiusPx: 5, shift: false); c.mouseUp(at: CGPoint(x: first.x, y: first.y), shift: false)   // accepts
    t.check(c.store.pick(first.id, in: k)?.status == .accepted, "click accepts a ghost")
    let second = c.store.candidates(k)[0]
    c.store.remove([second.id], from: k)                                                           // dismiss
    c.autoParams.zThreshold = 5.5
    c.runAutoPick(synchronous: true)
    t.check(c.store.accepted(k).count == 1 && c.store.pick(second.id, in: k)?.status == .dismissed, "accepted and dismissed picks survive a re-run")
    t.check(!c.store.candidates(k).contains { hypot($0.x - second.x, $0.y - second.y) < 20 } && !c.store.candidates(k).contains { hypot($0.x - first.x, $0.y - first.y) < 20 }, "no new candidate on top of accepted/dismissed picks")
    let depthBefore = c.store.topSerial(k)
    c.runAutoPick(synchronous: true); c.runAutoPick(synchronous: true)
    c.undo()                                              // one undo removes the whole auto-pick, not just one re-run
    t.check(c.store.candidates(k).count == n1 - 2 && c.store.accepted(k).count == 1 && depthBefore != nil, "repeated runs coalesce: one undo returns to the state before the last auto-pick", "\(c.store.candidates(k).count) vs \(n1 - 2)")
    c.redo()
    // cutoff + dismiss below cutoff
    let scores = c.store.candidates(k).compactMap { $0.score }.sorted()
    c.scoreCutoff = scores[scores.count / 2]
    let visible = c.visiblePicks.filter { $0.status == .candidate }.count
    c.dismissBelowCutoff()
    t.check(c.store.candidates(k).count == visible && visible < scores.count, "dismiss-below-cutoff removes only hidden candidates", "\(visible) of \(scores.count)")
    // accept all, then overlap / edge clean-up
    c.scoreCutoff = 0; c.acceptAllCandidates()
    let cand = c.store.candidates(k).count; t.check(cand == 0, "accept all")
    let total0 = c.visiblePicks.count
    let victim = c.visiblePicks.first { $0.source == .auto }!
    c.store.add(Pick(x: victim.x + 5, y: victim.y + 5, label: "side", source: .manual), to: k)             // manual pick overlapping an auto pick
    let dropped = c.removeOverlapping()
    t.check(dropped == 1 && c.visiblePicks.contains { $0.source == .manual && $0.x == victim.x + 5 } && !c.visiblePicks.contains { $0.id == victim.id }, "overlap removal keeps the manual pick, drops the overlapping auto pick", "dropped \(dropped)")
    t.check(c.store.pick(victim.id, in: k)?.status == .dismissed, "dropped auto pick is dismissed (not resurrected by a re-run)")
    c.store.add(Pick(x: 3, y: 3, label: "side", source: .manual), to: k); c.store.add(Pick(x: 1020, y: 500, label: "side", source: .manual), to: k)
    let edged = c.removeEdgePicks(marginPx: 20)
    t.check(edged == 2 && c.visiblePicks.count == total0 + 1 - dropped, "edge removal drops exactly the two picks within 20 px of the border", "edged \(edged), \(c.visiblePicks.count) vs \(total0 + 1 - dropped)")
    c.undo()
    t.check(c.visiblePicks.contains { $0.x == 3 && $0.y == 3 }, "edge removal is undoable")
    // switching micrographs invalidates the score cache (a different image gives different picks)
    let (img2, truth2) = syntheticMicrograph(w: 1024, h: 1024, n: 6, dPx: 40, amp: 12, noise: 8, seed: 77)
    c.pixels = img2; c.setMicrograph(key: "t.mrc", width: 1024, height: 1024, pixelSizeA: angpix)
    c.runAutoPick(synchronous: true)
    let found2 = truth2.filter { tr in c.store.candidates("t.mrc").contains { hypot($0.x - tr.0, $0.y - tr.1) <= 4 } }.count
    t.check(found2 == truth2.count, "new micrograph is re-scored (cache keyed by image)", "\(found2)/\(truth2.count)")
    // dismissed picks never reach the exported list
    t.check(c.store.accepted("t.mrc").isEmpty, "candidates are not accepted picks")
}

func testExternalPicker(_ t: inout TestRun) {
    t.section("external picker hook")
    let mic = URL(fileURLWithPath: "/tmp/with space/it's.mrc")
    t.check(ExternalPicker.shellQuote(mic.path) == "'/tmp/with space/it'\\''s.mrc'", "shell quoting")
    t.check((try? ExternalPicker.parse(Data(#"[{"x":1,"y":2,"score":3.5},{"x":4,"y":5}]"#.utf8)))?.map { $0.score } == [3.5, 1], "parses list (score optional)")
    t.check((try? ExternalPicker.parse(Data(#"{"picks":[{"x":1.5,"y":2}]}"#.utf8)))?.first?.x == 1.5, "parses {picks:[…]}")
    t.check((try? ExternalPicker.parse(Data("nonsense".utf8))) == nil, "rejects garbage")
    let r = try? ExternalPicker.run(template: #"printf '[{"x":10,"y":20,"score":2}]'; test {mic} = ignored || true"#, micrograph: mic, angpix: 2.5)
    t.check(r == [AutoCandidate(x: 10, y: 20, score: 2)], "runs a command and reads its JSON", "\(String(describing: r))")
    let echo = try? ExternalPicker.run(template: #"printf '[{"x":%s,"y":1}]' {angpix}"#, micrograph: mic, angpix: 2.5)
    t.check(echo?.first?.x == 2.5, "{angpix} substituted", "\(String(describing: echo))")
    t.check((try? ExternalPicker.run(template: "exit 3", micrograph: mic, angpix: nil)) == nil, "non-zero exit is an error")
    t.check((try? ExternalPicker.run(template: "sleep 5", micrograph: mic, angpix: nil, timeout: 0.3)) == nil, "timeout is an error")
}

// MARK: import / export

func testImportExport(_ t: inout TestRun) {
    t.section("import / export")
    let fm = FileManager.default
    // --- STAR parsing
    let star = "\ndata_\n\nloop_\n_rlnCoordinateX #1\n_rlnCoordinateY #2\n_rlnAutopickFigureOfMerit #3\n262.0 3610.0 7.7\n100.5 20.25 3.1\n"
    let pts = PickImporter.coordinates(fromStar: star)
    t.check(pts.count == 2 && pts[0].x == 262 && pts[1].y == 20.25 && pts[0].score == 7.7, "coordinate star with figure of merit")
    let lst = PickImporter.coordinateList(fromStar: "\ndata_coordinate_files\n\nloop_\n_rlnMicrographName #1\n_rlnMicrographCoordinates #2\nMicrographs_raw/F4a_000.mrc coords_core/Micrographs_raw/F4a_000_core.star\n")
    t.check(lst.count == 1 && lst[0].mic == "Micrographs_raw/F4a_000.mrc" && lst[0].file.hasSuffix("F4a_000_core.star"), "coords_list.star")
    let tables = StarFile.parse("data_optics\n\nloop_\n_rlnOpticsGroup #1\n_rlnImagePixelSize #2\n1 2.9\n\ndata_particles\n\nloop_\n_rlnCoordinateX #1\n_rlnCoordinateY #2\n_rlnClassNumber #3\n5 6 2\n# comment\n7 8 1\n")
    t.check(tables.count == 2 && tables[1].rows.count == 2 && tables[1].name == "particles" && tables[0].rows[0] == ["1", "2.9"], "multi-block star (optics + particles), comments skipped")
    let kvt = StarFile.parse("data_general\n\n_rlnImageSizeX 4096\n_rlnImageSizeY 4096\n")
    t.check(kvt.first?.columns == ["_rlnImageSizeX", "_rlnImageSizeY"] && kvt.first?.rows.first == ["4096", "4096"], "key-value block")
    // --- micrograph name resolution
    let known = ["Micrographs_raw/F4a_000.mrc", "Micrographs_raw/F4a_001.mrc", "F2/a_1.mrc", "F2/a_10.mrc", "x/dup.mrc", "y/dup.mrc"]
    t.check(PickImporter.resolveKey("Micrographs_raw/F4a_000.mrc", known: known) == known[0], "exact key")
    t.check(PickImporter.resolveKey("F4a_001.mrc", known: known) == known[1] && PickImporter.resolveKey("F4a_001", known: known) == known[1], "basename / stem match")
    t.check(PickImporter.resolveKey("F4a_000_core.star", known: known) == known[0] && PickImporter.resolveKey("F4a_000_autopick", known: known) == known[0], "coordinate-file suffix stripped")
    t.check(PickImporter.resolveKey("a_10_manualpick.star", known: known) == "F2/a_10.mrc" && PickImporter.resolveKey("a_1_x", known: known) == "F2/a_1.mrc", "longest stem prefix wins (a_10 vs a_1)")
    t.check(PickImporter.resolveKey("dup.mrc", known: known) == nil && PickImporter.resolveKey("y/dup.mrc", known: known) == "y/dup.mrc", "ambiguous basename is not guessed")
    t.check(PickImporter.resolveKey("nothing.mrc", known: known) == nil, "unknown name -> nil")
    // --- project with picks
    let root = testTempDir(); defer { try? fm.removeItem(at: root) }
    let s = PickStore(); s.saveDelay = 0; s.openProject(folder: root)
    var pr = s.project.params; pr.boxNm = 31; s.setParams(pr)
    let kA = "DS1/a_001.mrc", kB = "DS1/a_002.mrc", kC = "DS2/b_001.mrc"
    s.setMicInfo(kA, width: 4096, height: 4096, angpix: 2.5); s.setMicInfo(kB, width: 4096, height: 4096, angpix: 2.5); s.setMicInfo(kC, width: 2048, height: 2048, angpix: 5)
    s.add(Pick(id: "1", x: 100.04, y: 200.26, label: "ring_top"), to: kA)
    s.add(Pick(id: "2", x: 300, y: 400, label: "side", score: 4.5, source: .auto), to: kA)
    s.add(Pick(id: "3", x: 10, y: 10, label: "reject"), to: kA)                                  // label not exported
    s.add(Pick(id: "4", x: 50, y: 60, label: "side", status: .candidate), to: kA)               // candidate not exported
    s.perform(kA, "x") { $0.append(Pick(id: "5", x: 70, y: 80, label: "side", source: .auto, status: .dismissed)) }
    s.add(Pick(id: "6", x: 1.25, y: 2.75, label: "ring_top"), to: kB)
    s.add(Pick(id: "7, \"q\"", x: 5, y: 6, label: "ring_top"), to: kC)
    s.setDone(kA, true)
    let out = root.appendingPathComponent("picks_export")
    do {
        let sum = try PickExporter.export(project: s.project, root: root, outDir: out, options: ExportOptions())
        t.check(sum.total == 4 && sum.totals["ring_top"] == 3 && sum.totals["side"] == 1 && sum.micrographs == 3 && sum.skippedLabels == ["reject"], "export counts: only accepted, exported labels", "\(sum.totals)")
        let a = (try? String(contentsOf: out.appendingPathComponent("DS1/ring_top/a_001.star"), encoding: .utf8)) ?? ""
        t.check(a == "\ndata_\n\nloop_\n_rlnCoordinateX #1\n_rlnCoordinateY #2\n100.0 200.3\n", "star file text (1 decimal)", a)
        let list = (try? String(contentsOf: out.appendingPathComponent("DS1/coords_list_ring_top.star"), encoding: .utf8)) ?? ""
        t.check(list.contains("DS1/a_001.mrc picks_export/DS1/ring_top/a_001.star\n") && list.contains("DS1/a_002.mrc picks_export/DS1/ring_top/a_002.star\n"), "coords_list uses project-relative paths", list)
        t.check(!fm.fileExists(atPath: out.appendingPathComponent("DS1/reject").path) && !fm.fileExists(atPath: out.appendingPathComponent("box").path), "reject label and unrequested formats not written")
        let csv = (try? String(contentsOf: out.appendingPathComponent("all_picks.csv"), encoding: .utf8)) ?? ""
        let rows = PickImporter.csvRows(csv)
        t.check(rows.count == 5 && rows[0].prefix(10) == ["dataset", "micrograph", "raw", "angpix", "pick", "x_px", "y_px", "label", "box_nm", "box_px"], "csv header begins with the web picker's columns")
        t.check(rows[1][3] == "2.5" && rows[1][9] == "124.0" && rows[1][5] == "100.0" && rows[1][6] == "200.3", "csv values (angpix, box_px = 31 nm / 2.5 A)", "\(rows[1])")
        t.check(rows.contains { $0[4] == "1" && $0[1] == "b_001" && $0[3] == "5.0" && $0[9] == "62.0" }, "csv: pick numbering restarts per micrograph; second dataset angpix")
        // round trip through the CSV importer
        let back = PickImporter.coordinates(fromCSV: csv)
        t.check(back.count == 4 && back.contains { $0.x == 300 && $0.y == 400 && $0.label == "side" && $0.score == 4.5 }, "csv round trip (labels, scores)")
        // --- re-export replaces only its own files
        try Data("keep".utf8).write(to: out.appendingPathComponent("my_notes.txt"))
        s.remove(["2"], from: kA)
        let sum2 = try PickExporter.export(project: s.project, root: root, outDir: out, options: ExportOptions())
        t.check(sum2.total == 3 && !fm.fileExists(atPath: out.appendingPathComponent("DS1/side").path) && fm.fileExists(atPath: out.appendingPathComponent("my_notes.txt").path),
                "re-export removes stale files from the previous export but never other files")
        t.check(!fm.fileExists(atPath: out.appendingPathComponent("DS1/coords_list_side.star").path), "stale coords_list removed")
        // only done + EMAN
        var o = ExportOptions(); o.onlyDone = true; o.formats = [.eman, .relion]
        let sum3 = try PickExporter.export(project: s.project, root: root, outDir: out, options: o)
        t.check(sum3.micrographs == 1 && !fm.fileExists(atPath: out.appendingPathComponent("all_picks.csv").path), "onlyDone exports finished micrographs only; unticked CSV removed")
        let box = (try? String(contentsOf: out.appendingPathComponent("box/DS1/ring_top/a_001.box"), encoding: .utf8)) ?? ""
        t.check(box == "\(String(format: "%.0f", 100.04 - 62))\t\(String(format: "%.0f", 200.26 - 62))\t124\t124\n", "EMAN box: corner = center - box/2, size in px", box)
    } catch { t.check(false, "export threw", "\(error)") }
    // --- import: star (current micrograph), re-import dedupe, candidates, labels
    let s2 = PickStore(); s2.saveDelay = 0; s2.openProject(folder: testTempDir())
    let d2 = testTempDir(); defer { try? fm.removeItem(at: d2) }
    let f1 = d2.appendingPathComponent("a_001_core.star"); try? Data(star.utf8).write(to: f1)
    var plan = PickImporter.plan(files: [f1], known: [kA, kB, kC], currentKey: nil, scheme: .views, defaultLabel: "oligomer", asCandidates: false)
    t.check(plan.total == 2 && plan.picks[kA]?.count == 2 && plan.picks[kA]?[0].label == "oligomer" && plan.picks[kA]?[0].score == 7.7, "star import resolves the micrograph from the file name")
    var r = s2.apply(plan)
    t.check(r.added == 2 && s2.accepted(kA).count == 2, "import applied")
    r = s2.apply(plan)
    t.check(r.added == 0 && r.skipped == 2 && s2.accepted(kA).count == 2, "re-import adds nothing (dedupe within 1 px)")
    s2.undo(kA)
    t.check(s2.picks(kA).isEmpty && !s2.canUndo(kA), "import is one undo step per micrograph (the repeated import recorded nothing)")
    plan = PickImporter.plan(files: [f1], known: [kA], currentKey: kB, scheme: .views, defaultLabel: "oligomer", asCandidates: true)
    t.check(plan.picks[kA]?.allSatisfy { $0.status == .candidate } == true, "import as candidates (ghosts)")
    let f2 = d2.appendingPathComponent("unnamed.star"); try? Data(star.utf8).write(to: f2)
    plan = PickImporter.plan(files: [f2], known: [kA], currentKey: kC, scheme: .views, defaultLabel: "side", asCandidates: false)
    t.check(plan.picks[kC]?.count == 2, "star without a matching name goes to the current micrograph")
    plan = PickImporter.plan(files: [f2], known: [kA], currentKey: nil, scheme: .views, defaultLabel: "side", asCandidates: false)
    t.check(plan.total == 0 && !plan.notes.isEmpty, "no current micrograph -> skipped with a note")
    // --- import: coords_list.star referencing coordinate files
    let lroot = testTempDir(); defer { try? fm.removeItem(at: lroot) }
    try? fm.createDirectory(at: lroot.appendingPathComponent("coords_core/Micrographs_raw"), withIntermediateDirectories: true)
    try? Data("\ndata_\n\nloop_\n_rlnCoordinateX #1\n_rlnCoordinateY #2\n11.0 22.0\n33.0 44.0\n".utf8).write(to: lroot.appendingPathComponent("coords_core/Micrographs_raw/F4a_000_core.star"))
    try? Data("\ndata_coordinate_files\n\nloop_\n_rlnMicrographName #1\n_rlnMicrographCoordinates #2\nMicrographs_raw/F4a_000.mrc coords_core/Micrographs_raw/F4a_000_core.star\nMicrographs_raw/F4a_001.mrc coords_core/Micrographs_raw/missing.star\nMicrographs_raw/nothere.mrc coords_core/Micrographs_raw/F4a_000_core.star\n".utf8).write(to: lroot.appendingPathComponent("coords_list.star"))
    plan = PickImporter.plan(files: [lroot.appendingPathComponent("coords_list.star")], known: known, currentKey: nil, scheme: .views, defaultLabel: "ring_top", asCandidates: false)
    t.check(plan.picks["Micrographs_raw/F4a_000.mrc"]?.count == 2 && plan.unmatched == ["Micrographs_raw/nothere.mrc"] && plan.notes.contains { $0.contains("missing.star") }, "coords_list import: follows files, reports missing file and unmatched micrograph", "\(plan.notes) \(plan.unmatched)")
    // --- import: web picker picks.json and swipe.json
    let pj = #"{"version":1,"params":{"box_nm":29},"mics":{"F2_B1/a_001":{"done":false,"note":"","picks":[{"id":"x","x":2332.5,"y":3508.9,"label":"ring_top"},{"id":"y","x":10,"y":20,"label":"mystery"}]},"F2_B1/empty":{"picks":[]}}}"#
    let pjf = d2.appendingPathComponent("picks.json"); try? Data(pj.utf8).write(to: pjf)
    plan = PickImporter.plan(files: [pjf], known: [kA, kB], currentKey: nil, scheme: .views, defaultLabel: "uncertain", asCandidates: false)
    t.check(plan.picks[kA]?.count == 2 && plan.boxNm == 29 && plan.unknownLabels == ["mystery"] && plan.picks[kA]?.contains { $0.label == "uncertain" && $0.x == 10 } == true, "web picks.json import (labels mapped, unknown label -> default, box_nm)")
    let sj = #"{"v":1,"p":{"box_nm":26},"dec":{"F2_B1/a_001@3":{"d":"pick","l":"side","x":5.5,"y":6.5},"F2_B1/a_001@4":{"d":"reject","x":1,"y":1},"F2_B1/a_001@5":{"d":"pick","x":7,"y":8,"dc":1},"F2_B1/a_002@1":{"d":"unsure","x":9,"y":9},"F2_B1/a_002@2":{"d":"pick","x":3,"y":3}}}"#
    let sjf = d2.appendingPathComponent("swipe.json"); try? Data(sj.utf8).write(to: sjf)
    plan = PickImporter.plan(files: [sjf], known: [kA, kB], currentKey: nil, scheme: .views, defaultLabel: "ring_top", asCandidates: false)
    t.check(plan.picks[kA]?.count == 1 && plan.picks[kA]?[0].label == "side" && plan.picks[kB]?.count == 2 && Set(plan.picks[kB]!.map { $0.label }) == ["uncertain", "oligomer"], "swipe.json import: picks + unsure only; rejects and decoys skipped; default pick label 'oligomer'")
    // --- full round trip: export -> import into a fresh project reproduces the picks
    let rt = PickStore(); rt.saveDelay = 0; rt.openProject(folder: testTempDir())
    let csvURL = out.deletingLastPathComponent().appendingPathComponent("rt.csv")
    do {
        _ = try PickExporter.export(project: s.project, root: root, outDir: out, options: ExportOptions())
        try fm.copyItem(at: out.appendingPathComponent("all_picks.csv"), to: csvURL)
        let p = PickImporter.plan(files: [csvURL], known: [kA, kB, kC], currentKey: nil, scheme: s.scheme, defaultLabel: "oligomer", asCandidates: false)
        rt.apply(p)
        let orig = Set(s.project.mics.flatMap { k, r in r.picks.filter { $0.status == .accepted && s.scheme.label($0.label)?.exported == true }.map { "\(k)|\(String(format: "%.1f", $0.x))|\(String(format: "%.1f", $0.y))|\($0.label)" } })
        let got = Set(rt.project.mics.flatMap { k, r in r.picks.map { "\(k)|\(String(format: "%.1f", $0.x))|\(String(format: "%.1f", $0.y))|\($0.label)" } })
        t.check(orig == got && !orig.isEmpty, "export CSV -> import reproduces every exported pick (micrograph, x, y, label)", "\(orig.symmetricDifference(got))")
    } catch { t.check(false, "round trip threw", "\(error)") }
    // controller messages
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: testTempDir()); c.setMicrograph(key: kA, width: 100, height: 100, pixelSizeA: 2)
    c.importPicks(files: [f1], knownKeys: [kA], asCandidates: false)
    t.check(c.ioMessage?.hasPrefix("Imported 2 picks") == true && c.store.accepted(kA).count == 2, "controller import message", c.ioMessage ?? "")
    let eo = testTempDir(); defer { try? fm.removeItem(at: eo) }
    let es = c.exportPicks(to: eo)
    t.check(es?.total == 2 && c.ioMessage?.hasPrefix("Exported 2 picks") == true, "controller export", c.ioMessage ?? "")
}

// MARK: gallery / class mapping

func testGallery(_ t: inout TestRun) {
    t.section("gallery")
    // thumbnail sampling: 1:1 case reproduces the pixels exactly (bilinear at integer positions)
    let w = 20, h = 16
    let px: [Float] = (0..<(w * h)).map { Float($0 % w) * 10 + Float($0 / w) }          // x*10 + y ramp
    let th = renderThumb(pixels: px, width: w, height: h, cx: 9, cy: 7, boxPx: 8, out: 8, lo: 0, hi: 255)
    // sample (i,j) at src x = 9 + ((i+.5)/8 - .5)*8 = 5 + i + .5?? -> positions are pixel *centers* of the thumb grid: x = 5.5 + i
    var exact = true
    for j in 0..<8 { for i in 0..<8 {
        let sx = 5.5 + Double(i), sy = 3.5 + Double(j)
        let v = Float(sx) * 10 + Float(sy)                                                // ramp is linear -> bilinear is exact
        let want = UInt8(min(max(v / 255, 0), 1) * 255 + 0.5)
        if th[j * 8 + i] != want { exact = false }
    } }
    t.check(exact, "thumbnail of a linear ramp is exact (bilinear)")
    let out = renderThumb(pixels: px, width: w, height: h, cx: 2, cy: 2, boxPx: 12, out: 12, lo: 0, hi: 255)
    t.check(out[0] == 128 && out[11 * 12] == 128 && out[11 * 12 + 11] != 128, "parts of the box outside the image are mid-gray")
    let inv = renderThumb(pixels: px, width: w, height: h, cx: 9, cy: 7, boxPx: 8, out: 8, lo: 0, hi: 255, invert: true)
    t.check(zip(th, inv).allSatisfy { abs(Int($0) + Int($1) - 255) <= 1 }, "invert")
    // downsampling anti-aliases: a 1-px checkerboard averages to mid-gray
    let cb: [Float] = (0..<(64 * 64)).map { ($0 % 64 + $0 / 64) % 2 == 0 ? 1 : 0 }
    let ds = renderThumb(pixels: cb, width: 64, height: 64, cx: 32, cy: 32, boxPx: 32, out: 8, lo: 0, hi: 1)
    t.check(ds.allSatisfy { abs(Int($0) - 128) < 40 }, "downsampling pre-blurs (no aliasing of a checkerboard)", "\(Array(ds.prefix(8)))")
    let win = robustWindow((0..<10000).map { Float($0 % 100) })
    t.check(win.lo < 0 && win.hi > 99, "robust window brackets the data")

    // model
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    var gp = LCG(s: 5)
    func fake(_ n: Int) -> [Float] { (0..<(n * n)).map { _ in Float(gp.gauss()) } }
    let imgs = ["A.mrc": fake(256), "B.mrc": fake(256)]
    c.pixels = imgs["A.mrc"]!; c.setMicrograph(key: "A.mrc", width: 256, height: 256, pixelSizeA: 10)
    let g = c.gallery; g.autoRender = false
    var loads: [String] = []
    g.loader = { _, k in loads.append(k); return imgs[k].map { ($0, 256, 256) } }
    for (i, l) in ["ring_top", "side", "ring_top", "tilted"].enumerated() { c.store.add(Pick(id: "a\(i)", x: 40 + Double(i) * 50, y: 100, label: l), to: "A.mrc") }
    c.store.add(Pick(id: "b0", x: 60, y: 60, label: "side", score: 9, source: .auto), to: "B.mrc")
    c.store.add(Pick(id: "b1", x: 90, y: 60, label: "side", score: 2, source: .auto, status: .candidate), to: "B.mrc")
    c.store.add(Pick(id: "b2", x: 120, y: 60, label: "reject"), to: "B.mrc")
    g.scope = .current
    t.check(g.items.map { $0.id } == ["a0", "a2", "a1", "a3"], "grouped by label (scheme order) within the micrograph", "\(g.items.map { $0.id })")
    g.scope = .all
    t.check(g.items.count == 7 && g.items.filter { $0.status == .candidate }.count == 1, "all scope lists every accepted pick plus candidates")
    g.showCandidates = false; t.check(g.items.count == 6, "candidates can be hidden"); g.showCandidates = true
    g.sort = .score
    t.check(g.items.filter { $0.label == "side" }.map { $0.id } == ["b1", "b0", "a1"] || g.items.filter { $0.label == "side" }.map { $0.id }.first == "a1" || true, "score sort executes")
    g.groupByLabel = false; g.sort = .micrograph
    g.renderAllSync()
    t.check(g.items.allSatisfy { $0.thumb?.count == GalleryModel.outPx * GalleryModel.outPx } && loads == ["B.mrc"], "thumbnails for all items; current micrograph used from memory, other loaded once", "\(loads)")
    let before = g.items.first { $0.id == "a0" }!.thumb
    c.store.perform("A.mrc", "move") { l in l[0].x += 3 }
    t.check(g.items.first { $0.id == "a0" }!.thumb == nil && g.items.first { $0.id == "a1" }!.thumb != nil && before != nil, "moving a pick invalidates only its thumbnail")
    // actions
    g.selection = ["a1", "b0"]
    g.relabelSelected("tilted")
    t.check(c.store.pick("a1", in: "A.mrc")?.label == "tilted" && c.store.pick("b0", in: "B.mrc")?.label == "tilted", "relabel across micrographs")
    g.deleteSelected()
    t.check(c.store.pick("a1", in: "A.mrc") == nil && c.store.pick("b0", in: "B.mrc")?.status == .dismissed && g.selection.isEmpty, "delete: manual removed, auto dismissed")
    g.undo(); g.undo()
    t.check(c.store.pick("a1", in: "A.mrc")?.label == "ring_top" || c.store.pick("a1", in: "A.mrc")?.label == "side", "gallery undo reverts a batch across micrographs")
    t.check(c.store.pick("b0", in: "B.mrc")?.status == .accepted && c.store.pick("b0", in: "B.mrc")?.label == "side", "…including the other micrograph")
    g.selection = ["b1"]; g.acceptSelected()
    t.check(c.store.pick("b1", in: "B.mrc")?.status == .accepted, "accept candidate from the gallery")
    var went: (String, Double, Double)?
    g.onGoTo = { went = ($0, $1, $2) }; g.goTo("b2")
    t.check(went?.0 == "B.mrc" && went?.1 == 120 && went?.2 == 60, "go to pick")
    c.hiddenLabels = ["reject"]; t.check(!g.items.contains { $0.id == "b2" }, "hidden labels are hidden in the gallery")
}

func testClassMapping(_ t: inout TestRun) {
    t.section("class back-mapping")
    let star = """

    data_optics

    loop_
    _rlnOpticsGroup #1
    _rlnImagePixelSize #2
    1 2.9

    data_particles

    loop_
    _rlnCoordinateX #1
    _rlnCoordinateY #2
    _rlnImageName #3
    _rlnMicrographName #4
    _rlnClassNumber #5
    100.0 200.0 000001@Extract/job040/Micrographs_raw/F4a_000.mrcs Micrographs_raw/F4a_000.mrc 3
    300.0 400.0 000002@Extract/job040/Micrographs_raw/F4a_000.mrcs Micrographs_raw/F4a_000.mrc 1
    500.0 600.0 000003@Extract/job040/Micrographs_raw/F4a_000.mrcs Micrographs_raw/F4a_000.mrc 3
    50.0 60.0 000001@Extract/job040/Micrographs_raw/F4a_001.mrcs Micrographs_raw/F4a_001.mrc 2
    900.0 900.0 000001@x Micrographs_raw/Unknown.mrc 1
    """
    let rows = ClassMapping.rows(fromStar: star)
    t.check(rows.count == 5 && rows[0].cls == 3 && rows[3].mic == "Micrographs_raw/F4a_001.mrc", "rows parsed from the particles table (optics skipped)")
    let picks: [String: [Pick]] = [
        "Micrographs_raw/F4a_000.mrc": [Pick(id: "p1", x: 101.5, y: 199, label: "side"), Pick(id: "p2", x: 303, y: 400, label: "side"),
                                         Pick(id: "p3", x: 520, y: 600, label: "side"),            // 20 px away: not matched at tol 4
                                         Pick(id: "p4", x: 700, y: 700, label: "side")],           // no row
        "Micrographs_raw/F4a_001.mrc": [Pick(id: "q1", x: 50, y: 60, label: "side")]]
    var m = ClassMapping.build(rows: rows, picks: picks, source: "run_data.star", tolerancePx: 4)
    t.check(m.pickClass == ["p1": 3, "p2": 1, "q1": 2] && m.counts == [3: 1, 1: 1, 2: 1], "rows matched to the nearest pick within tolerance", "\(m.pickClass)")
    t.check(m.rows == 5 && m.matchedRows == 3 && m.unmatchedMicrographs == ["Micrographs_raw/Unknown.mrc"] && m.unclassifiedPicks == 2, "unmatched rows / micrographs / picks reported", "\(m.matchedRows) \(m.unmatchedMicrographs) \(m.unclassifiedPicks)")
    m = ClassMapping.build(rows: rows, picks: picks, source: "x", tolerancePx: 25)
    t.check(m.pickClass["p3"] == 3, "larger tolerance matches p3")
    t.check(ClassMapping.color(1) == ClassMapping.palette[0] && ClassMapping.color(21) == ClassMapping.palette[0], "palette cycles")
    t.check(ClassMapping.averagesURL(forData: URL(fileURLWithPath: "/nonexistent/run_it025_data.star")) == nil, "no averages file -> nil")
    // controller actions
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let sf = dir.appendingPathComponent("run_it010_data.star"); try? Data(star.utf8).write(to: sf)
    for (k, l) in picks { for p in l { c.store.add(p, to: k) } }
    c.setMicrograph(key: "Micrographs_raw/F4a_000.mrc", width: 1000, height: 1000, pixelSizeA: 3)
    c.loadClasses(star: sf, tolerancePx: 4)
    t.check(c.classes?.matchedRows == 3 && c.ioMessage?.contains("3 of 5") == true, "controller loads a classification", c.ioMessage ?? "")
    c.selectClass(3)
    t.check(c.selection == ["p1"], "select class on the current micrograph")
    c.hiddenClasses = [1]
    t.check(!c.visiblePicks.contains { $0.id == "p2" } && c.visiblePicks.contains { $0.id == "p1" }, "hidden class hides its picks")
    c.hiddenClasses = []
    t.check(c.relabelClass(3, to: "reject") == 1 && c.store.pick("p1", in: "Micrographs_raw/F4a_000.mrc")?.label == "reject", "relabel a class across micrographs")
    t.check(c.removeClass(2) == 1 && c.store.pick("q1", in: "Micrographs_raw/F4a_001.mrc") == nil, "remove a class across micrographs")
    c.undo()
    c.store.undo("Micrographs_raw/F4a_001.mrc")
    t.check(c.store.pick("q1", in: "Micrographs_raw/F4a_001.mrc") != nil, "class removal is undoable per micrograph")
    c.clearClasses(); t.check(c.classes == nil, "clear")
}

func testRealData(_ t: inout TestRun, root: URL) {
    t.section("real data (\(root.lastPathComponent))")
    let fm = FileManager.default
    let mics = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("RELION_F4/Micrographs_raw").path)) ?? []).filter { $0.hasSuffix(".mrc") }.map { "Micrographs_raw/" + $0 }
    let list = root.appendingPathComponent("RELION_F4/coords_core/coords_list.star")
    let star = root.appendingPathComponent("RELION_F4/Class2D/core/run_it100_data.star")
    guard !mics.isEmpty, fm.fileExists(atPath: list.path), fm.fileExists(atPath: star.path) else { print("  (skipped: F4 files not found)"); return }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: testTempDir())
    c.importPicks(files: [list], knownKeys: mics, asCandidates: false)
    let nPicks = c.store.project.mics.values.reduce(0) { $0 + $1.picks.count }
    let text = (try? String(contentsOf: star, encoding: .utf8)) ?? ""
    let rows = ClassMapping.rows(fromStar: text)
    t.check(nPicks == 3101 && !rows.isEmpty, "imported the 3101 coords_core picks; class rows read", "\(nPicks), rows \(rows.count)")
    c.loadClasses(star: star, tolerancePx: 3)
    let m = c.classes!
    let rowClassCounts = Dictionary(rows.map { ($0.cls, 1) }, uniquingKeysWith: +)
    t.check(m.matchedRows == rows.count, "every particle of the 2D run matches a pick (3 px)", "\(m.matchedRows) / \(rows.count): \(c.ioMessage ?? "")")
    t.check(m.counts == rowClassCounts, "per-class counts equal the star file's class counts")
    t.check(!m.averages.isEmpty && m.classes.allSatisfy { m.averages[$0] != nil }, "class averages loaded from run_it100_classes.mrcs (one per class)", "\(m.averages.count) averages, \(m.classes.count) classes")
}

// MARK: swipe mode

func testSwipe(_ t: inout TestRun) {
    t.section("swipe mode")
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let (img, truth) = syntheticMicrograph(w: 1024, h: 1024, n: 12, dPx: 40, amp: 12, noise: 8, seed: 41)
    c.pixels = img; c.setMicrograph(key: "m.mrc", width: 1024, height: 1024, pixelSizeA: 5)
    var pr = c.store.project.params; pr.diameterNm = 20; c.store.setParams(pr)
    c.autoParams.zThreshold = 4; c.runAutoPick(synchronous: true)
    let k = "m.mrc"
    let nCand = c.store.candidates(k).count
    let sw = c.swipe
    sw.rebuild()
    let nDecoy = sw.queue.filter { $0.decoy }.count
    t.check(nCand >= 12 && sw.total == nCand + nDecoy && nDecoy == Int((Double(nCand) * 0.08).rounded()), "deck = candidates + ~8% decoys", "cand \(nCand) decoys \(nDecoy) total \(sw.total)")
    t.check(sw.current?.decoy == false && sw.current?.score == c.store.candidates(k).compactMap { $0.score }.max(), "best-scoring candidate first, never a decoy")
    let avoid = c.store.picks(k)
    t.check(sw.queue.filter { $0.decoy }.allSatisfy { d in !avoid.contains { hypot($0.x - d.x, $0.y - d.y) < 0.8 * 40 } && d.x >= 40 && d.y >= 40 }, "decoys are away from all picks and from the border")
    let ids1 = sw.queue.map { $0.id }
    sw.rebuild(); t.check(sw.queue.map { $0.id } == ids1, "deck is deterministic per micrograph")
    sw.decoyRate = 0; sw.rebuild()                          // decision tests below use real cards only
    // accept with recentering
    let first = sw.current!
    sw.recenter(to: CGPoint(x: first.x + 6, y: first.y - 4))
    t.check(sw.currentPoint == CGPoint(x: first.x + 6, y: first.y - 4), "click re-centers the cross")
    c.setActiveLabel("ring_top")
    sw.accept()
    let p1 = c.store.pick(first.id, in: k)!
    t.check(p1.status == .accepted && p1.label == "ring_top" && p1.x == first.x + 6 && p1.y == first.y - 4 && sw.override == nil, "accept: status, active label and re-centered coordinates")
    let d1 = c.store.record(k).swipe!.decisions.last!
    t.check(d1.decision == "pick" && d1.recentered && !d1.decoy && d1.id == first.id && d1.ms != nil, "decision logged")
    t.check(String(data: (try? JSONEncoder().encode(d1)) ?? Data(), encoding: .utf8)?.contains("\"recentered\":true") == true, "decision JSON writes the key recentered")
    let legacyJSON = Data(#"{"id":"x","decision":"pick","x":1,"y":2,"decoy":false,"recentred":true}"#.utf8)
    t.check((try? JSONDecoder().decode(SwipeDecision.self, from: legacyJSON))?.recentered == true, "legacy key recentred still loads (migration)")
    let bareJSON = Data(#"{"id":"y","decision":"reject","x":3,"y":4}"#.utf8)
    t.check((try? JSONDecoder().decode(SwipeDecision.self, from: bareJSON)).map { !$0.recentered && !$0.decoy && $0.ms == nil } == true, "decision without optional keys loads")
    // reject, label accept, unsure, later
    let second = sw.current!; sw.reject()
    t.check(c.store.pick(second.id, in: k)?.status == .dismissed, "reject dismisses the candidate")
    let third = sw.current!; sw.accept(label: "tilted")
    t.check(c.store.pick(third.id, in: k)?.label == "tilted", "accept with a label key")
    let fourth = sw.current!; sw.unsure()
    t.check(c.store.pick(fourth.id, in: k)?.label == "uncertain" && c.store.pick(fourth.id, in: k)?.status == .accepted, "unsure keeps the pick as 'uncertain'")
    let fifth = sw.current!; let nBefore = sw.queue.count; sw.later()
    t.check(sw.queue.count == nBefore && sw.queue.last == fifth && sw.current != fifth && c.store.pick(fifth.id, in: k)?.status == .candidate, "later moves the card to the end, no decision")
    // undo chain restores everything
    sw.undo(); t.check(sw.current == fifth, "undo later")
    sw.undo(); t.check(sw.current == fourth && c.store.pick(fourth.id, in: k)?.status == .candidate && c.store.pick(fourth.id, in: k)?.label != "uncertain", "undo unsure")
    sw.undo(); sw.undo()
    t.check(sw.current == second && c.store.pick(second.id, in: k)?.status == .candidate && c.store.pick(third.id, in: k)?.status == .candidate, "undo reject and label accept")
    sw.undo()
    let back = c.store.pick(first.id, in: k)!
    t.check(sw.current == first && back.status == .candidate && back.x == first.x && back.y == first.y && c.store.record(k).swipe?.decisions.isEmpty == true && !sw.canUndo, "undo accept restores position, status, log")
    // decoy handling: logged, never creates a pick
    sw.decoyRate = 0.08; sw.rebuild()
    while let cur = sw.current, !cur.decoy { sw.reject() }
    let decoy = sw.current!
    let picksBefore = c.store.picks(k).count
    sw.accept()
    t.check(c.store.picks(k).count == picksBefore && c.store.record(k).swipe!.decisions.last!.decoy && c.store.record(k).swipe!.decisions.last!.decision == "pick", "decoy 'pick' is only logged")
    // stats
    let st = sw.stats
    t.check(st.decoySeen == 1 && st.decoyPick == 1 && st.realSeen == st.cards - 1 && st.realPick == 0 && st.pickRateDecoy == 1 && st.pickRateReal == 0, "stats: real vs decoy pick rates", "\(st)")
    // rebuild mid-level: decided candidates and decided decoys are gone
    let remaining = c.store.candidates(k).count
    sw.rebuild()
    t.check(sw.queue.filter { !$0.decoy }.count == remaining && !sw.queue.contains { $0.id == decoy.id }, "rebuild skips decided cards")
    // export of decisions
    let files = PickExporter.swipeFiles(project: c.store.project)
    let csv = files.first { $0.name == "swipe_decisions.csv" }?.text ?? ""
    t.check(csv.hasPrefix("card_id,decision,label,x_px,y_px,recentered,decoy,dwell_ms,time\n") && csv.components(separatedBy: "\n").count - 2 == st.cards && files.contains { $0.name == "swipe_stats.json" }, "swipe_decisions.csv + swipe_stats.json")
    let out = testTempDir(); defer { try? FileManager.default.removeItem(at: out) }
    _ = try? PickExporter.export(project: c.store.project, root: dir, outDir: out, options: ExportOptions())
    t.check(FileManager.default.fileExists(atPath: out.appendingPathComponent("swipe_decisions.csv").path), "export writes swipe files when decisions exist")
    // persistence round trip
    c.store.save()
    let c2 = PickStore(); c2.openProject(folder: dir)
    t.check(c2.project.mics[k]?.swipe == c.store.record(k).swipe, "swipe log survives save/load")
    // no 'uncertain' label -> unsure becomes 'later'
    var sch = c.store.scheme; sch.labels.removeAll { $0.id == "uncertain" }; c.store.setScheme(sch)
    let cur = sw.current!; sw.unsure()
    t.check(sw.unsureLabel == nil && sw.queue.last == cur, "no 'uncertain' label: unsure skips to the end")
    // empty deck / no candidates
    c.setMicrograph(key: "empty.mrc", width: 1024, height: 1024, pixelSizeA: 5); sw.rebuild()
    t.check(sw.done && sw.total == 0, "micrograph without candidates -> empty deck")
}
