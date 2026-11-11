import Foundation
import CoreGraphics

/// Headless checks for the swipe display controls (denoise, brightness / contrast, labels) — `Thon --picktest`.
func testSwipeDisplay(_ t: inout TestRun) {
    t.section("swipe display: denoise, brightness / contrast, raw vs denoised labels")

    func stdev(_ a: [Float]) -> Double {
        let m = a.reduce(0, { $0 + Double($1) }) / Double(a.count)
        return (a.reduce(0, { $0 + (Double($1) - m) * (Double($1) - m) }) / Double(a.count)).squareRoot()
    }
    func mean(_ a: [Float]) -> Double { a.reduce(0, { $0 + Double($1) }) / Double(a.count) }
    func rmse(_ a: [Float], _ b: [Float]) -> Double { (zip(a, b).reduce(0.0) { $0 + (Double($1.0) - Double($1.1)) * (Double($1.0) - Double($1.1)) } / Double(a.count)).squareRoot() }

    // --- plate render with no denoising is byte-identical to the existing thumbnail renderer (smoothing 0)
    let (img, _) = syntheticMicrograph(w: 400, h: 300, n: 6, dPx: 30, amp: 12, noise: 8, seed: 5)
    let win = robustWindow(img)
    var same = true, detail = ""
    for (cx, cy, box, out) in [(200.0, 150.0, 60.0, 90), (200.0, 150.0, 150.0, 60), (12.0, 20.0, 80.0, 64), (395.0, 290.0, 120.0, 50), (200.3, 150.7, 61.0, 77)] {
        let ref = renderThumb(pixels: img, width: 400, height: 300, cx: cx, cy: cy, boxPx: box, out: out, lo: win.lo, hi: win.hi, smoothSigma: 0)
        let plate = CardPlate.make(pixels: img, width: 400, height: 300, cx: cx, cy: cy, boxPx: box, out: out, denoise: .none, size: 1, h: 1)
        let got = plate.render(out: out, lo: win.lo, hi: win.hi)
        if got != ref { same = false; detail += " (\(cx),\(cy),\(box),\(out))" }
    }
    t.check(same, "raw plate == renderThumb byte for byte (enlarged, shrunk, at borders, fractional centres)", detail)

    // --- noise estimate
    var rng = LCG(s: 99)
    let n = 128
    var flat = [Float](repeating: 0, count: n * n)
    for i in 0..<flat.count { flat[i] = Float(100 + 5 * rng.gauss()) }
    let est = Double(Denoise.noiseSigma(flat, n, n))
    t.check(abs(est - 5) < 0.4, "noise σ estimate on white noise σ = 5", String(format: "%.2f", est))
    var stepClean = [Float](repeating: 100, count: n * n)
    for y in 0..<n { for x in n / 2..<n { stepClean[y * n + x] = 130 } }
    var stepNoisy = stepClean
    for i in 0..<stepNoisy.count { stepNoisy[i] += Float(6 * rng.gauss()) }
    let est2 = Double(Denoise.noiseSigma(stepNoisy, n, n))
    t.check(abs(est2 - 6) < 0.5, "noise σ estimate is not inflated by a 30-unit edge", String(format: "%.2f", est2))

    // --- noise reduction on flat noise
    let sg = 5.0, noise = Denoise.noiseSigma(flat, n, n)
    let g = Denoise.apply(.gaussian, flat, n, size: 1.5, h: 1, noise: noise)
    let md = Denoise.apply(.median, flat, n, size: 1, h: 1, noise: noise)
    let bl = Denoise.apply(.bilateral, flat, n, size: 2, h: 1.5, noise: noise)
    let nl = Denoise.apply(.nlm, flat, n, size: 1, h: 1, noise: noise)
    t.check(stdev(g) / sg < 0.3 && stdev(md) / sg < 0.6 && stdev(bl) / sg < 0.6 && stdev(nl) / sg < 0.55,
            "every denoiser lowers the σ of flat noise",
            String(format: "gauss %.2f median %.2f bilateral %.2f nlm %.2f of the input σ", stdev(g) / sg, stdev(md) / sg, stdev(bl) / sg, stdev(nl) / sg))
    t.check([g, md, bl, nl].allSatisfy { abs(mean($0) - mean(flat)) < 0.3 }, "denoisers keep the mean level")

    // --- edge: error against the clean step, and step height kept
    let sn = Denoise.noiseSigma(stepNoisy, n, n)
    let base = rmse(stepNoisy, stepClean)
    func edgeStep(_ a: [Float]) -> Double {      // mean difference across the edge on rows 20..<108
        var l = 0.0, r = 0.0
        for y in 20..<108 { l += Double(a[y * n + n / 2 - 1]); r += Double(a[y * n + n / 2]) }
        return (r - l) / 88
    }
    var edgeOK = true, errOK = true, msg = ""
    for (m, size, h) in [(SwipeDenoise.median, 1.0, 1.0), (.bilateral, 2.0, 1.5), (.nlm, 1.0, 1.0)] {
        let o = Denoise.apply(m, stepNoisy, n, size: size, h: h, noise: sn)
        let e = rmse(o, stepClean), st = edgeStep(o)
        if e > 0.7 * base { errOK = false }
        if st < 0.7 * 30 { edgeOK = false }
        msg += String(format: " %@: rmse %.2f step %.1f;", m.rawValue, e, st)
    }
    let gs = edgeStep(Denoise.apply(.gaussian, stepNoisy, n, size: 1.5, h: 1, noise: sn))
    t.check(errOK, "median / bilateral / NL-means move a noisy step edge closer to the clean one (rmse < 0.7 × noisy \(String(format: "%.2f", base)))", msg)
    t.check(edgeOK && gs < 0.4 * 30, "median / bilateral / NL-means keep ≥ 70 % of a noisy 30-unit step, Gaussian σ 1.5 keeps < 40 %", msg + String(format: " gauss step %.1f", gs))

    // --- border padding: pixels farther than `pad` from the crop edge do not depend on what lies outside it
    let (big, _) = syntheticMicrograph(w: 200, h: 200, n: 4, dPx: 30, amp: 12, noise: 8, seed: 21)
    func crop(_ x0: Int, _ y0: Int, _ s: Int) -> [Float] {
        var o = [Float](repeating: 0, count: s * s)
        for j in 0..<s { for i in 0..<s { o[j * s + i] = big[(y0 + j) * 200 + x0 + i] } }
        return o
    }
    let A = crop(50, 50, 80), B = crop(30, 30, 120)           // B contains A, offset (20, 20)
    var padOK = true, padMsg = ""
    for (m, size, h) in [(SwipeDenoise.gaussian, 2.0, 1.0), (.median, 2.0, 1.0), (.bilateral, 2.0, 1.5), (.nlm, 1.0, 1.0)] {
        let p = Denoise.pad(m, size: size)
        let a = Denoise.apply(m, A, 80, size: size, h: h, noise: 8), b = Denoise.apply(m, B, 120, size: size, h: h, noise: 8)
        var worst: Float = 0
        for j in p..<(80 - p) { for i in p..<(80 - p) { worst = max(worst, abs(a[j * 80 + i] - b[(j + 20) * 120 + i + 20])) } }
        if worst > 1e-3 { padOK = false; padMsg += " \(m.rawValue) \(worst)" }
    }
    t.check(padOK, "border padding is wide enough for every method", padMsg)

    // --- tone window
    let d0 = SwipeDisplay()
    let w0 = d0.window(base: (100, 200))
    t.check(w0.lo == 100 && w0.hi == 200 && d0.toneIsDefault, "default display leaves the window unchanged")
    var d1 = d0; d1.brightness = 0.2
    let w1 = d1.window(base: (100, 200))
    t.check(abs(w1.lo - 80) < 1e-4 && abs(w1.hi - 180) < 1e-4, "brightness +0.2 moves the window down by 20 % of its width (image brighter)", "\(w1)")
    var d2 = d0; d2.contrast = 2
    let w2 = d2.window(base: (100, 200))
    t.check(abs(w2.lo - 125) < 1e-4 && abs(w2.hi - 175) < 1e-4, "contrast ×2 halves the window around its centre", "\(w2)")
    let ramp: [Float] = (0..<64 * 64).map { Float($0 % 64) }
    let rp = CardPlate.make(pixels: ramp, width: 64, height: 64, cx: 32, cy: 32, boxPx: 32, out: 32, denoise: .none, size: 1, h: 1)
    let plain = rp.render(out: 32, lo: 16, hi: 48), inv = rp.render(out: 32, lo: 16, hi: 48, invert: true)
    t.check(zip(plain, inv).allSatisfy { abs(Int($0) + Int($1) - 255) <= 1 }, "invert flips the gray scale")
    let br = rp.render(out: 32, lo: 6, hi: 38)                            // window moved down = brighter
    t.check(zip(br, plain).allSatisfy { $0 >= $1 } && br != plain, "a lower window gives a brighter image")
    let gm = rp.render(out: 32, lo: 16, hi: 48, gamma: 2)
    t.check(zip(gm, plain).allSatisfy { $0 <= $1 } && gm != plain, "gamma > 1 darkens midtones")
    let lw = rp.localWindow()
    t.check(lw.lo >= 15 && lw.lo <= 17.5 && lw.hi >= 46 && lw.hi <= 48.5, "this-card window is the 0.5–99.5 % range of the crop", "\(lw)")

    // --- true pixels (nearest) shows image pixels as constant blocks
    var chk = [Float](repeating: 0, count: 8 * 8)
    for y in 0..<8 { for x in 0..<8 { chk[y * 8 + x] = Float((x + y) % 2 == 0 ? 10 : 90) } }
    let cp = CardPlate.make(pixels: chk, width: 8, height: 8, cx: 3.5, cy: 3.5, boxPx: 8, out: 32, denoise: .none, size: 1, h: 1)
    let nb = cp.render(out: 32, lo: 0, hi: 100, nearest: true), bb = cp.render(out: 32, lo: 0, hi: 100)
    var blocks = true
    for by in 0..<8 { for bx in 0..<8 {
        let v = nb[(by * 4 + 1) * 32 + bx * 4 + 1]
        for j in 0..<4 { for i in 0..<4 where nb[(by * 4 + j) * 32 + bx * 4 + i] != v { blocks = false } }
    } }
    t.check(blocks && Set(nb).count == 2 && Set(bb).count > 2, "true-pixel mode gives 4×4 blocks with two gray levels; bilinear interpolates")

    // --- what is on the badge / log
    t.check(d0.processingTitle(pixelA: 6.6, useAngstroms: false) == "RAW" && d0.logTag == "raw", "raw display is labelled RAW", d0.logTag)
    var dg = d0; dg.select(.gaussian)
    t.check(dg.processingTitle(pixelA: 6.6, useAngstroms: true) == "DENOISED · Gaussian σ 1.5 px (9.9 Å)" && dg.logTag == "gauss(1.5)", "Gaussian badge and log tag", dg.processingTitle(pixelA: 6.6, useAngstroms: true))
    var dn = d0; dn.select(.nlm); dn.brightness = 0.1; dn.invert = true
    t.check(dn.processingTitle(pixelA: nil, useAngstroms: false).hasPrefix("DENOISED · non-local means") && dn.logTag == "nlm(1.0) b+0.10 c1.00 g1.00 inv", "NL-means tag carries the tone changes", dn.logTag)
    var dm = d0; dm.select(.median)
    t.check(dm.processingTitle(pixelA: nil, useAngstroms: false) == "DENOISED · median 3×3 px", "median badge", dm.processingTitle(pixelA: nil, useAngstroms: false))
    t.check(swipeResampleNote(boxPx: 68, out: 460, pixelated: false) == "6.8× enlarged, bilinear" && swipeResampleNote(boxPx: 460, out: 460, pixelated: true) == "≈ 1:1"
            && swipeResampleNote(boxPx: 920, out: 460, pixelated: false) == "downsampled 2.0× (anti-aliased)", "resample note")
    t.check(d0.toneSummary() == "window: whole micrograph" && dn.toneSummary().contains("brightness +0.10") && dn.toneSummary().contains("inverted"), "tone summary lists only what was changed", dn.toneSummary())

    // --- session: display state, revert on new card, pinning, log
    let dir = testTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let c = PickController(); c.store.saveDelay = 0; c.store.openProject(folder: dir)
    let (m1, _) = syntheticMicrograph(w: 1024, h: 1024, n: 12, dPx: 40, amp: 12, noise: 8, seed: 41)
    c.pixels = m1; c.setMicrograph(key: "m.mrc", width: 1024, height: 1024, pixelSizeA: 5)
    var pr = c.store.project.params; pr.diameterNm = 20; c.store.setParams(pr)
    c.autoParams.zThreshold = 4; c.runAutoPick(synchronous: true)
    let sw = c.swipe
    sw.decoyRate = 0; sw.rebuild()
    let k = "m.mrc"
    let rawImg = sw.cardImage(out: 200)
    sw.display.select(.gaussian)
    let dnImg = sw.cardImage(out: 200)
    t.check(rawImg != nil && dnImg != nil && rawImg != dnImg, "denoised card image differs from the raw one")
    let again = sw.cardImage(out: 200)
    t.check(again == dnImg, "card image is stable between calls (cache)")
    sw.display.brightness = 0.3
    let br2 = sw.cardImage(out: 200)!
    t.check(zip(br2, dnImg!).allSatisfy { $0 >= $1 } && br2 != dnImg!, "brightness slider brightens the cached denoised card")
    sw.accept()
    let d = c.store.record(k).swipe!.decisions.last!
    t.check(d.view == "gauss(1.5) b+0.30 c1.00 g1.00", "decision stores what the card looked like", d.view ?? "nil")
    t.check(sw.display.denoise == .none && sw.display.brightness == 0.3, "next card starts raw; brightness carries over", "\(sw.display.denoise) \(sw.display.brightness)")
    sw.toggleDenoise()
    t.check(sw.display.denoise == .gaussian, "V toggles back to the last method")
    sw.toggleDenoise(); t.check(sw.display.denoise == .none, "V again: raw")
    sw.pinProcessing = true; sw.toggleDenoise()
    sw.reject()
    t.check(sw.display.denoise == .gaussian, "pinned: denoising stays on for the next card")
    sw.later()
    t.check(sw.display.denoise == .gaussian, "pinned: stays on after Later")
    sw.pinProcessing = false; sw.undo(); sw.undo()
    t.check(sw.display.denoise == .none, "unpinned: undo also returns to raw")
    sw.display.resetTone()
    t.check(sw.display.toneIsDefault, "reset display")
    sw.display.select(.nlm); sw.accept()
    let files = PickExporter.swipeFiles(project: c.store.project)
    let csv = files.first { $0.name == "swipe_decisions.csv" }?.text ?? ""
    let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
    t.check(lines.count >= 3 && lines[1].contains("gauss(1.5) b+0.30 c1.00 g1.00"), "csv display column holds the tag", lines.count > 1 ? lines[1] : "")
    t.check(lines.last?.hasSuffix(",nlm(1.0),swipe") == true, "csv records NL-means for the last card", lines.last ?? "")
    let oldJSON = Data(#"{"id":"a","decision":"pick","x":1,"y":2}"#.utf8)
    t.check((try? JSONDecoder().decode(SwipeDecision.self, from: oldJSON)).map { $0.view == nil } == true, "decisions logged before this feature still load")
    c.store.save()
    let c2 = PickStore(); c2.openProject(folder: dir)
    t.check(c2.project.mics[k]?.swipe?.decisions.first?.view == "gauss(1.5) b+0.30 c1.00 g1.00", "display tag survives save/load")
}
