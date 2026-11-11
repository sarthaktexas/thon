import Foundation
import CoreGraphics

/// Headless checks for grid triage and sort mode (`Thon --picktest`).
func testSortAndGrid(_ t: inout TestRun) {
    t.section("grid triage and sort mode")

    // --- direction map (pure logic)
    let views = LabelScheme.views, quality = LabelScheme.quality
    let mv = SortMap.defaults(for: views), mq = SortMap.defaults(for: quality)
    t.check(mv.up == .label("ring_top") && mv.right == .label("side") && mv.down == .label("tilted") && mv.left == .dismiss, "default map, Views scheme: up red ring, right yellow side, down cyan tilted, left dismiss")
    t.check(mq.up == .label("good") && mq.right == .label("maybe") && mq.down == .label("reject") && mq.left == .dismiss, "default map, Quality scheme")
    var broken = mv; broken.up = .label("gone"); broken.right = .later
    let fixed = broken.valid(for: views)
    t.check(fixed.up == .label("ring_top") && fixed.right == .later, "map entries pointing at a removed label fall back to the default; others stay")
    t.check(SortAction(code: SortAction.label("side").code) == .label("side") && SortAction(code: "dismiss") == .dismiss && SortAction(code: "later") == .later && SortAction(code: "x") == nil, "action code round trip")
    let suite = "thon.test.\(UUID().uuidString)"
    let ud = UserDefaults(suiteName: suite)!
    defer { ud.removePersistentDomain(forName: suite) }
    var custom = mv; custom.up = .label("tilted"); custom.down = .later; custom.save(ud)
    let back = SortMap.load(scheme: views, ud)
    t.check(back == custom, "map survives save / load")
    t.check(SortMap.load(scheme: quality, ud).up == mq.up && SortMap.load(scheme: quality, ud).down == .later, "stale label ids in a saved map are replaced when the scheme differs")
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
    let gr = c.grid
    gr.rebuild()
    let nDecoy = gr.deck.filter { $0.decoy }.count
    t.check(nCand >= 12 && nDecoy > 0 && gr.deck.count == nCand + nDecoy, "grid deck = candidates + decoys", "cand \(nCand) decoys \(nDecoy) deck \(gr.deck.count)")
    t.check(gr.tiles == 9 && gr.page.count == 9 && gr.pageCount == (gr.deck.count + 8) / 9 && !gr.page[0].decoy, "3×3 page, first tile is a real candidate")

    // --- commit a page: three particles marked, the rest rejected
    let page1 = gr.page
    let realIDs = page1.filter { !$0.decoy }.map { $0.id }
    let marked = Array(realIDs.prefix(3))
    for m in marked { gr.toggle(m) }
    t.check(gr.particleCount == 3, "three tiles marked as particles")
    let serial0 = c.store.topSerial(k)
    gr.commit()
    let accepted = Set(c.store.accepted(k).map { $0.id })
    let dismissed = Set(c.store.picks(k).filter { $0.status == .dismissed }.map { $0.id })
    t.check(accepted == Set(marked) && c.store.accepted(k).allSatisfy { $0.label == c.activeLabel }, "marked tiles are accepted with the active label")
    t.check(dismissed == Set(realIDs).subtracting(marked), "unmarked real tiles of the page are dismissed")
    t.check(c.store.candidates(k).count == nCand - realIDs.count && c.store.picks(k).count == nCand, "tiles of other pages stay candidates; decoys never become picks")
    var dl = c.store.record(k).swipe?.decisions ?? []
    t.check(dl.count == 9 && dl.allSatisfy { $0.mode == "grid" } && dl.filter { $0.decoy }.count == page1.filter { $0.decoy }.count, "one grid decision per tile, decoys flagged")
    t.check(dl.filter { $0.decision == "pick" && !$0.decoy }.count == 3 && dl.allSatisfy { $0.view == "raw" }, "log has 3 picks and the display tag")
    t.check(gr.start == 9 && gr.particleCount == 0, "next page starts clean")
    t.check(c.store.topSerial(k) != serial0 && c.store.undoName(k)?.hasPrefix("Grid: page") == true, "a page is one undoable store edit")

    // --- undo a page
    gr.undo()
    dl = c.store.record(k).swipe?.decisions ?? []
    t.check(c.store.candidates(k).count == nCand && c.store.accepted(k).isEmpty && dl.isEmpty && gr.start == 0 && c.store.topSerial(k) == serial0, "undo page restores picks, log and position")
    t.check(gr.particleCount == 3 && marked.allSatisfy { gr.clicked.contains($0) }, "undo page restores the marks")
    gr.clearPage()

    // --- unsure stays a candidate
    gr.toggleUnsure(realIDs[0]); gr.toggle(realIDs[1])
    gr.commit()
    t.check(c.store.pick(realIDs[0], in: k)?.status == .candidate && c.store.pick(realIDs[1], in: k)?.status == .accepted, "unsure tile stays a candidate, clicked tile accepted")
    t.check(c.store.record(k).swipe?.decisions.first { $0.id == realIDs[0] }?.decision == "unsure", "unsure is logged")
    gr.undo(); gr.clearPage()

    // --- junk mode: unmarked = particle
    gr.junkMode = true
    gr.toggle(realIDs[0])
    let pj = gr.particleCount
    gr.commit()
    t.check(c.store.pick(realIDs[0], in: k)?.status == .dismissed && realIDs.dropFirst().allSatisfy { c.store.pick($0, in: k)?.status == .accepted }, "junk mode: marked tile rejected, unmarked tiles accepted")
    let nd = page1.filter { $0.decoy }.count
    t.check(pj == page1.count - 1 && gr.decoySeen == nd && (nd > 0 ? gr.decoyRate == 1 : gr.decoyRate == nil), "junk mode counts unmarked decoys as particles (control rate)", "\(pj) \(String(describing: gr.decoyRate))")
    let swSt = SwipeStats.compute(c.store.project.mics.values.compactMap { $0.swipe })
    t.check(swSt.decoySeen == gr.decoySeen && swSt.cards == 9, "grid decisions feed the pick / decoy statistics")
    gr.junkMode = false

    // --- 4×4
    gr.rebuild()
    gr.n = 4
    t.check(gr.tiles == 16 && gr.page.count == min(16, gr.deck.count) && gr.start == 0, "4×4 page")
    gr.moveCursor(dx: 1, dy: 0); gr.moveCursor(dx: 0, dy: 1)
    t.check(gr.cursor == (gr.page.count > 4 ? min(5, gr.page.count - 1) : 1), "cursor moves right and down on the 4-wide grid, clamped to the tiles present", "\(gr.cursor) of \(gr.page.count)")
    gr.n = 3
    gr.rebuild()
    while !gr.done { gr.markAll(); gr.commit() }                  // accept everything that is left, page by page

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
    so.swipe(.up)                                                  // ring_top = the label the pick already has
    t.check(so.reviewed == 1 && so.current?.id != first.id && isSorted(first.id, in: c.store.record(k).swipe), "up: logged as sorted, next card")
    so.undo()
    t.check(c.store.accepted(k).count == acceptedBefore && !isSorted(first.id, in: c.store.record(k).swipe) && so.current?.id == first.id,
            "undo of a swipe that changed nothing does not undo an unrelated edit")

    so.swipe(.right)                                               // side
    let p1 = c.store.pick(first.id, in: k)!
    let d1 = c.store.record(k).swipe!.decisions.last!
    t.check(p1.label == "side" && p1.status == .accepted && d1.mode == "sort" && d1.decision == "pick" && d1.label == "side" && !d1.decoy, "right: pick relabelled, logged with mode sort")
    so.undo()
    t.check(c.store.pick(first.id, in: k)?.label == c.activeLabel && !isSorted(first.id, in: c.store.record(k).swipe), "undo restores the previous label and the log")

    so.swipe(.down)                                                // tilted
    t.check(c.store.pick(first.id, in: k)?.label == "tilted", "down: tilted")
    let second = so.current!
    so.swipe(.left)                                                // dismiss
    t.check(c.store.pick(second.id, in: k)?.status == .dismissed && c.store.record(k).swipe!.decisions.last!.decision == "reject", "left: dismissed and logged as reject")
    so.undo()
    t.check(c.store.pick(second.id, in: k)?.status == .accepted && so.current?.id == second.id, "undo of a dismissal brings the pick back")

    let logN = c.store.record(k).swipe!.decisions.count
    so.later()
    t.check(so.queue.last?.id == second.id && c.store.record(k).swipe!.decisions.count == logN, "later moves the card to the end without logging")
    so.undo()
    t.check(so.current?.id == second.id, "undo later")

    // custom map: up = side
    so.map.up = .label("side")
    so.swipe(.up)
    t.check(c.store.pick(second.id, in: k)?.label == "side", "re-mapped direction applies the new label")
    t.check(SortMap.load(scheme: c.store.scheme, ud).up == .label("side"), "map change is saved")
    so.label("oligomer")                                           // hotkey path for a label without a direction
    let third = c.store.record(k).swipe!.decisions.last!
    t.check(third.label == "oligomer" && third.view == "raw" && third.mode == "sort", "label by key: logged with display tag and mode sort")

    // recentering moves the pick
    let cur = so.current!
    so.recenter(to: CGPoint(x: cur.x + 6, y: cur.y - 4))
    so.swipe(.down)
    let moved = c.store.pick(cur.id, in: k)!
    t.check(abs(moved.x - (cur.x + 6)) < 1e-9 && abs(moved.y - (cur.y - 4)) < 1e-9 && c.store.record(k).swipe!.decisions.last!.recentered, "re-centered cross moves the pick")

    // deck now smaller; sorted picks stay out of the unsorted deck
    so.rebuild()
    t.check(so.total == autoAccepted.count - 4, "sorted picks are not offered again (4 sorted)", "\(so.total) of \(autoAccepted.count)")
    let files = PickExporter.swipeFiles(project: c.store.project)
    let csv = files.first { $0.name == "swipe_decisions.csv" }?.text ?? ""
    t.check(csv.hasPrefix("card_id,decision,label,x_px,y_px,recentered,decoy,dwell_ms,time,display,mode\n") && csv.contains(",sort\n") && csv.contains(",grid\n"), "csv has a mode column (grid / sort)")
    t.check(files.first { $0.name == "swipe_stats.json" }?.text.contains("\"cards\"") == true, "stats json still written")

    // persistence of mode
    c.store.save()
    let c2 = PickStore(); c2.openProject(folder: dir)
    t.check(c2.project.mics[k]?.swipe == c.store.record(k).swipe && c2.project.mics[k]?.swipe?.decisions.contains { $0.mode == "sort" } == true, "mode survives save / load")
    let oldJSON = Data(#"{"id":"a","decision":"pick","x":1,"y":2}"#.utf8)
    t.check((try? JSONDecoder().decode(SwipeDecision.self, from: oldJSON)).map { $0.mode == nil } == true, "older decisions without a mode still load")
}
