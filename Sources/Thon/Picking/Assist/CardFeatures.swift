import Foundation

/// Hand-made description of the crop around a candidate, used by the swipe assistant.
///
/// The crop is 2.5 particle diameters wide, resampled to 24 x 24, background-subtracted (median of its outer ring) and
/// scaled by its own robust noise level, so a feature vector does not depend on a micrograph's gain or offset.
/// Contents: radial profile (10) | nine summary numbers | an 8 x 8 thumbnail (64).
/// The summary numbers carry what separates a particle from a stain puddle or a clump: bright core against surround,
/// roundness (spread between angular sectors), and how far the bright mass sits from the centre.
enum CardFeatures {
    static let version = 1
    static let grid = 24
    static let radialBins = 10
    static let summaryCount = 9
    static let thumb = 8
    static var handLength: Int { radialBins + summaryCount + thumb * thumb }

    @inline(__always)
    static func bilinear(_ p: [Float], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Float {
        let xc = min(max(x, 0), Double(w - 1)), yc = min(max(y, 0), Double(h - 1))
        let x0 = Int(xc), y0 = Int(yc), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let fx = Float(xc - Double(x0)), fy = Float(yc - Double(y0))
        let a = p[y0 * w + x0], b = p[y0 * w + x1], c = p[y1 * w + x0], d = p[y1 * w + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    static func median(_ v: [Float]) -> Float {
        if v.isEmpty { return 0 }
        let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    /// `cx`, `cy` in pick coordinates (array indices, pixel centre = integer). nil when the input is unusable.
    static func hand(pixels: [Float], width: Int, height: Int, cx: Double, cy: Double, diameterPx: Double) -> [Float]? {
        guard width > 4, height > 4, pixels.count >= width * height, diameterPx > 2, cx.isFinite, cy.isFinite else { return nil }
        let n = grid, half = 1.25 * diameterPx, step = 2 * half / Double(n)
        var g = [Float](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n {
            var s: Float = 0
            for sj in 0..<2 { for si in 0..<2 {
                s += bilinear(pixels, width, height, cx - half + (Double(i) + 0.25 + 0.5 * Double(si)) * step,
                              cy - half + (Double(j) + 0.25 + 0.5 * Double(sj)) * step)
            } }
            g[j * n + i] = s / 4
        } }
        // radius (0 = centre, 1 = the crop's inscribed circle) and angle of every cell
        var rad = [Float](repeating: 0, count: n * n), ang = [Float](repeating: 0, count: n * n)
        let c0 = Float(n) / 2
        for j in 0..<n { for i in 0..<n {
            let dx = Float(i) + 0.5 - c0, dy = Float(j) + 0.5 - c0
            rad[j * n + i] = (dx * dx + dy * dy).squareRoot() / c0
            ang[j * n + i] = atan2f(dy, dx)
        } }
        var ringVals: [Float] = []
        for k in 0..<(n * n) where rad[k] >= 0.8 && rad[k] < 1 { ringVals.append(g[k]) }
        let bg = median(ringVals)
        let mad = median(g.map { abs($0 - median(g)) })
        var sigma = 1.4826 * mad
        if !(sigma > 1e-9) { sigma = max(1e-6, (g.map { abs($0 - bg) }.max() ?? 0) * 0.1) }
        var z = g.map { max(-6, min(6, ($0 - bg) / sigma)) }
        if z.contains(where: { !$0.isFinite }) { z = z.map { $0.isFinite ? $0 : 0 } }

        // radial profile
        var sum = [Float](repeating: 0, count: radialBins), cnt = [Float](repeating: 0, count: radialBins)
        for k in 0..<(n * n) where rad[k] < 1 { let b = min(radialBins - 1, Int(rad[k] * Float(radialBins))); sum[b] += z[k]; cnt[b] += 1 }
        let profile = (0..<radialBins).map { cnt[$0] > 0 ? sum[$0] / cnt[$0] : 0 }

        func mean(_ sel: (Int) -> Bool) -> Float {
            var s: Float = 0, c: Float = 0
            for k in 0..<(n * n) where sel(k) { s += z[k]; c += 1 }
            return c > 0 ? s / c : 0
        }
        func std(_ sel: (Int) -> Bool) -> Float {
            let m = mean(sel); var s: Float = 0, c: Float = 0
            for k in 0..<(n * n) where sel(k) { s += (z[k] - m) * (z[k] - m); c += 1 }
            return c > 1 ? (s / c).squareRoot() : 0
        }
        let core = mean { rad[$0] < 0.4 }, ringM = mean { rad[$0] >= 0.4 && rad[$0] < 0.8 }, outM = mean { rad[$0] >= 0.8 && rad[$0] < 1 }
        // sector spread: 8 angular sectors of the body ring; a round particle has equal sectors, a clump or an edge does not
        var secSum = [Float](repeating: 0, count: 8), secCnt = [Float](repeating: 0, count: 8)
        for k in 0..<(n * n) where rad[k] >= 0.3 && rad[k] < 0.8 {
            let s = min(7, Int((ang[k] + Float.pi) / (2 * Float.pi) * 8)); secSum[s] += z[k]; secCnt[s] += 1
        }
        let secMeans = (0..<8).map { secCnt[$0] > 0 ? secSum[$0] / secCnt[$0] : 0 }
        let sm = secMeans.reduce(0, +) / 8
        let sectorSpread = ((secMeans.map { ($0 - sm) * ($0 - sm) }.reduce(0, +)) / 8).squareRoot()
        // centroid of the positive signal inside the body, in units of the body radius (0 = centred)
        var wsum: Float = 0, mx: Float = 0, my: Float = 0, peak: Float = -6
        for j in 0..<n { for i in 0..<n where rad[j * n + i] < 0.8 {
            let v = z[j * n + i]; peak = max(peak, v)
            if v > 0 { wsum += v; mx += v * (Float(i) + 0.5 - c0) / c0; my += v * (Float(j) + 0.5 - c0) / c0 }
        } }
        let offset = wsum > 0 ? ((mx / wsum) * (mx / wsum) + (my / wsum) * (my / wsum)).squareRoot() / 0.8 : 1
        let summary: [Float] = [core, ringM, outM, core - outM, std { rad[$0] < 0.4 }, std { rad[$0] < 1 }, sectorSpread, offset, peak]

        // 8 x 8 thumbnail (3 x 3 means of the 24 x 24 grid)
        var thumbV = [Float](repeating: 0, count: thumb * thumb)
        let f = n / thumb
        for tj in 0..<thumb { for ti in 0..<thumb {
            var s: Float = 0
            for a in 0..<f { for b in 0..<f { s += z[(tj * f + a) * n + ti * f + b] } }
            thumbV[tj * thumb + ti] = s / Float(f * f)
        } }
        return profile + summary + thumbV
    }
}
