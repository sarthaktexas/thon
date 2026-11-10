import Foundation

// MARK: - CTF model and fit (display / diagnostics only; nothing here modifies the image data)

struct CTFParams: Equatable {
    var voltageKV = 120.0
    var csMM = 2.7
    var ampContrast = 0.10          // negative stain is usually 0.1 – 0.2; cryo ~0.07
    var minResA = 120.0             // low-resolution limit of the fit (Å)
    var maxResA = 15.0              // high-resolution limit of the fit (Å); clipped to 2.2 × pixel size
}

struct CTFFit {
    var df1: Double                 // Å, larger defocus (underfocus positive)
    var df2: Double                 // Å, smaller defocus
    var astigRad: Double            // direction of df1 axis in FFT array coordinates (x right, y down), [0, π)
    var cc: Double                  // Pearson correlation between model CTF² and flattened spectrum inside the fit annulus
    var params: CTFParams
    var n: Int
    var pixelSizeA: Double
    var rMin: Int, rMax: Int        // fit annulus in FFT pixels
    var radData: [Float]            // ring-averaged flattened spectrum (z-score), index = radius in FFT px
    var radModel: [Float]           // ring-averaged model CTF² (z-score) with the fitted astigmatism

    var meanDefocusUm: Double { (df1 + df2) / 2e4 }
    var astigA: Double { df1 - df2 }
    var astigDeg: Double { astigRad * 180 / .pi }
    var lambdaA: Double { ctfWavelengthA(kV: params.voltageKV) }

    func defocus(theta: Double) -> Double { 0.5 * (df1 + df2) + 0.5 * (df1 - df2) * cos(2 * (theta - astigRad)) }

    /// CTF² at spatial frequency k (1/Å) and in-plane angle theta.
    func power(k: Double, theta: Double) -> Double {
        ctfPower(k2: k * k, df: defocus(theta: theta), lambda: lambdaA, csA: params.csMM * 1e7, psi: asin(params.ampContrast))
    }

    /// Spatial frequency (1/Å) of the first CTF zero along the mean defocus (a handy sanity number).
    var summary: String {
        String(format: "defocus %.3f / %.3f µm   astigmatism %.0f Å at %.0f°   CC %.2f", df1 / 1e4, df2 / 1e4, astigA, astigDeg, cc)
    }
}

/// Electron wavelength in Å for an accelerating voltage in kV (relativistic).
func ctfWavelengthA(kV: Double) -> Double {
    let v = kV * 1000
    return 12.2643 / (v * (1 + 0.978466e-6 * v)).squareRoot()
}

/// CTF² = sin²(χ + ψ), χ = π λ Δf k² − ½ π Cs λ³ k⁴, ψ = asin(A).
@inline(__always)
func ctfPower(k2: Double, df: Double, lambda: Double, csA: Double, psi: Double) -> Double {
    let chi = Double.pi * lambda * df * k2 - 0.5 * Double.pi * csA * lambda * lambda * lambda * k2 * k2
    let s = sin(chi + psi)
    return s * s
}

private struct CTFPoint { var k2: Float; var c2: Float; var s2: Float; var z: Float }

/// Fit defocus, astigmatism and axis to the flattened (ring-preserving) power spectrum.
/// Stage 1 scans the ring-averaged profile for the defocus (a few candidates); stage 2 refines
/// mean defocus, astigmatism and angle on the 2-D spectrum by pattern search.
func fitCTF(ps: PowerSpectrum, pixelSizeA pa: Double, params: CTFParams) -> CTFFit? {
    let n = ps.n, h = n / 2
    let nyqLimit = 2.2 * pa
    let maxRes = max(params.maxResA, nyqLimit)
    var rMin = max(4, Int((Double(n) * pa / params.minResA).rounded()))
    let rMax = min(h - 2, Int((Double(n) * pa / maxRes).rounded()))
    if rMin >= rMax - 8 { rMin = max(2, rMax - 40) }
    guard rMax - rMin >= 8, params.ampContrast >= 0, params.ampContrast < 1 else { return nil }
    let lam = ctfWavelengthA(kV: params.voltageKV), csA = params.csMM * 1e7, psi = asin(params.ampContrast)
    let kPerPx = 1 / (Double(n) * pa)

    // all pixels in the annulus
    var all: [CTFPoint] = []
    all.reserveCapacity(Int(Double.pi * Double((rMax + 1) * (rMax + 1) - rMin * rMin)))
    var sum = 0.0, sum2 = 0.0
    let r2lo = Double(rMin * rMin), r2hi = Double((rMax + 1) * (rMax + 1))
    for y in 0..<n {
        let dy = Double(y - h)
        for x in 0..<n {
            let dx = Double(x - h)
            let r2 = dx * dx + dy * dy
            guard r2 >= r2lo, r2 < r2hi else { continue }
            let th = atan2(dy, dx)
            let v = ps.normPower[y * n + x]
            all.append(CTFPoint(k2: Float(r2 * kPerPx * kPerPx), c2: Float(cos(2 * th)), s2: Float(sin(2 * th)), z: v))
            sum += Double(v); sum2 += Double(v) * Double(v)
        }
    }
    guard all.count > 500 else { return nil }
    let mu = sum / Double(all.count)
    let sd = max((sum2 / Double(all.count) - mu * mu).squareRoot(), 1e-9)
    for i in 0..<all.count { all[i].z = Float((Double(all[i].z) - mu) / sd) }

    // Ring-averaged helpers. The flattened spectrum still carries a broad halo, so the fit compares only ring
    // oscillations: data and model are both high-passed with a radial moving average.
    func ringStats(_ pts: [CTFPoint]) -> (mean: [Double], cnt: [Double]) {
        var rs = [Double](repeating: 0, count: h + 1), rc = [Double](repeating: 0, count: h + 1)
        for p in pts { let r = min(h, Int(Double(p.k2).squareRoot() / kPerPx + 0.5)); rs[r] += Double(p.z); rc[r] += 1 }
        return ((0...h).map { rc[$0] > 0 ? rs[$0] / rc[$0] : 0 }, rc)
    }
    /// Moving average (±w) over rMin...rMax of v, weights wt.
    func movingAverage(_ v: [Double], _ wt: [Double], _ w: Int) -> [Double] {
        var cs = [Double](repeating: 0, count: h + 2), cw = [Double](repeating: 0, count: h + 2)
        for r in 0...h { cs[r + 1] = cs[r] + v[r] * wt[r]; cw[r + 1] = cw[r] + wt[r] }
        return (0...h).map { r in
            let lo = max(rMin, r - w), hi = min(rMax, r + w)
            guard hi >= lo, cw[hi + 1] - cw[lo] > 0 else { return 0 }
            return (cs[hi + 1] - cs[lo]) / (cw[hi + 1] - cw[lo])
        }
    }
    func highpass(_ pts: [CTFPoint], w: Int) -> [CTFPoint] {
        let (mean, cnt) = ringStats(pts)
        let tr = movingAverage(mean, cnt, w)
        var out = pts, s1 = 0.0, s2 = 0.0
        for i in 0..<out.count {
            let r = min(h, Int(Double(out[i].k2).squareRoot() / kPerPx + 0.5))
            let v = Double(out[i].z) - tr[r]
            out[i].z = Float(v); s1 += v; s2 += v * v
        }
        let m1 = s1 / Double(out.count), sd1 = max((s2 / Double(out.count) - m1 * m1).squareRoot(), 1e-9)
        for i in 0..<out.count { out[i].z = Float((Double(out[i].z) - m1) / sd1) }
        return out
    }

    // stage 1: 1-D scan of mean defocus on the ring profile (weighted Pearson on high-passed data and model)
    let (rawMean, rcnt) = ringStats(all)
    let w1 = 16
    let trRaw = movingAverage(rawMean, rcnt, w1)
    let dHP = (0...h).map { rawMean[$0] - trRaw[$0] }
    var sw = 0.0, sdd = 0.0, sdm = 0.0
    for r in rMin...rMax { sw += rcnt[r]; sdm += rcnt[r] * dHP[r]; sdd += rcnt[r] * dHP[r] * dHP[r] }
    let dMean = sdm / sw, dVar = sdd / sw - dMean * dMean
    var m1d = [Double](repeating: 0, count: h + 1)
    func radialCC(_ df: Double) -> Double {
        for r in rMin...rMax { let k = Double(r) * kPerPx; m1d[r] = ctfPower(k2: k * k, df: df, lambda: lam, csA: csA, psi: psi) }
        let tr = movingAverage(m1d, rcnt, w1)
        var sm = 0.0, smm = 0.0, smd = 0.0
        for r in rMin...rMax {
            let m = m1d[r] - tr[r], wgt = rcnt[r]
            sm += wgt * m; smm += wgt * m * m; smd += wgt * m * dHP[r]
        }
        let mm = sm / sw, varM = smm / sw - mm * mm
        guard varM > 1e-12, dVar > 1e-12 else { return -1 }
        return (smd / sw - mm * dMean) / (varM.squareRoot() * dVar.squareRoot())
    }
    var scan: [(df: Double, cc: Double)] = []
    var df = 1000.0
    while df <= 600000 { scan.append((df, radialCC(df))); df += 100 }
    var peaks: [(df: Double, cc: Double)] = []
    for i in 1..<(scan.count - 1) where scan[i].cc > scan[i - 1].cc && scan[i].cc >= scan[i + 1].cc { peaks.append(scan[i]) }
    peaks.sort { $0.cc > $1.cc }
    var cands: [Double] = []
    for p in peaks { if cands.allSatisfy({ abs($0 - p.df) > max(1500, 0.05 * p.df) }) { cands.append(p.df) }; if cands.count == 3 { break } }
    if ProcessInfo.processInfo.environment["CTF_DEBUG"] != nil { print("stage-1 candidates:", peaks.prefix(6).map { String(format: "%.2fµm cc %.2f", $0.df / 1e4, $0.cc) }) }
    guard !cands.isEmpty else { return nil }

    // stage 2: 2-D refinement of (mean defocus, astigmatism, axis) with a high-pass window matched to the ring spacing
    func cc2d(_ pts: [CTFPoint], _ dfm: Double, _ a: Double, _ phi: Double) -> Double {
        guard dfm - abs(a) > 200 else { return -2 }
        let cp = a * cos(2 * phi), sp = a * sin(2 * phi)
        var sm = 0.0, smm = 0.0, smz = 0.0, sz = 0.0
        for p in pts {
            let d = dfm + cp * Double(p.c2) + sp * Double(p.s2)
            let m = ctfPower(k2: Double(p.k2), df: d, lambda: lam, csA: csA, psi: psi)
            let z = Double(p.z)
            sm += m; smm += m * m; smz += m * z; sz += z
        }
        let N = Double(pts.count), mm = sm / N, varM = smm / N - mm * mm
        guard varM > 1e-12 else { return -2 }
        return (smz / N - mm * (sz / N)) / varM.squareRoot()     // z has unit variance
    }
    func refine(_ pts: [CTFPoint], dfm0: Double, a0: Double, phi0: Double, steps0: (Double, Double, Double)) -> (x: (Double, Double, Double), cc: Double) {
        var x = (dfm0, a0, phi0), best = cc2d(pts, x.0, x.1, x.2)
        var st = steps0
        var iter = 0
        while st.0 > 4 && iter < 200 {
            iter += 1
            var improved = false
            for (dd, da, dp) in [(st.0, 0, 0), (-st.0, 0, 0), (0, st.1, 0), (0, -st.1, 0), (0, 0, st.2), (0, 0, -st.2)] as [(Double, Double, Double)] {
                var cand = (x.0 + dd, x.1 + da, x.2 + dp)
                if cand.1 < 0 { cand.1 = -cand.1; cand.2 += .pi / 2 }
                cand.2 = cand.2.truncatingRemainder(dividingBy: .pi); if cand.2 < 0 { cand.2 += .pi }
                let c = cc2d(pts, cand.0, cand.1, cand.2)
                if c > best + 1e-6 { best = c; x = cand; improved = true }
            }
            if !improved { st = (st.0 / 2, st.1 / 2, st.2 / 2) }
        }
        return (x, best)
    }
    var x = (cands[0], 0.0, 0.0), xCC = -2.0, xW = w1
    let pts16 = highpass(all, w: w1)
    var xPts: [CTFPoint] = []
    for c in cands {
        let rMid = Double(rMin + rMax) / 2
        let spacing = (Double(n) * pa) * (Double(n) * pa) / (2 * rMid * lam * c)       // ring spacing in FFT px at mid radius
        let w = min(64, max(8, Int(spacing.rounded())))
        let pts = highpass(all, w: w)
        var sub: [CTFPoint] = []
        var i = 0
        while i < pts.count { sub.append(pts[i]); i += 3 }
        let ds = max(200, 0.01 * c), asz = max(100, 0.006 * c)           // search steps scale with defocus
        var bestX = (c, 0.0, 0.0), bestCC = -2.0
        let r0 = refine(sub, dfm0: c, a0: 0, phi0: 0, steps0: (ds, asz, 0.2))
        if r0.cc > bestCC { bestCC = r0.cc; bestX = r0.x }
        for k in 0..<4 {
            let r = refine(sub, dfm0: c, a0: 3 * asz, phi0: Double(k) * .pi / 4, steps0: (ds, 1.5 * asz, 0.25))
            if r.cc > bestCC { bestCC = r.cc; bestX = r.x }
        }
        let fin = refine(pts, dfm0: bestX.0, a0: bestX.1, phi0: bestX.2, steps0: (max(20, 0.002 * bestX.0), max(20, 0.002 * bestX.0), 0.03))
        // candidates are ranked under one common high-pass (±16 px) so a broad-halo match at small defocus cannot win by construction
        let score = cc2d(pts16, fin.x.0, fin.x.1, fin.x.2)
        if score > xCC { xCC = score; x = fin.x; xW = w; xPts = pts }
    }
    _ = xW
    // Astigmatism is only kept if it improves the ring-scale correlation noticeably; otherwise fit a single defocus.
    do {
        let r0 = refine(xPts, dfm0: x.0, a0: 0, phi0: 0, steps0: (max(20, 0.002 * x.0), 0, 0))
        let cc0 = cc2d(pts16, r0.x.0, 0, 0)
        if xCC - cc0 < 0.02 { x = (r0.x.0, 0, 0); xCC = cc0 }
    }
    let fin = (x: x, cc: xCC)
    let radData = ringStats(xPts).mean

    // ring-averaged model for the diagnostic chart (same astigmatism, same pixels)
    var msum = [Double](repeating: 0, count: h + 1)
    var mAll = 0.0, mAll2 = 0.0
    var cnt = 0.0
    var rcount = [Double](repeating: 0, count: h + 1)
    let cp = x.1 * cos(2 * x.2), sp = x.1 * sin(2 * x.2)
    for y in 0..<n {
        let dy = Double(y - h)
        for xx in 0..<n {
            let dx = Double(xx - h)
            let r2 = dx * dx + dy * dy
            guard r2 >= r2lo, r2 < r2hi else { continue }
            let th = atan2(dy, dx)
            let d = x.0 + cp * cos(2 * th) + sp * sin(2 * th)
            let m = ctfPower(k2: r2 * kPerPx * kPerPx, df: d, lambda: lam, csA: csA, psi: psi)
            let r = Int(r2.squareRoot() + 0.5)
            if r <= h { msum[r] += m; rcount[r] += 1 }
            mAll += m; mAll2 += m * m; cnt += 1
        }
    }
    let mMean = mAll / cnt, mStd = max((mAll2 / cnt - mMean * mMean).squareRoot(), 1e-9)
    // scale the model curve to the amplitude of the ring-averaged data (least squares) so the two overlay in the chart
    var num = 0.0, den = 0.0
    for r in rMin...rMax where rcount[r] > 0 {
        let mz = (msum[r] / rcount[r] - mMean) / mStd
        num += radData[r] * mz; den += mz * mz
    }
    let amp = den > 0 ? max(num / den, 0) : 1
    let radModel: [Float] = (0...h).map { rcount[$0] > 0 ? Float(amp * (msum[$0] / rcount[$0] - mMean) / mStd) : 0 }

    if ProcessInfo.processInfo.environment["CTF_DEBUG"] != nil {
        print(String(format: "  cc(full astig) %.3f   cc(a=0, same df) %.3f   w=%d", xCC, cc2d(pts16, x.0, 0, 0), xW))
    }
    var fit = CTFFit(df1: x.0 + x.1, df2: x.0 - x.1, astigRad: x.2, cc: fin.cc, params: params, n: n, pixelSizeA: pa,
                     rMin: rMin, rMax: rMax, radData: radData.map { Float($0) }, radModel: radModel)
    if fit.df2 > fit.df1 { swap(&fit.df1, &fit.df2) }
    return fit
}

/// Zero contours (k in 1/Å at each angle) of the fitted CTF, one polyline per zero order, for drawing on the spectrum.
func ctfZeroContours(_ fit: CTFFit, angles: Int = 120) -> [[(k: Double, theta: Double)]] {
    let lam = fit.lambdaA, csA = fit.params.csMM * 1e7, psi = asin(fit.params.ampContrast)
    let kPerPx = 1 / (Double(fit.n) * fit.pixelSizeA)
    let kLo = Double(fit.rMin) * kPerPx, kHi = Double(fit.rMax) * kPerPx
    let dk = kPerPx / 6
    var byOrder: [Int: [(Int, Double)]] = [:]
    for j in 0..<angles {
        let th = 2 * Double.pi * Double(j) / Double(angles)
        let d = fit.defocus(theta: th)
        func g(_ k: Double) -> Double {
            let k2 = k * k
            return (Double.pi * lam * d * k2 - 0.5 * Double.pi * csA * lam * lam * lam * k2 * k2 + psi) / Double.pi
        }
        var k = kLo, prev = g(k)
        while k < kHi {
            let kn = k + dk, cur = g(kn)
            if floor(cur) != floor(prev) {
                let m = Int(max(floor(cur), floor(prev)))
                let f = (Double(m) - prev) / (cur - prev)
                byOrder[m, default: []].append((j, k + f * dk))
            }
            k = kn; prev = cur
        }
    }
    var out: [[(k: Double, theta: Double)]] = []
    for m in byOrder.keys.sorted() {
        let pts = byOrder[m]!.sorted { $0.0 < $1.0 }
        var run: [(k: Double, theta: Double)] = []
        var last = -10
        for (j, k) in pts {
            if j != last + 1 && !run.isEmpty { if run.count >= 6 { out.append(run) }; run = [] }
            run.append((k: k, theta: 2 * Double.pi * Double(j) / Double(angles))); last = j
        }
        if run.count >= 6 { out.append(run) }
    }
    return out
}

// MARK: - tests

func testCTF(_ t: inout TestRun) {
    t.section("CTF fit")
    let n = 512, h = n / 2, pa = 6.6, kV = 120.0, cs = 2.7, ac = 0.1
    let lam = ctfWavelengthA(kV: kV)
    t.check(abs(lam - 0.03349) < 2e-4, "wavelength 120 kV", "\(lam)")
    let truth = (dfm: 17000.0, a: 1200.0, phi: 0.6)
    var rng = SystemRandomNumberGenerator()
    func gauss() -> Float {
        let u1 = Float.random(in: 1e-6..<1, using: &rng), u2 = Float.random(in: 0..<1, using: &rng)
        return (-2 * logf(u1)).squareRoot() * cosf(2 * .pi * u2)
    }
    var norm = [Float](repeating: 0, count: n * n)
    let kPerPx = 1 / (Double(n) * pa)
    for y in 0..<n { for x in 0..<n {
        let dx = Double(x - h), dy = Double(y - h)
        let k2 = (dx * dx + dy * dy) * kPerPx * kPerPx, th = atan2(dy, dx)
        let d = truth.dfm + truth.a * cos(2 * (th - truth.phi))
        norm[y * n + x] = Float(ctfPower(k2: k2, df: d, lambda: lam, csA: cs * 1e7, psi: asin(ac))) + 0.8 * gauss()
    } }
    let ps = PowerSpectrum(n: n, tiles: 1, logPower: norm, normPower: norm, profile: [Float](repeating: 1, count: h + 1), imageLog: nil, imageNorm: nil)
    var p = CTFParams(); p.voltageKV = kV; p.csMM = cs; p.ampContrast = ac
    if let f = fitCTF(ps: ps, pixelSizeA: pa, params: p) {
        t.check(abs(f.meanDefocusUm - 1.7) < 0.03, "synthetic mean defocus", f.summary)
        t.check(abs(f.astigA - 2400) < 250, "synthetic astigmatism", f.summary)
        var dphi = abs(f.astigRad - truth.phi); dphi = min(dphi, .pi - dphi)
        t.check(dphi < 0.1, "synthetic astigmatism axis", f.summary)
        t.check(f.cc > 0.12, "synthetic CC", f.summary)
        let zc = ctfZeroContours(f)
        t.check(zc.count >= 1, "zero contours", "\(zc.count) contours, lens \(zc.map { $0.count }), fit rMin \(f.rMin) rMax \(f.rMax)")
    } else { t.check(false, "synthetic CTF fit returned nil") }

    // large defocus (low-magnification / far-from-focus regime seen in stain data) on a coarse pixel size
    let pa2 = 11.0, t2 = (dfm: 150000.0, a: 6000.0, phi: 2.2), kp2 = 1 / (Double(n) * pa2)
    for y in 0..<n { for x in 0..<n {
        let dx = Double(x - h), dy = Double(y - h)
        let th = atan2(dy, dx)
        let d = t2.dfm + t2.a * cos(2 * (th - t2.phi))
        norm[y * n + x] = Float(ctfPower(k2: (dx * dx + dy * dy) * kp2 * kp2, df: d, lambda: lam, csA: cs * 1e7, psi: asin(ac))) + 0.8 * gauss()
    } }
    let ps2 = PowerSpectrum(n: n, tiles: 1, logPower: norm, normPower: norm, profile: [Float](repeating: 1, count: h + 1), imageLog: nil, imageNorm: nil)
    if let f = fitCTF(ps: ps2, pixelSizeA: pa2, params: p) {
        t.check(abs(f.meanDefocusUm - 15.0) < 0.3, "synthetic large defocus", f.summary)
        t.check(abs(f.astigA - 12000) < 2500, "synthetic large-defocus astigmatism", f.summary)
        t.check(ctfZeroContours(f).count >= 5, "zero contours (large defocus)")
    } else { t.check(false, "synthetic large-defocus fit returned nil") }
}
