import Foundation

/// Small deterministic generator (SplitMix64) so folds and exploration picks repeat exactly.
struct AssistRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func nextU64() -> UInt64 {
        s = s &+ 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(nextU64() >> 11) / Double(1 << 53) }
    mutating func int(below n: Int) -> Int { n <= 1 ? 0 : Int(nextU64() % UInt64(n)) }
}

/// Logistic regression on standardized features. Trains in milliseconds for the few hundred decisions a swipe session produces.
struct LogisticModel: Codable, Equatable {
    var mean: [Float], scale: [Float], w: [Float], b: Float

    func probability(_ x: [Float]) -> Float {
        guard x.count == w.count else { return 0.5 }
        var s = b
        for i in 0..<w.count { s += w[i] * ((x[i] - mean[i]) / scale[i]) }
        return 1 / (1 + expf(-max(-30, min(30, s))))
    }
}

enum Logistic {
    /// L2-penalized, class-balanced fit by accelerated gradient descent with a step from the Lipschitz bound.
    /// `weights` are per-sample importance weights (e.g. low for easy random-position decoys). nil if one class is missing or the data are unusable.
    static func fit(_ X: [[Float]], _ y: [Float], weights: [Float]? = nil, lambda: Float, iterations: Int = 250) -> LogisticModel? {
        let n = X.count
        guard n >= 4, y.count == n, let d = X.first?.count, d > 0, X.allSatisfy({ $0.count == d }) else { return nil }
        let wIn = weights ?? [Float](repeating: 1, count: n)
        var posW: Float = 0, negW: Float = 0
        for i in 0..<n { if y[i] > 0.5 { posW += wIn[i] } else { negW += wIn[i] } }
        guard posW > 0, negW > 0 else { return nil }
        // standardize
        var mean = [Float](repeating: 0, count: d), scale = [Float](repeating: 1, count: d)
        for j in 0..<d { var s: Float = 0; for i in 0..<n { s += X[i][j] }; mean[j] = s / Float(n) }
        for j in 0..<d {
            var s: Float = 0; for i in 0..<n { let v = X[i][j] - mean[j]; s += v * v }
            let sd = (s / Float(n)).squareRoot(); scale[j] = sd > 1e-6 ? sd : 1
        }
        var Z = [Float](repeating: 0, count: n * d)
        for i in 0..<n { for j in 0..<d { Z[i * d + j] = (X[i][j] - mean[j]) / scale[j] } }
        // balanced weights, normalised to sum 1
        var sw = [Float](repeating: 0, count: n); var tot: Float = 0
        for i in 0..<n { sw[i] = wIn[i] * (y[i] > 0.5 ? 0.5 / posW : 0.5 / negW); tot += sw[i] }
        for i in 0..<n { sw[i] /= tot }
        // step size: 1 / (0.25 * largest eigenvalue of Z^T diag(sw) Z + lambda)
        var v = [Float](repeating: 1 / Float(d).squareRoot(), count: d); var lmax: Float = 1
        for _ in 0..<25 {
            var t = [Float](repeating: 0, count: n)
            for i in 0..<n { var s: Float = 0; for j in 0..<d { s += Z[i * d + j] * v[j] }; t[i] = s * sw[i] }
            var u = [Float](repeating: 0, count: d)
            for i in 0..<n { for j in 0..<d { u[j] += Z[i * d + j] * t[i] } }
            let nrm = u.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if nrm < 1e-12 { break }
            lmax = nrm; v = u.map { $0 / nrm }
        }
        let step = 1 / (0.25 * lmax + lambda + 1e-6)
        var w = [Float](repeating: 0, count: d), b: Float = 0
        var yw = w, yb = b, tPrev: Float = 1
        for _ in 0..<iterations {
            var gw = [Float](repeating: 0, count: d), gb: Float = 0
            for i in 0..<n {
                var s = yb; for j in 0..<d { s += Z[i * d + j] * yw[j] }
                let p = 1 / (1 + expf(-max(-30, min(30, s))))
                let r = sw[i] * (p - y[i]); gb += r
                for j in 0..<d { gw[j] += r * Z[i * d + j] }
            }
            var wNew = w, bNew = b
            for j in 0..<d { wNew[j] = yw[j] - step * (gw[j] + lambda * yw[j]) }
            bNew = yb - step * gb
            let tNew = (1 + (1 + 4 * tPrev * tPrev).squareRoot()) / 2, m = (tPrev - 1) / tNew
            for j in 0..<d { yw[j] = wNew[j] + m * (wNew[j] - w[j]) }
            yb = bNew + m * (bNew - b)
            w = wNew; b = bNew; tPrev = tNew
        }
        return LogisticModel(mean: mean, scale: scale, w: w, b: b)
    }

    /// Area under the ROC curve (Mann-Whitney, ties count half). nil unless both classes are present.
    static func auc(scores: [Float], labels: [Float]) -> Double? {
        let idx = scores.indices.sorted { scores[$0] < scores[$1] }
        var rankSum = 0.0, pos = 0.0, neg = 0.0, i = 0
        while i < idx.count {
            var j = i; while j + 1 < idx.count && scores[idx[j + 1]] == scores[idx[i]] { j += 1 }
            let r = Double(i + j) / 2 + 1
            for k in i...j { if labels[idx[k]] > 0.5 { rankSum += r; pos += 1 } else { neg += 1 } }
            i = j + 1
        }
        guard pos > 0, neg > 0 else { return nil }
        return (rankSum - pos * (pos + 1) / 2) / (pos * neg)
    }

    struct CVResult: Equatable { var auc: Double; var accuracy: Double; var lambda: Float; var folds: Int }

    /// Stratified k-fold cross-validation; picks the penalty with the best AUC. Out-of-fold predictions only.
    static func crossValidate(_ X: [[Float]], _ y: [Float], weights: [Float]? = nil, lambdas: [Float] = [0.3, 3, 30], folds: Int = 5, seed: UInt64 = 1) -> CVResult? {
        let n = X.count
        let pos = (0..<n).filter { y[$0] > 0.5 }, neg = (0..<n).filter { y[$0] <= 0.5 }
        let k = min(folds, pos.count, neg.count)
        guard k >= 2 else { return nil }
        var rng = AssistRNG(seed)
        func shuffled(_ a: [Int]) -> [Int] { var a = a; if a.count > 1 { for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, rng.int(below: i + 1)) } }; return a }
        var fold = [Int](repeating: 0, count: n)
        for (i, id) in shuffled(pos).enumerated() { fold[id] = i % k }
        for (i, id) in shuffled(neg).enumerated() { fold[id] = i % k }
        var best: CVResult?
        for lam in lambdas {
            var oof = [Float](repeating: 0.5, count: n)
            var ok = true
            for f in 0..<k {
                let tr = (0..<n).filter { fold[$0] != f }, te = (0..<n).filter { fold[$0] == f }
                guard let m = fit(tr.map { X[$0] }, tr.map { y[$0] }, weights: weights.map { w in tr.map { w[$0] } }, lambda: lam) else { ok = false; break }
                for i in te { oof[i] = m.probability(X[i]) }
            }
            guard ok, let a = auc(scores: oof, labels: y) else { continue }
            // balanced accuracy: a plain hit rate sits near the majority share when yes and no are uneven, and hardly moves while AUC does
            let tp = pos.filter { oof[$0] >= 0.5 }.count, tn = neg.filter { oof[$0] < 0.5 }.count
            let acc = 0.5 * (Double(tp) / Double(pos.count) + Double(tn) / Double(neg.count))
            if best == nil || a > best!.auc { best = CVResult(auc: a, accuracy: acc, lambda: lam, folds: k) }
        }
        return best
    }
}
