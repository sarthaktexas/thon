import Foundation
import CoreGraphics

/// Headless checks for the crop editor and the assistant's early-estimate figures (`Thon --picktest`).
func testCrops(_ t: inout TestRun) {
    t.section("crop editor")

    // --- tile layout
    let ctr = CropSession.centres(length: 1000, side: 400)
    t.check(ctr.first == 200 && ctr.last == 800 && zip(ctr.dropFirst(), ctr).allSatisfy { $0 - $1 <= 300 + 1e-9 && $0 - $1 > 0 }, "crop centres cover the image with overlap", "\(ctr)")
    t.check(CropSession.centres(length: 300, side: 400) == [150], "an image smaller than the crop gets one crop")

    // --- fixture: one micrograph, three known candidates in the first crop
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let (img, _) = syntheticMicrograph(w: 1024, h: 1024, n: 12, dPx: 40, amp: 12, noise: 8, seed: 41)
    c.pixels = img; c.setMicrograph(key: "m.mrc", width: 1024, height: 1024, pixelSizeA: 5)
    var pr = c.store.project.params; pr.diameterNm = 20; c.store.setParams(pr)            // 20 nm at 5 Å/px = 40 px
    let k = "m.mrc"
    _ = c.store.perform(k, "fixture") { l in
        l.append(Pick(id: "t1", x: 80, y: 100, label: c.activeLabel, score: 9, source: .auto, status: .candidate))
        l.append(Pick(id: "t2", x: 130, y: 110, label: c.activeLabel, score: 9, source: .auto, status: .candidate))
        l.append(Pick(id: "t3", x: 100, y: 60, label: c.activeLabel, score: 9, source: .auto, status: .candidate))
        l.append(Pick(id: "u1", x: 500, y: 500, label: c.activeLabel, score: 9, source: .auto, status: .candidate))
        l.append(Pick(id: "u2", x: 700, y: 640, label: c.activeLabel, score: 9, source: .auto, status: .candidate))
    }
    let cs = c.crops
    cs.classifier.enabled = false
    cs.order = .scan
    cs.rebuild()
    t.check(cs.tilesTotal > 0 && cs.queue.count == cs.tilesTotal && cs.current?.id == 0, "tiles with candidates are queued, scan order starts at the top left", "\(cs.tilesTotal)")
    t.check(["t1", "t2", "t3"].allSatisfy { id in cs.items.contains { $0.id == id && $0.untouched && !$0.isNew && $0.level == .sure } }, "the first crop shows its candidates, untouched and green")
    t.check(cs.hit(x: 82, y: 101, tolerancePx: 2)?.id == "t1" && cs.hit(x: 400, y: 400, tolerancePx: 2) == nil, "hit test finds the circle under the pointer, nothing on empty ground")
    t.check(cs.cropImage(out: 128)?.count == 128 * 128, "the crop renders")

    // --- edits
    cs.beginEdit(); cs.move("t1", to: CGPoint(x: 60, y: 100))
    cs.beginEdit(); cs.setDiameter("t2", nm: 30)
    t.check(cs.items.first { $0.id == "t2" }?.diameterNm == 30 && cs.penNm == 30, "resizing sets the size and remembers it for the next circle you add")
    cs.setDiameter("t2", nm: 1000)
    t.check(cs.items.first { $0.id == "t2" }!.diameterNm <= cs.defaultDiameterNm * 6 + 1e-9, "size is limited")
    cs.setDiameter("t2", nm: 30)
    cs.remove("t3")
    t.check(cs.items.first { $0.id == "t3" }?.removed == true && !cs.visibleItems.contains { $0.id == "t3" }, "double-click removal hides the circle but keeps it for the commit")
    c.activeLabel = "maybe"
    let n1 = cs.add(x: 140, y: 140)!
    t.check(cs.items.first { $0.id == n1 }.map { $0.isNew && $0.label == "maybe" && $0.level == .maybe && $0.diameterNm == 30 } == true && cs.selected == n1, "a click on empty ground adds a circle of the active type (maybe) and the last size, and selects it")
    cs.undo()
    t.check(!cs.items.contains { $0.id == n1 }, "Z takes back the last edit")
    let n2 = cs.add(x: 140, y: 140)!
    cs.setDiameter(n2, nm: 24)
    cs.remove(n2)
    t.check(!cs.items.contains { $0.id == n2 }, "removing a circle you added just drops it")
    let n3 = cs.add(x: 140, y: 140)!
    cs.setDiameter(n3, nm: 24)
    cs.setLabel("t2", "maybe")
    t.check(cs.items.first { $0.id == "t2" }.map { $0.label == "maybe" && $0.level == .maybe } == true, "changing a circle's type to maybe makes it a maybe (level follows the type)")
    cs.setLabel("t2", "good")
    t.check(cs.items.first { $0.id == "t2" }.map { $0.label == "good" && $0.level == .sure } == true, "and back to good makes it sure again")
    cs.setLabel("t2", "ring_top"); cs.cycleLabel("t2")
    t.check(cs.items.first { $0.id == "t2" }?.label == "side" && c.activeLabel == "side", "Space steps to the next type in the scheme")
    cs.setLabel("t2", "good")
    t.check(cs.add(x: -50, y: 10) == nil, "no circle outside the micrograph")
    t.check(["t1", "t2", n3].allSatisfy { id in cs.items.first { $0.id == id }.map { !$0.untouched } == true } && cs.items.first { $0.id == "u1" } == nil, "edited circles are no longer drawn as suggestions")

    // --- confirm
    let before = c.store.picks(k).count
    cs.commit()
    let p1 = c.store.pick("t1", in: k)!, p2 = c.store.pick("t2", in: k)!, p3 = c.store.pick("t3", in: k)!
    t.check(p1.status == .accepted && p1.x == 60 && p1.y == 100, "moved circle: accepted at its new position")
    t.check(p2.status == .accepted && p2.diameterNm == 30 && p2.maybe == nil, "resized circle keeps its own size")
    t.check(p3.status == .dismissed, "removed suggestion is dismissed")
    let added = c.store.picks(k).first { $0.id == n3 }
    t.check(added?.status == .accepted && added?.source == .manual && added?.label == "maybe" && added?.maybe == true && added?.diameterNm == 24 && c.store.picks(k).count == before + 1, "added circle becomes a manual pick with its type (maybe) and size")
    t.check(c.store.project.params.maybeFlag, "using a maybe type turns the maybe flag on, so the picks show as ? and can be left out of an export")
    t.check(c.store.undoName(k)?.hasPrefix("Crop") == true, "a crop is one undoable store edit")
    let log = c.store.record(k).swipe?.decisions ?? []
    t.check(log.allSatisfy { $0.mode == "crop" } && log.contains { $0.id == "t3" && $0.decision == "reject" } && log.contains { $0.id == "t1" && $0.decision == "pick" && $0.recentered }, "decisions are logged with mode crop (reject, pick, moved)")
    t.check(SwipeStats.compute([c.store.record(k).swipe ?? SwipeLog()]).cards == 0, "crop decisions are not counted as candidate-review pick rates")
    t.check(isSorted("t1", in: c.store.record(k).swipe) && !isSorted("t3", in: nil), "a confirmed circle counts as sorted, so it is not drawn white")
    let rr = c.swipe.reranker
    t.check(rr.samples["m.mrc@t1"]?.y == 1 && rr.samples["m.mrc@t3"]?.y == 0 && rr.samples["m.mrc@\(n3)"]?.w == 0.5, "assistant learns: kept = yes, removed = no, yellow counts half")
    t.check(rr.samples["m.mrc@o_t1"].map { $0.y == 0 && $0.w == 0.5 } == true, "the old spot of a moved circle is a half-weight no")
    t.check(rr.samples.keys.contains { $0.hasPrefix("m.mrc@b0_") && rr.samples[$0]!.decoy && rr.samples[$0]!.y == 0 }, "blank spots of the crop are easy negatives")
    t.check(cs.reviewedCount == 1 && cs.current != nil && cs.current?.id != 0, "next crop is on screen")

    // --- undo the crop
    let nSamples = rr.samples.count
    cs.undo()
    t.check(c.store.pick("t3", in: k)?.status == .candidate && c.store.pick("t1", in: k)?.x == 80 && c.store.picks(k).count == before, "undo takes the whole crop back (picks)")
    t.check((c.store.record(k).swipe?.decisions ?? []).isEmpty && rr.samples.count < nSamples && rr.samples["m.mrc@t1"] == nil, "and its log and training examples")
    t.check(cs.reviewedCount == 0 && cs.current?.id == 0 && cs.items.first { $0.id == "t3" }?.removed == true, "and the crop is back on screen with your edits")
    cs.commit()
    cs.rebuild()
    t.check(cs.reviewedCount == 1 && !cs.queue.contains { $0.id == 0 }, "reviewed crops stay reviewed when the editor is reopened")

    // --- zoom out brings the wider window's circles in
    guard let tile = cs.current else { t.check(false, "a second crop is still waiting"); return }
    _ = c.store.perform(k, "far") { l in l.append(Pick(id: "far", x: tile.cx + 1.2 * cs.sidePx / 2 * 1.2, y: tile.cy, label: c.activeLabel, score: 9, source: .auto, status: .candidate)) }
    cs.zoomOut = true
    t.check(cs.items.contains { $0.id == "far" } && cs.windowPx == 2 * cs.sidePx, "zoom out ×2 adds the circles of the wider window")
    cs.zoomOut = false

    // --- reject is not a type; deleting is the only way to reject
    t.section("crop editor: no reject type")
    let aT = cs.current!
    _ = c.store.perform(k, "rej") { l in
        l.append(Pick(id: "rj1", x: aT.cx, y: aT.cy, label: "reject", score: 9, source: .auto, status: .candidate))
        l.append(Pick(id: "rj2", x: aT.cx + 8, y: aT.cy + 8, label: "reject", source: .manual, status: .accepted))
    }
    c.activeLabel = "reject"
    cs.rebuild()
    t.check(!cs.typeLabels.contains { $0.id == "reject" } && cs.penLabelID != "reject", "Reject is not offered as a type, and an active Reject falls back to an exported type", "\(cs.typeLabels.map { $0.id }) \(cs.penLabelID)")
    t.check(cs.items.first { $0.id == "rj1" }.map { $0.label == cs.penLabelID } == true, "a candidate that carries the Reject label shows as a normal type")
    t.check(!cs.items.contains { $0.id == "rj2" }, "a pick you already rejected in the viewer does not come back as a circle")
    cs.setLabel("rj1", "reject")
    t.check(cs.items.first { $0.id == "rj1" }?.label != "reject", "a circle cannot be set to Reject")
    let nr = cs.add(x: aT.cx + 30, y: aT.cy + 30)!
    t.check(cs.items.first { $0.id == nr }?.label != "reject", "a new circle never gets the Reject label")
    cs.remove(nr)
    t.check(!cs.items.contains { $0.id == nr }, "removing a circle you added just drops it")
    c.activeLabel = "ring_top"

    // --- size typing (view schemes)
    t.section("crop editor: type from size")
    let st = SizeTyper.learn([("ring_top", 26), ("ring_top", 28), ("ring_top", 27), ("side", 17), ("side", 19), ("side", 18), ("tilted", 22)])
    t.check(st?.centres.map { $0.id } == ["side", "ring_top"], "learns a typical size per view, only for views with 3 or more sized circles", "\(String(describing: st?.centres))")
    t.check(st?.label(forNm: 25) == "ring_top" && st?.label(forNm: 19) == "side" && st?.label(forNm: 14) == "side", "a circle takes the view with the closest typical size")
    t.check(SizeTyper.learn([("ring_top", 26), ("ring_top", 27), ("ring_top", 28), ("side", 18)]) == nil, "one view alone, or too few examples, learns nothing")
    c.store.setScheme_forTest(LabelScheme.views); c.activeLabel = "ring_top"
    t.check(cs.isViewScheme && cs.viewLabelIDs == ["ring_top", "side", "tilted", "oligomer"], "the views preset is a view scheme (confidence and reject types are not views)", "\(cs.viewLabelIDs)")
    let savedTyping = cs.sizeTyping                                   // the test must not change the user's saved preference
    cs.sizeTyping = true; cs.refreshSizeTyper()
    let w0 = cs.add(x: 120, y: 120)!
    cs.setDiameter(w0, nm: 30)
    t.check(cs.items.first { $0.id == w0 }?.label == "ring_top", "with nothing learned, resizing leaves the type alone")
    for (i, d) in [26.0, 27, 28, 17, 18, 19].enumerated() {
        _ = c.store.perform(k, "sized\(i)") { l in l.append(Pick(id: "sz\(i)", x: 300 + Double(i) * 10, y: 300, label: i < 3 ? "ring_top" : "side", source: .manual, status: .accepted, diameterNm: d)) }
    }
    cs.refreshSizeTyper()
    t.check(cs.sizeTyper != nil, "the sized picks of the project teach it")
    cs.setDiameter(w0, nm: 18)
    t.check(cs.items.first { $0.id == w0 }?.label == "side" && c.activeLabel == "side", "resizing a circle to a side-view size makes it a side view")
    cs.setLabel(w0, "uncertain"); cs.setDiameter(w0, nm: 27)
    t.check(cs.items.first { $0.id == w0 }?.label == "uncertain", "a type you set that is not a view (uncertain, reject) is never overwritten by size")
    cs.sizeTyping = false; cs.setLabel(w0, "ring_top"); cs.setDiameter(w0, nm: 18)
    t.check(cs.items.first { $0.id == w0 }?.label == "ring_top", "switched off, size never changes the type")
    cs.sizeTyping = savedTyping

    // --- assistant: early estimate and balanced accuracy
    t.section("assistant: early estimate")
    var rng = AssistRNG(21)
    var noise: [[Float]] = [], lab: [Float] = []
    for i in 0..<200 { noise.append((0..<10).map { _ in Float(rng.unit() - 0.5) }); lab.append(i < 180 ? 1 : 0) }
    let cv = Logistic.crossValidate(noise, lab)
    t.check((cv?.accuracy ?? 1) < 0.7, "with 90 % yes and no signal the reported agreement stays near chance (balanced), not at the 90 % majority share", "\(String(describing: cv))")
    t.check(Reranker.minEach == 10 && Reranker.minEach < Reranker.fullEach, "first fit needs 10 yes and 10 no")
    let r = Reranker()
    for i in 0..<24 {
        var f = [Float](repeating: 0, count: CardFeatures.handLength)
        f[0] = (i % 2 == 0 ? 1 : -1) + Float(rng.unit() - 0.5) * 0.6
        r.observe(key: "e", id: "s\(i)", decision: i % 2 == 0 ? "pick" : "reject", decoy: false, hand: f, embedding: nil, fit: false)
    }
    t.check(!r.status.ready, "recording a batch with fit: false does not fit")
    r.finishBatch()
    t.check(cropWait(20) { r.status.ready }, "a batch of 12 yes and 12 no is enough for a first fit")
    t.check(r.status.folds == 3 && r.status.summary.contains("early estimate") && r.status.summary.contains("balanced"), "the figures are labelled an early estimate, with the fold count", "\(r.status.summary)")
}

/// Runs the main run loop until `cond` holds (background fits report back on the main queue) or `seconds` pass.
private func cropWait(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return cond()
}
