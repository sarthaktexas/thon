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
    let tagChanges = TagChanges()

    private(set) var root: URL?                            // project folder (for a .thon project: the folder containing the file)
    private(set) var projectURL: URL?
    private(set) var keyMap = PickKeyMap(root: nil)         // micrograph file <-> key (session aware)
    static let projectExtension = "thon"
    var isProjectFile: Bool { projectURL?.pathExtension.lowercased() == Self.projectExtension }
    var projectTitle: String { project.name ?? projectURL?.deletingPathExtension().lastPathComponent ?? "" }
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
        keyMap = PickKeyMap(root: folder)
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

    /// Opens a `.thon` project file (picks, label scheme and sessions all live in it). A missing file starts an empty project there.
    @discardableResult
    func openProject(file: URL) -> Bool {
        flush()
        root = file.deletingLastPathComponent()
        projectURL = file
        undoStacks = [:]; redoStacks = [:]; gridCache = [:]; micRev = [:]
        lastBackup = nil
        var ok = true
        if FileManager.default.fileExists(atPath: file.path) {
            do { project = try Self.decode(Data(contentsOf: file)) }
            catch { lastError = "Could not read \(file.lastPathComponent): \(error.localizedDescription)"; project = PickProject(); ok = false }
        } else {
            project = PickProject()
        }
        rebuildKeyMap()
        dirty = false; revision += 1
        return ok
    }

    /// Creates a new `.thon` project at `file` with one session per folder (named after the folder) and saves it.
    @discardableResult
    func createProject(file: URL, name: String? = nil, folders: [URL]) -> Bool {
        flush()
        root = file.deletingLastPathComponent()
        projectURL = file
        undoStacks = [:]; redoStacks = [:]; gridCache = [:]; micRev = [:]
        lastBackup = nil
        project = PickProject()
        project.name = name ?? file.deletingPathExtension().lastPathComponent
        for f in folders { appendSession(folder: f, name: nil) }
        rebuildKeyMap()
        dirty = true; revision += 1
        return save()
    }

    private func rebuildKeyMap() { keyMap = PickKeyMap(root: root, sessions: project.sessions) }
    /// Value snapshot for background work (gallery rendering).
    func keyResolver() -> PickKeyMap { keyMap }
    func url(forKey key: String) -> URL { keyMap.url(forKey: key) }

    // MARK: sessions

    @discardableResult
    private func appendSession(folder: URL, name: String?) -> PickSession {
        let nm = name ?? folder.lastPathComponent
        let id = PickSession.makeID(from: nm, taken: Set(project.sessions.map { $0.id }))
        let rel = root.map { PathUtil.relative(from: $0, to: folder) } ?? folder.path
        let s = PickSession(id: id, name: nm, folder: rel, absFolder: folder.standardizedFileURL.path)
        project.sessions.append(s)
        return s
    }

    /// Adds a session for `folder`. Returns nil (and sets `lastError`) if the folder is already a session or lies inside / contains one.
    @discardableResult
    func addSession(folder: URL, name: String? = nil) -> PickSession? {
        guard isProjectFile else { lastError = "Open or create a .thon project first."; return nil }
        let fp = folder.standardizedFileURL.path
        for r in keyMap.roots {
            let rp = r.url.path
            if fp == rp || fp.hasPrefix(rp + "/") || rp.hasPrefix(fp + "/") {
                lastError = "\(folder.lastPathComponent) overlaps the session folder \(rp)."; return nil
            }
        }
        let s = appendSession(folder: folder, name: name)
        rebuildKeyMap(); touch(nil)
        return s
    }

    func setProjectName(_ n: String) {
        let v = n.isEmpty ? nil : n
        guard v != project.name else { return }
        project.name = v; touch(nil)
    }

    func updateSession(_ s: PickSession) {
        guard let i = project.sessions.firstIndex(where: { $0.id == s.id }), project.sessions[i] != s else { return }
        project.sessions[i] = s; touch(nil)
    }

    /// Points the session at another folder (its picks stay attached: keys use the session id, not the path).
    func relocateSession(id: String, folder: URL) {
        guard let i = project.sessions.firstIndex(where: { $0.id == id }), let root else { return }
        project.sessions[i].folder = PathUtil.relative(from: root, to: folder)
        project.sessions[i].absFolder = folder.standardizedFileURL.path
        rebuildKeyMap(); touch(nil)
    }

    func moveSession(from: Int, to: Int) {
        guard project.sessions.indices.contains(from), to >= 0, to < project.sessions.count, from != to else { return }
        let s = project.sessions.remove(at: from); project.sessions.insert(s, at: to); touch(nil)
    }

    /// Removes the session and every micrograph record (picks, notes) under it. A backup is written first when picks are lost.
    @discardableResult
    func removeSession(id: String) -> Int {
        guard project.sessions.contains(where: { $0.id == id }) else { return 0 }
        let lost = originStats(id).picks
        if lost > 0 || project.mics.values.contains(where: { $0.session == id }), projectURL != nil { save(forceBackup: true) }
        // micrographs that were moved INTO this session from another one go back to their own session
        for (k, r) in project.mics where r.session == id && !k.hasPrefix(id + "/") {
            var r2 = r; r2.session = nil
            if r2 == MicRecord() { project.mics[k] = nil } else { project.mics[k] = r2 }
        }
        project.mics = project.mics.filter { !$0.key.hasPrefix(id + "/") }
        project.sessions.removeAll { $0.id == id }
        undoStacks = [:]; redoStacks = [:]; gridCache = [:]
        rebuildKeyMap(); touch(nil)
        return lost
    }

    /// Session a micrograph is listed / exported under: the one it was moved to, else the session whose folder holds the file.
    func effectiveSessionID(_ rawKey: String) -> String? {
        let key = FrameKey.base(rawKey)               // the frames of a stack belong to the session of their file
        if let s = project.mics[key]?.session, project.sessions.contains(where: { $0.id == s }) { return s }
        return keyMap.sessionID(ofKey: key)
    }
    /// Session whose folder holds the file (what the key is built from).
    func originSessionID(_ key: String) -> String? { keyMap.sessionID(ofKey: key) }
    func session(forKey key: String) -> PickSession? {
        effectiveSessionID(key).flatMap { id in project.sessions.first { $0.id == id } }
    }

    /// Moves micrographs to session `id` (nil = back to the session whose folder holds them). Only the organization changes:
    /// files stay where they are and picks stay attached. Returns how many micrographs changed.
    @discardableResult
    func moveMicrographs(_ keys: [String], to id: String?) -> Int {
        guard isProjectFile, id == nil || project.sessions.contains(where: { $0.id == id }) else { return 0 }
        var n = 0
        for k in Set(keys) {
            let target = (id == keyMap.sessionID(ofKey: k)) ? nil : id
            if project.mics[k]?.session == target { continue }          // already there
            var r = project.mics[k] ?? MicRecord()
            r.session = target
            if r == MicRecord() { project.mics[k] = nil } else { project.mics[k] = r }
            n += 1
        }
        if n > 0 { touch(nil) }
        return n
    }
    func sessionFolder(_ id: String) -> URL? { keyMap.roots.first { $0.id == id }?.url }
    func sessionFolderExists(_ id: String) -> Bool { sessionFolder(id).map { PathUtil.isDirectory($0) } ?? false }

    struct SessionStats: Equatable { var micrographs = 0, picks = 0, candidates = 0, maybe = 0, done = 0 }
    /// Counts over the micrographs currently in the session that have a record (picks = accepted picks).
    func sessionStats(_ id: String) -> SessionStats {
        var st = SessionStats()
        for (k, r) in project.mics where effectiveSessionID(k) == id {
            tally(&st, r)
        }
        return st
    }
    /// Same counts over the records of files that live in the session's folder, wherever they were moved to (what removing the session deletes).
    func originStats(_ id: String) -> SessionStats {
        var st = SessionStats()
        for (k, r) in project.mics where k.hasPrefix(id + "/") { tally(&st, r) }
        return st
    }
    private func tally(_ st: inout SessionStats, _ r: MicRecord) {
        st.micrographs += 1
        if r.done { st.done += 1 }
        for p in r.picks {
            if p.status == .accepted { st.picks += 1; if p.isMaybe { st.maybe += 1 } }
            else if p.status == .candidate { st.candidates += 1 }
        }
    }

    static func decode(_ d: Data) throws -> PickProject { try JSONDecoder().decode(PickProject.self, from: d) }
    func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(project)
    }

    /// Key of a micrograph: path relative to the project folder (forward slashes), else the absolute path;
    /// in a .thon project "<session id>/<path inside the session folder>".
    func key(for url: URL) -> String { keyMap.key(for: url) }
    func key(for url: URL, frame: Int?) -> String { keyMap.key(for: url, frame: frame) }

    /// Test hook: replace the scheme without touching picks.
    func setScheme_forTest(_ s: LabelScheme) { project.scheme = s }
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
    /// True when some frame of the stack `base` (a plain micrograph key) has picks or candidates of its own.
    func hasFramePicks(base: String) -> Bool {
        let pre = base + FrameKey.marker
        return project.mics.contains { $0.key.hasPrefix(pre) && FrameKey.base($0.key) == base && !$0.value.picks.isEmpty }
    }
    func picks(_ key: String) -> [Pick] { project.mics[key]?.picks ?? [] }
    func accepted(_ key: String) -> [Pick] { picks(key).filter { $0.status == .accepted } }
    func candidates(_ key: String) -> [Pick] { picks(key).filter { $0.status == .candidate } }
    func pick(_ id: String, in key: String) -> Pick? { project.mics[key]?.picks.first { $0.id == id } }
    func diameterNm(_ p: Pick) -> Double { p.diameterNm ?? project.params.diameterNm }
    func boxNm(_ p: Pick) -> Double { p.boxNm ?? project.params.boxNm }

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
    /// Crop editor: the parts of a micrograph that are finished. Not part of the pick undo history (the crop editor undoes them itself).
    func sections(_ key: String) -> [DoneRegion] { project.mics[key]?.sections ?? [] }
    func addSection(_ key: String, _ r: DoneRegion) {
        mutateRecord(key) { var l = $0.sections ?? []; l.append(r); $0.sections = l }; touch(key, structural: false)
    }
    func removeSection(_ key: String, id: String) {
        guard project.mics[key]?.sections?.contains(where: { $0.id == id }) == true else { return }
        mutateRecord(key) { var l = $0.sections ?? []; l.removeAll { $0.id == id }; $0.sections = l.isEmpty ? nil : l }; touch(key, structural: false)
    }
    func clearSections(_ key: String) {
        guard project.mics[key]?.sections != nil else { return }
        mutateRecord(key) { $0.sections = nil }; touch(key, structural: false)
    }
    // colour tags (micrographs and frames; not part of the pick undo history)
    func tags(_ key: String) -> [FinderTag] { (project.mics[key]?.tags ?? []).compactMap(FinderTag.init(rawValue:)) }
    func setTag(_ key: String, _ tag: FinderTag, on: Bool) {
        var l = project.mics[key]?.tags ?? []
        guard l.contains(tag.rawValue) != on else { return }
        if on { l.append(tag.rawValue) } else { l.removeAll { $0 == tag.rawValue } }
        mutateRecord(key) { $0.tags = l.isEmpty ? nil : l }
        pruneEmpty(key); touch(key, structural: false); tagChanges.bump()
    }
    func toggleTag(_ key: String, _ tag: FinderTag) { setTag(key, tag, on: !tags(key).contains(tag)) }
    func clearTags(_ key: String) {
        guard project.mics[key]?.tags != nil else { return }
        mutateRecord(key) { $0.tags = nil }
        pruneEmpty(key); touch(key, structural: false); tagChanges.bump()
    }
    /// Keys (micrographs and frames) that carry `tag`.
    func keys(tagged tag: FinderTag) -> Set<String> {
        Set(project.mics.filter { $0.value.tags?.contains(tag.rawValue) == true }.map { $0.key })
    }
    private func pruneEmpty(_ key: String) { if project.mics[key] == MicRecord() { project.mics[key] = nil } }
    /// Edits one micrograph's record outside the pick history, drops the record when it ends up empty, and saves.
    func mutateMic(_ key: String, _ f: (inout MicRecord) -> Void) {
        mutateRecord(key, f); pruneEmpty(key); touch(key, structural: false)
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
    /// Sets or clears the "maybe" flag on the given picks (one undoable edit).
    @discardableResult func setMaybe(_ ids: Set<String>, _ on: Bool, in key: String) -> Bool {
        perform(key, on ? "Flag maybe" : "Clear maybe") { l in for i in l.indices where ids.contains(l[i].id) { l[i].maybe = on ? true : nil } }
    }
    func maybeCount(_ key: String) -> Int { picks(key).filter { $0.status == .accepted && $0.isMaybe }.count }

    /// Number of live (non-dismissed) picks per label id across the whole project.
    func labelUsage() -> [String: Int] {
        var c: [String: Int] = [:]
        for (_, r) in project.mics { for p in r.picks where p.status != .dismissed { c[p.label, default: 0] += 1 } }
        return c
    }

    /// Replaces the scheme and moves picks of removed labels per `map` (old id -> new id) in one step.
    /// A backup of the project is written first. Not undoable (per-micrograph undo history is cleared).
    /// Picks (including dismissed ones) whose label is neither in `s` nor in `map` are left untouched, so callers must check first.
    @discardableResult func replaceScheme(_ s: LabelScheme, remapping map: [String: String]) -> Int {
        var moved = 0
        if !map.isEmpty {
            if projectURL != nil { save(forceBackup: true) }
            for k in project.mics.keys {
                var r = project.mics[k]!
                var changed = false
                for i in r.picks.indices {
                    let l = r.picks[i].label
                    if s.label(l) == nil, let t = map[l], s.label(t) != nil { r.picks[i].label = t; moved += 1; changed = true }
                }
                if changed { project.mics[k] = r; micRev[k, default: 0] += 1 }
            }
            undoStacks = [:]; redoStacks = [:]
        }
        project.scheme = s
        touch(nil)
        return moved
    }
    @discardableResult func setDiameter(_ ids: Set<String>?, nm: Double?, in key: String) -> Bool {
        perform(key, "Resize") { l in for i in l.indices where ids?.contains(l[i].id) ?? true { l[i].diameterNm = nm } }
    }
    @discardableResult func setStatus(_ ids: Set<String>, _ s: PickStatus, in key: String) -> Bool {
        perform(key, s == .accepted ? "Accept" : "Dismiss") { l in for i in l.indices where ids.contains(l[i].id) { l[i].status = s } }
    }

    /// Replaces the micrograph's undecided auto candidates with `cands` as ONE undoable edit. Accepted picks and
    /// dismissed candidates are kept; new candidates within `suppressPx` of either are dropped.
    /// A candidate that carries its own diameter (a size sweep) is suppressed within half of THAT diameter (`angpix` converts it).
    @discardableResult
    func applyCandidates(_ key: String, _ cands: [AutoCandidate], label: String, suppressPx: Double, name: String, angpix: Double? = nil) -> Int {
        var added = 0
        func radius(_ c: AutoCandidate) -> Double { (c.diameterNm != nil && angpix != nil) ? 0.5 * c.diameterNm! * 10 / angpix! : suppressPx }
        let widest = cands.map(radius).max() ?? suppressPx
        perform(key, name) { l in
            l.removeAll { $0.status == .candidate && $0.source == .auto }
            let fixed = PickGrid(picks: l.filter { $0.status != .candidate }, cell: max(16, widest))
            for c in cands where fixed.nearest(x: c.x, y: c.y, radius: radius(c)) == nil {
                l.append(Pick(x: c.x, y: c.y, label: label, score: c.score, source: .auto, status: .candidate, diameterNm: c.diameterNm, boxNm: c.boxNm)); added += 1
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
    fileprivate func mutateRecord(_ key: String, _ f: (inout MicRecord) -> Void) {
        var r = project.mics[key] ?? MicRecord(); f(&r); project.mics[key] = r
    }
    fileprivate func touch(_ key: String?, structural: Bool = true) {
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

    /// Hidden (dot-prefixed) so the project folder stays tidy. Folder projects: <folder>/.backups;
    /// .thon projects: <folder>/.<name>_backups (several projects can share a folder).
    func backupDirectory(root: URL) -> URL {
        isProjectFile ? root.appendingPathComponent("." + (projectURL!.deletingPathExtension().lastPathComponent) + "_backups") : root.appendingPathComponent(".backups")
    }

    /// The visible directory older versions used (`backups`, `<name>_backups`).
    private func legacyBackupDirectory(root: URL) -> URL {
        isProjectFile ? root.appendingPathComponent((projectURL!.deletingPathExtension().lastPathComponent) + "_backups") : root.appendingPathComponent("backups")
    }

    /// Moves this project's backup files out of the old visible directory into the hidden one (only files that carry this
    /// project's prefix and extension; other files are left alone, and the old directory is removed only if it ends up empty).
    private func adoptLegacyBackups(into dir: URL, root: URL, prefix: String, ext: String) {
        let fm = FileManager.default
        let old = legacyBackupDirectory(root: root)
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []) where f.hasPrefix(prefix) && f.hasSuffix("." + ext) {
            let dst = dir.appendingPathComponent(f)
            if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: old.appendingPathComponent(f), to: dst) }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? ["x"]).filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: old)     // empty directory we created ourselves
        }
    }

    /// Swipe-assistant samples live inside the project; setting them schedules an autosave (no UI revision change).
    func setAssist(_ d: Data?) {
        guard d != project.assist else { return }
        project.assist = d
        dirty = true
        scheduleSave()
    }

    private func writeBackup(_ data: Data) {
        guard let root else { return }
        let dir = backupDirectory(root: root)
        let (prefix, ext) = isProjectFile ? (projectURL!.deletingPathExtension().lastPathComponent + "_", Self.projectExtension) : ("picks_project_", "json")
        adoptLegacyBackups(into: dir, root: root, prefix: prefix, ext: ext)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss_SSS"; f.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(prefix)\(f.string(from: Date())).\(ext)"       // a .thon backup is itself an openable project file
        try? writeFileAtomically(data, to: dir.appendingPathComponent(name))
        lastBackup = Date()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix("." + ext) }.sorted()
        if files.count > backupsToKeep {
            for old in files.prefix(files.count - backupsToKeep) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        }
    }
}
