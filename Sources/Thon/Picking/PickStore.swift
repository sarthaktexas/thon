import Foundation
import Combine

/// Writes to a sibling temp file and renames over the target (atomic on one volume); never leaves a half-written file.
func writeFileAtomically(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp\(getpid())")
    try data.write(to: tmp)
    if rename(tmp.path, url.path) != 0 {
        let code = errno
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}

/// One undoable change set for a single micrograph.
struct PickEdit {
    struct Change { var id: String; var before: Pick?; var after: Pick? }
    var key: String
    var name: String
    var changes: [Change]
    var serial = 0                   // identity of the edit (used to coalesce repeated auto-pick runs)
}

/// Uniform grid for fast nearest-pick queries.
struct PickGrid {
    let cell: Double
    private var cells: [Int64: [Int]] = [:]
    private(set) var picks: [Pick]

    init(picks: [Pick], cell: Double = 64) {
        self.cell = cell; self.picks = picks
        for (i, p) in picks.enumerated() { cells[Self.k(Int(floor(p.x / cell)), Int(floor(p.y / cell))), default: []].append(i) }
    }
    private static func k(_ cx: Int, _ cy: Int) -> Int64 { Int64(cx) << 32 | Int64(UInt32(truncatingIfNeeded: cy)) }

    /// Nearest pick within `radius` (px) that passes `filter`; ties -> first inserted.
    func nearest(x: Double, y: Double, radius: Double, filter: (Pick) -> Bool = { _ in true }) -> Pick? {
        let c0x = Int(floor((x - radius) / cell)), c1x = Int(floor((x + radius) / cell))
        let c0y = Int(floor((y - radius) / cell)), c1y = Int(floor((y + radius) / cell))
        var best: (Int, Double)?
        for cx in c0x...c1x { for cy in c0y...c1y {
            for i in cells[Self.k(cx, cy)] ?? [] {
                let p = picks[i]
                guard filter(p) else { continue }
                let d = hypot(p.x - x, p.y - y)
                if d <= radius, best == nil || d < best!.1 || (d == best!.1 && i < best!.0) { best = (i, d) }
            }
        } }
        return best.map { picks[$0.0] }
    }

    /// All picks within `radius`, nearest first.
    func within(x: Double, y: Double, radius: Double, filter: (Pick) -> Bool = { _ in true }) -> [Pick] {
        let c0x = Int(floor((x - radius) / cell)), c1x = Int(floor((x + radius) / cell))
        let c0y = Int(floor((y - radius) / cell)), c1y = Int(floor((y + radius) / cell))
        var hits: [(Int, Double)] = []
        for cx in c0x...c1x { for cy in c0y...c1y {
            for i in cells[Self.k(cx, cy)] ?? [] where filter(picks[i]) {
                let d = hypot(picks[i].x - x, picks[i].y - y)
                if d <= radius { hits.append((i, d)) }
            }
        } }
        return hits.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { picks[$0.0] }
    }

    func inRect(x0: Double, y0: Double, x1: Double, y1: Double, filter: (Pick) -> Bool = { _ in true }) -> [Pick] {
        let lx = min(x0, x1), hx = max(x0, x1), ly = min(y0, y1), hy = max(y0, y1)
        return picks.filter { $0.x >= lx && $0.x <= hx && $0.y >= ly && $0.y <= hy && filter($0) }
    }
}

/// Project state + undo/redo + persistence. Main-thread only. UI observes `revision` / objectWillChange.
final class PickStore: ObservableObject {
    @Published private(set) var project = PickProject()
    @Published private(set) var revision = 0               // bumps on every change (views redraw)
    @Published private(set) var dirty = false
    @Published private(set) var lastSaved: Date?
    @Published var lastError: String?

    private(set) var root: URL?                            // project folder
    private(set) var projectURL: URL?
    private var undoStacks: [String: [PickEdit]] = [:]
    private var redoStacks: [String: [PickEdit]] = [:]
    private var gridCache: [String: (rev: Int, grid: PickGrid)] = [:]
    private var micRev: [String: Int] = [:]
    private var serialCounter = 0
    private var micInfo: [String: (Int, Int, Double?)] = [:]
    func topSerial(_ key: String) -> Int? { undoStacks[key]?.last?.serial }

    var saveDelay: TimeInterval = 1.5
    var backupInterval: TimeInterval = 300
    var backupsToKeep = 30
    private var saveWork: DispatchWorkItem?
    private var lastBackup: Date?
    static let fileName = "picks_project.json"
    static let schemeFileName = "labels.json"

    var scheme: LabelScheme { project.scheme }

    // MARK: project lifecycle

    /// Opens `folder/picks_project.json` if present, else starts a new project there (using `labels.json` if it exists).
    @discardableResult
    func openProject(folder: URL) -> Bool {
        flush()
        root = folder
        projectURL = folder.appendingPathComponent(Self.fileName)
        undoStacks = [:]; redoStacks = [:]; gridCache = [:]; micRev = [:]
        lastBackup = nil
        var ok = true
        if let u = projectURL, FileManager.default.fileExists(atPath: u.path) {
            do { project = try Self.decode(Data(contentsOf: u)) }
            catch { lastError = "Could not read \(Self.fileName): \(error.localizedDescription)"; project = PickProject(); ok = false }
        } else {
            project = PickProject()
            let sch = folder.appendingPathComponent(Self.schemeFileName)
            if FileManager.default.fileExists(atPath: sch.path), let s = try? LabelScheme.load(from: sch), s.validate().isEmpty {
                project.scheme = s
            }
        }
        dirty = false; revision += 1
        return ok
    }

    static func decode(_ d: Data) throws -> PickProject { try JSONDecoder().decode(PickProject.self, from: d) }
    func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(project)
    }

    /// Key of a micrograph: path relative to the project folder (forward slashes), else the absolute path.
    func key(for url: URL) -> String {
        guard let root else { return url.path }
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    func setScheme(_ s: LabelScheme) {
        guard s != project.scheme else { return }
        project.scheme = s; touch(nil)
    }
    func setParams(_ p: ProjectParams) {
        guard p != project.params else { return }
        project.params = p; touch(nil)
    }

    // MARK: reading

    func record(_ key: String) -> MicRecord { project.mics[key] ?? MicRecord() }
    func picks(_ key: String) -> [Pick] { project.mics[key]?.picks ?? [] }
    func accepted(_ key: String) -> [Pick] { picks(key).filter { $0.status == .accepted } }
    func candidates(_ key: String) -> [Pick] { picks(key).filter { $0.status == .candidate } }
    func pick(_ id: String, in key: String) -> Pick? { project.mics[key]?.picks.first { $0.id == id } }
    func diameterNm(_ p: Pick) -> Double { p.diameterNm ?? project.params.diameterNm }

    func counts(_ key: String) -> [String: Int] {
        var c: [String: Int] = [:]
        for p in picks(key) where p.status == .accepted { c[p.label, default: 0] += 1 }
        return c
    }
    func totalCounts() -> [String: Int] {
        var c: [String: Int] = [:]
        for (_, r) in project.mics { for p in r.picks where p.status == .accepted { c[p.label, default: 0] += 1 } }
        return c
    }

    func grid(_ key: String) -> PickGrid {
        let rev = micRev[key] ?? 0
        if let g = gridCache[key], g.rev == rev { return g.grid }
        let g = PickGrid(picks: picks(key).filter { $0.status != .dismissed })
        gridCache[key] = (rev, g)
        return g
    }

    // MARK: editing

    /// Applies `mutate` to the micrograph's pick list, records the diff as one undoable edit.
    @discardableResult
    func perform(_ key: String, _ name: String, _ mutate: (inout [Pick]) -> Void) -> Bool {
        let before = picks(key)
        var after = before
        mutate(&after)
        var edit = Self.diff(key: key, name: name, before: before, after: after)
        guard !edit.changes.isEmpty else { return false }
        serialCounter += 1; edit.serial = serialCounter
        setPicks(key, after)
        undoStacks[key, default: []].append(edit)
        if undoStacks[key]!.count > 1000 { undoStacks[key]!.removeFirst() }
        redoStacks[key] = []
        touch(key)
        return true
    }

    /// Live update without history (e.g. during a drag). Follow with `commit(key, from:, name:)`.
    func transient(_ key: String, _ mutate: (inout [Pick]) -> Void) {
        var after = picks(key); mutate(&after)
        setPicks(key, after); micRev[key, default: 0] += 1; revision += 1
    }
    /// Records the net change between `snapshot` (taken before the transient edits) and now as one undo step.
    func commit(_ key: String, from snapshot: [Pick], name: String) {
        var edit = Self.diff(key: key, name: name, before: snapshot, after: picks(key))
        guard !edit.changes.isEmpty else { return }
        serialCounter += 1; edit.serial = serialCounter
        undoStacks[key, default: []].append(edit); redoStacks[key] = []
        touch(key)
    }

    func canUndo(_ key: String) -> Bool { !(undoStacks[key]?.isEmpty ?? true) }
    func canRedo(_ key: String) -> Bool { !(redoStacks[key]?.isEmpty ?? true) }
    func undoName(_ key: String) -> String? { undoStacks[key]?.last?.name }

    @discardableResult func undo(_ key: String) -> Bool {
        guard let e = undoStacks[key]?.popLast() else { return false }
        apply(e, forward: false); redoStacks[key, default: []].append(e); touch(key); return true
    }
    @discardableResult func redo(_ key: String) -> Bool {
        guard let e = redoStacks[key]?.popLast() else { return false }
        apply(e, forward: true); undoStacks[key, default: []].append(e); touch(key); return true
    }

    func setDone(_ key: String, _ v: Bool) { mutateRecord(key) { $0.done = v }; touch(key, structural: false) }
    func setNote(_ key: String, _ s: String) { mutateRecord(key) { $0.note = s }; touch(key, structural: false) }
    /// Remembers size / pixel size of a micrograph; written into its record once it has one (does not dirty the project otherwise).
    func setMicInfo(_ key: String, width: Int, height: Int, angpix: Double?) {
        micInfo[key] = (width, height, angpix)
        guard let r = project.mics[key], r.width != width || r.height != height || r.angpix != angpix else { return }
        mutateRecord(key) { $0.width = width; $0.height = height; $0.angpix = angpix }
        touch(key, structural: false)
    }
    func setSwipe(_ key: String, _ log: SwipeLog?) { mutateRecord(key) { $0.swipe = log }; touch(key, structural: false) }
    func setAutoParams(_ key: String, _ a: AutoParams?) { mutateRecord(key) { $0.auto = a }; touch(key, structural: false) }

    // convenience edits
    @discardableResult func add(_ p: Pick, to key: String) -> Bool { perform(key, "Add pick") { $0.append(p) } }
    /// Deleting a manual pick removes it; deleting an auto-picked pick (candidate or accepted) marks it `dismissed`
    /// so the next auto-pick run does not bring it back.
    @discardableResult func remove(_ ids: Set<String>, from key: String) -> Bool {
        perform(key, ids.count == 1 ? "Delete pick" : "Delete \(ids.count) picks") { l in
            l.removeAll { ids.contains($0.id) && $0.source == .manual }
            for i in l.indices where ids.contains(l[i].id) && l[i].source == .auto { l[i].status = .dismissed }
        }
    }
    @discardableResult func relabel(_ ids: Set<String>, to label: String, in key: String) -> Bool {
        perform(key, "Relabel") { l in for i in l.indices where ids.contains(l[i].id) { l[i].label = label } }
    }
    @discardableResult func setDiameter(_ ids: Set<String>?, nm: Double?, in key: String) -> Bool {
        perform(key, "Resize") { l in for i in l.indices where ids?.contains(l[i].id) ?? true { l[i].diameterNm = nm } }
    }
    @discardableResult func setStatus(_ ids: Set<String>, _ s: PickStatus, in key: String) -> Bool {
        perform(key, s == .accepted ? "Accept" : "Dismiss") { l in for i in l.indices where ids.contains(l[i].id) { l[i].status = s } }
    }

    /// Replaces the micrograph's undecided auto candidates with `cands` as ONE undoable edit. Accepted picks and
    /// dismissed candidates are kept; new candidates within `suppressPx` of either are dropped.
    @discardableResult
    func applyCandidates(_ key: String, _ cands: [AutoCandidate], label: String, suppressPx: Double, name: String) -> Int {
        var added = 0
        perform(key, name) { l in
            l.removeAll { $0.status == .candidate && $0.source == .auto }
            let fixed = PickGrid(picks: l.filter { $0.status != .candidate }, cell: max(16, suppressPx))
            for c in cands where fixed.nearest(x: c.x, y: c.y, radius: suppressPx) == nil {
                l.append(Pick(x: c.x, y: c.y, label: label, score: c.score, source: .auto, status: .candidate)); added += 1
            }
        }
        return added
    }

    // MARK: internals

    private func setPicks(_ key: String, _ l: [Pick]) {
        var r = project.mics[key] ?? MicRecord(); r.picks = l
        if let i = micInfo[key] { r.width = i.0; r.height = i.1; r.angpix = i.2 }
        project.mics[key] = r
    }
    private func mutateRecord(_ key: String, _ f: (inout MicRecord) -> Void) {
        var r = project.mics[key] ?? MicRecord(); f(&r); project.mics[key] = r
    }
    private func touch(_ key: String?, structural: Bool = true) {
        if let key, structural { micRev[key, default: 0] += 1 }
        revision += 1; dirty = true
        scheduleSave()
    }

    static func diff(key: String, name: String, before: [Pick], after: [Pick]) -> PickEdit {
        let b = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let a = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        var ch: [PickEdit.Change] = []
        for p in before where a[p.id] != p { ch.append(.init(id: p.id, before: p, after: a[p.id])) }
        for p in after where b[p.id] == nil { ch.append(.init(id: p.id, before: nil, after: p)) }
        return PickEdit(key: key, name: name, changes: ch)
    }

    private func apply(_ e: PickEdit, forward: Bool) {
        var l = picks(e.key)
        for c in e.changes {
            let target = forward ? c.after : c.before
            if let i = l.firstIndex(where: { $0.id == c.id }) {
                if let t = target { l[i] = t } else { l.remove(at: i) }
            } else if let t = target { l.append(t) }
        }
        setPicks(e.key, l)
    }

    // MARK: persistence

    func scheduleSave() {
        saveWork?.cancel()
        guard saveDelay > 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: w)
    }

    /// Writes immediately (atomic); also writes a rolling backup if one is due.
    @discardableResult
    func save(forceBackup: Bool = false) -> Bool {
        saveWork?.cancel(); saveWork = nil
        guard let url = projectURL else { return false }
        do {
            let data = try encoded()
            try writeFileAtomically(data, to: url)
            dirty = false; lastSaved = Date()
            if forceBackup || lastBackup == nil || Date().timeIntervalSince(lastBackup!) >= backupInterval { writeBackup(data) }
            return true
        } catch { lastError = "Autosave failed: \(error.localizedDescription)"; return false }
    }
    func flush() { if dirty { save() } }

    private func writeBackup(_ data: Data) {
        guard let root else { return }
        let dir = root.appendingPathComponent("backups")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss_SSS"; f.locale = Locale(identifier: "en_US_POSIX")
        let name = "picks_project_\(f.string(from: Date())).json"
        try? writeFileAtomically(data, to: dir.appendingPathComponent(name))
        lastBackup = Date()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("picks_project_") && $0.hasSuffix(".json") }.sorted()
        if files.count > backupsToKeep {
            for old in files.prefix(files.count - backupsToKeep) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        }
    }
}
