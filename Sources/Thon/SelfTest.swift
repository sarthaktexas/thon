import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

// MARK: CPU references

private func cpuWeights(_ sigma: Double) -> [Float] {
    let r = max(1, min(Int((3.5 * sigma).rounded(.up)), 300))
    var w = (0...r).map { Float(exp(-0.5 * Double($0 * $0) / (sigma * sigma))) }
    let sum = w[0] + 2 * w.dropFirst().reduce(0, +)
    w = w.map { $0 / sum }
    return w
}

private func cpuGauss(_ a: [Float], _ W: Int, _ H: Int, sigma: Double) -> [Float] {
    let w = cpuWeights(sigma), r = w.count - 1
    var t = [Float](repeating: 0, count: W * H), o = t
    for y in 0..<H { for x in 0..<W {
        var s: Float = 0
        for k in -r...r { s += w[abs(k)] * a[y * W + min(max(x + k, 0), W - 1)] }
        t[y * W + x] = s
    } }
    for y in 0..<H { for x in 0..<W {
        var s: Float = 0
        for k in -r...r { s += w[abs(k)] * t[min(max(y + k, 0), H - 1) * W + x] }
        o[y * W + x] = s
    } }
    return o
}

private func cpuDown(_ a: [Float], _ W: Int, _ H: Int) -> ([Float], Int, Int) {
    let w2 = max(1, W >> 1), h2 = max(1, H >> 1)
    var o = [Float](repeating: 0, count: w2 * h2)
    for y in 0..<h2 { for x in 0..<w2 {
        func p(_ dx: Int, _ dy: Int) -> Float { a[min(2 * y + dy, H - 1) * W + min(2 * x + dx, W - 1)] }
        o[y * w2 + x] = (p(0, 0) + p(1, 0) + p(0, 1) + p(1, 1)) * 0.25
    } }
    return (o, w2, h2)
}

private func cpuFlatten(_ a: [Float], _ W: Int, _ H: Int, sigma fl: Double, mean: Double) -> [Float] {
    var l = 1; while min(W, H) >> l >= 64 { l += 1 }
    let k = max(1, min(Int(log2(max(fl, 4) / 4).rounded()), l - 1))
    var lev = a, lw = W, lh = H
    for _ in 0..<k { (lev, lw, lh) = cpuDown(lev, lw, lh) }
    let bg = cpuGauss(lev, lw, lh, sigma: max(1, fl / Double(1 << k)))
    let inv = Float(1.0 / Double(1 << k))
    var o = [Float](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W {
        let qx = (Float(x) + 0.5) * inv - 0.5, qy = (Float(y) + 0.5) * inv - 0.5
        let fx = qx - floor(qx), fy = qy - floor(qy)
        let x0 = min(max(Int(floor(qx)), 0), lw - 1), x1 = min(max(Int(floor(qx)) + 1, 0), lw - 1)
        let y0 = min(max(Int(floor(qy)), 0), lh - 1), y1 = min(max(Int(floor(qy)) + 1, 0), lh - 1)
        let b0 = bg[y0 * lw + x0] * (1 - fx) + bg[y0 * lw + x1] * fx
        let b1 = bg[y1 * lw + x0] * (1 - fx) + bg[y1 * lw + x1] * fx
        o[y * W + x] = a[y * W + x] - (b0 * (1 - fy) + b1 * fy) + Float(mean)
    } }
    return o
}

private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
    var m: Float = 0
    for i in 0..<min(a.count, b.count) { m = max(m, abs(a[i] - b[i])) }
    return m
}

// MARK: --selftest

func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print((ok ? "PASS " : "FAIL ") + name + "  " + detail)
        if !ok { failures += 1 }
    }
    guard let dev = MTLCreateSystemDefaultDevice() else { print("FAIL no Metal device available"); return 2 }
    print("Metal device:", dev.name, "| unified memory:", dev.hasUnifiedMemory)
    let vs = ViewState()
    let r: MicrographRenderer
    do { r = try MicrographRenderer(device: dev, pixelFormat: .bgra8Unorm, state: vs) }
    catch { print("FAIL", error.localizedDescription); return 1 }
    check("shader compile + pipeline creation", true, "")

    let W = 300, H = 200
    var seed: UInt32 = 12345
    var img = [Float](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W {
        seed = seed &* 1664525 &+ 1013904223
        img[y * W + x] = 1000 + 100 * sin(Float(x) * 0.07) + 0.8 * Float(y) + Float(seed >> 16) / 65536 * 50
    } }
    let mean = img.reduce(0.0) { $0 + Double($1) } / Double(img.count)
    r.setImage(width: W, height: H, pixels: img, mean: mean)
    vs.pendingFit = false

    r.waitIdle()
    check("upload / identity read-back", maxDiff(r.readProcessed() ?? [], img) == 0, "")

    vs.lowpassSigma = 2; r.reprocess()
    var d = maxDiff(r.readProcessed() ?? [], cpuGauss(img, W, H, sigma: 2))
    check("Gaussian low-pass σ=2 vs CPU", d < 1e-2, "max |Δ| = \(d)")

    vs.lowpassSigma = 0; vs.flattenSigma = 8; r.reprocess()
    d = maxDiff(r.readProcessed() ?? [], cpuFlatten(img, W, H, sigma: 8, mean: mean))
    check("background flatten σ=8 vs CPU", d < 1e-2, "max |Δ| = \(d)")

    vs.lowpassSigma = 0; vs.flattenSigma = 0; r.reprocess(); r.waitIdle()
    let lo = img.min()!, hi = img.max()!
    vs.lo = Double(lo); vs.hi = Double(hi); vs.gamma = 1; vs.invert = false
    func gray(_ v: Float) -> Int { Int((min(max((v - lo) / (hi - lo), 0), 1) * 255).rounded()) }

    vs.zoom = 3; vs.center = CGPoint(x: 150.5, y: 100.5)
    if let px = r.renderOffscreen(width: 64, height: 48) {
        let i = (24 * 64 + 32) * 4
        let want = gray(img[100 * W + 150])
        check("render nearest-neighbor (zoom 3)", abs(Int(px[i]) - want) <= 1 && abs(Int(px[i + 2]) - want) <= 1, "got \(px[i]) want \(want)")
    } else { check("render nearest-neighbor", false, "offscreen render failed") }

    vs.zoom = 3; vs.center = CGPoint(x: -50, y: -50)
    if let px = r.renderOffscreen(width: 64, height: 48) {
        check("render surround color outside image", abs(Int(px[0]) - 22) <= 1 && abs(Int(px[2]) - 19) <= 1, "BGR = \(px[0]),\(px[1]),\(px[2])")
    } else { check("render surround", false, "offscreen render failed") }

    vs.zoom = 0.5; vs.center = CGPoint(x: 150, y: 100)
    if let px = r.renderOffscreen(width: 64, height: 48) {
        let (l1, w1, _) = cpuDown(img, W, H)
        let want = gray(l1[50 * w1 + 75])
        let i = (24 * 64 + 32) * 4
        check("pyramid level 1 selection (zoom 0.5)", abs(Int(px[i]) - want) <= 1, "got \(px[i]) want \(want)")
    } else { check("render pyramid", false, "offscreen render failed") }

    vs.invert = true; vs.zoom = 3; vs.center = CGPoint(x: 150.5, y: 100.5)
    if let px = r.renderOffscreen(width: 64, height: 48) {
        let want = 255 - gray(img[100 * W + 150])
        check("invert", abs(Int(px[(24 * 64 + 32) * 4]) - want) <= 1, "got \(px[(24 * 64 + 32) * 4]) want \(want)")
    }
    print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
    return failures == 0 ? 0 : 1
}

// MARK: --render  FILE OUT.png [--lowpass S] [--flatten S] [--size WxH]

func runRender(_ args: [String]) -> Int32 {
    guard let ri = args.firstIndex(of: "--render"), args.count > ri + 2 else {
        print("usage: Thon --render FILE.dm4 OUT.png [--lowpass SIGMA] [--flatten SIGMA] [--size WxH] [--invert]"); return 2
    }
    func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard let dev = MTLCreateSystemDefaultDevice() else { print("No Metal device available"); return 2 }
    do {
        let doc = try LoadedExposure(url: URL(fileURLWithPath: args[ri + 1]), frame: 0)
        let vs = ViewState()
        let r = try MicrographRenderer(device: dev, pixelFormat: .bgra8Unorm, state: vs)
        vs.lowpassSigma = Double(opt("--lowpass") ?? "0") ?? 0
        vs.flattenSigma = Double(opt("--flatten") ?? "0") ?? 0
        vs.invert = args.contains("--invert")
        r.setImage(width: doc.entry.width, height: doc.entry.height, pixels: doc.pixels, mean: doc.stats.mean)
        let sz = (opt("--size") ?? "1600x1200").split(separator: "x").compactMap { Int($0) }
        let w = sz.count == 2 ? sz[0] : 1600, h = sz.count == 2 ? sz[1] : 1200
        vs.viewPixels = CGSize(width: w, height: h)
        vs.fit()
        let st = (vs.lowpassSigma > 0 || vs.flattenSigma > 0) ? ImageStats.compute(r.readProcessed() ?? doc.pixels) : doc.stats
        vs.displayStats = st; vs.applyAuto()
        guard let bgra = r.renderOffscreen(width: w, height: h) else { print("render failed"); return 1 }
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        guard let prov = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[ri + 2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { print("could not create PNG"); return 1 }
        CGImageDestinationAddImage(dest, img, nil)
        print(CGImageDestinationFinalize(dest) ? "wrote \(args[ri + 2]) (\(w)x\(h), lo=\(vs.lo), hi=\(vs.hi))" : "PNG write failed")
        return 0
    } catch { print("ERROR:", error.localizedDescription); return 1 }
}
