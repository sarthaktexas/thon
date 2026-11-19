import Foundation

// Pattern suggestions: spatial point-pattern statistics on the saved picks.
//
// Everything here uses the pick coordinates only (no pixels). For each micrograph the picks are compared with random
// arrangements of the same number of points in the same window ("the null"). The null is a random sequential placement that
// keeps the smallest spacing seen between the picks, so the picker's own minimum-separation rule is not mistaken for a pattern.
// A statistic is a pattern when the picks sit in the far tail of the null (Monte-Carlo p-value). Micrographs are combined with
// Fisher's method and the twelve tests are corrected together with Holm's method, so a list that says "likely" or "strong"
// already allows for having looked in twelve places.
//
// Foundation only, so it also compiles on its own for testing.

// MARK: - Types

enum PatternKind: String, CaseIterable, Identifiable, Codable {
    case clustering, dispersion, spacing, aggregates, lines, rings, hexagonal, square, patchiness, gradient, segregation, mixing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clustering: return "Closer together than chance"
        case .dispersion: return "Further apart than chance"
        case .spacing: return "Preferred spacing"
        case .aggregates: return "Aggregates"
        case .lines: return "Straight rows"
        case .rings: return "Rings"
        case .hexagonal: return "Hexagonal packing"
        case .square: return "Square packing"
        case .patchiness: return "Uneven density"
        case .gradient: return "Drift across the image"
        case .segregation: return "Same types sit together"
        case .mixing: return "Types alternate"
        }
    }
}

struct PatSegment: Equatable { var x0: Double, y0: Double, x1: Double, y1: Double }
struct PatCircle: Equatable { var x: Double, y: Double, r: Double }
struct PatDot: Equatable { var x: Double, y: Double }
struct PatRect: Equatable { var x0: Double, y0: Double, x1: Double, y1: Double }

/// What to draw over the micrograph for one kind of pattern (pick coordinates).
struct PatternGeometry: Equatable {
    var segments: [PatSegment] = []
    var circles: [PatCircle] = []
    var dots: [PatDot] = []
    var rects: [PatRect] = []
    var isEmpty: Bool { segments.isEmpty && circles.isEmpty && dots.isEmpty && rects.isEmpty }
}

struct PatternInput {
    var key: String
    var x: [Double]
    var y: [Double]
    var group: [String]                  // same length as x; "" for everything when not grouping
    var width: Double                    // image size in pixels (0 = unknown: the picks' bounding box is the window)
    var height: Double
    var diameterPx: Double
    var angpix: Double                   // Å per pixel
    init(key: String, x: [Double], y: [Double], group: [String]? = nil, width: Double, height: Double, diameterPx: Double, angpix: Double) {
        self.key = key; self.x = x; self.y = y; self.group = group ?? [String](repeating: "", count: x.count)
        self.width = width; self.height = height; self.diameterPx = diameterPx; self.angpix = angpix
    }
}

struct PatternParams: Equatable {
    var nSim = 999                       // random arrangements per micrograph (the smallest p-value is 1 / (nSim + 1))
    var useDensity = true                // random positions follow the picks' own smooth density, so uneven density is not read as clustering
    var densitySigmaD = 3.0              // smoothing of that density for tests of closeness, in diameters. Wider flattens crowded patches and
                                         // makes real picks look clustered there; narrower follows the noise in the picks.
    var densitySigmaWideD = 8.0          // smoothing for the test of being further apart than chance (the opposite error, so the opposite choice)
    var minPoints = 15
    var minGroup = 8                     // a type needs this many picks to take part in the label tests
    var seed: UInt64 = 20261118
    var shellStepD = 0.25                // pair-distance shells, in diameters
    var maxShellD = 6.0
    var linkD = 1.2                      // two particles touch when their centres are closer than this many diameters
    var lineTolD = 0.35                  // a particle is on a row when within this distance of the row axis
    var lineGapD = 1.8                   // largest centre-to-centre gap inside a row
    var lineMin = 5                      // shortest row listed
    var ringTolD = 0.35
    var ringRminD = 0.8, ringRmaxD = 8.0
    var ringMin = 5                      // fewest particles on a ring
    var ringMaxTriples = 4000
    var flaggedPsi = 0.8                 // |ψ| above this = near-perfect local order
}

enum PatternStatus: String { case ok, tooFew, smallWindow, noScale }

struct PatternTestResult: Equatable {
    var p: Double                        // one-sided Monte-Carlo p-value
    var obs: Double
    var nullMean: Double
    var nullSD: Double
}

struct MicPatternResult {
    var key: String
    var n = 0
    var status = PatternStatus.ok
    var diameterPx = 0.0
    var angpix = 0.0
    var densityAdjusted = false
    var densitySigmaPx = 0.0
    var hardCore = true                  // false: the null had to fall back to plain random positions (picks too crowded)
    var minSpacingPx = 0.0
    var nSim = 0
    var tests: [PatternKind: PatternTestResult] = [:]
    var desc: [PatternKind: [String: Double]] = [:]      // numbers the wording needs
    var geometry: [PatternKind: PatternGeometry] = [:]
    // pair-distance shells (counts per shell: picks, null mean, null sd), for pooling
    var shellObs: [Double] = [], shellMean: [Double] = [], shellSD: [Double] = []
    var cumMean: [Double] = [], cumSD: [Double] = []
    var cumMeanWide: [Double] = [], cumSDWide: [Double] = []     // the wide-smoothing comparison used for "further apart"
    var cancelled = false
    var diameterNm: Double { diameterPx * angpix / 10 }
}

enum PatternLevel: Int, Comparable {
    case none = 0, weak, likely, strong
    static func < (a: PatternLevel, b: PatternLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String { switch self { case .strong: return "Strong"; case .likely: return "Likely"; case .weak: return "Hint"; case .none: return "None" } }
}

struct PatternRow: Identifiable, Equatable {
    var kind: PatternKind
    var p: Double
    var pAdj: Double
    var micrographs: Int                 // micrographs the test could run on
    var significantIn: Int               // of those, with p <= 0.05 on their own
    var effect = 0.0                     // how far the picks are from the random ones, in standard deviations of the random ones (orders ties)
    var summary: String
    var caveat: String?
    var id: String { kind.rawValue }
    var level: PatternLevel { pAdj < 0.01 ? .strong : pAdj < 0.05 ? .likely : p < 0.05 ? .weak : .none }
}

struct PatternReport {
    var micrographs: [MicPatternResult] = []
    var rows: [PatternRow] = []          // every test that could run, smallest p first
    var picks = 0
    var skipped: [(key: String, why: String)] = []
    var notes: [String] = []
    var nSim = 0
    var testsRun: Int { rows.count }
    var findings: [PatternRow] { rows.filter { $0.level >= .likely } }
    var hints: [PatternRow] { rows.filter { $0.level == .weak } }
}

// MARK: - Random numbers

struct PatternRNG: RandomNumberGenerator {
    var s: UInt64
    init(seed: UInt64) {
        // scramble the seed first, so streams started from seeds a fixed stride apart are unrelated
        var z = seed &+ 0xD1B54A32D192ED03
        z = (z ^ (z >> 32)) &* 0xDABA0B6EB09322E3
        z = (z ^ (z >> 32)) &* 0xDABA0B6EB09322E3
        z = z ^ (z >> 32)
        s = z
    }
    mutating func next() -> UInt64 {
        s = s &+ 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / 9007199254740992.0 }
}

// MARK: - Neighbour grid

struct PointGrid {
    let xs: [Double], ys: [Double]
    let cell: Double, minX: Double, minY: Double
    let nx: Int, ny: Int
    private var start: [Int]
    private var items: [Int]
    let span: Double

    init(xs: [Double], ys: [Double], cell c: Double) {
        self.xs = xs; self.ys = ys
        let mnx = xs.min() ?? 0, mny = ys.min() ?? 0, mxx = xs.max() ?? 0, mxy = ys.max() ?? 0
        let sp = max(mxx - mnx, mxy - mny, 1e-9)
        let cs = max(c, sp / 800, 1e-9)
        cell = cs; minX = mnx; minY = mny; span = sp
        nx = Int((mxx - mnx) / cs) + 1; ny = Int((mxy - mny) / cs) + 1
        var cnt = [Int](repeating: 0, count: nx * ny + 1)
        var cellOf = [Int](repeating: 0, count: xs.count)
        for i in 0..<xs.count {
            let cx = min(Int((xs[i] - mnx) / cs), nx - 1), cy = min(Int((ys[i] - mny) / cs), ny - 1)
            let k = cy * nx + cx
            cellOf[i] = k; cnt[k + 1] += 1
        }
        for k in 0..<(nx * ny) { cnt[k + 1] += cnt[k] }
        start = cnt
        var fill = cnt
        var it = [Int](repeating: 0, count: xs.count)
        for i in 0..<xs.count { it[fill[cellOf[i]]] = i; fill[cellOf[i]] += 1 }
        items = it
    }

    /// Calls `body(index, squaredDistance)` for every point within `r` of (x, y), the point itself included.
    func within(_ x: Double, _ y: Double, _ r: Double, _ body: (Int, Double) -> Void) {
        let fx0 = ((x - r) - minX) / cell, fx1 = ((x + r) - minX) / cell, fy0 = ((y - r) - minY) / cell, fy1 = ((y + r) - minY) / cell
        let cx0 = max(Int(fx0.rounded(.down)), 0), cx1 = min(Int(fx1.rounded(.down)), nx - 1)
        let cy0 = max(Int(fy0.rounded(.down)), 0), cy1 = min(Int(fy1.rounded(.down)), ny - 1)
        guard cx0 <= cx1, cy0 <= cy1 else { return }
        let r2 = r * r
        for cy in cy0...cy1 {
            for cx in cx0...cx1 {
                let k = cy * nx + cx
                for t in start[k]..<start[k + 1] {
                    let i = items[t]
                    let dx = xs[i] - x, dy = ys[i] - y
                    let d2 = dx * dx + dy * dy
                    if d2 <= r2 { body(i, d2) }
                }
            }
        }
    }

    /// The `k` nearest other points to point `i`, nearest first.
    func nearest(of i: Int, k: Int) -> [Int] {
        guard k > 0, xs.count > 1 else { return [] }
        var r = cell
        let big = span * 2 + cell
        while true {
            var c: [(Int, Double)] = []
            within(xs[i], ys[i], r) { j, d2 in if j != i { c.append((j, d2)) } }
            if c.count >= k {
                c.sort { $0.1 < $1.1 }
                if c[k - 1].1 <= r * r || r > big { return c.prefix(k).map { $0.0 } }
            } else if r > big {
                c.sort { $0.1 < $1.1 }
                return c.map { $0.0 }
            }
            r *= 2
        }
    }
}

// MARK: - Window

struct PatternWindow: Equatable {
    var x0: Double, y0: Double, x1: Double, y1: Double
    var w: Double { x1 - x0 }
    var h: Double { y1 - y0 }
    var area: Double { w * h }
}

// MARK: - Statistics of one point set

struct PatChain { var members: [Int]; var x0: Double, y0: Double, x1: Double, y1: Double }
struct PatRing { var x: Double, y: Double, r: Double, members: [Int] }

struct SetStats {
    var shells: [Double] = []
    var aggFrac = 0.0, aggPoints = 0, largestComp = 0, compCount = 0
    var line = 0.0, ring = 0.0
    var psi6 = 0.0, psi4 = 0.0
    var patch = 0.0
    var grad = 0.0, gradX = 0.0, gradY = 0.0
    var nnMin = 0.0
    // only kept for the real picks
    var chains: [PatChain] = []
    var rings: [PatRing] = []
    var comps: [[Int]] = []
    var links: [(Int, Int)] = []
    var psi6Re: [Double] = [], psi6Im: [Double] = [], psi4Mag: [Double] = []
    var knn: [[Int]] = []
    var patchCell = (gx: 0, gy: 0, best: 0, bestCount: 0, mean: 0.0)
}

enum PatternEngine {
    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    // MARK: window and null

    static func window(_ inp: PatternInput) -> PatternWindow {
        let mnx = inp.x.min() ?? 0, mxx = inp.x.max() ?? 0, mny = inp.y.min() ?? 0, mxy = inp.y.max() ?? 0
        guard inp.width > 0, inp.height > 0 else { return PatternWindow(x0: mnx, y0: mny, x1: mxx, y1: mxy) }
        // the image, less the strip the picks never enter (the auto-picker drops boxes that overhang the edge)
        var m = Double.infinity
        for i in 0..<inp.x.count { m = min(m, inp.x[i], inp.y[i], inp.width - inp.x[i], inp.height - inp.y[i]) }
        m = min(max(m, 0), 0.25 * min(inp.width, inp.height))
        return PatternWindow(x0: min(m, mnx), y0: min(m, mny), x1: max(inp.width - m, mxx), y1: max(inp.height - m, mxy))
    }

    /// A smooth density of the picks over the window, used to draw the null positions.
    struct NullIntensity {
        var x0: Double, y0: Double, cw: Double, ch: Double
        var gx: Int, gy: Int
        var cum: [Double]
        func sample(_ rng: inout PatternRNG) -> (Double, Double) {
            let u = rng.uniform() * cum[cum.count - 1]
            var lo = 0, hi = cum.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if cum[mid] >= u { hi = mid } else { lo = mid + 1 } }
            let cx = lo % gx, cy = lo / gx
            return (x0 + (Double(cx) + rng.uniform()) * cw, y0 + (Double(cy) + rng.uniform()) * ch)
        }
    }

    private static func normalCDF(_ z: Double) -> Double { 0.5 * (1 + erf(z / 2.0.squareRoot())) }

    /// Gaussian kernel density (points per px²) at the centres of a gx × gy grid of cells over the window, corrected for the part of
    /// each kernel that falls outside the window (otherwise the edges would look emptier than the middle).
    static func kdeGrid(x: [Double], y: [Double], win: PatternWindow, sigma: Double, gx: Int, gy: Int) -> [Double] {
        let cw = win.w / Double(gx), ch = win.h / Double(gy)
        let grid = PointGrid(xs: x, ys: y, cell: sigma)
        var lam = [Double](repeating: 0, count: gx * gy)
        let inv2 = 1 / (2 * sigma * sigma), norm = 1 / (2 * Double.pi * sigma * sigma)
        for cy in 0..<gy {
            for cx in 0..<gx {
                let px = win.x0 + (Double(cx) + 0.5) * cw, py = win.y0 + (Double(cy) + 0.5) * ch
                var sum = 0.0
                grid.within(px, py, 3 * sigma) { _, d2 in sum += exp(-d2 * inv2) }
                let mass = (normalCDF((win.x1 - px) / sigma) - normalCDF((win.x0 - px) / sigma)) * (normalCDF((win.y1 - py) / sigma) - normalCDF((win.y0 - py) / sigma))
                lam[cy * gx + cx] = norm * sum / max(mass, 0.05)
            }
        }
        return lam
    }

    /// Separable Gaussian blur of a gx × gy grid (sigma in cells), renormalised at the borders.
    static func blurGrid(_ v: [Double], gx: Int, gy: Int, sigmaCells: Double) -> [Double] {
        let rad = max(1, Int((3 * sigmaCells).rounded(.up)))
        let k = (-rad...rad).map { exp(-Double($0 * $0) / (2 * sigmaCells * sigmaCells)) }
        var tmp = [Double](repeating: 0, count: v.count), out = tmp
        for y in 0..<gy { for x in 0..<gx {
            var s = 0.0, w = 0.0
            for d in -rad...rad { let xx = x + d; if xx >= 0 && xx < gx { s += v[y * gx + xx] * k[d + rad]; w += k[d + rad] } }
            tmp[y * gx + x] = s / w
        } }
        for y in 0..<gy { for x in 0..<gx {
            var s = 0.0, w = 0.0
            for d in -rad...rad { let yy = y + d; if yy >= 0 && yy < gy { s += tmp[yy * gx + x] * k[d + rad]; w += k[d + rad] } }
            out[y * gx + x] = s / w
        } }
        return out
    }

    /// Smooth density of the picks over the window, sharpened once ("twicing": 2·λ̂ − blur(λ̂)) because a plain kernel estimate flattens
    /// every crowded patch, and flattened random positions would make the real picks look clustered there.
    static func intensity(x: [Double], y: [Double], win: PatternWindow, sigma: Double, cell: Double, sharpen: Bool = true) -> NullIntensity {
        let gx = max(1, min(Int((win.w / cell).rounded(.up)), 120)), gy = max(1, min(Int((win.h / cell).rounded(.up)), 120))
        let cw = win.w / Double(gx), ch = win.h / Double(gy)
        var lam = kdeGrid(x: x, y: y, win: win, sigma: sigma, gx: gx, gy: gy)
        if sharpen {
            let bl = blurGrid(lam, gx: gx, gy: gy, sigmaCells: max(sigma / min(cw, ch), 0.5))
            for i in 0..<lam.count { lam[i] = max(2 * lam[i] - bl[i], 0.1 * lam[i]) }
        }
        let mean = lam.reduce(0, +) / Double(lam.count)
        var cum = [Double](repeating: 0, count: lam.count)
        var c = 0.0
        for i in 0..<lam.count { c += lam[i] + 0.02 * mean + 1e-18; cum[i] = c }       // a little uniform floor keeps every cell reachable
        return NullIntensity(x0: win.x0, y0: win.y0, cw: cw, ch: ch, gx: gx, gy: gy, cum: cum)
    }

    /// `n` random positions in `win`, no two closer than `d0` (random sequential placement), drawn from `inhom` when given.
    /// Falls back to a smaller spacing, then to plain random positions, when the window is too crowded; `hard` says which one it ended on.
    static func nullPoints(n: Int, win: PatternWindow, d0: Double, inhom: NullIntensity? = nil, rng: inout PatternRNG) -> (x: [Double], y: [Double], hard: Bool) {
        var spacing = d0
        func draw(_ rng: inout PatternRNG) -> (Double, Double) {
            if let h = inhom { return h.sample(&rng) }
            return (win.x0 + rng.uniform() * win.w, win.y0 + rng.uniform() * win.h)
        }
        func csr() -> ([Double], [Double]) {
            var xs = [Double](), ys = [Double]()
            xs.reserveCapacity(n); ys.reserveCapacity(n)
            for _ in 0..<n { let q = draw(&rng); xs.append(q.0); ys.append(q.1) }
            return (xs, ys)
        }
        guard d0 > 1e-6 * max(win.w, win.h), win.w > 0, win.h > 0 else { let c = csr(); return (c.0, c.1, d0 <= 0) }
        for _ in 0..<5 {
            let cs = max(spacing, max(win.w, win.h) / 256)
            let gx = Int(win.w / cs) + 1, gy = Int(win.h / cs) + 1
            for _ in 0..<6 {
                var heads = [[Int32]](repeating: [], count: gx * gy)
                var xs = [Double](), ys = [Double]()
                xs.reserveCapacity(n); ys.reserveCapacity(n)
                var ok = true
                let s2 = spacing * spacing
                for _ in 0..<n {
                    var placed = false
                    for _ in 0..<300 {
                        let (x, y) = draw(&rng)
                        let cx = min(max(Int((x - win.x0) / cs), 0), gx - 1), cy = min(max(Int((y - win.y0) / cs), 0), gy - 1)
                        var clash = false
                        search: for yy in max(cy - 1, 0)...min(cy + 1, gy - 1) {
                            for xx in max(cx - 1, 0)...min(cx + 1, gx - 1) {
                                for q in heads[yy * gx + xx] {
                                    let dx = xs[Int(q)] - x, dy = ys[Int(q)] - y
                                    if dx * dx + dy * dy < s2 { clash = true; break search }
                                }
                            }
                        }
                        if !clash {
                            heads[cy * gx + cx].append(Int32(xs.count)); xs.append(x); ys.append(y); placed = true; break
                        }
                    }
                    if !placed { ok = false; break }
                }
                if ok { return (xs, ys, spacing >= d0 * 0.999) }
            }
            spacing *= 0.85
        }
        let c = csr()
        return (c.0, c.1, false)
    }

    /// Density tests: spread of counts over square cells, and the shift of the centre of mass.
    static func densityStats(x: [Double], y: [Double], win: PatternWindow, collect: Bool = false) -> (patch: Double, gradX: Double, gradY: Double, cell: (gx: Int, gy: Int, best: Int, bestCount: Int, mean: Double)) {
        let n = x.count
        let side = (5 * win.area / Double(n)).squareRoot()
        let gx = max(2, min(Int(win.w / side), 14)), gy = max(2, min(Int(win.h / side), 14))
        var counts = [Int](repeating: 0, count: gx * gy)
        for i in 0..<n {
            let cx = min(max(Int((x[i] - win.x0) / win.w * Double(gx)), 0), gx - 1), cy = min(max(Int((y[i] - win.y0) / win.h * Double(gy)), 0), gy - 1)
            counts[cy * gx + cx] += 1
        }
        let mean = Double(n) / Double(gx * gy)
        var v = 0.0
        for c in counts { v += (Double(c) - mean) * (Double(c) - mean) }
        v /= Double(gx * gy - 1)
        var cell = (gx: 0, gy: 0, best: 0, bestCount: 0, mean: 0.0)
        if collect, let b = counts.indices.max(by: { counts[$0] < counts[$1] }) { cell = (gx, gy, b, counts[b], mean) }
        let mx = x.reduce(0, +) / Double(n), my = y.reduce(0, +) / Double(n)
        let se = (12.0 * Double(n)).squareRoot()
        return (v / max(mean, 1e-9), (mx - (win.x0 + win.w / 2)) / (win.w / se), (my - (win.y0 + win.h / 2)) / (win.h / se), cell)
    }

    // MARK: lines

    /// Longest straight chains of particles, one per seed pair of near neighbours.
    static func lineChains(x: [Double], y: [Double], grid: PointGrid, knn: [[Int]], d: Double, p: PatternParams, collect: Bool) -> (best: Int, chains: [PatChain]) {
        let tol = p.lineTolD * d, gap = p.lineGapD * d, range = 14 * d
        var best = 0
        var out: [PatChain] = []
        var buf: [(t: Double, m: Int)] = []

        /// Members of the run (consecutive gaps <= gap along the axis) that contains point `i`, for the axis through (ox, oy).
        func run(i: Int, ox: Double, oy: Double, ux: Double, uy: Double) -> [(Double, Int)] {
            buf.removeAll(keepingCapacity: true)
            grid.within(x[i], y[i], range) { m, _ in
                let dx = x[m] - ox, dy = y[m] - oy
                if abs(-dx * uy + dy * ux) <= tol { buf.append((dx * ux + dy * uy, m)) }
            }
            buf.sort { $0.t < $1.t }
            guard let ci = buf.firstIndex(where: { $0.m == i }) else { return [] }
            var lo = ci, hi = ci
            while lo > 0, buf[lo].t - buf[lo - 1].t <= gap { lo -= 1 }
            while hi + 1 < buf.count, buf[hi + 1].t - buf[hi].t <= gap { hi += 1 }
            return Array(buf[lo...hi])
        }

        for i in 0..<x.count {
            for j in knn[i].prefix(5) {
                if j < i, knn[j].prefix(5).contains(i) { continue }
                var ux = x[j] - x[i], uy = y[j] - y[i]
                let L = (ux * ux + uy * uy).squareRoot()
                guard L > 1e-9 else { continue }
                ux /= L; uy /= L
                var r = run(i: i, ox: x[i], oy: y[i], ux: ux, uy: uy)
                guard r.contains(where: { $0.1 == j }) else { continue }
                // one refinement: refit the axis through the members and look again
                if r.count >= 3 {
                    var mx = 0.0, my = 0.0
                    for e in r { mx += x[e.1]; my += y[e.1] }
                    mx /= Double(r.count); my /= Double(r.count)
                    var sxx = 0.0, syy = 0.0, sxy = 0.0
                    for e in r { let dx = x[e.1] - mx, dy = y[e.1] - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
                    let th = 0.5 * atan2(2 * sxy, sxx - syy)
                    let r2 = run(i: i, ox: mx, oy: my, ux: cos(th), uy: sin(th))
                    if r2.count > r.count { r = r2 }
                }
                best = max(best, r.count)
                if collect, r.count >= p.lineMin {
                    let a = r.first!.1, b = r.last!.1
                    out.append(PatChain(members: r.map { $0.1 }, x0: x[a], y0: y[a], x1: x[b], y1: y[b]))
                }
            }
        }
        return (best, out)
    }

    // MARK: rings

    /// Circles through three near neighbours that many particles lie on, all the way round.
    static func ringFits(x: [Double], y: [Double], grid: PointGrid, d: Double, p: PatternParams, collect: Bool, rng: inout PatternRNG) -> (best: Int, rings: [PatRing]) {
        let n = x.count
        let tol = p.ringTolD * d, rmin = p.ringRminD * d, rmax = p.ringRmaxD * d
        var nb = [[Int]](repeating: [], count: n)
        var total = 0.0
        for i in 0..<n {
            var l: [Int] = []
            grid.within(x[i], y[i], 2.5 * d) { j, _ in if j != i { l.append(j) } }
            nb[i] = l
            total += Double(l.count * (l.count - 1)) / 2
        }
        let keep = total <= Double(p.ringMaxTriples) ? 1.0 : Double(p.ringMaxTriples) / total
        var best = 0
        var out: [PatRing] = []
        let maxGap = 200.0 * Double.pi / 180

        /// inliers of the circle, or nil when they do not go far enough round
        func inliers(_ cx: Double, _ cy: Double, _ R: Double) -> [Int]? {
            var m: [Int] = []
            var ang: [Double] = []
            grid.within(cx, cy, R + tol) { j, d2 in
                if abs(d2.squareRoot() - R) <= tol { m.append(j); ang.append(atan2(y[j] - cy, x[j] - cx)) }
            }
            guard m.count >= p.ringMin else { return nil }
            ang.sort()
            var g = 2 * Double.pi - (ang.last! - ang.first!)
            for k in 1..<ang.count { g = max(g, ang[k] - ang[k - 1]) }
            return g <= maxGap ? m : nil
        }

        for j in 0..<n {
            let l = nb[j]
            if l.count < 2 { continue }
            for a in 0..<(l.count - 1) {
                for b in (a + 1)..<l.count {
                    if keep < 1, rng.uniform() > keep { continue }
                    let ia = l[a], ib = l[b]
                    // circumcircle of (ia, j, ib)
                    let ax = x[ia], ay = y[ia], bx = x[j], by = y[j], cx = x[ib], cy = y[ib]
                    let dd = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
                    guard abs(dd) > 1e-9 else { continue }
                    let ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / dd
                    let uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / dd
                    let R = ((ax - ux) * (ax - ux) + (ay - uy) * (ay - uy)).squareRoot()
                    guard R >= rmin, R <= rmax else { continue }
                    guard var mem = inliers(ux, uy, R) else { continue }
                    var fx = ux, fy = uy, fr = R
                    // one algebraic refit through the inliers
                    if mem.count >= 4 {
                        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sz = 0.0, sxz = 0.0, syz = 0.0
                        for q in mem {
                            let px = x[q], py = y[q], z = px * px + py * py
                            sx += px; sy += py; sxx += px * px; syy += py * py; sxy += px * py; sz += z; sxz += px * z; syz += py * z
                        }
                        let m = Double(mem.count)
                        // solve [sxx sxy sx; sxy syy sy; sx sy m] [A B C]^T = [sxz syz sz]^T   (x²+y² = A x + B y + C)
                        let det = sxx * (syy * m - sy * sy) - sxy * (sxy * m - sy * sx) + sx * (sxy * sy - syy * sx)
                        if abs(det) > 1e-9 {
                            let A = (sxz * (syy * m - sy * sy) - sxy * (syz * m - sy * sz) + sx * (syz * sy - syy * sz)) / det
                            let B = (sxx * (syz * m - sy * sz) - sxz * (sxy * m - sy * sx) + sx * (sxy * sz - syz * sx)) / det
                            let C = (sxx * (syy * sz - syz * sy) - sxy * (sxy * sz - syz * sx) + sxz * (sxy * sy - syy * sx)) / det
                            let rx = A / 2, ry = B / 2, rr2 = C + rx * rx + ry * ry
                            if rr2 > 0 {
                                let rr = rr2.squareRoot()
                                if rr >= rmin, rr <= rmax, let m2 = inliers(rx, ry, rr), m2.count >= mem.count { mem = m2; fx = rx; fy = ry; fr = rr }
                            }
                        }
                    }
                    best = max(best, mem.count)
                    if collect { out.append(PatRing(x: fx, y: fy, r: fr, members: mem)) }
                }
            }
        }
        return (best, out)
    }

    // MARK: one point set

    static func stats(x: [Double], y: [Double], win: PatternWindow, d: Double, p: PatternParams, rng: inout PatternRNG, collect: Bool, shellsOnly: Bool = false) -> SetStats {
        var s = SetStats()
        let n = x.count
        guard n >= 2 else { return s }
        let grid = PointGrid(xs: x, ys: y, cell: 3 * d)

        // neighbours
        var knn = [[Int]](repeating: [], count: n)
        for i in 0..<n { knn[i] = grid.nearest(of: i, k: min(6, n - 1)) }
        var nnMin = Double.infinity
        for i in 0..<n { if let j = knn[i].first { nnMin = min(nnMin, hypot(x[j] - x[i], y[j] - y[i])) } }
        s.nnMin = nnMin.isFinite ? nnMin : 0

        // pair-distance shells and touching groups
        let step = p.shellStepD * d
        let R = min(p.maxShellD * d, 0.25 * min(win.w, win.h))
        let nb = max(Int(R / step), 0)
        var shells = [Double](repeating: 0, count: nb)
        let link = p.linkD * d
        var parent = Array(0..<n)
        func find(_ a: Int) -> Int { var a = a; while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }; return a }
        var links: [(Int, Int)] = []
        for i in 0..<n {
            grid.within(x[i], y[i], max(R, link)) { j, d2 in
                guard j > i else { return }
                let dist = d2.squareRoot()
                if nb > 0 { let b = Int(dist / step); if b < nb { shells[b] += 1 } }
                if dist <= link {
                    let a = find(i), c = find(j)
                    if a != c { parent[a] = c }
                    if collect { links.append((i, j)) }
                }
            }
        }
        s.shells = shells
        if shellsOnly { return s }
        var sizes: [Int: Int] = [:]
        for i in 0..<n { sizes[find(i), default: 0] += 1 }
        var pts = 0, largest = 0, cc = 0
        for (_, c) in sizes { largest = max(largest, c); if c >= 3 { pts += c; cc += 1 } }
        s.aggPoints = pts; s.aggFrac = Double(pts) / Double(n); s.largestComp = largest; s.compCount = cc
        if collect {
            var groups: [Int: [Int]] = [:]
            for i in 0..<n { groups[find(i), default: []].append(i) }
            s.comps = groups.values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
            let big = Set(s.comps.flatMap { $0 })
            s.links = links.filter { big.contains($0.0) && big.contains($0.1) }
        }

        // bond-orientational order
        if n >= 7 {
            var s6 = 0.0, s4 = 0.0
            if collect { s.psi6Re = [Double](repeating: 0, count: n); s.psi6Im = s.psi6Re; s.psi4Mag = s.psi6Re }
            for i in 0..<n {
                let l = knn[i]
                var r6 = 0.0, i6 = 0.0, r4 = 0.0, i4 = 0.0
                for (k, j) in l.enumerated() {
                    let th = atan2(y[j] - y[i], x[j] - x[i])
                    r6 += cos(6 * th); i6 += sin(6 * th)
                    if k < 4 { r4 += cos(4 * th); i4 += sin(4 * th) }
                }
                let m6 = (r6 * r6 + i6 * i6).squareRoot() / Double(l.count)
                let m4 = (r4 * r4 + i4 * i4).squareRoot() / 4
                s6 += m6; s4 += m4
                if collect { s.psi6Re[i] = r6 / Double(l.count); s.psi6Im[i] = i6 / Double(l.count); s.psi4Mag[i] = m4 }
            }
            s.psi6 = s6 / Double(n); s.psi4 = s4 / Double(n)
        }
        if collect { s.knn = knn }

        // density
        let ds = densityStats(x: x, y: y, win: win, collect: collect)
        s.patch = ds.patch; s.gradX = ds.gradX; s.gradY = ds.gradY; s.grad = max(abs(ds.gradX), abs(ds.gradY)); s.patchCell = ds.cell

        // rows and rings
        let lc = lineChains(x: x, y: y, grid: grid, knn: knn, d: d, p: p, collect: collect)
        s.line = Double(lc.best); s.chains = lc.chains
        let rf = ringFits(x: x, y: y, grid: grid, d: d, p: p, collect: collect, rng: &rng)
        s.ring = Double(rf.best); s.rings = rf.rings
        return s
    }

    // MARK: Monte-Carlo helpers

    static func mcP(_ obs: Double, _ sims: [Double]) -> Double {
        guard !sims.isEmpty, obs.isFinite else { return 1 }
        var c = 0
        for v in sims where v >= obs - 1e-9 { c += 1 }
        return Double(1 + c) / Double(sims.count + 1)
    }
    static func meanSD(_ v: [Double]) -> (Double, Double) {
        guard !v.isEmpty else { return (0, 0) }
        let m = v.reduce(0, +) / Double(v.count)
        let s = v.count > 1 ? (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot() : 0
        return (m, s)
    }
    static func quantile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let pos = min(max(q, 0), 1) * Double(s.count - 1)
        let i = Int(pos.rounded(.down)), f = pos - Double(i)
        return i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[i]
    }

    // MARK: one micrograph

    static func analyze(_ inp: PatternInput, params p: PatternParams = PatternParams(), cancel: () -> Bool = { false }) -> MicPatternResult {
        var res = MicPatternResult(key: inp.key)
        let n = inp.x.count
        res.n = n; res.diameterPx = inp.diameterPx; res.angpix = inp.angpix; res.nSim = p.nSim
        guard inp.diameterPx > 0, inp.angpix > 0 else { res.status = .noScale; return res }
        guard n >= p.minPoints else { res.status = .tooFew; return res }
        let d = inp.diameterPx
        let win = window(inp)
        guard min(win.w, win.h) >= 8 * d else { res.status = .smallWindow; return res }
        let base = fnv(inp.key) ^ p.seed
        var rng0 = PatternRNG(seed: base)
        let obs = stats(x: inp.x, y: inp.y, win: win, d: d, p: p, rng: &rng0, collect: true)
        res.minSpacingPx = obs.nnMin

        var inhom: NullIntensity? = nil, inhomWide: NullIntensity? = nil
        if p.useDensity {
            let cell = max(d, max(win.w, win.h) / 120)
            inhom = intensity(x: inp.x, y: inp.y, win: win, sigma: p.densitySigmaD * d, cell: cell)
            inhomWide = intensity(x: inp.x, y: inp.y, win: win, sigma: p.densitySigmaWideD * d, cell: cell, sharpen: false)
            res.densitySigmaPx = p.densitySigmaD * d
        }
        res.densityAdjusted = p.useDensity
        var sims: [SetStats] = []
        sims.reserveCapacity(p.nSim)
        var hard = true
        for s in 0..<p.nSim {
            if cancel() { res.cancelled = true; return res }
            var rng = PatternRNG(seed: base &+ UInt64(s + 1) &* 0x2545F4914F6CDD1D)
            let np = nullPoints(n: n, win: win, d0: obs.nnMin, inhom: inhom, rng: &rng)
            if !np.hard { hard = false }
            sims.append(stats(x: np.x, y: np.y, win: win, d: d, p: p, rng: &rng, collect: false))
        }
        res.hardCore = hard
        // wide-smoothing comparison for "further apart", and uniform random positions for the two density tests
        var wideShells = sims.map { $0.shells }
        if p.useDensity {
            wideShells = []
            for s in 0..<p.nSim {
                if cancel() { res.cancelled = true; return res }
                var rng = PatternRNG(seed: base &+ UInt64(s + 1) &* 0x1D8E4E27C47D124F &+ 5)
                let np = nullPoints(n: n, win: win, d0: obs.nnMin, inhom: inhomWide, rng: &rng)
                wideShells.append(stats(x: np.x, y: np.y, win: win, d: d, p: p, rng: &rng, collect: false, shellsOnly: true).shells)
            }
        }
        var simPatch = sims.map { $0.patch }, simGrad = sims.map { $0.grad }
        if p.useDensity {
            simPatch = []; simGrad = []
            for s in 0..<p.nSim {
                if cancel() { res.cancelled = true; return res }
                var rng = PatternRNG(seed: base &+ UInt64(s + 1) &* 0x7F4A7C15D2B1E3A9 &+ 77)
                let np = nullPoints(n: n, win: win, d0: obs.nnMin, inhom: nil, rng: &rng)
                let ds = densityStats(x: np.x, y: np.y, win: win)
                simPatch.append(ds.patch); simGrad.append(max(abs(ds.gradX), abs(ds.gradY)))
            }
        }
        func add(_ k: PatternKind, _ o: Double, _ sv: [Double]) {
            let (m, sd) = meanSD(sv)
            res.tests[k] = PatternTestResult(p: mcP(o, sv), obs: o, nullMean: m, nullSD: sd)
        }

        // pair-distance shells: studentised deviations of the cumulative count (closeness / further apart) and of each shell (spacing)
        let nb = obs.shells.count
        if nb >= 8 {
            func cum(_ a: [Double]) -> [Double] { var c = 0.0; return a.map { c += $0; return c } }
            struct Ref { var cMean: [Double], cSD: [Double], hMean: [Double], hSD: [Double], cSims: [[Double]], hSims: [[Double]] }
            func reference(_ sh: [[Double]]) -> Ref {
                let cs = sh.map { cum($0) }
                var cM = [Double](repeating: 0, count: nb), cS = cM, hM = cM, hS = cM
                for j in 0..<nb {
                    let a = meanSD(cs.map { $0[j] }), b = meanSD(sh.map { $0[j] })
                    cM[j] = a.0; cS[j] = max(a.1, 1); hM[j] = b.0; hS[j] = max(b.1, 1)
                }
                return Ref(cMean: cM, cSD: cS, hMean: hM, hSD: hS, cSims: cs, hSims: sh)
            }
            let near = reference(sims.map { $0.shells }), wide = reference(wideShells)
            let cObs = cum(obs.shells)
            /// highest studentised excess over the reference, of the cumulative counts (or of the single shells), and where it is
            func peak(_ v: [Double], _ mean: [Double], _ sd: [Double], sign: Double) -> (z: Double, j: Int) {
                var best = -Double.infinity, bj = 0
                for j in 0..<nb { let z = sign * (v[j] - mean[j]) / sd[j]; if z > best { best = z; bj = j } }
                return (best, bj)
            }
            let kp = peak(cObs, near.cMean, near.cSD, sign: 1), g = peak(obs.shells, near.hMean, near.hSD, sign: 1), km = peak(cObs, wide.cMean, wide.cSD, sign: -1)
            let kps = near.cSims.map { peak($0, near.cMean, near.cSD, sign: 1).z }
            let gs = near.hSims.map { peak($0, near.hMean, near.hSD, sign: 1).z }
            let kms = wide.cSims.map { peak($0, wide.cMean, wide.cSD, sign: -1).z }
            add(.clustering, kp.z, kps); add(.dispersion, km.z, kms); add(.spacing, g.z, gs)
            res.shellObs = obs.shells; res.shellMean = near.hMean; res.shellSD = near.hSD; res.cumMean = near.cMean; res.cumSD = near.cSD
            res.cumMeanWide = wide.cMean; res.cumSDWide = wide.cSD
            res.desc[.clustering] = ["j": Double(kp.j), "ratio": cObs[kp.j] / max(near.cMean[kp.j], 1e-9)]
            res.desc[.dispersion] = ["j": Double(km.j), "ratio": cObs[km.j] / max(wide.cMean[km.j], 1e-9)]
            res.desc[.spacing] = ["j": Double(g.j), "ratio": obs.shells[g.j] / max(near.hMean[g.j], 1e-9)]
        }

        // touching groups
        add(.aggregates, obs.aggFrac, sims.map { $0.aggFrac })
        res.desc[.aggregates] = ["largest": Double(obs.largestComp), "groups": Double(obs.compCount)]
        if let t = res.tests[.aggregates] { res.desc[.aggregates]!["expected"] = t.nullMean }
        if obs.compCount > 0 {
            var g = PatternGeometry()
            for c in obs.comps.prefix(60) { for i in c { g.dots.append(PatDot(x: inp.x[i], y: inp.y[i])) } }
            let big = Set(obs.comps.prefix(60).flatMap { $0 })
            for l in obs.links where big.contains(l.0) { g.segments.append(PatSegment(x0: inp.x[l.0], y0: inp.y[l.0], x1: inp.x[l.1], y1: inp.y[l.1])) }
            res.geometry[.aggregates] = g
        }

        // rows
        let lineSims = sims.map { $0.line }
        add(.lines, obs.line, lineSims)
        let lineCut = max(Double(p.lineMin), quantile(lineSims, 0.95).rounded(.up) + 1)
        var rowsListed: [PatChain] = []
        var used = Set<Int>()
        for c in obs.chains.sorted(by: { $0.members.count > $1.members.count }) where Double(c.members.count) >= lineCut {
            if c.members.filter({ used.contains($0) }).count * 2 > c.members.count { continue }
            rowsListed.append(c); used.formUnion(c.members)
            if rowsListed.count >= 12 { break }
        }
        var ld: [String: Double] = ["rows": Double(rowsListed.count), "minLen": lineCut, "longest": obs.line]
        if !rowsListed.isEmpty {
            var g = PatternGeometry(); var sx = 0.0, sy = 0.0, longestPx = 0.0
            for c in rowsListed {
                g.segments.append(PatSegment(x0: c.x0, y0: c.y0, x1: c.x1, y1: c.y1))
                for i in c.members { g.dots.append(PatDot(x: inp.x[i], y: inp.y[i])) }
                let th = atan2(c.y1 - c.y0, c.x1 - c.x0)
                sx += cos(2 * th); sy += sin(2 * th)
                longestPx = max(longestPx, hypot(c.x1 - c.x0, c.y1 - c.y0))
            }
            res.geometry[.lines] = g
            ld["parallel"] = (sx * sx + sy * sy).squareRoot() / Double(rowsListed.count)
            var deg = atan2(sy, sx) / 2 * 180 / .pi; if deg < 0 { deg += 180 }
            ld["angle"] = deg
            ld["lengthNm"] = longestPx * inp.angpix / 10
        }
        res.desc[.lines] = ld

        // rings
        let ringSims = sims.map { $0.ring }
        add(.rings, obs.ring, ringSims)
        let ringCut = max(Double(p.ringMin), quantile(ringSims, 0.95).rounded(.up) + 1)
        var ringsListed: [PatRing] = []
        for r in obs.rings.sorted(by: { $0.members.count > $1.members.count }) where Double(r.members.count) >= ringCut {
            if ringsListed.contains(where: { o in Set(o.members).intersection(r.members).count * 2 > min(o.members.count, r.members.count) }) { continue }
            ringsListed.append(r)
            if ringsListed.count >= 10 { break }
        }
        var rd: [String: Double] = ["rings": Double(ringsListed.count), "minCount": ringCut, "largest": obs.ring]
        if !ringsListed.isEmpty {
            var g = PatternGeometry()
            for r in ringsListed { g.circles.append(PatCircle(x: r.x, y: r.y, r: r.r)); for i in r.members { g.dots.append(PatDot(x: inp.x[i], y: inp.y[i])) } }
            res.geometry[.rings] = g
            rd["radiusNm"] = quantile(ringsListed.map { $0.r }, 0.5) * inp.angpix / 10
        }
        res.desc[.rings] = rd

        // local order
        if n >= 7 {
            add(.hexagonal, obs.psi6, sims.map { $0.psi6 })
            add(.square, obs.psi4, sims.map { $0.psi4 })
            let flagged6 = (0..<n).filter { (obs.psi6Re[$0] * obs.psi6Re[$0] + obs.psi6Im[$0] * obs.psi6Im[$0]).squareRoot() >= p.flaggedPsi }
            let flagged4 = (0..<n).filter { obs.psi4Mag[$0] >= p.flaggedPsi }
            var h: [String: Double] = ["flagged": Double(flagged6.count) / Double(n)]
            var sq: [String: Double] = ["flagged": Double(flagged4.count) / Double(n)]
            func overlay(_ f: [Int], _ kk: Int) -> PatternGeometry {
                var g = PatternGeometry()
                let set = Set(f)
                for i in f {
                    g.dots.append(PatDot(x: inp.x[i], y: inp.y[i]))
                    for j in obs.knn[i].prefix(kk) where set.contains(j) && i < j { g.segments.append(PatSegment(x0: inp.x[i], y0: inp.y[i], x1: inp.x[j], y1: inp.y[j])) }
                }
                return g
            }
            if !flagged6.isEmpty {
                res.geometry[.hexagonal] = overlay(flagged6, 6)
                var nn: [Double] = []
                var cs = 0.0, sn = 0.0
                for i in flagged6 {
                    if let j = obs.knn[i].first { nn.append(hypot(inp.x[j] - inp.x[i], inp.y[j] - inp.y[i])) }
                    let a = atan2(obs.psi6Im[i], obs.psi6Re[i]); cs += cos(a); sn += sin(a)
                }
                h["spacingNm"] = quantile(nn, 0.5) * inp.angpix / 10
                var deg = atan2(sn, cs) / 6 * 180 / .pi; deg = deg.truncatingRemainder(dividingBy: 60); if deg < 0 { deg += 60 }
                h["axis"] = deg
            }
            if !flagged4.isEmpty {
                res.geometry[.square] = overlay(flagged4, 4)
                var nn: [Double] = []
                for i in flagged4 { if let j = obs.knn[i].first { nn.append(hypot(inp.x[j] - inp.x[i], inp.y[j] - inp.y[i])) } }
                sq["spacingNm"] = quantile(nn, 0.5) * inp.angpix / 10
            }
            res.desc[.hexagonal] = h; res.desc[.square] = sq
        }

        // density
        add(.patchiness, obs.patch, simPatch)
        if obs.patchCell.gx > 0 {
            let c = obs.patchCell
            let cx = c.best % c.gx, cy = c.best / c.gx
            let w = win.w / Double(c.gx), hh = win.h / Double(c.gy)
            res.geometry[.patchiness] = PatternGeometry(rects: [PatRect(x0: win.x0 + Double(cx) * w, y0: win.y0 + Double(cy) * hh, x1: win.x0 + Double(cx + 1) * w, y1: win.y0 + Double(cy + 1) * hh)])
            res.desc[.patchiness] = ["densest": Double(c.bestCount), "mean": c.mean]
        }
        add(.gradient, obs.grad, simGrad)
        res.desc[.gradient] = ["zx": obs.gradX, "zy": obs.gradY]

        // types: do neighbours share a label more (or less) often than a shuffle of the labels would give?
        var counts: [String: Int] = [:]
        for g in inp.group { counts[g, default: 0] += 1 }
        if counts.values.filter({ $0 >= p.minGroup }).count >= 2, n >= 7 {
            let nn1 = obs.knn.map { $0.first ?? 0 }
            let names = Array(Set(inp.group)).sorted()
            let code: [Int] = inp.group.map { names.firstIndex(of: $0) ?? 0 }
            func same(_ c: [Int]) -> Double { var k = 0; for i in 0..<n where c[i] == c[nn1[i]] { k += 1 }; return Double(k) / Double(n) }
            let o = same(code)
            var prng = PatternRNG(seed: base ^ 0xABCDEF)
            var sv: [Double] = []
            var shuffled = code
            for _ in 0..<p.nSim { shuffled.shuffle(using: &prng); sv.append(same(shuffled)) }
            let (m, sd) = meanSD(sv)
            res.tests[.segregation] = PatternTestResult(p: mcP(o, sv), obs: o, nullMean: m, nullSD: sd)
            res.tests[.mixing] = PatternTestResult(p: mcP(-o, sv.map { -$0 }), obs: o, nullMean: m, nullSD: sd)
            res.desc[.segregation] = ["same": o, "expected": m]
            res.desc[.mixing] = ["same": o, "expected": m]
        }
        return res
    }

    // MARK: pooling

    /// Upper tail of chi-square with 2m degrees of freedom at x.
    static func chiSquareTail2m(_ x: Double, m: Int) -> Double {
        guard x > 0, m > 0 else { return 1 }
        let y = x / 2
        var t = 1.0, sum = 1.0
        if m > 1 { for k in 1..<m { t *= y / Double(k); sum += t } }
        return min(1, max(exp(-y) * sum, 1e-300))
    }

    static func fisher(_ ps: [Double]) -> Double {
        guard !ps.isEmpty else { return 1 }
        if ps.count == 1 { return ps[0] }
        let x = -2 * ps.reduce(0) { $0 + log(max($1, 1e-300)) }
        return chiSquareTail2m(x, m: ps.count)
    }

    /// Holm step-down adjustment (same order as the input).
    static func holm(_ ps: [Double]) -> [Double] {
        let order = ps.indices.sorted { ps[$0] < ps[$1] }
        var adj = [Double](repeating: 1, count: ps.count)
        var running = 0.0
        for (rank, i) in order.enumerated() {
            running = max(running, min(1, Double(ps.count - rank) * ps[i]))
            adj[i] = running
        }
        return adj
    }

    static func pool(_ results: [MicPatternResult], params p: PatternParams = PatternParams()) -> [PatternRow] {
        let ok = results.filter { $0.status == .ok && !$0.cancelled }
        var rows: [PatternRow] = []
        let medDiaNm = quantile(ok.map { $0.diameterNm }, 0.5)
        func wmean(_ kind: PatternKind, _ f: (MicPatternResult) -> Double?) -> Double? {
            var s = 0.0, w = 0.0
            for r in ok { if let v = f(r), v.isFinite { s += v * Double(r.n); w += Double(r.n) } }
            return w > 0 ? s / w : nil
        }
        // pooled shells: common number of shells, summed counts
        let shellMics = ok.filter { !$0.shellObs.isEmpty }
        let nbCommon = shellMics.map { $0.shellObs.count }.min() ?? 0
        func pooledShell() -> (zc: [Double], rc: [Double], zh: [Double], rh: [Double], zw: [Double], rw: [Double]) {
            var zc = [Double](repeating: 0, count: nbCommon), rc = zc, zh = zc, rh = zc, zw = zc, rw = zc
            for j in 0..<nbCommon {
                var oC = 0.0, mC = 0.0, vC = 0.0, oH = 0.0, mH = 0.0, vH = 0.0, mW = 0.0, vW = 0.0
                for r in shellMics {
                    oC += r.shellObs[0...j].reduce(0, +); mC += r.cumMean[j]; vC += r.cumSD[j] * r.cumSD[j]
                    oH += r.shellObs[j]; mH += r.shellMean[j]; vH += r.shellSD[j] * r.shellSD[j]
                    mW += r.cumMeanWide[j]; vW += r.cumSDWide[j] * r.cumSDWide[j]
                }
                zc[j] = (oC - mC) / vC.squareRoot(); rc[j] = oC / max(mC, 1e-9)
                zh[j] = (oH - mH) / vH.squareRoot(); rh[j] = oH / max(mH, 1e-9)
                zw[j] = (oC - mW) / vW.squareRoot(); rw[j] = oC / max(mW, 1e-9)
            }
            return (zc, rc, zh, rh, zw, rw)
        }
        let ps = pooledShell()
        func nm(_ dUnits: Double) -> String { String(format: "%.0f nm", dUnits * medDiaNm) }
        func dia(_ v: Double) -> String { String(format: "%.1f", v) }
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        func f2(_ v: Double) -> String { String(format: "%.2f", v) }
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

        for kind in PatternKind.allCases {
            let have = ok.filter { $0.tests[kind] != nil }
            guard !have.isEmpty else { continue }
            let pv = fisher(have.map { $0.tests[kind]!.p })
            let sig = have.filter { $0.tests[kind]!.p <= 0.05 }.count
            var summary = "", caveat: String? = nil
            switch kind {
            case .clustering:
                if nbCommon >= 8 {
                    let j = ps.zc.indices.max { ps.zc[$0] < ps.zc[$1] } ?? 0
                    let r = Double(j + 1) * p.shellStepD
                    summary = "Within \(nm(r)) (\(dia(r)) diameters) of a particle there are \(f1(ps.rc[j]))× as many other particles as random positions would give."
                    caveat = "Random positions keep the smallest spacing your picks already have."
                }
            case .dispersion:
                if nbCommon >= 8 {
                    let j = ps.zw.indices.min { ps.zw[$0] < ps.zw[$1] } ?? 0
                    let r = Double(j + 1) * p.shellStepD
                    summary = "Within \(nm(r)) (\(dia(r)) diameters) there are only \(f2(ps.rw[j]))× as many neighbours as random positions would give: particles keep apart beyond the minimum spacing the picks already have."
                }
            case .spacing:
                if nbCommon >= 8 {
                    let j = ps.zh.indices.max { ps.zh[$0] < ps.zh[$1] } ?? 0
                    let r = (Double(j) + 0.5) * p.shellStepD
                    summary = "Centre-to-centre distances cluster near \(nm(r)) (\(dia(r)) diameters): \(f1(ps.rh[j]))× more pairs there than random positions give."
                    caveat = "A single preferred distance usually means regular packing, a repeated assembly, or the picker's spacing rule."
                }
            case .aggregates:
                let o = wmean(kind) { $0.tests[kind]?.obs } ?? 0, e = wmean(kind) { $0.tests[kind]?.nullMean } ?? 0
                let lg = have.compactMap { $0.desc[kind]?["largest"] }.max() ?? 0
                summary = "\(pct(o)) of the particles sit in groups of three or more touching particles (about \(pct(e)) expected by chance); the largest group has \(Int(lg)) particles. Touching means centres closer than \(f1(p.linkD)) diameters."
            case .lines:
                let rows = have.compactMap { $0.desc[kind]?["rows"] }.reduce(0, +)
                let lg = have.compactMap { $0.desc[kind]?["longest"] }.max() ?? 0
                let mn = have.compactMap { $0.desc[kind]?["minLen"] }.min() ?? Double(p.lineMin)
                summary = "Particles line up more than chance allows: the longest straight row has \(Int(lg)) particles (random positions rarely give more than \(Int(mn) - 1))."
                if rows > 0 {
                    summary += " \(Int(rows)) row\(rows == 1 ? "" : "s") of \(Int(mn))+ particles listed"
                    let par = have.compactMap { $0.desc[kind]?["parallel"] }, ang = have.compactMap { $0.desc[kind]?["angle"] }
                    if have.count == 1, let pr = par.first, let a = ang.first, rows >= 3, pr >= 0.8 { summary += ", mostly parallel at about \(String(format: "%.0f", a))°" }
                    summary += "."
                }
            case .rings:
                let rings = have.compactMap { $0.desc[kind]?["rings"] }.reduce(0, +)
                let lg = have.compactMap { $0.desc[kind]?["largest"] }.max() ?? 0
                summary = "Particles arrange on rings: up to \(Int(lg)) particles on one circle, more than random positions give."
                if rings > 0, let r = have.compactMap({ $0.desc[kind]?["radiusNm"] }).first { summary += " \(Int(rings)) ring\(rings == 1 ? "" : "s") listed, radius about \(String(format: "%.0f", r)) nm."}
                if ok.contains(where: { ($0.tests[.hexagonal]?.p ?? 1) < 0.01 }) { caveat = "Hexagonal packing also places particles on circles, so check that finding first." }
            case .hexagonal:
                let o = wmean(kind) { $0.tests[kind]?.obs } ?? 0, e = wmean(kind) { $0.tests[kind]?.nullMean } ?? 0
                let fl = wmean(kind) { $0.desc[kind]?["flagged"] } ?? 0
                summary = "Neighbours sit at 60° steps more than chance allows: mean ψ6 \(f2(o)) against \(f2(e)) for random positions; \(pct(fl)) of particles have near-perfect six-fold surroundings."
                if let s = have.compactMap({ $0.desc[kind]?["spacingNm"] }).sorted().first.map({ _ in quantile(have.compactMap { $0.desc[kind]?["spacingNm"] }, 0.5) }) { summary += " Lattice spacing about \(String(format: "%.0f", s)) nm." }
                if have.count == 1, let a = have[0].desc[kind]?["axis"] { summary += " Lattice axes near \(String(format: "%.0f", a))° (mod 60°)." }
            case .square:
                let o = wmean(kind) { $0.tests[kind]?.obs } ?? 0, e = wmean(kind) { $0.tests[kind]?.nullMean } ?? 0
                let fl = wmean(kind) { $0.desc[kind]?["flagged"] } ?? 0
                summary = "Neighbours sit at 90° steps more than chance allows: mean ψ4 \(f2(o)) against \(f2(e)) for random positions; \(pct(fl)) of particles have near-perfect four-fold surroundings."
                if !have.compactMap({ $0.desc[kind]?["spacingNm"] }).isEmpty { summary += " Spacing about \(String(format: "%.0f", quantile(have.compactMap { $0.desc[kind]?["spacingNm"] }, 0.5))) nm." }
            case .patchiness:
                let o = wmean(kind) { $0.tests[kind]?.obs } ?? 0, e = wmean(kind) { $0.tests[kind]?.nullMean } ?? 0
                summary = "Particle density varies across the micrograph more than random positions would: variance-to-mean of local counts \(f1(o)) against \(f1(e))."
                caveat = "Parts of a micrograph that were not checked have no picks, and that alone gives this result. Thick stain, ice or grid-bar edges can too."
            case .gradient:
                let zx = wmean(kind) { $0.desc[kind]?["zx"] } ?? 0, zy = wmean(kind) { $0.desc[kind]?["zy"] } ?? 0
                let dir = abs(zx) >= abs(zy) ? (zx > 0 ? "right" : "left") : (zy > 0 ? "bottom" : "top")
                summary = have.count == 1
                    ? "Picks lean toward the \(dir) of the image: the average position is \(f1(max(abs(zx), abs(zy)))) standard errors off centre."
                    : "Where the picks sit within a micrograph is not even (on average toward the \(dir))."
                caveat = "A one-sided pile-up often follows the sample: a thick edge, a carbon hole, or a region you picked more carefully."
            case .segregation:
                let o = wmean(kind) { $0.tests[kind]?.obs } ?? 0, e = wmean(kind) { $0.tests[kind]?.nullMean } ?? 0
                summary = "Nearest neighbours share the same type \(pct(o)) of the time, against \(pct(e)) if the types were shuffled: particles of one type sit together."
            case .mixing:
                let o = wmean(kind) { $0.tests[kind]?.obs } ?? 0, e = wmean(kind) { $0.tests[kind]?.nullMean } ?? 0
                summary = "Nearest neighbours share the same type only \(pct(o)) of the time, against \(pct(e)) if the types were shuffled: different types sit side by side."
            }
            if summary.isEmpty { continue }
            var eff = 0.0
            for r in have { let t = r.tests[kind]!; eff += t.nullSD > 1e-12 ? (t.obs - t.nullMean) / t.nullSD : 0 }
            rows.append(PatternRow(kind: kind, p: pv, pAdj: 1, micrographs: have.count, significantIn: sig, effect: eff / Double(have.count), summary: summary, caveat: caveat))
        }
        let adj = holm(rows.map { $0.p })
        for i in rows.indices { rows[i].pAdj = adj[i] }
        return rows.sorted { $0.p != $1.p ? $0.p < $1.p : $0.effect > $1.effect }
    }

    /// Whole run: analyse each micrograph (in order), pool, correct.
    static func run(_ inputs: [PatternInput], params p: PatternParams = PatternParams(), cancel: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) -> PatternReport {
        var rep = PatternReport()
        rep.nSim = p.nSim
        for (i, inp) in inputs.enumerated() {
            if cancel() { break }
            progress(i, inputs.count)
            let r = analyze(inp, params: p, cancel: cancel)
            if r.cancelled { break }
            switch r.status {
            case .ok: rep.micrographs.append(r); rep.picks += r.n
            case .tooFew: rep.skipped.append((inp.key, "fewer than \(p.minPoints) picks"))
            case .smallWindow: rep.skipped.append((inp.key, "picks span less than 8 particle diameters"))
            case .noScale: rep.skipped.append((inp.key, "pixel size or particle diameter unknown"))
            }
        }
        progress(inputs.count, inputs.count)
        rep.rows = pool(rep.micrographs, params: p)
        if p.useDensity {
            rep.notes.append("Compared with random positions that follow each micrograph's own smooth density (smoothed over about \(String(format: "%.0f", p.densitySigmaD)) particle diameters; \(String(format: "%.0f", p.densitySigmaWideD)) for the test of being further apart), so a crowded patch or an uneven background is not read as clustering. Structure wider than that smoothing counts as density, not as a pattern, and the two density tests use uniform random positions.")
        }
        if rep.micrographs.contains(where: { !$0.hardCore }) {
            rep.notes.append("Some micrographs are so crowded that random positions could not keep the picks' minimum spacing; for those the comparison used plain random positions, so spacing findings there may just reflect crowding.")
        }
        return rep
    }
}
