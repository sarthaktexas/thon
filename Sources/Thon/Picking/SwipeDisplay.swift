import Foundation
import CoreGraphics

// Display controls for swipe cards: brightness / contrast / gamma / invert and optional denoising,
// plus the text that says exactly what the card is showing (raw pixels vs. processed).
// Everything here is CPU-only and display-only: picks, coordinates and exports never use the processed pixels.

enum SwipeDenoise: String, CaseIterable, Identifiable {
    case none, gaussian, median, bilateral, nlm
    var id: String { rawValue }
    var menuName: String {
        switch self {
        case .none: return "Raw"
        case .gaussian: return "Gaussian"
        case .median: return "Median"
        case .bilateral: return "Bilateral"
        case .nlm: return "NL-means"
        }
    }
    var fullName: String {
        switch self {
        case .none: return "raw"
        case .gaussian: return "Gaussian blur"
        case .median: return "Median filter"
        case .bilateral: return "Bilateral filter"
        case .nlm: return "Non-local means"
        }
    }
    var usesSize: Bool { self == .gaussian || self == .median || self == .bilateral }
    var usesH: Bool { self == .bilateral || self == .nlm }
    var sizeRange: ClosedRange<Double> {
        switch self {
        case .median: return 1...3
        case .bilateral: return 1...4
        default: return 0.5...5
        }
    }
    var defaultSize: Double { self == .gaussian ? 1.5 : (self == .median ? 1 : (self == .bilateral ? 2 : 1)) }
    var defaultH: Double { self == .bilateral ? 1.5 : 1.0 }
}

enum SwipeTone: String, CaseIterable, Identifiable {
    case micrograph, local
    var id: String { rawValue }
    var menuName: String { self == .micrograph ? "Whole micrograph" : "This card" }
}

struct SwipeDisplay: Equatable {
    var denoise: SwipeDenoise = .none
    var size = 1.5                  // Gaussian σ (px) / median radius (px) / bilateral spatial σ (px)
    var h = 1.0                     // bilateral range σ and NL-means strength, in units of the estimated noise σ
    var tone: SwipeTone = .micrograph
    var brightness = 0.0            // -1...1, fraction of the window width; positive = brighter image
    var contrast = 1.0              // multiplier on the window (2 = twice the contrast)
    var gamma = 1.0
    var invert = false
    var pixelated = false           // nearest-neighbour: every source pixel is a visible block

    var isDenoised: Bool { denoise != .none }
    var toneIsDefault: Bool { tone == .micrograph && brightness == 0 && contrast == 1 && gamma == 1 && !invert }
    var medianRadius: Int { max(1, Int(size.rounded())) }

    mutating func select(_ m: SwipeDenoise) {
        denoise = m
        if m != .none { size = m.defaultSize; h = m.defaultH }
    }
    mutating func resetTone() { tone = .micrograph; brightness = 0; contrast = 1; gamma = 1; invert = false }

    /// Display window after brightness / contrast, starting from `base` (the window at brightness 0, contrast 1).
    func window(base: (lo: Float, hi: Float)) -> (lo: Float, hi: Float) {
        let span = max(base.hi - base.lo, 1e-12)
        let width = span / Float(max(contrast, 1e-3))
        let centre = (base.lo + base.hi) / 2 - Float(brightness) * span
        return (centre - width / 2, centre + width / 2)
    }

    /// First line of the on-card badge: what the pixels are.
    func processingTitle(pixelA: Double?, useAngstroms: Bool) -> String {
        switch denoise {
        case .none: return "RAW"
        case .gaussian:
            return "DENOISED · Gaussian σ \(String(format: "%.1f", size)) px" + lengthSuffix(size, pixelA, useAngstroms)
        case .median:
            let k = 2 * medianRadius + 1
            return "DENOISED · median \(k)×\(k) px"
        case .bilateral:
            return "DENOISED · bilateral σ \(String(format: "%.1f", size)) px, range \(String(format: "%.1f", h)) σn"
        case .nlm:
            return "DENOISED · non-local means h = \(String(format: "%.1f", h)) σn"
        }
    }
    private func lengthSuffix(_ px: Double, _ pixelA: Double?, _ useA: Bool) -> String {
        guard let a = pixelA else { return "" }
        return " (" + LengthUnits.format(angstroms: px * a, useAngstroms: useA) + ")"
    }

    /// Contrast part of the caption; "default window" when nothing was changed.
    func toneSummary() -> String {
        var parts = [tone == .micrograph ? "window: whole micrograph" : "window: this card"]
        if brightness != 0 { parts.append(String(format: "brightness %+.2f", brightness)) }
        if contrast != 1 { parts.append(String(format: "contrast ×%.2f", contrast)) }
        if gamma != 1 { parts.append(String(format: "γ %.2f", gamma)) }
        if invert { parts.append("inverted") }
        return parts.joined(separator: " · ")
    }

    /// Short machine-readable description stored with each swipe decision (`display` column of swipe_decisions.csv).
    var logTag: String {
        var s: String
        switch denoise {
        case .none: s = "raw"
        case .gaussian: s = String(format: "gauss(%.1f)", size)
        case .median: s = "median(\(medianRadius))"
        case .bilateral: s = String(format: "bilateral(%.1f,%.1f)", size, h)
        case .nlm: s = String(format: "nlm(%.1f)", h)
        }
        if !toneIsDefault {
            s += String(format: " b%+.2f c%.2f g%.2f", brightness, contrast, gamma)
            if invert { s += " inv" }
            if tone == .local { s += " local" }
        }
        if pixelated { s += " px" }
        return s
    }
}

/// How the crop is resampled to the card, for the caption ("5.3× enlarged, bilinear").
func swipeResampleNote(boxPx: Double, out: Int, pixelated: Bool) -> String {
    let scale = boxPx / Double(max(out, 1))          // source px per card px
    if scale < 0.95 {
        return String(format: "%.1f× enlarged, %@", 1 / scale, pixelated ? "pixelated (nearest)" : "bilinear")
    }
    if scale > 1.5 { return String(format: "downsampled %.1f× (anti-aliased)", scale) }
    return "≈ 1:1"
}

// MARK: filters

enum Denoise {
    /// Noise σ from the residual against the 4-neighbour mean (robust: median absolute deviation, so edges and particles barely count).
    /// For white noise var(residual) = 1.25 σ². Correlated noise (the detector MTF) makes this an underestimate.
    static func noiseSigma(_ a: [Float], _ w: Int, _ h: Int) -> Float {
        guard w > 2, h > 2 else { return 1e-6 }
        let total = (w - 2) * (h - 2)
        let step = max(1, total / 60_000)
        var r = [Float](); r.reserveCapacity(total / step + 1)
        var k = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                k += 1
                if k % step != 0 { continue }
                let i = y * w + x
                r.append(a[i] - 0.25 * (a[i - 1] + a[i + 1] + a[i - w] + a[i + w]))
            }
        }
        guard !r.isEmpty else { return 1e-6 }
        r.sort()
        let med = r[r.count / 2]
        var dev = r.map { abs($0 - med) }; dev.sort()
        return max(1.4826 * dev[dev.count / 2] / Float(1.25).squareRoot(), 1e-6)
    }

    static func median(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        let r = max(1, r), k = (2 * r + 1) * (2 * r + 1)
        var out = a
        var buf = [Float](repeating: 0, count: k)
        for y in 0..<h {
            for x in 0..<w {
                var c = 0
                for j in -r...r {
                    let row = min(max(y + j, 0), h - 1) * w
                    for i in -r...r { buf[c] = a[row + min(max(x + i, 0), w - 1)]; c += 1 }
                }
                buf.sort()
                out[y * w + x] = buf[k / 2]
            }
        }
        return out
    }

    static func bilateral(_ a: [Float], _ w: Int, _ h: Int, sigmaS: Double, sigmaR: Float) -> [Float] {
        let r = max(1, Int((2 * sigmaS).rounded(.up)))
        var sp = [Float](repeating: 0, count: (2 * r + 1) * (2 * r + 1))
        for j in -r...r { for i in -r...r { sp[(j + r) * (2 * r + 1) + i + r] = Float(exp(-0.5 * Double(i * i + j * j) / (sigmaS * sigmaS))) } }
        let inv2r = 1 / (2 * max(sigmaR, 1e-9) * max(sigmaR, 1e-9))
        var out = a
        for y in 0..<h {
            for x in 0..<w {
                let c = a[y * w + x]
                var s: Float = 0, ws: Float = 0
                for j in -r...r {
                    let row = min(max(y + j, 0), h - 1) * w
                    for i in -r...r {
                        let v = a[row + min(max(x + i, 0), w - 1)]
                        let d = v - c
                        let wt = sp[(j + r) * (2 * r + 1) + i + r] * exp(-d * d * inv2r)
                        s += wt * v; ws += wt
                    }
                }
                out[y * w + x] = s / ws
            }
        }
        return out
    }

    /// Non-local means, 3x3 patches, (2s+1)² search window; patch distances by shifted-difference images.
    /// Weight exp(-max(d² − 2σ², 0) / (hσ)²) for patch mean-squared distance d²; the centre pixel gets the largest weight seen.
    static func nlm(_ a: [Float], _ w: Int, _ h: Int, hFactor: Float, sigma: Float, search s: Int = 5) -> [Float] {
        let n = w * h
        var acc = [Float](repeating: 0, count: n), wsum = acc, wmax = acc
        var d = acc, tmp = acc
        let hh = max(hFactor * sigma, 1e-6), h2 = hh * hh, s2 = 2 * sigma * sigma
        for dy in -s...s {
            for dx in -s...s {
                if dx == 0 && dy == 0 { continue }
                for y in 0..<h {
                    let yq = min(max(y + dy, 0), h - 1)
                    for x in 0..<w {
                        let t = a[y * w + x] - a[yq * w + min(max(x + dx, 0), w - 1)]
                        d[y * w + x] = t * t
                    }
                }
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w { tmp[row + x] = d[row + max(x - 1, 0)] + d[row + x] + d[row + min(x + 1, w - 1)] }
                }
                for y in 0..<h {
                    let ym = max(y - 1, 0) * w, y0 = y * w, yp = min(y + 1, h - 1) * w
                    let yq = min(max(y + dy, 0), h - 1)
                    for x in 0..<w {
                        let dist = (tmp[ym + x] + tmp[y0 + x] + tmp[yp + x]) / 9
                        let wt = exp(-max(dist - s2, 0) / h2)
                        let i = y0 + x
                        acc[i] += wt * a[yq * w + min(max(x + dx, 0), w - 1)]
                        wsum[i] += wt
                        if wt > wmax[i] { wmax[i] = wt }
                    }
                }
            }
        }
        var out = a
        for i in 0..<n {
            let wc = wmax[i] > 0 ? wmax[i] : 1
            out[i] = (acc[i] + wc * a[i]) / (wsum[i] + wc)
        }
        return out
    }

    /// Extra border (source px) a method needs around the visible crop so that the crop itself is free of edge effects.
    static func pad(_ m: SwipeDenoise, size: Double) -> Int {
        switch m {
        case .none: return 0
        case .gaussian: return Int((3.5 * size).rounded(.up)) + 1
        case .median: return max(1, Int(size.rounded())) + 1
        case .bilateral: return max(1, Int((2 * size).rounded(.up))) + 1
        case .nlm: return 7
        }
    }

    static func apply(_ m: SwipeDenoise, _ region: [Float], _ n: Int, size: Double, h: Double, noise: Float) -> [Float] {
        switch m {
        case .none: return region
        case .gaussian: return AutoPicker.gaussianBlur(region, n, n, sigma: size)
        case .median: return median(region, n, n, radius: max(1, Int(size.rounded())))
        case .bilateral: return bilateral(region, n, n, sigmaS: size, sigmaR: Float(h) * noise)
        case .nlm: return nlm(region, n, n, hFactor: Float(h), sigma: noise, search: n * n > 400_000 ? 3 : 5)
        }
    }
}

// MARK: card rendering

/// A crop around a card centre with the denoising and the anti-alias blur already applied (floats, source resolution).
/// Tone mapping (window, gamma, invert) and resampling are cheap and done per `render`, so brightness / contrast
/// sliders do not re-run a denoiser.
struct CardPlate {
    let region: [Float]
    let n: Int, x0: Int, y0: Int
    let width: Int, height: Int
    let cx: Double, cy: Double, boxPx: Double
    let noiseSigma: Float

    static func make(pixels: [Float], width: Int, height: Int, cx: Double, cy: Double, boxPx: Double, out: Int,
                     denoise: SwipeDenoise, size: Double, h: Double) -> CardPlate {
        let scale = boxPx / Double(out)
        let aa = scale > 1.5 ? 0.5 * scale : 0                               // anti-alias pre-blur when shrinking
        let aaPad = aa > 0.05 ? Int((3.5 * aa).rounded(.up)) + 1 : 1
        let pad = aaPad + Denoise.pad(denoise, size: size)
        let half = Int((boxPx / 2).rounded(.up)) + pad + 1
        let x0 = Int(cx.rounded(.down)) - half, y0 = Int(cy.rounded(.down)) - half, n = 2 * half + 1
        var region = [Float](repeating: 0, count: n * n)
        for j in 0..<n {
            let yy = min(max(y0 + j, 0), height - 1)
            for i in 0..<n { region[j * n + i] = pixels[yy * width + min(max(x0 + i, 0), width - 1)] }
        }
        let noise = Denoise.noiseSigma(region, n, n)
        if denoise != .none { region = Denoise.apply(denoise, region, n, size: size, h: h, noise: noise) }
        if aa > 0.05 { region = AutoPicker.gaussianBlur(region, n, n, sigma: aa) }
        return CardPlate(region: region, n: n, x0: x0, y0: y0, width: width, height: height, cx: cx, cy: cy, boxPx: boxPx, noiseSigma: noise)
    }

    /// Percentile window (0.5 % ... 99.5 %) of the visible crop, for "this card" tone mode.
    func localWindow() -> (lo: Float, hi: Float) {
        let half = boxPx / 2
        let i0 = max(0, Int((cx - half - Double(x0)).rounded(.down))), i1 = min(n - 1, Int((cx + half - Double(x0)).rounded(.up)))
        let j0 = max(0, Int((cy - half - Double(y0)).rounded(.down))), j1 = min(n - 1, Int((cy + half - Double(y0)).rounded(.up)))
        var v = [Float]()
        if i1 >= i0, j1 >= j0 { for j in j0...j1 { for i in i0...i1 { v.append(region[j * n + i]) } } }
        guard v.count > 10 else { return (0, 1) }
        v.sort()
        let lo = v[Int(0.005 * Double(v.count - 1))], hi = v[Int(0.995 * Double(v.count - 1))]
        return hi > lo ? (lo, hi) : (lo, lo + 1e-6)
    }

    func render(out: Int, lo: Float, hi: Float, gamma: Float = 1, invert: Bool = false, nearest: Bool = false) -> [UInt8] {
        var o = [UInt8](repeating: 128, count: out * out)
        let span = max(hi - lo, 1e-12)
        let g = max(gamma, 0.05)
        for j in 0..<out {
            let sy = cy + ((Double(j) + 0.5) / Double(out) - 0.5) * boxPx
            if sy < -0.5 || sy > Double(height) - 0.5 { continue }
            let ry = sy - Double(y0), jy = min(max(Int(ry.rounded(.down)), 0), n - 2), fy = Float(ry - Double(jy))
            for i in 0..<out {
                let sx = cx + ((Double(i) + 0.5) / Double(out) - 0.5) * boxPx
                if sx < -0.5 || sx > Double(width) - 0.5 { continue }
                let rx = sx - Double(x0), ix = min(max(Int(rx.rounded(.down)), 0), n - 2), fx = Float(rx - Double(ix))
                let v: Float
                if nearest {
                    v = region[min(max(Int(ry.rounded()), 0), n - 1) * n + min(max(Int(rx.rounded()), 0), n - 1)]
                } else {
                    let a = region[jy * n + ix], b = region[jy * n + ix + 1], c = region[(jy + 1) * n + ix], d = region[(jy + 1) * n + ix + 1]
                    v = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
                }
                var t = min(max((v - lo) / span, 0), 1)
                if g != 1 { t = powf(t, g) }
                if invert { t = 1 - t }
                o[j * out + i] = UInt8(t * 255 + 0.5)
            }
        }
        return o
    }
}
