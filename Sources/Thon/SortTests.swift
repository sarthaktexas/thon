import Foundation
import CoreGraphics

/// Headless checks for sort mode (`Thon --picktest`).
func testSort(_ t: inout TestRun) {
    t.section("sort mode")

    // --- direction map (pure logic)
    let views = LabelScheme.views, quality = LabelScheme.quality
    let mv = SortMap.defaults(for: views), mq = SortMap.defaults(for: quality)
    t.check(mv.left == .label("ring_top") && mv.up == .label("side") && mv.right == .label("tilted") && mv.down == .dismiss, "default map, Views scheme: left view 1, up view 2, right view 3, down dismiss")
    t.check(mq.left == .label("reject") && mq.up == .label("maybe") && mq.right == .label("good") && mq.down == .dismiss, "default map, Quality scheme: left reject, up maybe, right good, down dismiss")
    t.check(SortMap.storageKey(for: views) != SortMap.storageKey(for: quality), "each scheme has its own saved map")
    var broken = mv; broken.up = .label("gone"); broken.right = .later
    let fixed = broken.valid(for: views)
    t.check(fixed.up == mv.up && fixed.right == .later, "map entries pointing at a removed label fall back to the default; others stay")
    t.check(SortAction(code: SortAction.label("side").code) == .label("side") && SortAction(code: "dismiss") == .dismiss && SortAction(code: "later") == .later && SortAction(code: "x") == nil, "action code round trip")
    let suite = "thon.test.\(UUID().uuidString)"
    let ud = UserDefaults(suiteName: suite)!
    defer { ud.removePersistentDomain(forName: suite) }
    var custom = mv; custom.up = .label("tilted"); custom.down = .later; custom.save(scheme: views, ud)
    let back = SortMap.load(scheme: views, ud)
    t.check(back == custom, "map survives save / load")
    t.check(SortMap.load(scheme: quality, ud) == mq, "a map saved for the Views scheme does not touch the Quality scheme")
    SortMap.forget(scheme: views, ud)
    t.check(SortMap.load(scheme: views, ud) == mv, "forgetting a saved map restores the built-in directions")
    t.check(SortSession.direction(of: CGSize(width: 90, height: 10)) == .right && SortSession.direction(of: CGSize(width: -90, height: 10)) == .left
            && SortSession.direction(of: CGSize(width: 10, height: -90)) == .up && SortSession.direction(of: CGSize(width: 10, height: 90)) == .down
            && SortSession.direction(of: CGSize(width: 5, height: 5)) == nil, "drag direction from the dominant axis, nil for tiny drags")

    // --- sorted detection
    var log = SwipeLog()
    log.decisions = [SwipeDecision(id: "a", decision: "pick", x: 1, y: 1), SwipeDecision(id: "b", decision: "reject", x: 1, y: 1),
                     SwipeDecision(id: "c", decision: "pick", x: 1, y: 1, mode: "grid"), SwipeDecision(id: "d", decision: "pick", x: 1, y: 1, mode: "sort"),
                     SwipeDecision(id: "e", decision: "pick", x: 1, y: 1, decoy: true)]
    t.check(isSorted("a", in: log) && !isSorted("b", in: log) && !isSorted("c", in: log) && isSorted("d", in: log) && !isSorted("e", in: log) && !isSorted("a", in: nil),
            "sorted = sort decision or accepting decision of the old review swipe; grid triage and decoys do not count")
    let st = SwipeStats.compute([log])
    t.check(st.sorted == 1 && st.cards == 4, "pick / reject statistics skip sort decisions", "\(st)")

    // --- fixture
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let (img, _) = syntheticMicrograph(w: 1024, h: 1024, n: 12, dPx: 40, amp: 12, noise: 8, seed: 41)
    c.pixels = img; c.setMicrograph(key: "m.mrc", width: 1024, height: 1024, pixelSizeA: 5)
    var pr = c.store.project.params; pr.diameterNm = 20; c.store.setParams(pr)
    c.autoParams.zThreshold = 4; c.runAutoPick(synchronous: true)
    let k = "m.mrc"
    let nCand = c.store.candidates(k).count
    t.check(nCand >= 12, "fixture has candidates", "\(nCand)")
    c.store.setStatus(Set(c.store.candidates(k).map { $0.id }), .accepted, in: k)        // every candidate accepted, as after a pass of the crop editor

    // --- sort mode
    let so = SortSession(pc: c, defaults: ud)
    so.map = SortMap.defaults(for: c.store.scheme)
    _ = c.store.perform(k, "manual") { $0.append(Pick(x: 500, y: 500, label: "side")) }
    let manualID = c.store.picks(k).last!.id
    so.rebuild()
    let autoAccepted = c.store.accepted(k).filter { $0.source == .auto }
    t.check(so.total == autoAccepted.count && so.total >= 8 && !so.queue.contains { $0.id == manualID } && so.pendingCount(k) == so.total, "sort deck = accepted auto picks not yet sorted (manual picks excluded)", "\(so.total) of \(autoAccepted.count)")
    so.scope = .all; so.rebuild()
    t.check(so.total == autoAccepted.count + 1, "'All picks' scope includes manual picks")
    so.scope = .unsorted; so.rebuild()

    let first = so.current!
    let acceptedBefore = c.store.accepted(k).count
    so.swipe(.left)                                                // ring_top = the label the pick already has
    t.check(so.reviewed == 1 && so.current?.id != first.id && isSorted(first.id, in: c.store.record(k).swipe), "left (view 1): logged as sorted, next card")
    so.undo()
    t.check(c.store.accepted(k).count == acceptedBefore && !isSorted(first.id, in: c.store.record(k).swipe) && so.current?.id == first.id,
            "undo of a swipe that changed nothing does not undo an unrelated edit")

    so.swipe(.right)                                               // tilted
    let p1 = c.store.pick(first.id, in: k)!
    let d1 = c.store.record(k).swipe!.decisions.last!
    t.check(p1.label == "tilted" && p1.status == .accepted && d1.mode == "sort" && d1.decision == "pick" && d1.label == "tilted" && !d1.decoy, "right (view 3): pick relabelled, logged with mode sort")
    so.undo()
    t.check(c.store.pick(first.id, in: k)?.label == c.activeLabel && !isSorted(first.id, in: c.store.record(k).swipe), "undo restores the previous label and the log")

    so.swipe(.up)                                                  // side
    t.check(c.store.pick(first.id, in: k)?.label == "side", "up (view 2): side")
    let second = so.current!
    so.swipe(.down)                                                // dismiss
    t.check(c.store.pick(second.id, in: k)?.status == .dismissed && c.store.record(k).swipe!.decisions.last!.decision == "reject", "down: dismissed and logged as reject")
    so.undo()
    t.check(c.store.pick(second.id, in: k)?.status == .accepted && so.current?.id == second.id, "undo of a dismissal brings the pick back")

    let logN = c.store.record(k).swipe!.decisions.count
    so.later()
    t.check(so.queue.last?.id == second.id && c.store.record(k).swipe!.decisions.count == logN, "later moves the card to the end without logging")
    so.undo()
    t.check(so.current?.id == second.id, "undo later")

    // custom map: up = tilted
    so.map.up = .label("tilted")
    so.swipe(.up)
    t.check(c.store.pick(second.id, in: k)?.label == "tilted", "re-mapped direction applies the new label")
    t.check(SortMap.load(scheme: c.store.scheme, ud).up == .label("tilted"), "map change is saved for this scheme")
    so.label("oligomer")                                           // hotkey path for a label without a direction
    let third = c.store.record(k).swipe!.decisions.last!
    t.check(third.label == "oligomer" && third.view == "raw" && third.mode == "sort", "label by key: logged with display tag and mode sort")

    // recentering moves the pick
    let cur = so.current!
    so.recenter(to: CGPoint(x: cur.x + 6, y: cur.y - 4))
    so.swipe(.right)
    let moved = c.store.pick(cur.id, in: k)!
    t.check(abs(moved.x - (cur.x + 6)) < 1e-9 && abs(moved.y - (cur.y - 4)) < 1e-9 && c.store.record(k).swipe!.decisions.last!.recentered, "re-centered cross moves the pick")

    // deck now smaller; sorted picks stay out of the unsorted deck
    so.rebuild()
    t.check(so.total == autoAccepted.count - 4, "sorted picks are not offered again (4 sorted)", "\(so.total) of \(autoAccepted.count)")
    let files = PickExporter.swipeFiles(project: c.store.project)
    let csv = files.first { $0.name == "swipe_decisions.csv" }?.text ?? ""
    t.check(csv.hasPrefix("card_id,decision,label,x_px,y_px,recentered,decoy,dwell_ms,time,display,mode\n") && csv.contains(",sort\n"), "csv has a mode column")
    t.check(files.first { $0.name == "swipe_stats.json" }?.text.contains("\"cards\"") == true, "stats json still written")

    // persistence of mode
    c.store.save()
    let c2 = PickStore(); c2.openProject(folder: dir)
    t.check(c2.project.mics[k]?.swipe == c.store.record(k).swipe && c2.project.mics[k]?.swipe?.decisions.contains { $0.mode == "sort" } == true, "mode survives save / load")
    let oldJSON = Data(#"{"id":"a","decision":"pick","x":1,"y":2}"#.utf8)
    t.check((try? JSONDecoder().decode(SwipeDecision.self, from: oldJSON)).map { $0.mode == nil } == true, "older decisions without a mode still load")
}
