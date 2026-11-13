import Foundation

/// The picker's workflow, one micrograph at a time: find particles automatically, check section by section (where particles
/// are also added and removed by hand), then export. The automatic step can be skipped; the check cannot, so one way of
/// finding particles always runs: after a skip the check visits every section instead of only those with candidates.
enum FlowStep: String, CaseIterable, Identifiable {
    case auto, review, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Find automatically"
        case .review: return "Check and pick by hand"
        case .export: return "Export"
        }
    }
    var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

enum StepMark: String, Codable { case done, skipped }

/// What was done on one micrograph (saved in the project file). The check is tracked by `MicRecord.done` and the done sections.
/// An older file that also carries a mark for the removed "pick by hand" step simply ignores it.
struct FlowMarks: Codable, Equatable {
    var auto: StepMark?
    var isEmpty: Bool { auto == nil }

    func mark(_ s: FlowStep) -> StepMark? { s == .auto ? auto : nil }
    mutating func set(_ s: FlowStep, _ m: StepMark?) { if s == .auto { auto = m } }

    /// Only the automatic step can be skipped: the check, where circles are also added by hand, always runs.
    func canSkip(_ s: FlowStep) -> Bool { s == .auto }
    /// The step to show for a micrograph: the automatic step until it was run or skipped, then the check.
    var nextStep: FlowStep { auto == nil ? .auto : .review }
}

/// Particle size range of the automatic step → the sizes the picker searches.
enum SizeRange {
    /// Sizes closer than this cannot be told apart by the picker's core-minus-annulus filter (measured on synthetic discs).
    static let minRatio = 1.4
    /// Step between searched sizes: a little above `minRatio`, so neighbouring scales stay distinct.
    static let step = 1.5
    static let maxScales = 6
    static let bounds: ClosedRange<Double> = 3...150

    /// Sizes to search for particles between `lo` and `hi` nm: [] for one size (no sweep), else a geometric ladder from `lo` to `hi`
    /// whose steps are about `step` and never below `minRatio`. A range narrower than `minRatio` is searched as one size
    /// at its geometric mean (the project diameter).
    static func diameters(min lo: Double, max hi: Double) -> [Double] {
        guard lo > 0, hi > lo * 1.0001, hi / lo >= minRatio else { return [] }
        let span = log(hi / lo)
        let wanted = Int((span / log(step)).rounded())
        let allowed = Int(floor(span / log(minRatio) + 1e-9))
        let k = Swift.max(1, Swift.min(wanted, allowed, maxScales - 1))
        let r = pow(hi / lo, 1 / Double(k))
        return (0...k).map { i in i == 0 ? lo : (i == k ? hi : ((lo * pow(r, Double(i))) * 10).rounded() / 10) }
    }
    /// The size a hand-placed circle starts with: the geometric mean of the range.
    static func typical(min lo: Double, max hi: Double) -> Double { ((lo * hi).squareRoot() * 10).rounded() / 10 }
}

extension ProjectParams {
    /// Box : diameter ratio of a new project, and what "Auto" returns to after a typed-in box.
    static let defaultBoxRatio = 1.45
    /// Box : diameter ratio the automatic box keeps.
    var boxRatio: Double { boxNm / max(diameterNm, 1e-9) }
    /// Sizes the automatic step searches (empty = just `diameterNm`).
    var sweepDiametersNm: [Double] {
        guard let a = sizeMinNm, let b = sizeMaxNm else { return [] }
        return SizeRange.diameters(min: a, max: b)
    }
    /// Boxes for those sizes: empty = follow each diameter, one value = the typed-in box for all.
    var sweepBoxesNm: [Double] { isBoxCustom ? [boxNm] : [] }

    /// New size range (nm). Equal ends = one size. Keeps the box following the diameter unless it was typed in.
    mutating func setSize(min lo: Double, max hi: Double) {
        let a = Swift.min(lo, hi), b = Swift.max(lo, hi)
        let ratio = boxRatio
        if b > a * 1.0001 { sizeMinNm = a; sizeMaxNm = b; diameterNm = SizeRange.typical(min: a, max: b) }
        else { sizeMinNm = nil; sizeMaxNm = nil; diameterNm = a }
        if !isBoxCustom { boxNm = ((diameterNm * ratio) * 10).rounded() / 10 }
    }
    /// The size range as the slider shows it (both ends equal when there is one size).
    var sizeRangeNm: (min: Double, max: Double) { (sizeMinNm ?? diameterNm, sizeMaxNm ?? diameterNm) }
}

extension PickStore {
    func isUnpacked(base: String) -> Bool { project.isUnpacked(base: base) }
    /// Saves whether a stack is unpacked (nil = forget the choice).
    func setUnpacked(_ base: String, _ v: Bool?) {
        guard record(base).unpacked != v else { return }
        mutateMic(base) { $0.unpacked = v }
    }
    func flow(_ key: String) -> FlowMarks { record(key).flow ?? FlowMarks() }
    func setFlow(_ key: String, _ s: FlowStep, _ m: StepMark?) {
        var f = flow(key)
        guard f.mark(s) != m else { return }
        f.set(s, m)
        mutateMic(key) { $0.flow = f.isEmpty ? nil : f }
    }

    /// Removes picks for good (they do not come back as dismissed). With a `label`: its accepted picks, the ones the label row counts.
    /// Without: every accepted pick and every candidate. `everything` also forgets dismissed candidates, the done sections and the
    /// workflow marks (a fresh start for the micrograph).
    /// One undo step. Returns how many picks went.
    @discardableResult
    func removeAll(in key: String, label: String? = nil, everything: Bool = false) -> Int {
        let n = picks(key).filter { matches($0, label: label, everything: everything) }.count
        if n > 0 { perform(key, label == nil ? "Delete all picks" : "Delete all \(label!) picks") { $0.removeAll { matches($0, label: label, everything: everything) } } }
        if everything { resetReview(key) }
        return n
    }
    private func matches(_ p: Pick, label: String?, everything: Bool) -> Bool {
        if let label { return p.label == label && p.status == .accepted }
        return p.status != .dismissed || everything
    }
    /// The same on every micrograph (one undo step each). Returns the total.
    @discardableResult
    func removeAllEverywhere(label: String) -> Int {
        project.mics.keys.sorted().reduce(0) { $0 + removeAll(in: $1, label: label) }
    }
    /// Done sections and workflow marks of a micrograph (not the picks).
    func resetReview(_ key: String) {
        guard record(key).sections != nil || record(key).flow != nil || record(key).done else { return }
        mutateMic(key) { $0.sections = nil; $0.flow = nil; $0.done = false }
    }
}

// MARK: controller side of the workflow

extension PickController {
    /// Called when the open step changes: the check runs the section-by-section editor (and with it pick mode), the others
    /// turn both off so a stray click in the viewer cannot add a pick.
    func stepChanged(from old: FlowStep) {
        switch flowStep {
        case .review:
            // with the automatic step skipped there are no candidates to visit: go through every section, so picking by hand happens here
            if let k = currentKey, store.flow(k).auto == .skipped { crops.includeEmpty = true }
            if !crops.active { crops.active = true }
        default:
            if crops.active { crops.active = false }
            enabled = false
        }
    }

    var flow: FlowMarks { currentKey.map { store.flow($0) } ?? FlowMarks() }

    func canSkip(_ s: FlowStep) -> Bool { flow.canSkip(s) }

    /// Marks the automatic step finished on this micrograph and opens the check.
    func finish(_ s: FlowStep) {
        guard let k = currentKey, s == .auto else { return }
        store.setFlow(k, s, .done)
        flowStep = .review
    }
    /// Skips the automatic step: the check opens and visits every section.
    @discardableResult
    func skip(_ s: FlowStep) -> Bool {
        guard let k = currentKey, canSkip(s) else { return false }
        store.setFlow(k, s, .skipped)
        crops.includeEmpty = true
        flowStep = .review
        return true
    }
    /// Puts a skipped or finished automatic step back to "not started" and opens it.
    func reopen(_ s: FlowStep) {
        guard let k = currentKey, s == .auto else { return }
        store.setFlow(k, s, nil); crops.includeEmpty = false; flowStep = s
    }

    // MARK: size range of the automatic step

    /// Slider ends (nm). Equal ends = one size. Updates the box (unless typed in) and the sizes the picker searches.
    func setSizeRange(min lo: Double, max hi: Double) {
        var p = store.project.params; p.setSize(min: lo, max: hi); store.setParams(p); applySweepText()
        crops.penNm = 0                                   // new circles in the check start at the new typical size
    }
    /// nil = the box follows the diameter; a value = that box (nm) for every particle.
    func setBox(custom nm: Double?) {
        var p = store.project.params
        if let nm { p.boxCustom = true; p.boxNm = nm }
        else { p.boxCustom = nil; p.boxNm = ((p.diameterNm * ProjectParams.defaultBoxRatio) * 10).rounded() / 10 }
        store.setParams(p); applySweepText()
    }

    // MARK: delete all

    /// Every pick and candidate of the open micrograph, plus its done sections and workflow marks. Picks are undoable (⌘Z).
    @discardableResult
    func deleteAllPicks() -> Int {
        guard let k = currentKey else { return 0 }
        let n = store.removeAll(in: k, everything: true)
        afterBulkDelete(n, what: "picks", everywhere: false)
        if flowStep != .export { flowStep = .auto }
        return n
    }
    /// Every accepted pick of one label, on the open micrograph or on all of them.
    @discardableResult
    func deleteAll(label: String, everywhere: Bool) -> Int {
        let n: Int
        if everywhere { n = store.removeAllEverywhere(label: label) }
        else if let k = currentKey { n = store.removeAll(in: k, label: label) } else { n = 0 }
        afterBulkDelete(n, what: store.scheme.label(label)?.name ?? label, everywhere: everywhere)
        return n
    }
    private func afterBulkDelete(_ n: Int, what: String, everywhere: Bool) {
        selection = []
        editMessage = n == 0 ? "Nothing to delete." : "Deleted \(n) \(what)\(everywhere ? " on all micrographs" : ""). ⌘Z undoes this on the open micrograph."
        if crops.active { crops.rebuild() }
    }

    // MARK: export destination

    /// The folder chosen for this project's export (nil = the default next to the project).
    var exportFolder: URL? {
        get { exportChoice.flatMap { $0.root == store.root ? $0.folder : nil } }
        set { exportChoice = newValue.map { (store.root, $0) }; objectWillChange.send() }
    }
    var exportDestination: URL? { exportFolder ?? defaultExportFolder }
}
