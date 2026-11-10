import Foundation
import Combine
import CoreGraphics

enum DragMode { case none, pan, movePicks, box }

/// Tool state + interaction logic of the picker. UI-independent so it can be tested headlessly.
/// All coordinates passed in are *pick coordinates* (see ViewGeometry) unless stated otherwise.
final class PickController: ObservableObject {
    let store = PickStore()

    @Published var enabled = false
    @Published var showMarkers = true
    @Published var showBoxes = false
    @Published var showScores = false
    @Published var showCandidates = true
    @Published var scoreCutoff: Float = 0
    @Published var activeLabel = PickProject.newProjectScheme.firstID
    @Published var selection = Set<String>()
    @Published var hiddenLabels = Set<String>()
    @Published var boxRect: CGRect?                 // rubber band, pick coordinates
    @Published var showLabelEditor = false
    @Published var draftScheme = LabelScheme.default
    @Published var draftMaybeFlag = false
    @Published var draftRemap: [String: String] = [:]     // removed label id -> label id that takes over its picks
    @Published var schemeError: String?
    @Published var imageSize = CGSize.zero
    @Published var pixelSizeA: Double?
    @Published var currentKey: String?

    // auto-picker state
    @Published var autoParams = AutoParams()
    @Published var autoLive = false
    @Published var autoBusy = false
    @Published var autoMessage: String?
    @Published var externalCommand = ""
    @Published var maxScore: Float = 10              // upper end of the score-cutoff slider (from the last run)
    var pixels: [Float] = []                          // raw pixels of the current micrograph
    var currentURL: URL?
    private var imageGeneration = 0
    private var scoreCache: (gen: Int, sig: String, map: ScoreMap)?
    private var autoToken = 0
    private var lastAutoSerial: [String: Int] = [:]
    private let autoQueue = DispatchQueue(label: "thon.autopick", qos: .userInitiated)

    private var storeBag = Set<AnyCancellable>()
    init() {
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &storeBag)
        $autoParams.dropFirst().debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if let s = self, s.autoLive, s.enabled { s.runAutoPick() } }.store(in: &storeBag)
    }

    // MARK: current micrograph

    func setMicrograph(key: String?, width: Int, height: Int, pixelSizeA: Double?) {
        currentKey = key
        imageGeneration += 1
        autoMessage = nil
        imageSize = CGSize(width: width, height: height)
        self.pixelSizeA = pixelSizeA
        if let key { store.setMicInfo(key, width: width, height: height, angpix: pixelSizeA) }
        selection = []; boxRect = nil; drag = .idle
        if store.scheme.label(activeLabel) == nil { activeLabel = store.scheme.firstID }
    }

    var effectiveAngpix: Double { pixelSizeA ?? 1 }
    func diameterPx(_ p: Pick) -> Double { store.diameterNm(p) * 10 / effectiveAngpix }
    var boxPx: Double { store.project.params.boxNm * 10 / effectiveAngpix }

    func isVisible(_ p: Pick) -> Bool {
        if p.status == .dismissed || hiddenLabels.contains(p.label) { return false }
        if let m = classes, let c = m.pickClass[p.id], hiddenClasses.contains(c) { return false }
        if p.status == .candidate { return showCandidates && (p.score ?? .infinity) >= scoreCutoff }
        return true
    }
    var visiblePicks: [Pick] { currentKey.map { store.picks($0).filter(isVisible) } ?? [] }
    var selectedPicks: [Pick] { currentKey.map { k in store.picks(k).filter { selection.contains($0.id) } } ?? [] }

    func pruneSelection() {
        guard let k = currentKey else { selection = []; return }
        let ids = Set(store.picks(k).filter { isVisible($0) }.map { $0.id })
        selection.formIntersection(ids)
    }

    func inside(_ p: CGPoint) -> Bool {
        p.x >= -0.5 && p.y >= -0.5 && p.x <= imageSize.width - 0.5 && p.y <= imageSize.height - 0.5
    }
    private func clamp(_ x: Double, _ y: Double) -> (Double, Double) {
        (min(max(x, 0), imageSize.width - 1), min(max(y, 0), imageSize.height - 1))
    }

    /// Visible pick under `p`: within the larger of `radiusPx` (a screen-based tolerance) and 0.6 × marker diameter.
    func hit(_ p: CGPoint, radiusPx: Double) -> Pick? {
        guard let k = currentKey else { return nil }
        let maxR = max(radiusPx, 1.8 * store.project.params.diameterNm * 10 / effectiveAngpix)
        let cands = store.grid(k).within(x: p.x, y: p.y, radius: maxR, filter: isVisible)
        return cands.first { hypot($0.x - p.x, $0.y - p.y) <= max(radiusPx, 0.6 * diameterPx($0)) }
    }

    // MARK: mouse state machine

    private enum Drag {
        case idle
        case onPick(hit: Pick, start: CGPoint, snapshot: [Pick], moved: Bool)
        case onEmpty(start: CGPoint, shift: Bool, moved: Bool)
    }
    private var drag = Drag.idle

    func mouseDown(at p: CGPoint, radiusPx: Double, shift: Bool) {
        guard currentKey != nil else { return }
        if let h = hit(p, radiusPx: radiusPx) { drag = .onPick(hit: h, start: p, snapshot: store.picks(currentKey!), moved: false) }
        else { drag = .onEmpty(start: p, shift: shift, moved: false) }
    }

    /// `movedPoints` = pointer travel since mouse-down in view points (click vs drag threshold = 3).
    func mouseDragged(to p: CGPoint, movedPoints: Double, shift: Bool) -> DragMode {
        guard let k = currentKey else { return .pan }
        switch drag {
        case .idle: return .pan
        case .onEmpty(let start, let sh, _):
            guard movedPoints >= 3 else { return .none }
            drag = .onEmpty(start: start, shift: sh, moved: true)
            if sh {
                boxRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                return .box
            }
            return .pan
        case .onPick(let h, let start, let snap, let wasMoved):
            guard wasMoved || movedPoints >= 3 else { return .none }
            if !wasMoved {
                if !selection.contains(h.id) { selection = shift ? selection.union([h.id]) : [h.id] }
                drag = .onPick(hit: h, start: start, snapshot: snap, moved: true)
            }
            let dx = p.x - start.x, dy = p.y - start.y
            let orig = Dictionary(snap.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let sel = selection
            store.transient(k) { list in
                for i in list.indices where sel.contains(list[i].id) {
                    guard let o = orig[list[i].id] else { continue }
                    let (nx, ny) = clamp(o.x + dx, o.y + dy)
                    list[i].x = nx; list[i].y = ny
                }
            }
            return .movePicks
        }
    }

    func mouseUp(at p: CGPoint, shift: Bool) {
        defer { drag = .idle; boxRect = nil }
        guard let k = currentKey else { return }
        switch drag {
        case .idle: break
        case .onPick(let h, _, let snap, let moved):
            if moved { store.commit(k, from: snap, name: selection.count > 1 ? "Move \(selection.count) picks" : "Move pick"); return }
            // plain click on an existing pick
            if h.status == .candidate {
                store.setStatus([h.id], .accepted, in: k); selection = [h.id]
            } else if shift {
                if selection.contains(h.id) { selection.remove(h.id) } else { selection.insert(h.id) }
            } else { selection = [h.id] }
        case .onEmpty(let start, let sh, let moved):
            if moved {
                if sh, let r = boxRect {
                    let inBox = visiblePicks.filter { r.contains(CGPoint(x: $0.x, y: $0.y)) }.map { $0.id }
                    selection = shift ? selection.union(inBox) : Set(inBox)   // (shift is always held for a rubber band)
                }
                return
            }
            // plain click on empty space: add a pick with the active label
            guard inside(start) else { selection = []; return }
            let (x, y) = clamp(start.x, start.y)
            let np = Pick(x: x, y: y, label: activeLabel)
            store.add(np, to: k); selection = [np.id]
        }
    }

    /// Right-click / ctrl-click: delete the pick under the cursor (or the whole selection if it is part of it).
    func rightClick(at p: CGPoint, radiusPx: Double) {
        guard let k = currentKey, let h = hit(p, radiusPx: radiusPx) else { return }
        let ids: Set<String> = selection.contains(h.id) ? selection : [h.id]
        store.remove(ids, from: k); selection.subtract(ids)
    }

    // MARK: auto-picking

    /// Score map (cached while only extraction parameters change) -> candidates -> one undoable edit.
    /// `synchronous` is for tests; the app runs the numerics on a background queue.
    func runAutoPick(synchronous: Bool = false) {
        guard let k = currentKey, !pixels.isEmpty, imageSize.width > 0 else { return }
        var params = autoParams
        params.diameterNm = store.project.params.diameterNm
        autoToken += 1
        let token = autoToken, gen = imageGeneration
        let px = pixels, w = Int(imageSize.width), h = Int(imageSize.height), ap = effectiveAngpix
        let sig = params.scoreSignature
        let cached = (scoreCache?.gen == gen && scoreCache?.sig == sig) ? scoreCache!.map : nil
        autoBusy = true
        let work = { () -> (ScoreMap, [AutoCandidate]) in
            let m = cached ?? AutoPicker.scoreMap(pixels: px, width: w, height: h, angpix: ap, params: params)
            return (m, AutoPicker.extract(m, params: params, angpix: ap))
        }
        let finish = { [weak self] (r: (ScoreMap, [AutoCandidate])) in
            guard let self, token == self.autoToken, gen == self.imageGeneration, self.currentKey == k else { return }
            self.scoreCache = (gen, sig, r.0)
            self.installCandidates(k, r.1, name: "Auto-pick", params: params)
            self.autoBusy = false
        }
        if synchronous { finish(work()) }
        else { autoQueue.async { let r = work(); DispatchQueue.main.async { finish(r) } } }
    }

    private func installCandidates(_ k: String, _ cands: [AutoCandidate], name: String, params: AutoParams?) {
        // a repeat run replaces the previous run's edit instead of stacking undo steps
        if let s = lastAutoSerial[k], store.topSerial(k) == s { store.undo(k) }
        let suppress = 0.5 * store.project.params.diameterNm * 10 / effectiveAngpix
        let n = store.applyCandidates(k, cands, label: activeLabel, suppressPx: suppress, name: name)
        lastAutoSerial[k] = store.topSerial(k)
        if let params { store.setAutoParams(k, params) }
        maxScore = max(10, ceil((cands.map { $0.score }.max() ?? 10)))
        autoMessage = "\(n) candidates" + (cands.count > n ? " (\(cands.count - n) suppressed near existing picks)" : "")
        pruneSelection()
    }

    /// Runs `externalCommand` (prints JSON coordinates) for the current micrograph.
    func runExternalPicker() {
        guard let k = currentKey, let url = currentURL, !externalCommand.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cmd = externalCommand, ap = pixelSizeA, gen = imageGeneration
        autoBusy = true
        autoQueue.async { [weak self] in
            let res = Result { try ExternalPicker.run(template: cmd, micrograph: url, angpix: ap) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.autoBusy = false
                guard gen == self.imageGeneration, self.currentKey == k else { return }
                switch res {
                case .success(let c): self.installCandidates(k, c, name: "External picks", params: nil)
                case .failure(let e): self.autoMessage = "External picker: \(e.localizedDescription)"
                }
            }
        }
    }

    // clean-up tools (each is one undo step)

    /// Dismisses candidates that are hidden by the score cutoff.
    func dismissBelowCutoff() {
        guard let k = currentKey else { return }
        let ids = Set(store.candidates(k).filter { ($0.score ?? .infinity) < scoreCutoff }.map { $0.id })
        if !ids.isEmpty { store.setStatus(ids, .dismissed, in: k) }
    }

    /// Among picks closer than `factor` x diameter keeps manual/accepted picks first, then the highest score.
    @discardableResult
    func removeOverlapping(factor: Double = 0.9) -> Int {
        guard let k = currentKey else { return 0 }
        let live = store.picks(k).filter { $0.status != .dismissed }
        func rank(_ p: Pick) -> (Int, Float) { (p.source == .manual ? 2 : (p.status == .accepted ? 1 : 0), p.score ?? 0) }
        let order = live.sorted { let a = rank($0), b = rank($1); return a.0 != b.0 ? a.0 > b.0 : a.1 > b.1 }
        var kept: [Pick] = [], drop = Set<String>()
        for p in order {
            let minD = factor * diameterPx(p)
            if p.source != .manual, kept.contains(where: { hypot($0.x - p.x, $0.y - p.y) < minD }) { drop.insert(p.id) } else { kept.append(p) }
        }
        if !drop.isEmpty { store.remove(drop, from: k) }
        selection.subtract(drop)
        return drop.count
    }

    /// Removes picks whose center lies within `marginPx` of the image border (default: half the extraction box).
    @discardableResult
    func removeEdgePicks(marginPx: Double? = nil) -> Int {
        guard let k = currentKey else { return 0 }
        let m = marginPx ?? boxPx / 2
        let ids = Set(store.picks(k).filter { $0.status != .dismissed &&
            ($0.x < m || $0.y < m || $0.x > imageSize.width - 1 - m || $0.y > imageSize.height - 1 - m) }.map { $0.id })
        if !ids.isEmpty { store.remove(ids, from: k) }
        selection.subtract(ids)
        return ids.count
    }

    // MARK: classification back-mapping

    @Published var classes: ClassMapping?
    @Published var showClassColors = true
    @Published var hiddenClasses = Set<Int>()
    @Published var classTolerance = 4.0
    lazy var gallery = GalleryModel(pc: self)
    lazy var swipe = SwipeSession(pc: self)
    private var classStar: URL?

    func loadClasses(star: URL, tolerancePx: Double? = nil) {
        guard let text = try? String(contentsOf: star, encoding: .utf8) else { ioMessage = "Could not read \(star.lastPathComponent)"; return }
        let rows = ClassMapping.rows(fromStar: text)
        guard !rows.isEmpty else { ioMessage = "\(star.lastPathComponent): no particle table with _rlnMicrographName, _rlnCoordinateX/Y and _rlnClassNumber"; return }
        let tol = tolerancePx ?? classTolerance
        var picks: [String: [Pick]] = [:]
        for (k, r) in store.project.mics { picks[k] = r.picks.filter { $0.status == .accepted } }
        var m = ClassMapping.build(rows: rows, picks: picks, source: star.lastPathComponent, tolerancePx: tol)
        if let a = ClassMapping.averagesURL(forData: star) { m.averages = ClassMapping.loadAverages(a) }
        classes = m; classStar = star; hiddenClasses = []
        ioMessage = "\(m.matchedRows) of \(m.rows) particles in \(star.lastPathComponent) matched picks (tolerance \(Int(tol)) px); \(m.classes.count) classes" +
            (m.unmatchedMicrographs.isEmpty ? "" : "; no micrograph for: \(m.unmatchedMicrographs.prefix(3).joined(separator: ", "))")
    }
    func reloadClasses() { if let u = classStar { loadClasses(star: u) } }
    func clearClasses() { classes = nil; classStar = nil; hiddenClasses = [] }
    func classColor(of p: Pick) -> String? { classes.flatMap { m in m.pickClass[p.id].map { ClassMapping.color($0) } } }

    /// Picks of class `n` on all micrographs, as (micrograph key, ids).
    func picks(inClass n: Int) -> [String: Set<String>] {
        guard let m = classes else { return [:] }
        var out: [String: Set<String>] = [:]
        for (k, r) in store.project.mics { for p in r.picks where p.status == .accepted && m.pickClass[p.id] == n { out[k, default: []].insert(p.id) } }
        return out
    }
    func selectClass(_ n: Int) {
        guard let k = currentKey, let m = classes else { return }
        selection = Set(store.picks(k).filter { $0.status == .accepted && m.pickClass[$0.id] == n && isVisible($0) }.map { $0.id })
    }
    /// Relabel / dismiss every pick of a class across all micrographs (one undo step per micrograph).
    @discardableResult
    func relabelClass(_ n: Int, to label: String) -> Int {
        let g = picks(inClass: n); for (k, ids) in g { store.relabel(ids, to: label, in: k) }
        return g.values.reduce(0) { $0 + $1.count }
    }
    @discardableResult
    func removeClass(_ n: Int) -> Int {
        let g = picks(inClass: n); for (k, ids) in g { store.remove(ids, from: k) }
        pruneSelection()
        return g.values.reduce(0) { $0 + $1.count }
    }

    // MARK: import / export

    @Published var exportFormats: Set<ExportFormat> = [.relion, .csv]
    @Published var exportOnlyDone = false
    @Published var exportExcludeMaybe = false
    @Published var ioMessage: String?

    var defaultExportFolder: URL? { store.root?.appendingPathComponent("picks_export") }

    @discardableResult
    func exportPicks(to folder: URL) -> ExportSummary? {
        guard let root = store.root else { return nil }
        store.save()
        var o = ExportOptions(); o.formats = exportFormats; o.onlyDone = exportOnlyDone; o.excludeMaybe = exportExcludeMaybe
        do {
            let s = try PickExporter.export(project: store.project, root: root, outDir: folder, options: o)
            let per = store.scheme.labels.compactMap { l in s.totals[l.id].map { "\(l.name) \($0)" } }.joined(separator: ", ")
            ioMessage = "Exported \(s.total) picks from \(s.micrographs) micrographs (\(per)) to \(folder.path)" +
                (s.skippedLabels.isEmpty ? "" : "; not exported: \(s.skippedLabels.joined(separator: ", "))")
            return s
        } catch { ioMessage = "Export failed: \(error.localizedDescription)"; return nil }
    }

    /// `knownKeys` = keys of the micrographs in the open folder (used to match names in the imported files).
    func importPicks(files: [URL], knownKeys: [String], asCandidates: Bool) {
        let plan = PickImporter.plan(files: files, known: Array(Set(knownKeys + store.project.mics.keys)), currentKey: currentKey,
                                     scheme: store.scheme, defaultLabel: activeLabel, asCandidates: asCandidates)
        let r = store.apply(plan)
        var msg = "Imported \(r.added) picks" + (r.skipped > 0 ? " (\(r.skipped) already present)" : "")
        if !plan.unmatched.isEmpty { msg += "; no matching micrograph for: \(plan.unmatched.prefix(4).joined(separator: ", "))" + (plan.unmatched.count > 4 ? " …" : "") }
        if !plan.unknownLabels.isEmpty { msg += "; unknown labels mapped to \(activeLabel): \(plan.unknownLabels.sorted().joined(separator: ", "))" }
        if !plan.notes.isEmpty { msg += "; " + Array(Set(plan.notes)).sorted().joined(separator: "; ") }
        ioMessage = msg
        pruneSelection()
    }

    // MARK: label editor

    func openLabelEditor() {
        draftScheme = store.scheme; draftMaybeFlag = store.project.params.maybeFlag; draftRemap = [:]
        schemeError = nil; showLabelEditor = true
    }

    func addDraftLabel() {
        var n = draftScheme.labels.count + 1
        while draftScheme.label("label_\(n)") != nil { n += 1 }
        let used = Set(draftScheme.labels.map { $0.key.lowercased() })
        let key = ("123456789cdeghjklmnoqrstuwxyz".map(String.init)).first { !used.contains($0) && !LabelScheme.reservedKeys.contains($0) } ?? ""
        draftScheme.labels.append(PickLabel(id: "label_\(n)", name: "Label \(n)", key: key, color: "#4da3ff"))
    }

    /// Labels that still have picks in the project but are absent from the draft: id -> pick count.
    var draftMissingLabels: [(id: String, count: Int)] {
        let ids = Set(draftScheme.labels.map { $0.id })
        return store.labelUsage().filter { !ids.contains($0.key) }.map { (id: $0.key, count: $0.value) }.sorted { $0.id < $1.id }
    }

    /// Loads a preset into the editor and pre-fills a sensible destination for every label the preset drops.
    func loadDraftPreset(_ s: LabelScheme) {
        draftScheme = s; draftRemap = [:]; schemeError = nil
        for m in draftMissingLabels { if let t = s.suggestedTarget(forMissing: m.id) { draftRemap[m.id] = t } }
    }

    /// Validates and applies the edited scheme. Labels that still have picks can only be dropped if the editor
    /// maps them onto a label that remains; otherwise nothing is changed.
    func applyDraftScheme() {
        var errs = draftScheme.validate()
        let ids = Set(draftScheme.labels.map { $0.id })
        var map: [String: String] = [:]
        var unresolved: [String] = []
        for m in draftMissingLabels {
            if let t = draftRemap[m.id], ids.contains(t) { map[m.id] = t } else { unresolved.append(m.id) }
        }
        if !unresolved.isEmpty { errs.append("labels still in use cannot be removed (choose where their picks go): \(unresolved.joined(separator: ", "))") }
        guard errs.isEmpty else { schemeError = errs.joined(separator: "; "); return }
        store.replaceScheme(draftScheme, remapping: map)
        if store.project.params.maybeFlag != draftMaybeFlag { var p = store.project.params; p.maybeFlag = draftMaybeFlag; store.setParams(p) }
        if store.scheme.label(activeLabel) == nil { activeLabel = store.scheme.firstID }
        hiddenLabels.formIntersection(ids)
        pruneSelection()
        schemeError = nil; draftRemap = [:]; showLabelEditor = false
    }

    func schemeFileURL() -> URL? { store.root?.appendingPathComponent(PickStore.schemeFileName) }
    func saveDraftSchemeToFile() {
        guard let u = schemeFileURL() else { return }
        do { try draftScheme.save(to: u); schemeError = nil } catch { schemeError = error.localizedDescription }
    }
    func loadDraftSchemeFromFile() {
        guard let u = schemeFileURL() else { return }
        do { draftScheme = try LabelScheme.load(from: u); schemeError = nil } catch { schemeError = "Could not read labels.json: \(error.localizedDescription)" }
    }

    // MARK: commands

    func setActiveLabel(_ id: String) {
        guard store.scheme.label(id) != nil else { return }
        activeLabel = id
        if let k = currentKey, !selection.isEmpty { store.relabel(selection, to: id, in: k) }
    }
    func deleteSelection() {
        guard let k = currentKey, !selection.isEmpty else { return }
        store.remove(selection, from: k); selection = []
    }
    func acceptSelected() {
        guard let k = currentKey else { return }
        let ids = Set(selectedPicks.filter { $0.status == .candidate }.map { $0.id })
        if !ids.isEmpty { store.setStatus(ids, .accepted, in: k) }
    }
    /// Accepts every visible candidate (those above the score cutoff).
    func acceptAllCandidates() {
        guard let k = currentKey else { return }
        let ids = Set(visiblePicks.filter { $0.status == .candidate }.map { $0.id })
        if !ids.isEmpty { store.setStatus(ids, .accepted, in: k) }
    }
    func dismissAllCandidates() {
        guard let k = currentKey else { return }
        let ids = Set(store.picks(k).filter { $0.status == .candidate }.map { $0.id })
        if !ids.isEmpty { store.setStatus(ids, .dismissed, in: k) }
    }
    /// Toggles the "maybe" flag on the selection (if any are unflagged, flags all; otherwise clears). Only when the flag is enabled.
    func toggleMaybe() {
        guard store.project.params.maybeFlag, let k = currentKey, !selection.isEmpty else { return }
        let sel = selectedPicks.filter { $0.status != .dismissed }
        guard !sel.isEmpty else { return }
        store.setMaybe(Set(sel.map { $0.id }), sel.contains { !$0.isMaybe }, in: k)
    }
    func selectAll() { selection = Set(visiblePicks.map { $0.id }) }
    func clearSelection() { selection = [] }
    func undo() { if let k = currentKey { store.undo(k); pruneSelection() } }
    func redo() { if let k = currentKey { store.redo(k); pruneSelection() } }

    /// Grow/shrink the selected picks by `deltaNm`; with nothing selected, change the project default diameter.
    func resize(byNm d: Double) {
        guard let k = currentKey else { return }
        if selection.isEmpty {
            var p = store.project.params; p.diameterNm = max(1, p.diameterNm + d); store.setParams(p)
        } else {
            for pk in selectedPicks { store.setDiameter([pk.id], nm: max(1, store.diameterNm(pk) + d), in: k) }
        }
    }

    /// Keyboard handling while pick mode is on. Returns true if consumed.
    func handleKey(chars: String, keyCode: UInt16, shift: Bool, command: Bool) -> Bool {
        guard enabled, !command else { return false }
        switch keyCode {
        case 51, 117: deleteSelection(); return true         // delete / forward delete
        case 36, 76: acceptSelected(); return true           // return / enter
        case 53: if selection.isEmpty { enabled = false } else { clearSelection() }; return true   // escape
        default: break
        }
        let c = chars.lowercased()
        if let l = store.scheme.label(forKey: c) { setActiveLabel(l.id); return true }
        switch c {
        case "?", "/": toggleMaybe(); return store.project.params.maybeFlag
        case "a": acceptAllCandidates(); return true
        case "v": showMarkers.toggle(); return true
        case "b": showBoxes.toggle(); return true
        case ",": resize(byNm: -1); return true
        case ".": resize(byNm: 1); return true
        default: return false
        }
    }
}
