import Foundation
import Combine

/// Learns from the swipe decisions of a project which candidates the user accepts, and orders the cards still to review.
///
/// Nothing is decided by the model: it only changes the ORDER of cards that are still waiting. The card on screen and the
/// blind decoys keep their places, and every fifth card is a random one so the training data keep covering cases the
/// model would not choose itself (otherwise it only ever learns from what it already ranks high).
final class Reranker: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off", likely = "Likely first", uncertain = "Uncertain first"
        var id: String { rawValue }
    }

    struct Sample: Codable, Equatable {
        var key: String, id: String
        var y: Float                       // 1 = accepted, 0 = rejected ("unsure" is not used)
        var decoy: Bool
        var f: [Float]                     // CardFeatures.hand
        var e: [Float]?                    // optional Core ML embedding
    }

    struct Status: Equatable {
        var positives = 0, negatives = 0
        var ready = false
        var auc: Double?, accuracy: Double?
        var trainedOn = 0
        var usingEmbedding = false
        var note: String?
        var summary: String {
            if !ready {
                let need = Reranker.minEach
                return "Learning from your decisions: \(positives) yes, \(negatives) no so far (needs \(need) of each)."
            }
            var s = "Trained on \(trainedOn) decisions"
            if let a = accuracy, let u = auc { s += String(format: ". On cards it had not seen it agreed with you %.0f%% of the time (AUC %.2f)", a * 100, u) }
            s += usingEmbedding ? ", with Core ML image features." : "."
            if let n = note { s += " " + n }
            return s
        }
    }

    static let minEach = 30
    static let refitEvery = 5
    static let exploreEvery = 5
    static let decoyNegativeWeight: Float = 0.3          // random-position decoys are easy negatives: count them, but less

    @Published var mode: Mode = .off { didSet { if mode != oldValue { onChange?() } } }
    @Published var useEmbedding = false { didSet { if useEmbedding != oldValue { refit() } } }
    @Published private(set) var status = Status()
    private(set) var model: LogisticModel?
    private(set) var modelUsesEmbedding = false
    /// Called on the main thread after the model or the mode changed, so the owner can re-order its deck.
    var onChange: (() -> Void)?

    private(set) var samples: [String: Sample] = [:]
    private var sinceFit = 0, fitToken = 0
    private let queue = DispatchQueue(label: "thon.assist", qos: .utility)
    private(set) var sidecar: URL?

    private static func sampleKey(_ key: String, _ id: String) -> String { "\(key)@\(id)" }

    // MARK: samples

    func observe(key: String, id: String, decision: String, decoy: Bool, hand: [Float]?, embedding: [Float]?) {
        let k = Self.sampleKey(key, id)
        guard (decision == "pick" || decision == "reject"), let hand, hand.count == CardFeatures.handLength else { samples[k] = nil; refreshCounts(); return }
        samples[k] = Sample(key: key, id: id, y: decision == "pick" ? 1 : 0, decoy: decoy, f: hand, e: embedding)
        refreshCounts()
        sinceFit += 1
        if status.positives >= Self.minEach && status.negatives >= Self.minEach && (model == nil || sinceFit >= Self.refitEvery) { refit() }
        else if sinceFit % 10 == 0 { save() }
    }

    func forget(key: String, id: String) {
        if samples.removeValue(forKey: Self.sampleKey(key, id)) != nil { refreshCounts(); sinceFit += 1 }
    }

    func reset() {
        fitToken += 1; samples = [:]; model = nil; modelUsesEmbedding = false; sinceFit = 0
        status = Status(); save(); onChange?()
    }

    private func refreshCounts() {
        var s = status
        s.positives = samples.values.filter { $0.y > 0.5 }.count
        s.negatives = samples.count - s.positives
        status = s
    }

    // MARK: training

    func refit() {
        let all = Array(samples.values)
        var set = all, withE = false
        if useEmbedding {
            let e = all.filter { $0.e != nil }
            if e.filter({ $0.y > 0.5 }).count >= Self.minEach && e.filter({ $0.y <= 0.5 }).count >= Self.minEach { set = e; withE = true }
        }
        let pos = set.filter { $0.y > 0.5 }.count
        guard pos >= Self.minEach, set.count - pos >= Self.minEach else { refreshCounts(); return }
        fitToken += 1
        let token = fitToken
        let note: String? = (useEmbedding && !withE) ? "Core ML features are missing for most decisions, so hand-made features are used." : nil
        sinceFit = 0
        queue.async { [weak self] in
            let X = set.map { withE ? $0.f + ($0.e ?? []) : $0.f }
            let y = set.map { $0.y }
            let w = set.map { $0.decoy && $0.y < 0.5 ? Reranker.decoyNegativeWeight : 1 }
            let cv = Logistic.crossValidate(X, y, weights: w)
            let model = Logistic.fit(X, y, weights: w, lambda: cv?.lambda ?? 3)
            DispatchQueue.main.async {
                guard let self, token == self.fitToken, let model else { return }
                self.model = model; self.modelUsesEmbedding = withE
                var s = self.status
                s.ready = true; s.auc = cv?.auc; s.accuracy = cv?.accuracy; s.trainedOn = set.count; s.usingEmbedding = withE; s.note = note
                self.status = s
                self.save()
                self.onChange?()
            }
        }
    }

    func probability(hand: [Float]?, embedding: [Float]?) -> Float? {
        guard let m = model, let hand else { return nil }
        if modelUsesEmbedding { guard let e = embedding else { return nil }; return m.probability(hand + e) }
        return m.probability(hand)
    }

    // MARK: ordering

    /// New order of a deck as a permutation (position -> old index). The first card (on screen) and every decoy keep their positions;
    /// the other cards go by probability (`likely`) or closeness to 0.5 (`uncertain`), with every `exploreEvery`-th slot filled at random.
    static func order(decoy: [Bool], p: [Float?], mode: Mode, exploreEvery: Int = Reranker.exploreEvery, seed: UInt64) -> [Int] {
        let n = decoy.count
        var out = Array(0..<n)
        guard mode != .off, n > 2, p.count == n else { return out }
        let slots = (1..<n).filter { !decoy[$0] }
        guard slots.count > 1 else { return out }
        func key(_ i: Int) -> Float { mode == .likely ? -(p[i] ?? 0) : abs((p[i] ?? 0.5) - 0.5) }
        let known = slots.filter { p[$0] != nil }.sorted { (key($0), $0) < (key($1), $1) }
        var pool = known + slots.filter { p[$0] == nil }
        var rng = AssistRNG(seed)
        var chosen: [Int] = []
        for k in 0..<slots.count {
            if exploreEvery > 0, (k + 1) % exploreEvery == 0, pool.count > 1 { chosen.append(pool.remove(at: rng.int(below: pool.count))) }
            else { chosen.append(pool.removeFirst()) }
        }
        for (s, i) in zip(slots, chosen) { out[s] = i }
        return out
    }

    // MARK: persistence (a sidecar next to the project, so a model survives restarts without the micrographs)

    private struct File: Codable { var version: Int; var samples: [Sample] }

    static func sidecarURL(forProject url: URL?) -> URL? {
        url?.deletingPathExtension().appendingPathExtension("assist.json")
    }

    /// Switches to the sidecar of another project (loading its samples and retraining once if enough are there).
    func use(project url: URL?) {
        let u = Self.sidecarURL(forProject: url)
        guard u != sidecar else { return }
        sidecar = u; fitToken += 1; samples = [:]; model = nil; modelUsesEmbedding = false; sinceFit = 0; status = Status()
        if let u, let d = try? Data(contentsOf: u), let f = try? JSONDecoder().decode(File.self, from: d), f.version == CardFeatures.version {
            for s in f.samples where s.f.count == CardFeatures.handLength { samples[Self.sampleKey(s.key, s.id)] = s }
        }
        refreshCounts(); refit()
    }

    func save() {
        guard let u = sidecar else { return }
        guard let d = try? JSONEncoder().encode(File(version: CardFeatures.version, samples: Array(samples.values))) else { return }
        do { try d.write(to: u, options: .atomic) } catch { try? d.write(to: u) }
    }
}
