import Foundation

enum PickMethod: String, Codable, CaseIterable, Identifiable {
    case core = "Bright core", log = "LoG blob"
    var id: String { rawValue }
}

/// Auto-picker settings (also stored per micrograph in the project so a run can be reproduced).
struct AutoParams: Codable, Equatable {
    var method: PickMethod = .core
    var bright = true                 // particles brighter than background (raw polarity of the stain data)
    var diameterNm = 20.0
    var flattenNm = 0.0               // background (large Gaussian) sigma in nm, 0 = off
    var smoothNm = 0.0                // 0 -> 0.1 x diameter
    var minSepNm = 0.0                // 0 -> 0.9 x diameter
    var zThreshold = 4.0              // robust z of the score map
    var edgeMarginPx = 0.0            // 0 -> half a diameter
    var maxPicks = 400

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = AutoParams()
        method = try c.decodeIfPresent(PickMethod.self, forKey: .method) ?? z.method
        bright = try c.decodeIfPresent(Bool.self, forKey: .bright) ?? z.bright
        diameterNm = try c.decodeIfPresent(Double.self, forKey: .diameterNm) ?? z.diameterNm
        flattenNm = try c.decodeIfPresent(Double.self, forKey: .flattenNm) ?? z.flattenNm
        smoothNm = try c.decodeIfPresent(Double.self, forKey: .smoothNm) ?? z.smoothNm
        minSepNm = try c.decodeIfPresent(Double.self, forKey: .minSepNm) ?? z.minSepNm
        zThreshold = try c.decodeIfPresent(Double.self, forKey: .zThreshold) ?? z.zThreshold
        edgeMarginPx = try c.decodeIfPresent(Double.self, forKey: .edgeMarginPx) ?? z.edgeMarginPx
        maxPicks = try c.decodeIfPresent(Int.self, forKey: .maxPicks) ?? z.maxPicks
    }

    /// Parameters that change the score map (the expensive part); the rest only changes peak extraction.
    var scoreSignature: String {
        "\(method.rawValue)|\(bright)|\(diameterNm)|\(flattenNm)|\(smoothNm)"
    }
}

/// Robust-z score map on a binned grid.
struct ScoreMap {
    var w: Int, h: Int
    var bin: Int
    var data: [Float]
    var imageWidth: Int, imageHeight: Int
}

struct AutoCandidate: Equatable { var x: Double; var y: Double; var score: Float }

/// CPU auto-picker (Foundation only). Pipeline: bin -> flatten -> robust z-score -> polarity ->
/// smooth -> score (bright core minus annulus, or difference-of-Gaussians blob) -> robust z of the score ->
/// local maxima with minimum separation. Coordinates are pick coordinates (array indices, pixel centre = integer).
enum AutoPicker {
    // MARK: primitives (also used by tests)

    static func gaussianKernel(_ sigma: Double) -> [Float] {
        let r = max(1, Int(3.5 * sigma + 0.5))
        var k = (0...r).map { Float(exp(-0.5 * Double($0 * $0) / (sigma * sigma))) }
        let s = k[0] + 2 * k.dropFirst().reduce(0, +)
        k = k.map { $0 / s }
        return k
    }

    /// Separable Gaussian, edge pixels replicated ("nearest").
    static func gaussianBlur(_ a: [Float], _ w: Int, _ h: Int, sigma: Double) -> [Float] {
        guard sigma > 0.05 else { return a }
        let k = gaussianKernel(sigma), r = k.count - 1
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        var row = [Float](repeating: 0, count: w + 2 * r)
        for y in 0..<h {
            for i in 0..<(w + 2 * r) { row[i] = a[y * w + min(max(i - r, 0), w - 1)] }
            for x in 0..<w {
                var s = k[0] * row[x + r]
                for j in 1...r { s += k[j] * (row[x + r - j] + row[x + r + j]) }
                tmp[y * w + x] = s
            }
        }
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = k[0] * tmp[y * w + x] }
            for j in 1...r {
                let ya = max(y - j, 0) * w, yb = min(y + j, h - 1) * w, kj = k[j]
                for x in 0..<w { out[y * w + x] += kj * (tmp[ya + x] + tmp[yb + x]) }
            }
        }
        return out
    }

    /// Mean over the pixels of the disk dx²+dy² <= r² that lie inside the image (edge-aware).
    static func diskMean(_ a: [Float], _ w: Int, _ h: Int, radius r: Double) -> [Float] {
        let ri = Int(r.rounded(.down))
        var half = [Int](repeating: 0, count: 2 * ri + 1)
        for dy in -ri...ri { half[dy + ri] = Int((r * r - Double(dy * dy)).squareRoot().rounded(.down)) }
        var P = [Float](repeating: 0, count: (w + 1) * h)
        for y in 0..<h {
            var s: Float = 0
            for x in 0..<w { s += a[y * w + x]; P[y * (w + 1) + x + 1] = s }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0, cnt = 0
                for dy in -ri...ri {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    let hw = half[dy + ri]
                    let x0 = max(x - hw, 0), x1 = min(x + hw, w - 1)
                    sum += P[yy * (w + 1) + x1 + 1] - P[yy * (w + 1) + x0]
                    cnt += x1 - x0 + 1
                }
                out[y * w + x] = sum / Float(max(cnt, 1))
            }
        }
        return out
    }

    /// Median and MAD-based sigma (1.4826 x MAD) from a strided sample of at most `maxSample` values.
    static func robustStats(_ a: [Float], maxSample: Int = 200_000) -> (median: Float, sigma: Float) {
        let stride = max(1, a.count / maxSample)
        var s = [Float](); s.reserveCapacity(a.count / stride + 1)
        var i = 0
        while i < a.count { s.append(a[i]); i += stride }
        s.sort()
        let med = s[s.count / 2]
        var dev = s.map { abs($0 - med) }; dev.sort()
        return (med, max(1.4826 * dev[dev.count / 2], 1e-12))
    }

    static func bin(_ a: [Float], _ w: Int, _ h: Int, factor b: Int) -> ([Float], Int, Int) {
        if b <= 1 { return (a, w, h) }
        let w2 = w / b, h2 = h / b
        var out = [Float](repeating: 0, count: w2 * h2)
        let inv = 1 / Float(b * b)
        for y in 0..<h2 {
            for dy in 0..<b {
                let src = (y * b + dy) * w
                for x in 0..<w2 {
                    var s: Float = 0
                    for dx in 0..<b { s += a[src + x * b + dx] }
                    out[y * w2 + x] += s * inv
                }
            }
        }
        return (out, w2, h2)
    }

    // MARK: score map

    /// Bin so the particle is ~10-20 px across on the working grid (keeps the disk filters cheap).
    static func binFactor(diameterPx: Double) -> Int { min(16, max(1, Int(diameterPx / 10))) }

    static func scoreMap(pixels: [Float], width: Int, height: Int, angpix: Double, params p: AutoParams) -> ScoreMap {
        let dPx = p.diameterNm * 10 / angpix
        let b = binFactor(diameterPx: dPx)
        var (a, w, h) = bin(pixels, width, height, factor: b)
        let dB = dPx / Double(b), R = dB / 2
        if p.flattenNm > 0 {
            let bg = gaussianBlur(a, w, h, sigma: p.flattenNm * 10 / angpix / Double(b))
            for i in 0..<a.count { a[i] -= bg[i] }
        }
        let st = robustStats(a)
        let sgn: Float = p.bright ? 1 : -1
        for i in 0..<a.count { a[i] = sgn * (a[i] - st.median) / st.sigma }
        var score: [Float]
        switch p.method {
        case .core:
            let sm = gaussianBlur(a, w, h, sigma: p.smoothNm > 0 ? p.smoothNm * 10 / angpix / Double(b) : max(0.7, 0.1 * dB))
            let rc = max(1, 0.65 * R), rIn = 1.4 * R, rOut = 2.9 * R
            let core = diskMean(sm, w, h, radius: rc)
            let inner = diskMean(sm, w, h, radius: rIn), outer = diskMean(sm, w, h, radius: rOut)
            // annulus mean from the two disk means (sums = mean x count; counts approximated by disk areas,
            // exact away from the image edge)
            let aIn = Float(countDisk(rIn)), aOut = Float(countDisk(rOut))
            score = [Float](repeating: 0, count: w * h)
            for i in 0..<score.count {
                let ann = (outer[i] * aOut - inner[i] * aIn) / max(aOut - aIn, 1)
                score[i] = core[i] - ann
            }
        case .log:
            let s1 = max(0.8, R / 2.0.squareRoot())
            let g1 = gaussianBlur(a, w, h, sigma: s1), g2 = gaussianBlur(a, w, h, sigma: 1.6 * s1)
            score = zip(g1, g2).map { $0 - $1 }
        }
        let rs = robustStats(score)
        for i in 0..<score.count { score[i] = (score[i] - rs.median) / rs.sigma }
        return ScoreMap(w: w, h: h, bin: b, data: score, imageWidth: width, imageHeight: height)
    }

    static func countDisk(_ r: Double) -> Int {
        let ri = Int(r.rounded(.down)); var n = 0
        for dy in -ri...ri { n += 2 * Int((r * r - Double(dy * dy)).squareRoot().rounded(.down)) + 1 }
        return n
    }

    // MARK: peaks

    static func extract(_ m: ScoreMap, params p: AutoParams, angpix: Double) -> [AutoCandidate] {
        let b = Double(m.bin)
        let dPx = p.diameterNm * 10 / angpix
        let sepFull = (p.minSepNm > 0 ? p.minSepNm * 10 / angpix : 0.9 * dPx)
        let sepB = max(1.0, sepFull / b)
        let edgeFull = p.edgeMarginPx > 0 ? p.edgeMarginPx : dPx / 2
        let edgeB = Int((edgeFull / b).rounded(.up))
        let w = m.w, h = m.h, d = m.data
        let thr = Float(p.zThreshold)
        var peaks: [(Float, Int, Int)] = []
        if w > 2 * edgeB + 2, h > 2 * edgeB + 2 {
            for y in max(1, edgeB)..<(h - max(1, edgeB)) {
                for x in max(1, edgeB)..<(w - max(1, edgeB)) {
                    let v = d[y * w + x]
                    if v < thr { continue }
                    var isMax = true
                    outer: for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let o = d[(y + dy) * w + x + dx]
                        // strict on the "earlier" half of the neighbourhood so plateaus yield one peak
                        if o > v || (o == v && (dy < 0 || (dy == 0 && dx < 0))) { isMax = false; break outer }
                    } }
                    if isMax { peaks.append((v, x, y)) }
                }
            }
        }
        peaks.sort { $0.0 != $1.0 ? $0.0 > $1.0 : ($0.2 != $1.2 ? $0.2 < $1.2 : $0.1 < $1.1) }
        // greedy non-maximum suppression with a cell grid
        let cell = max(sepB, 1)
        var occ: [Int64: [Int]] = [:]
        var kept: [(Float, Int, Int)] = []
        func key(_ cx: Int, _ cy: Int) -> Int64 { Int64(cx) << 32 | Int64(UInt32(truncatingIfNeeded: cy)) }
        for pk in peaks {
            if kept.count >= p.maxPicks { break }
            let cx = Int(Double(pk.1) / cell), cy = Int(Double(pk.2) / cell)
            var ok = true
            search: for ix in (cx - 1)...(cx + 1) { for iy in (cy - 1)...(cy + 1) {
                for j in occ[key(ix, iy)] ?? [] {
                    let o = kept[j]
                    if hypot(Double(o.1 - pk.1), Double(o.2 - pk.2)) < sepB { ok = false; break search }
                }
            } }
            if ok { occ[key(cx, cy), default: []].append(kept.count); kept.append(pk) }
        }
        return kept.map { (v, x, y) in
            // sub-pixel refinement: centroid of the positive scores in the 3x3 neighbourhood
            var sx = 0.0, sy = 0.0, sw = 0.0
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                let s = Double(max(d[yy * w + xx], 0)); sx += s * Double(dx); sy += s * Double(dy); sw += s
            } }
            let ox = sw > 0 ? sx / sw : 0, oy = sw > 0 ? sy / sw : 0
            return AutoCandidate(x: (Double(x) + ox) * b + (b - 1) / 2, y: (Double(y) + oy) * b + (b - 1) / 2, score: v)
        }
    }

    static func run(pixels: [Float], width: Int, height: Int, angpix: Double, params: AutoParams) -> [AutoCandidate] {
        extract(scoreMap(pixels: pixels, width: width, height: height, angpix: angpix, params: params), params: params, angpix: angpix)
    }
}

// MARK: external pickers

/// Runs a user-supplied command that prints candidate coordinates as JSON:
/// `[{"x":..,"y":..,"score":..}, ...]` or `{"picks":[...]}`. `{mic}` and `{angpix}` are substituted.
enum ExternalPicker {
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func parse(_ data: Data) throws -> [AutoCandidate] {
        struct C: Decodable { var x: Double; var y: Double; var score: Float? }
        struct W: Decodable { var picks: [C] }
        let list: [C]
        if let l = try? JSONDecoder().decode([C].self, from: data) { list = l } else { list = try JSONDecoder().decode(W.self, from: data).picks }
        return list.map { AutoCandidate(x: $0.x, y: $0.y, score: $0.score ?? 1) }
    }

    static func run(template: String, micrograph: URL, angpix: Double?, timeout: TimeInterval = 600) throws -> [AutoCandidate] {
        let cmd = template.replacingOccurrences(of: "{mic}", with: shellQuote(micrograph.path))
            .replacingOccurrences(of: "{angpix}", with: angpix.map { String($0) } ?? "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue(label: "extpicker.read")
        let g = DispatchGroup()
        g.enter(); reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); throw NSError(domain: "ExternalPicker", code: 1, userInfo: [NSLocalizedDescriptionKey: "command timed out"]) }
        g.wait()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ExternalPicker", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "command failed (\(p.terminationStatus)): \(msg.prefix(300))"])
        }
        return try parse(data)
    }
}

/// `Thon --autopick FILE.mrc [--diameter nm] [--z z] [--method core|log] [--dark] [--flatten nm] [--max n]` prints x,y,score CSV.
func runAutoPickCLI(_ args: [String]) -> Int32 {
    guard let i = args.firstIndex(of: "--autopick"), args.count > i + 1 else { print("usage: --autopick FILE.mrc [options]"); return 2 }
    func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    do {
        let f = try MRCFile(url: URL(fileURLWithPath: args[i + 1]))
        let px = try f.readPixels()
        var p = AutoParams()
        p.diameterNm = Double(opt("--diameter") ?? "") ?? p.diameterNm
        p.zThreshold = Double(opt("--z") ?? "") ?? p.zThreshold
        p.flattenNm = Double(opt("--flatten") ?? "") ?? 0
        p.maxPicks = Int(opt("--max") ?? "") ?? p.maxPicks
        p.bright = !args.contains("--dark")
        p.method = (opt("--method") ?? "core") == "log" ? .log : .core
        let ap = f.header.pixelSizeA ?? 1
        let t0 = Date()
        let c = AutoPicker.run(pixels: px, width: f.width, height: f.height, angpix: ap, params: p)
        FileHandle.standardError.write(Data(String(format: "%d picks in %.2f s (%.4g A/px)\n", c.count, Date().timeIntervalSince(t0), ap).utf8))
        for k in c { print(String(format: "%.3f,%.3f,%.4f", k.x, k.y, k.score)) }
        return 0
    } catch { print("ERROR:", error.localizedDescription); return 1 }
}
