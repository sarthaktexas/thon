import Foundation
import Combine

// Particle size histogram. Two sources of a size:
//   • set: the diameter stored with the pick (a size sweep, the arrow keys, or the project default);
//   • measured: the diameter estimated from the image around the pick (half-maximum radius of the radial profile).
// The statistics are plain functions so they can be tested headlessly; `SizeModel` is the state the Picks tab shows.

/// One particle's size.
struct SizeSample: Equatable {
    var key: String              // micrograph key
    var id: String               // pick id
    var label: String
    var cls: Int?                // RELION class when a classification is loaded
    var nm: Double
}

enum SizeSource: String, CaseIterable, Identifiable {
    case set = "Set diameter", measured = "Measured from image"
    var id: String { rawValue }
}

enum SizeColorBy: String, CaseIterable, Identifiable {
    case none = "None", label = "Label", cls = "Class"
    var id: String { rawValue }
}

struct SizeBin: Identifiable, Equatable {
    var lo: Double, hi: Double
    var group: String
    var count: Int
    var below = 0                // particles of the groups drawn before this one in the same bin (bars are stacked explicitly)
    var id: String { "\(lo)|\(group)" }
    var mid: Double { (lo + hi) / 2 }
    var yLo: Double { Double(below) }
    var yHi: Double { Double(below + count) }
}

struct SizeSummary: Equatable {
    var n = 0
    var mean = 0.0, sd = 0.0, median = 0.0, min = 0.0, max = 0.0
    var p5 = 0.0, p95 = 0.0
}

enum SizeStats {
    /// Linear-interpolated quantile (q in 0...1) of a sorted array.
    static func quantile(_ s: [Double], _ q: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        let p = min(max(q, 0), 1) * Double(s.count - 1)
        let i = Int(p.rounded(.down)), f = p - Double(i)
        return i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[i]
    }

    static func summary(_ values: [Double]) -> SizeSummary {
        guard !values.isEmpty else { return SizeSummary() }
        let s = values.sorted()
        let mean = s.reduce(0, +) / Double(s.count)
        let sd = s.count > 1 ? (s.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(s.count - 1)).squareRoot() : 0
        return SizeSummary(n: s.count, mean: mean, sd: sd, median: quantile(s, 0.5), min: s[0], max: s[s.count - 1], p5: quantile(s, 0.05), p95: quantile(s, 0.95))
    }

    /// 1, 2, 2.5, 5 x 10^k at or above `v` (bin widths read nicely).
    static func niceWidth(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 1 }
        let e = pow(10, floor(log10(v))), f = v / e
        let m = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10
        return m * e
    }

    /// Freedman-Diaconis bin width (2 IQR n^-1/3), rounded to a nice number; falls back to range / 10 when the IQR is 0.
    static func autoBinWidth(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 1 }
        let s = values.sorted()
        let iqr = quantile(s, 0.75) - quantile(s, 0.25)
        var w = 2 * iqr * pow(Double(s.count), -1.0 / 3)
        if !(w > 0) { w = (s[s.count - 1] - s[0]) / 10 }
        if !(w > 0) { w = max(abs(s[0]) * 0.05, 0.5) }
        return niceWidth(w)
    }

    /// Bins aligned to multiples of `width`; one `SizeBin` per (bin, group) with a nonzero count, plus the bin range.
    /// At most `maxBins` bins: the width grows to fit.
    static func bins(_ samples: [SizeSample], width: Double, group: (SizeSample) -> String = { _ in "" }, maxBins: Int = 200) -> (bins: [SizeBin], lo: Double, width: Double, count: Int) {
        guard let mn = samples.map({ $0.nm }).min(), let mx = samples.map({ $0.nm }).max() else { return ([], 0, width, 0) }
        var w = max(width, 1e-6)
        while Int(((mx - mn) / w).rounded(.down)) + 1 > maxBins { w = niceWidth(w * 1.01) }
        let lo = (mn / w).rounded(.down) * w
        let n = Int(((mx - lo) / w).rounded(.down)) + 1
        var cells: [String: [Int]] = [:]
        for s in samples {
            let i = min(max(Int(((s.nm - lo) / w).rounded(.down)), 0), n - 1)
            cells[group(s), default: [Int](repeating: 0, count: n)][i] += 1
        }
        var out: [SizeBin] = []
        var stacked = [Int](repeating: 0, count: n)
        for (g, c) in cells.sorted(by: { $0.key < $1.key }) {
            for (i, k) in c.enumerated() where k > 0 {
                out.append(SizeBin(lo: lo + Double(i) * w, hi: lo + Double(i + 1) * w, group: g, count: k, below: stacked[i]))
                stacked[i] += k
            }
        }
        return (out, lo, w, n)
    }

    /// Sizes of the accepted picks (and candidates when asked). `measured` maps pick id -> diameter (nm); for `.measured` picks without one are left out.
    static func samples(project: PickProject, classes: ClassMapping?, source: SizeSource, measured: [String: Double], keys: [String]? = nil,
                        labels: Set<String>? = nil, hiddenClasses: Set<Int> = [], includeCandidates: Bool = false) -> [SizeSample] {
        var out: [SizeSample] = []
        for k in keys ?? project.mics.keys.sorted() {
            guard let rec = project.mics[k] else { continue }
            for p in rec.picks {
                guard p.status == .accepted || (includeCandidates && p.status == .candidate) else { continue }
                if let l = labels, !l.contains(p.label) { continue }
                let c = classes?.pickClass[p.id]
                if let c, hiddenClasses.contains(c) { continue }
                let nm: Double
                switch source {
                case .set: nm = p.diameterNm ?? project.params.diameterNm
                case .measured: guard let m = measured[p.id] else { continue }; nm = m
                }
                out.append(SizeSample(key: k, id: p.id, label: p.label, cls: c, nm: nm))
            }
        }
        return out
    }

    static func csv(_ samples: [SizeSample], source: SizeSource) -> String {
        var l = ["micrograph,pick,label,class,diameter_nm,source"]
        for s in samples {
            l.append([PickExporter.csvField(s.key), s.id, PickExporter.csvField(s.label), s.cls.map(String.init) ?? "", String(format: "%.2f", s.nm),
                      source == .set ? "set" : "measured"].joined(separator: ","))
        }
        return l.joined(separator: "\n") + "\n"
    }
}

/// Diameter of a particle estimated from the image.
///
/// Around the pick the mean intensity is taken in 1-px rings. The background is the mean of the outer rings (2 to 2.5 x the set radius);
/// the particle level is the ring with the largest departure from it within 1.5 x the set radius (a disc peaks in the middle, a ring-shaped
/// particle on its rim). The edge is where the profile, going outward from that peak, first drops below half way to the background (linear
/// interpolation between rings). Works for bright or dark particles; sizes up to about 1.5 x the set diameter are seen. A pick too near
/// the image border, or with no clear contrast, gives nil.
enum SizeMeasure {
    static func diameterPx(pixels: [Float], width: Int, height: Int, cx: Double, cy: Double, nominalDiameterPx: Double) -> Double? {
        let rn = max(nominalDiameterPx / 2, 2)
        let rmax = max(2.5 * rn, rn + 6)
        let R = Int(rmax.rounded(.up))
        guard cx - rmax >= 0, cy - rmax >= 0, cx + rmax <= Double(width - 1), cy + rmax <= Double(height - 1), pixels.count >= width * height else { return nil }
        var sum = [Double](repeating: 0, count: R + 1), sq = [Double](repeating: 0, count: R + 1), cnt = [Int](repeating: 0, count: R + 1)
        let x0 = Int((cx - rmax).rounded(.down)), x1 = Int((cx + rmax).rounded(.up)), y0 = Int((cy - rmax).rounded(.down)), y1 = Int((cy + rmax).rounded(.up))
        for y in y0...y1 {
            let dy = Double(y) - cy
            for x in x0...x1 {
                let dx = Double(x) - cx
                let r = (dx * dx + dy * dy).squareRoot()
                guard r < rmax else { continue }
                let b = Int(r)
                let v = Double(pixels[y * width + x])
                sum[b] += v; sq[b] += v * v; cnt[b] += 1
            }
        }
        let nb = Int(rmax.rounded(.down))
        guard nb >= 6, (0..<nb).allSatisfy({ cnt[$0] > 0 }) else { return nil }
        var prof = (0..<nb).map { sum[$0] / Double(cnt[$0]) }
        // background and its pixel noise
        let bgFrom = Int((2.0 * rn).rounded(.down))
        guard bgFrom < nb - 1 else { return nil }
        var bs = 0.0, bq = 0.0, bn = 0
        for b in bgFrom..<nb { bs += sum[b]; bq += sq[b]; bn += cnt[b] }
        guard bn > 8 else { return nil }
        let bg = bs / Double(bn), sd = max(bq / Double(bn) - bg * bg, 0).squareRoot()
        // light smoothing along the radius
        let raw = prof
        for i in 1..<(nb - 1) { prof[i] = 0.25 * raw[i - 1] + 0.5 * raw[i] + 0.25 * raw[i + 1] }
        let peakTo = min(Int((1.5 * rn).rounded(.down)), bgFrom - 1, nb - 2)
        guard peakTo >= 1 else { return nil }
        var pk = 0
        for i in 0...peakTo where abs(prof[i] - bg) > abs(prof[pk] - bg) { pk = i }
        let contrast = prof[pk] - bg
        // the peak must stand out of the pixel noise averaged over the ring it came from
        let noise = sd / Double(max(cnt[pk], 1)).squareRoot()
        guard abs(contrast) > 1e-9, abs(contrast) >= 3 * noise else { return nil }
        let n = prof.map { ($0 - bg) / contrast }
        var i = pk
        while i + 1 < nb, n[i + 1] >= 0.5 { i += 1 }
        guard i + 1 < nb - 1 else { return nil }          // never fell below half within the window
        let f = (n[i] - 0.5) / max(n[i] - n[i + 1], 1e-12)
        let radius = (Double(i) + 0.5) + min(max(f, 0), 1)
        return 2 * radius
    }
}

/// State of the size histogram in the Picks tab.
final class SizeModel: ObservableObject {
    unowned let pc: PickController
    @Published var source = SizeSource.set
    @Published var thisMicrographOnly = false
    @Published var colorBy = SizeColorBy.none
    @Published var includeCandidates = false
    @Published var binWidthNm: Double?                 // nil = automatic
    @Published var hiddenLabelsOnly = true             // follow the picker's visible-label toggles
    @Published private(set) var measured: [String: (nm: Double, x: Double, y: Double)] = [:]   // pick id -> size at the position it was measured
    @Published var busy = false
    @Published var progress: String?
    @Published var message: String?
    /// Loads raw pixels of a micrograph by key (set by the app).
    var loader: ((URL?, String) -> (pixels: [Float], width: Int, height: Int)?)?
    private var token = 0
    private let queue = DispatchQueue(label: "thon.sizes", qos: .utility)

    init(pc: PickController) { self.pc = pc }

    /// Measured sizes that still belong to where the pick is now.
    private var validMeasured: [String: Double] {
        var out: [String: Double] = [:]
        for (_, r) in pc.store.project.mics { for p in r.picks { if let m = measured[p.id], m.x == p.x, m.y == p.y { out[p.id] = m.nm } } }
        return out
    }

    var labelFilter: Set<String>? {
        let hidden = pc.hiddenLabels
        return hiddenLabelsOnly && !hidden.isEmpty ? Set(pc.store.scheme.labels.map { $0.id }).subtracting(hidden) : nil
    }

    func samples() -> [SizeSample] {
        let keys: [String]? = thisMicrographOnly ? (pc.currentKey.map { [$0] } ?? []) : nil
        return SizeStats.samples(project: pc.store.project, classes: pc.classes, source: source, measured: validMeasured, keys: keys,
                                 labels: labelFilter, hiddenClasses: pc.hiddenClasses, includeCandidates: includeCandidates)
    }

    /// Accepted picks in scope that have no (current) measurement yet.
    func unmeasuredCount() -> Int {
        let keys = thisMicrographOnly ? (pc.currentKey.map { [$0] } ?? []) : pc.store.project.mics.keys.sorted()
        let v = validMeasured
        var n = 0
        for k in keys { for p in pc.store.picks(k) where (p.status == .accepted || (includeCandidates && p.status == .candidate)) && v[p.id] == nil { n += 1 } }
        return n
    }

    func group(_ s: SizeSample) -> String {
        switch colorBy {
        case .none: return ""
        case .label: return s.label
        case .cls: return s.cls.map { String(format: "class %02d", $0) } ?? "no class"
        }
    }

    func histogram(_ samples: [SizeSample]) -> (bins: [SizeBin], lo: Double, width: Double, count: Int) {
        SizeStats.bins(samples, width: binWidthNm ?? SizeStats.autoBinWidth(samples.map { $0.nm }), group: group)
    }

    func csvText() -> String { SizeStats.csv(samples(), source: source) }

    // MARK: measuring

    /// Measures every accepted pick in scope (picks already measured at their present position are kept).
    func measure() {
        guard !busy else { return }
        let keys = thisMicrographOnly ? (pc.currentKey.map { [$0] } ?? []) : pc.store.project.mics.keys.sorted()
        let have = validMeasured
        var jobs: [(key: String, picks: [Pick], angpix: Double?)] = []
        for k in keys {
            let ps = pc.store.picks(k).filter { ($0.status == .accepted || (includeCandidates && $0.status == .candidate)) && have[$0.id] == nil }
            if !ps.isEmpty { jobs.append((k, ps, pc.store.record(k).angpix)) }
        }
        guard !jobs.isEmpty else { message = "Every pick in scope is already measured."; return }
        token += 1
        let tk = token
        busy = true; message = nil
        let total = jobs.reduce(0) { $0 + $1.picks.count }
        progress = "Measuring 0 / \(total)…"
        let loader = self.loader, root = pc.store.root, km = pc.store.keyResolver()
        let curKey = pc.currentKey, curPixels = pc.pixels, curW = Int(pc.imageSize.width), curH = Int(pc.imageSize.height)
        let defaultNm = pc.store.project.params.diameterNm, curAngpix = pc.pixelSizeA
        queue.async { [weak self] in
            var done = 0, failed = 0, noAngpix = 0
            for j in jobs {
                if self?.token != tk { return }
                var src: (pixels: [Float], width: Int, height: Int)?
                if j.key == curKey, !curPixels.isEmpty { src = (curPixels, curW, curH) } else { src = loader?(root, km.loaderKey(j.key)) }
                guard let s = src, let ap = j.angpix ?? (j.key == curKey ? curAngpix : nil), ap > 0 else {
                    if src != nil { noAngpix += j.picks.count } else { failed += j.picks.count }
                    done += j.picks.count; continue
                }
                var res: [String: (nm: Double, x: Double, y: Double)] = [:]
                for p in j.picks {
                    let nomPx = (p.diameterNm ?? defaultNm) * 10 / ap
                    if let d = SizeMeasure.diameterPx(pixels: s.pixels, width: s.width, height: s.height, cx: p.x, cy: p.y, nominalDiameterPx: nomPx) {
                        res[p.id] = (d * ap / 10, p.x, p.y)
                    } else { failed += 1 }
                }
                done += j.picks.count
                let d = done
                DispatchQueue.main.async {
                    guard let self, self.token == tk else { return }
                    for (id, v) in res { self.measured[id] = v }
                    self.progress = "Measuring \(d) / \(total)…"
                }
            }
            DispatchQueue.main.async {
                guard let self, self.token == tk else { return }
                self.busy = false; self.progress = nil
                var m = "Measured \(total - failed - noAngpix) of \(total) picks"
                if failed > 0 { m += "; \(failed) skipped (too near the edge, no clear contrast, or the file could not be read)" }
                if noAngpix > 0 { m += "; \(noAngpix) skipped (pixel size unknown: open the micrograph once)" }
                self.message = m
            }
        }
    }

    func cancelMeasure() { token += 1; busy = false; progress = nil; message = "Measuring stopped." }
    func clearMeasured() { measured = [:]; message = nil }
}
