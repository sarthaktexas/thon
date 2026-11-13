import Foundation
import CoreGraphics

/// The picking workflow: size range, box, steps and their skip rule, delete all, and the saved unpack state of stacks.
func testWorkflow(_ t: inout TestRun) {
    t.section("workflow: size range and box")
    let fm = FileManager.default

    // --- the ladder of sizes
    t.check(SizeRange.diameters(min: 20, max: 20).isEmpty && SizeRange.diameters(min: 20, max: 24).isEmpty, "one size, or two closer than 1.4x: no sweep")
    t.check(SizeRange.diameters(min: 10, max: 15) == [10, 15], "10 to 15 nm: two sizes", "\(SizeRange.diameters(min: 10, max: 15))")
    let l4 = SizeRange.diameters(min: 10, max: 40)
    t.check(l4.first == 10 && l4.last == 40 && l4.count == 4, "10 to 40 nm: four sizes", "\(l4)")
    var steps = true
    for (lo, hi) in [(10.0, 14.0), (10, 18.4), (10, 22.6), (10, 34), (5, 100), (3, 150), (12, 30), (8, 9.5)] {
        let d = SizeRange.diameters(min: lo, max: hi)
        if d.isEmpty { continue }
        if d.count > SizeRange.maxScales { steps = false }
        for (a, b) in zip(d, d.dropFirst()) where b / a < 1.39 || b / a > 2.2 { steps = false }
        if d.first != lo || d.last != hi || d != d.sorted() { steps = false }
    }
    t.check(steps, "ladder steps stay between 1.4x and 2.2x and end on the two ends")
    t.check(SizeRange.typical(min: 10, max: 40) == 20 && SizeRange.typical(min: 20, max: 20) == 20, "typical size = geometric mean")

    // --- parameters
    var pp = ProjectParams()
    t.check(!pp.hasSizeRange && pp.sizeRangeNm.min == 20 && pp.sizeRangeNm.max == 20 && !pp.isBoxCustom && abs(pp.boxRatio - ProjectParams.defaultBoxRatio) < 1e-9, "a new project has one size and an automatic box")
    pp.setSize(min: 10, max: 40)
    t.check(pp.hasSizeRange && pp.diameterNm == 20 && pp.boxNm == 29 && pp.sweepDiametersNm == l4 && pp.sweepBoxesNm.isEmpty, "range: diameter = geometric mean, box follows it, boxes blank", "\(pp.diameterNm) \(pp.boxNm)")
    pp.setSize(min: 16, max: 16)
    t.check(!pp.hasSizeRange && pp.sizeMinNm == nil && pp.diameterNm == 16 && pp.boxNm == 23.2 && pp.sweepDiametersNm.isEmpty, "equal ends: one size again, box follows (1.45 x 16)", "\(pp.boxNm)")
    pp.boxCustom = true; pp.boxNm = 40
    pp.setSize(min: 12, max: 30)
    t.check(pp.boxNm == 40 && pp.sweepBoxesNm == [40], "a typed-in box is left alone and used for every size")
    pp.setSize(min: 30, max: 12)
    t.check(pp.sizeMinNm == 12 && pp.sizeMaxNm == 30, "ends given the wrong way round are sorted")
    let pj = try? JSONDecoder().decode(ProjectParams.self, from: JSONEncoder().encode(pp))
    t.check(pj == pp, "size range and box mode survive saving")
    let old = try? JSONDecoder().decode(ProjectParams.self, from: Data("{\"boxNm\":30,\"diameterNm\":20}".utf8))
    t.check(old?.sizeMinNm == nil && old?.boxCustom == nil && old?.hasSizeRange == false && old?.boxNm == 30, "an older project without the new fields loads")

    // --- controller: range -> picker settings
    t.section("workflow: controller")
    let dir = testTempDir(); defer { try? fm.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let k = "m.mrc"
    c.setMicrograph(key: k, width: 1000, height: 800, pixelSizeA: 10)
    c.setSizeRange(min: 10, max: 40)
    t.check(c.autoParams.sweepDiametersNm == l4 && c.autoParams.sweepBoxesNm.isEmpty, "the range becomes the sizes the picker searches")
    c.setBox(custom: 35)
    t.check(c.store.project.params.isBoxCustom && c.store.project.params.boxNm == 35 && c.autoParams.sweepBoxesNm == [35], "a typed-in box goes to every size")
    c.setBox(custom: nil)
    t.check(!c.store.project.params.isBoxCustom && c.store.project.params.boxNm == 29 && c.autoParams.sweepBoxesNm.isEmpty, "Automatic returns the box to 1.45 x the diameter")
    c.sweepOn = true; c.sweepDiameterText = "12, 16"; c.applySweepText()
    t.check(c.autoParams.sweepDiametersNm == [12, 16], "exact sizes typed under More settings win over the range")
    c.sweepOn = false; c.applySweepText()
    t.check(c.autoParams.sweepDiametersNm == l4, "…and the range is back when they are off")
    c.setSizeRange(min: 20, max: 20)
    t.check(c.autoParams.sweepDiametersNm.isEmpty, "one size: no sweep")

    // --- steps and the skip rule
    var f = FlowMarks()
    t.check(f.canSkip(.auto) && !f.canSkip(.review) && !f.canSkip(.export), "only the automatic step can be skipped; the check and export cannot")
    t.check(FlowMarks().nextStep == .auto && FlowMarks(auto: .done).nextStep == .review && FlowMarks(auto: .skipped).nextStep == .review, "next step from the marks")
    f.set(.auto, .skipped); t.check(f.auto == .skipped && f.mark(.auto) == .skipped && f.mark(.review) == nil, "marks are set and read per step")
    let legacyFlow = try? JSONDecoder().decode(FlowMarks.self, from: Data("{\"auto\":\"done\",\"manual\":\"skipped\"}".utf8))
    t.check(legacyFlow == FlowMarks(auto: .done), "a mark for the removed pick-by-hand step is ignored")

    t.check(c.flowStep == .auto && !c.enabled, "a new micrograph starts at the automatic step")
    t.check(c.skip(.auto) && c.store.flow(k).auto == .skipped && c.flowStep == .review && c.crops.active && c.crops.includeEmpty && c.enabled, "skip automatic: the check opens (editor on) and visits every section, so picking by hand happens there")
    c.flowStep = .export
    t.check(!c.enabled && !c.crops.active, "export step: pick mode and the editor are off")
    c.reopen(.auto)
    t.check(c.store.flow(k).auto == nil && c.flowStep == .auto && !c.crops.includeEmpty, "reopening the automatic step clears its mark")
    c.finish(.auto)
    t.check(c.store.flow(k).auto == .done && c.flowStep == .review && c.crops.active, "continuing from the automatic step opens the check")
    c.flowStep = .export
    t.check(!c.crops.active, "leaving the check turns the editor off")
    // a micrograph that is opened resumes at its next step
    c.flowStep = .review
    c.setMicrograph(key: "other.mrc", width: 1000, height: 800, pixelSizeA: 10)
    t.check(c.flowStep == .auto && !c.crops.active, "a micrograph nobody has worked on starts at the automatic step (the editor goes off)")
    c.setMicrograph(key: k, width: 1000, height: 800, pixelSizeA: 10)
    t.check(c.flowStep == .review && c.crops.active, "going back to a micrograph whose automatic step is done opens the check")
    c.flowStep = .export
    c.setMicrograph(key: "other.mrc", width: 1000, height: 800, pixelSizeA: 10)
    t.check(c.flowStep == .export, "the export step stays open when the micrograph changes")
    c.setMicrograph(key: k, width: 1000, height: 800, pixelSizeA: 10)
    if let data = try? c.store.encoded(), let back = try? PickStore.decode(data) {
        t.check(back.mics[k]?.flow == FlowMarks(auto: .done), "step marks survive saving and loading")
    } else { t.check(false, "project encodes") }

    // --- running the picker marks the automatic step
    let c2 = PickController(); c2.store.saveDelay = 0
    let d2 = testTempDir(); defer { try? fm.removeItem(at: d2) }
    c2.store.openProject(folder: d2)
    let (img, _) = syntheticMicrograph(w: 512, h: 512, n: 6, dPx: 40, amp: 14, noise: 6, seed: 5)
    c2.pixels = img; c2.setMicrograph(key: "a.mrc", width: 512, height: 512, pixelSizeA: 5)
    var pr2 = c2.store.project.params; pr2.diameterNm = 20; c2.store.setParams(pr2)
    c2.runAutoPick(synchronous: true)
    t.check(c2.store.flow("a.mrc").auto == .done && !c2.store.candidates("a.mrc").isEmpty, "running the picker marks the automatic step done")

    // --- delete all
    t.section("delete all picks")
    let s = PickStore(); s.saveDelay = 0
    let d3 = testTempDir(); defer { try? fm.removeItem(at: d3) }
    s.openProject(folder: d3)
    for key in ["a.mrc", "b.mrc"] {
        s.add(Pick(id: key + "1", x: 10, y: 10, label: "side"), to: key)
        s.add(Pick(id: key + "2", x: 50, y: 10, label: "side"), to: key)
        s.add(Pick(id: key + "3", x: 90, y: 10, label: "tilted"), to: key)
    }
    _ = s.perform("a.mrc", "fixture") { l in
        l.append(Pick(id: "c1", x: 200, y: 200, label: "side", score: 5, source: .auto, status: .candidate))
        l.append(Pick(id: "d1", x: 300, y: 200, label: "side", score: 5, source: .auto, status: .dismissed))
    }
    s.addSection("a.mrc", DoneRegion(x0: 0, y0: 0, x1: 100, y1: 100)); s.setFlow("a.mrc", .auto, .done); s.setDone("a.mrc", true)
    t.check(s.removeAll(in: "a.mrc", label: "side") == 2 && s.counts("a.mrc") == ["tilted": 1], "delete all of one label: its accepted picks only")
    t.check(s.candidates("a.mrc").count == 1 && s.picks("a.mrc").contains { $0.id == "d1" }, "candidates and dismissed picks stay")
    t.check(s.undo("a.mrc") && s.counts("a.mrc")["side"] == 2, "one undo brings them back")
    t.check(s.removeAllEverywhere(label: "side") == 4 && s.counts("b.mrc") == ["tilted": 1] && s.totalCounts()["side"] == nil, "delete one label on every micrograph")
    let n = s.removeAll(in: "a.mrc", everything: true)
    t.check(n == 3 && s.picks("a.mrc").isEmpty && s.sections("a.mrc").isEmpty && s.flow("a.mrc").isEmpty && !s.record("a.mrc").done, "delete all on the micrograph: picks, candidates, dismissed, sections, step marks", "\(n)")
    t.check(s.picks("b.mrc").count == 1, "…and nothing on other micrographs")
    t.check(s.removeAll(in: "a.mrc", everything: true) == 0 && s.removeAll(in: "nothing.mrc", label: "side") == 0, "nothing to delete is a no-op")
    // through the controller
    let c3 = PickController(); c3.store.saveDelay = 0
    let d4 = testTempDir(); defer { try? fm.removeItem(at: d4) }
    c3.store.openProject(folder: d4)
    c3.setMicrograph(key: "m.mrc", width: 800, height: 800, pixelSizeA: 10)
    c3.store.add(Pick(id: "p1", x: 10, y: 10, label: "side"), to: "m.mrc"); c3.store.add(Pick(id: "p2", x: 90, y: 10, label: "tilted"), to: "m.mrc")
    c3.selection = ["p1"]
    t.check(c3.deleteAll(label: "side", everywhere: false) == 1 && c3.selection.isEmpty && c3.editMessage?.contains("Deleted 1") == true, "controller: delete a label, selection cleared, message")
    t.check(c3.deleteAllPicks() == 1 && c3.store.picks("m.mrc").isEmpty && c3.flowStep == .auto, "controller: delete all picks starts the micrograph over")
    t.check(c3.deleteAllPicks() == 0 && c3.editMessage == "Nothing to delete.", "controller: nothing to delete says so")

    // --- stacks: unpacked state is saved in the project
    t.section("workflow: unpacked stacks")
    let st = PickStore(); st.saveDelay = 0
    let d5 = testTempDir(); defer { try? fm.removeItem(at: d5) }
    st.openProject(folder: d5)
    t.check(!st.isUnpacked(base: "s.mrcs") && !st.project.isHiddenAverage("s.mrcs"), "a stack nobody unpacked shows its average")
    st.setUnpacked("s.mrcs", true)
    t.check(st.isUnpacked(base: "s.mrcs") && st.project.isHiddenAverage("s.mrcs") && !st.project.isHiddenAverage("s.mrcs#f1"), "unpacked: the average is hidden, frames are not")
    if let data = try? st.encoded(), let back = try? PickStore.decode(data) {
        t.check(back.mics["s.mrcs"]?.unpacked == true && back.isUnpacked(base: "s.mrcs"), "unpacked state survives saving and loading the project")
    } else { t.check(false, "project encodes") }
    st.setUnpacked("s.mrcs", false)
    t.check(!st.isUnpacked(base: "s.mrcs") && st.record("s.mrcs").unpacked == false, "average chosen again: saved as false")
    st.add(Pick(id: "f1", x: 1, y: 1, label: "side"), to: "s.mrcs#f2")
    t.check(!st.isUnpacked(base: "s.mrcs"), "an explicit choice of the average beats frame picks")
    st.setUnpacked("s.mrcs", nil)
    t.check(st.isUnpacked(base: "s.mrcs"), "no choice saved: a stack with frame picks counts as unpacked (older projects)")
    st.add(Pick(id: "v1", x: 1, y: 1, label: "side"), to: "plain.mrc")
    t.check(!st.project.isHiddenAverage("plain.mrc"), "a single image is never a hidden average")
    let rec = try? JSONDecoder().decode(MicRecord.self, from: Data("{\"done\":true}".utf8))
    t.check(rec?.unpacked == nil && rec?.flow == nil, "records without the new fields still load")

    // the average of an unpacked stack cannot be picked on
    let c4 = PickController(); c4.store.saveDelay = 0
    let d6 = testTempDir(); defer { try? fm.removeItem(at: d6) }
    c4.store.openProject(folder: d6)
    c4.store.setUnpacked("u.mrcs", true)
    c4.setMicrograph(key: "u.mrcs", width: 1000, height: 800, pixelSizeA: 10)
    c4.enabled = true
    t.check(c4.averageBlocked, "the average of an unpacked stack is blocked")
    c4.mouseDown(at: CGPoint(x: 300, y: 300), radiusPx: 10, shift: false); c4.mouseUp(at: CGPoint(x: 300, y: 300), shift: false)
    t.check(c4.store.picks("u.mrcs").isEmpty, "clicking the blocked average adds nothing")
    c4.store.add(Pick(id: "old", x: 300, y: 300, label: "side"), to: "u.mrcs")
    t.check(c4.visiblePicks.isEmpty, "picks stored on the hidden average are not drawn")
    c4.pixels = [Float](repeating: 1, count: 1000 * 800); c4.runAutoPick(synchronous: true)
    t.check(c4.store.candidates("u.mrcs").isEmpty, "the picker does not run on the blocked average")
    c4.setMicrograph(key: "u.mrcs#f1", width: 1000, height: 800, pixelSizeA: 10)
    c4.mouseDown(at: CGPoint(x: 300, y: 300), radiusPx: 10, shift: false); c4.mouseUp(at: CGPoint(x: 300, y: 300), shift: false)
    t.check(!c4.averageBlocked && c4.store.picks("u.mrcs#f1").count == 1, "frames of the same stack can be picked")
    st.setUnpacked("keep.mrcs", false); st.setUnpacked("keep.mrcs", nil)
    t.check(st.project.mics["keep.mrcs"] == nil, "forgetting the choice on an empty record removes the record")

    // export destination is per project
    let c5 = PickController(); c5.store.saveDelay = 0
    let d7 = testTempDir(); defer { try? fm.removeItem(at: d7) }
    c5.store.openProject(folder: d7)
    t.check(c5.exportFolder == nil && c5.exportDestination == c5.defaultExportFolder, "export goes to the default folder until another is chosen")
    let chosen = d7.appendingPathComponent("elsewhere")
    c5.exportFolder = chosen
    t.check(c5.exportDestination == chosen, "a chosen export folder is used")
    let d8 = testTempDir(); defer { try? fm.removeItem(at: d8) }
    c5.store.openProject(folder: d8)
    t.check(c5.exportFolder == nil, "…but only for the project it was chosen in")
}
