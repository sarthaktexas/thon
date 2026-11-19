import Foundation
import Combine

/// What the "types" tests compare neighbours by.
enum PatternGroupBy: String, CaseIterable, Identifiable {
    case label = "Label", cls = "Class", none = "Nothing"
    var id: String { rawValue }
}

/// State of the Picks tab ▸ Pattern suggestions card. The statistics live in `PatternEngine` (Patterns.swift); this class feeds it the
/// saved picks, runs it off the main thread (one thread, low priority) and keeps the answer for the card and the viewer overlay.
final class PatternModel: ObservableObject {
    unowned let pc: PickController
    @Published var scopeAll = false
    @Published var groupBy = PatternGroupBy.label
    @Published var allowUnevenDensity = true
    /// Also use the auto-picker's candidates that are above the score cutoff (unreviewed, so they may be picker artefacts rather than particles).
    @Published var includeCandidates = false
    @Published private(set) var report: PatternReport?
    @Published private(set) var reportScope = ""
    @Published var busy = false
    @Published var progress: String?
    @Published var message: String?
    /// Kinds drawn on the micrograph (only those with something to draw).
    @Published var shown = Set<PatternKind>()
    /// Tests set this to shorten the run; nil = 1999 random arrangements for one micrograph of up to 800 picks (fewer for bigger ones), 499 each for several.
    var nSimOverride: Int?

    private var token = 0
    private let queue = DispatchQueue(label: "thon.patterns", qos: .utility)
    private var runSignature = 0
    private var staleCache: (revision: Int, stale: Bool) = (-1, false)

    init(pc: PickController) { self.pc = pc }

    // MARK: inputs

    /// Labels that count: saved, exported and not switched off in the Labels card.
    private var countedLabels: Set<String> {
        let hidden = pc.hiddenLabels
        return Set(pc.store.scheme.labels.filter { $0.exported && !hidden.contains($0.id) }.map { $0.id })
    }

    var scopeKeys: [String] {
        scopeAll ? pc.store.project.mics.keys.sorted() : (pc.currentKey.map { [$0] } ?? [])
    }

    func buildInputs(keys: [String]) -> [PatternInput] {
        let project = pc.store.project, labels = countedLabels
        var out: [PatternInput] = []
        let mode: PatternGroupBy = (groupBy == .cls && pc.classes == nil) ? .none : groupBy
        for k in keys {
            guard let rec = project.mics[k], !project.isHiddenAverage(k) else { continue }
            let cutoff = pc.scoreCutoff, cands = includeCandidates
            let picks = rec.picks.filter { ($0.status == .accepted || (cands && $0.status == .candidate && ($0.score ?? .infinity) >= cutoff)) && labels.contains($0.label) }
            guard !picks.isEmpty else { continue }
            let isCur = k == pc.currentKey
            let ap = rec.angpix ?? (isCur ? pc.pixelSizeA : nil) ?? 0
            let w = Double(rec.width ?? (isCur ? Int(pc.imageSize.width) : 0)), h = Double(rec.height ?? (isCur ? Int(pc.imageSize.height) : 0))
            let dnm = picks.map { $0.diameterNm ?? project.params.diameterNm }.sorted()
            let med = dnm[dnm.count / 2]
            let groups: [String] = picks.map { p in
                switch mode {
                case .label: return p.label
                case .cls: return pc.classes?.pickClass[p.id].map { "class \($0)" } ?? "none"
                case .none: return ""
                }
            }
            out.append(PatternInput(key: k, x: picks.map { $0.x }, y: picks.map { $0.y }, group: groups, width: w, height: h,
                                    diameterPx: ap > 0 ? med * 10 / ap : 0, angpix: ap))
        }
        return out
    }

    private func signature(_ inputs: [PatternInput]) -> Int {
        var h = Hasher()
        h.combine(inputs.count); h.combine(scopeAll); h.combine(groupBy); h.combine(allowUnevenDensity); h.combine(includeCandidates)
        for i in inputs { h.combine(i.key); h.combine(i.x.count); for t in 0..<i.x.count { h.combine(i.x[t]); h.combine(i.y[t]) }; h.combine(i.group) }
        return h.finalize()
    }

    /// True when the picks (or the options) changed since the result on screen was computed.
    func isStale() -> Bool {
        guard report != nil else { return false }
        let rev = pc.store.revision
        if staleCache.revision == rev { return staleCache.stale }
        let s = signature(buildInputs(keys: scopeKeys)) != runSignature
        staleCache = (rev, s)
        return s
    }

    // MARK: run

    func run() {
        guard !busy else { return }
        let keys = scopeKeys
        let inputs = buildInputs(keys: keys)
        guard !inputs.isEmpty else {
            message = (scopeAll ? "No accepted picks to analyse." : "No accepted picks on this micrograph.") + (includeCandidates ? "" : " Tick Include candidates to use the auto-picker's unreviewed candidates.")
            return
        }
        var params = PatternParams()
        params.useDensity = allowUnevenDensity
        // more random arrangements = finer p-values (the smallest is 1 / (nSim + 1)); fewer when there is a lot to compute
        let biggest = inputs.map { $0.x.count }.max() ?? 0
        params.nSim = nSimOverride ?? (inputs.count == 1 ? (biggest <= 800 ? 1999 : biggest <= 2500 ? 999 : 499) : 499)
        token += 1
        let tk = token
        busy = true; message = nil
        progress = "Looking at micrograph 1 of \(inputs.count)…"
        let cands = includeCandidates
        let sig = signature(inputs), scope = scopeAll ? "All micrographs (\(inputs.count))" : "This micrograph"
        queue.async { [weak self] in
            let rep = PatternEngine.run(inputs, params: params, cancel: { self?.token != tk }, progress: { i, n in
                DispatchQueue.main.async { guard let self, self.token == tk, self.busy else { return }; self.progress = "Looking at micrograph \(min(i + 1, n)) of \(n)…" }
            })
            DispatchQueue.main.async {
                guard let self, self.token == tk else { return }
                self.busy = false; self.progress = nil
                var rep = rep
                if cands { rep.notes.append("Includes the auto-picker's candidates above the score cutoff. They are unreviewed, so a pattern here may come from the picker (noise peaks, ice, stain edges, its spacing rule) as much as from particles. Check the finding again on accepted picks.") }
                self.report = rep; self.reportScope = scope; self.runSignature = sig
                self.staleCache = (self.pc.store.revision, false)
                self.shown = Set(rep.findings.map { $0.kind }.filter { k in rep.micrographs.contains { !($0.geometry[k]?.isEmpty ?? true) } })
                if rep.micrographs.isEmpty { self.message = "Nothing to analyse: " + (rep.skipped.first.map { "\($0.why)." } ?? "no picks.") }
            }
        }
    }

    func cancel() { token += 1; busy = false; progress = nil; message = "Stopped." }
    func clear() { token += 1; busy = false; progress = nil; report = nil; shown = []; message = nil }

    // MARK: overlay

    /// Shapes to draw on the micrograph with this key, per kind.
    func overlay(forKey key: String) -> [(PatternKind, PatternGeometry)] {
        guard let r = report?.micrographs.first(where: { $0.key == key }) else { return [] }
        return PatternKind.allCases.compactMap { k in shown.contains(k) ? r.geometry[k].map { (k, $0) } : nil }
    }

    /// Kinds that can be drawn on the micrograph on screen.
    func drawable(forKey key: String?) -> Set<PatternKind> {
        guard let key, let r = report?.micrographs.first(where: { $0.key == key }) else { return [] }
        return Set(r.geometry.filter { !$0.value.isEmpty }.map { $0.key })
    }

    // MARK: export

    func csvText() -> String {
        guard let rep = report else { return "" }
        var l = ["pattern,scope,p_value,p_adjusted_for_all_tests,level,micrographs_tested,micrographs_p_below_0.05,effect_sd,summary"]
        for r in rep.rows {
            l.append([r.kind.rawValue, PickExporter.csvField(reportScope), String(format: "%.4g", r.p), String(format: "%.4g", r.pAdj), r.level.label,
                      String(r.micrographs), String(r.significantIn), String(format: "%.2f", r.effect), PickExporter.csvField(r.summary)].joined(separator: ","))
        }
        return l.joined(separator: "\n") + "\n"
    }
}
