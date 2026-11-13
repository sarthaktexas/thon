import SwiftUI
import Combine
import UniformTypeIdentifiers
import ImageIO

struct ExposureItem: Identifiable, Hashable {
    let url: URL
    let rel: String
    var session: String? = nil          // session id in a .thon project
    var id: URL { url }
}

/// A row of the sidebar: a file (a stack shows as its average) or one frame of a stack.
enum SidebarID: Hashable { case file(URL), frame(URL, Int) }

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", time = "Acquired", mag = "Magnification"
    var id: String { rawValue }
}

/// Format-independent image description (what the views need).
struct ImageInfo {
    var width: Int, height: Int, depth: Int
    var pixelSizeA: Double?
    var dataTypeName: String
}

extension DMImageEntry {
    var info: ImageInfo { ImageInfo(width: width, height: height, depth: depth, pixelSizeA: pixelSizeA, dataTypeName: dataTypeName) }
}

final class LoadedExposure: @unchecked Sendable {
    let url: URL
    let file: DMFile?
    let mrc: MRCFile?
    let entry: ImageInfo
    let pixels: [Float]
    let stats: ImageStats
    let sections: [InfoSection]
    let tags: [TagRow]
    let frame: Int                  // 0-based frame; -1 = the average of all frames (a single image is its own average)
    let isSerialEM: Bool            // the file's tags / header say it was written by SerialEM

    init(url: URL, frame: Int) throws {
        self.url = url
        if AppModel.isMRC(url) {
            let f = try MRCFile(url: url)
            let px = try LoadedExposure.read(depth: f.depth, frame: frame) { try f.readPixels(frame: $0) }
            let st = ImageStats.compute(px)
            file = nil; mrc = f; pixels = px; stats = st; self.frame = frame
            entry = ImageInfo(width: f.width, height: f.height, depth: f.depth, pixelSizeA: f.header.pixelSizeA, dataTypeName: f.header.modeName)
            sections = f.buildSections(stats: st)
            let tg = f.flatTags()
            tags = tg
            isSerialEM = f.header.extType == "SERI" || tg.contains(where: LoadedExposure.mentionsSerialEM)
        } else {
            let f = try DMFile(url: url)
            guard let e = f.primaryImage else { throw DMError.unsupported("No image data found in \(url.lastPathComponent)") }
            let px = try LoadedExposure.read(depth: e.depth, frame: frame) { try f.readPixels(e, frame: $0) }
            let st = ImageStats.compute(px)
            file = f; mrc = nil; entry = e.info; pixels = px; stats = st; self.frame = frame
            sections = f.buildSections(entry: e, stats: st)
            let tg = f.flatTags()
            tags = tg
            isSerialEM = tg.contains(where: LoadedExposure.mentionsSerialEM)
        }
    }

    /// One frame (`frame` >= 0), or the mean of all `depth` frames (`frame` < 0).
    static func read(depth: Int, frame: Int, _ readFrame: (Int) throws -> [Float]) throws -> [Float] {
        if frame >= 0 || depth <= 1 { return try readFrame(max(frame, 0)) }
        var sum = try readFrame(0)
        for i in 1..<depth {
            let f = try readFrame(i)
            for j in sum.indices { sum[j] += f[j] }
        }
        let inv = 1 / Float(depth)
        for j in sum.indices { sum[j] *= inv }
        return sum
    }

    static func mentionsSerialEM(_ t: TagRow) -> Bool {
        t.path.range(of: "serialem", options: .caseInsensitive) != nil || t.value.range(of: "serialem", options: .caseInsensitive) != nil
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var items: [ExposureItem] = []
    @Published var selection: URL? {
        didSet {
            guard selection != oldValue else { return }
            // The sidebar List (NSTableView) writes `selection` from inside its delegate callback. Doing the
            // follow-up work (frame reset, load, picker/cursor updates) synchronously publishes more changes
            // there and triggers AppKit's "reentrant operation in its NSTableView delegate" warning, so defer it.
            let sel = selection
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selection == sel else { return }
                self.frame = self.pendingFrame ?? -1          // stacks open as the average of their frames (see `loadSelection`)
                self.pendingFrame = nil
                self.loadSelection()
            }
        }
    }
    @Published var thumbs: [URL: NSImage] = [:]
    @Published var metas: [URL: ExposureMeta] = [:]
    @Published var sortKey: SortKey = .name { didSet { resort() } }
    @Published var doc: LoadedExposure?
    @Published var fft: PowerSpectrum?
    @Published var loadError: String?
    @Published var isLoading = false
    @Published var generation = 0
    /// -1 = the average of all frames of a stack (the default); 0... = that frame, picked on its own.
    @Published var frame = -1
    var pendingFrame: Int?
    /// Stacks the user has unpacked into frames / explicitly kept averaged in this run. A stack that already has picks on its
    /// frames opens unpacked, so those picks are never hidden.
    var unpackedFiles = Set<URL>(), forcedAverage = Set<URL>()
    struct StackHint: Equatable { let url: URL; let depth: Int }
    /// Offered when a SerialEM stack opens as its average: unpack it to pick each frame separately.
    @Published var stackHint: StackHint?
    private var hintedFiles = Set<URL>()
    /// Stacks whose frames are listed in the sidebar.
    @Published var expandedStacks = Set<URL>()
    /// Sidebar shows only what carries this tag (files with a tagged frame show those frames).
    @Published var tagFilter: FinderTag?
    static let stackHintOffKey = "stack.hintOff"
    @Published var showInspector = true
    @Published var fftNormalize = true
    @Published var ctfParams = CTFParams()
    @Published var ctf: CTFFit?
    @Published var ctfContours: [[(k: Double, theta: Double)]] = []
    @Published var ctfBusy = false
    @Published var ctfMessage: String?
    @Published var showCTFZeros = true
    @Published var fftTile = 512 { didSet { if fftTile != oldValue { recomputeFFT() } } }
    @Published var tagQuery = ""
    @Published var inspectorTab: InspectorTab = .overview
    @Published var showGallery = false
    /// True while Space is held over the image: every overlay is hidden and clicks only pan.
    @Published var overlaysHidden = false
    @Published var showSwipe = false
    @Published var showSessions = false
    @Published var collapsedSessions: Set<String> = []

    let view = ViewState()
    let cursor = CursorState()
    let picks = PickController()
    let recents = RecentStore()
    let measure = MeasureState()
    private var picksBag = Set<AnyCancellable>()

    init() {
        picks.gallery.loader = { root, key in AppModel.loadPixels(root: root, key: key) }
        picks.gallery.onGoTo = { [weak self] key, x, y in self?.goTo(key: key, x: x, y: y) }
        picks.$enabled.sink { [weak self] on in
            if on { self?.inspectorTab = .picks; self?.showInspector = true }
        }.store(in: &picksBag)
        // The crop editor lives in the main viewer: it frames sections there, follows the micrograph, and ends with pick mode.
        picks.crops.view = view
        picks.$currentKey.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in if self?.picks.crops.active == true { self?.picks.crops.rebuild() } }.store(in: &picksBag)
        picks.$autoBusy.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] busy in if !busy, self?.picks.crops.active == true { self?.picks.crops.rebuild() } }.store(in: &picksBag)
        picks.$enabled.sink { [weak self] on in if !on, self?.picks.crops.active == true { self?.picks.crops.active = false } }.store(in: &picksBag)
        // Switching Topaz / CryoSegNet off in Preferences puts the picker back on the built-in engine.
        picks.engineSettings.$enabled.sink { [weak self] on in
            if !on, let p = self?.picks, p.engine != .builtin { p.engine = .builtin; p.autoLive = false; p.autoMessage = nil }
        }.store(in: &picksBag)
        // The picker and the ruler both own the left mouse button, so only one can be active.
        picks.$enabled.sink { [weak self] on in if on { self?.measure.enabled = false } }.store(in: &picksBag)
        measure.$enabled.sink { [weak self] on in if on { self?.picks.enabled = false } }.store(in: &picksBag)
    }
    var renderer: MicrographRenderer?

    private var loadToken = 0
    private let indexQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2          // keep CPU load modest
        q.qualityOfService = .utility
        return q
    }()

    /// Raw pixels of a micrograph by project key (background use; no stats / tags).
    /// A frame key (`...#f3`) loads that frame; a plain key loads the whole file (the average of the frames of a stack).
    nonisolated static func loadPixels(root: URL?, key rawKey: String) -> (pixels: [Float], width: Int, height: Int)? {
        let (key, frame) = FrameKey.split(rawKey)
        let url = key.hasPrefix("/") ? URL(fileURLWithPath: key) : (root ?? URL(fileURLWithPath: "/")).appendingPathComponent(key)
        let fr = frame ?? -1
        if isMRC(url) {
            guard let f = try? MRCFile(url: url), let px = try? LoadedExposure.read(depth: f.depth, frame: fr, { try f.readPixels(frame: $0) }) else { return nil }
            return (px, f.width, f.height)
        }
        guard let f = try? DMFile(url: url), let e = f.primaryImage,
              let px = try? LoadedExposure.read(depth: e.depth, frame: fr, { try f.readPixels(e, frame: $0) }) else { return nil }
        return (px, e.width, e.height)
    }

    /// Opens micrograph `key` (if needed) and centers the view on the pick, zoomed so ~5 boxes fit across the view.
    func goTo(key rawKey: String, x: Double, y: Double) {
        let (key, onFrame) = FrameKey.split(rawKey)
        showGallery = false
        let box = max(picks.boxPx, 8)
        let z = min(max(Double(min(view.viewPixels.width, view.viewPixels.height)) / (5 * box), 0.05), 32)
        let focus = CGPoint(x: x + 0.5, y: y + 0.5)
        guard let target = items.first(where: { picks.store.key(for: $0.url) == key })?.url else { loadError = "Micrograph \(key) is not in the open folder / project."; return }
        if let f = onFrame { unpackedFiles.insert(target); forcedAverage.remove(target); expandedStacks.insert(target); pendingFrame = f }
        else { unpackedFiles.remove(target); forcedAverage.insert(target) }               // a pick on the whole file shows on the average
        if target == selection {
            view.center = focus; view.zoom = z
            if let f = onFrame, f != frame { frame = f; pendingFrame = nil; loadSelection() }
            else if onFrame == nil, frame >= 0 { frame = -1; loadSelection() }
        } else { view.pendingFocus = (focus, z); selection = target }
    }

    // MARK: library

    static let allowedExtensions: Set<String> = ["dm3", "dm4", "mrc", "mrcs"]
    nonisolated static func isMRC(_ u: URL) -> Bool { ["mrc", "mrcs"].contains(u.pathExtension.lowercased()) }

    var sortedItems: [ExposureItem] { items }

    func open(urls: [URL]) {
        if let proj = urls.first(where: { $0.pathExtension.lowercased() == PickStore.projectExtension }) { openProjectFile(proj); return }
        var found: [ExposureItem] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let base = u.deletingLastPathComponent().path
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in en where Self.allowedExtensions.contains(f.pathExtension.lowercased()) {
                        found.append(ExposureItem(url: f, rel: String(f.path.dropFirst(base.count + 1))))
                    }
                }
            } else if Self.allowedExtensions.contains(u.pathExtension.lowercased()) {
                found.append(ExposureItem(url: u, rel: u.lastPathComponent))
            }
        }
        guard !found.isEmpty else { loadError = "No .dm3 / .dm4 / .mrc files found."; return }
        // one folder or file is remembered as itself; several files as their folder
        if urls.count == 1 { recents.note(urls[0]) } else if let first = found.first { recents.note(first.url.deletingLastPathComponent()) }
        indexQueue.cancelAllOperations()
        // the project (picks_project.json, labels.json, backups/) lives in the opened folder,
        // or next to the first file when individual files were opened
        if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            picks.store.openProject(folder: urls[0])
        } else if let first = found.first {
            picks.store.openProject(folder: first.url.deletingLastPathComponent())
        }
        thumbs = [:]; metas = [:]; pendingIndex = [:]
        items = found.sorted { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        selection = items.first?.url
        index(items)
    }

    // MARK: .thon projects (sessions)

    var isProject: Bool { picks.store.isProjectFile }

    /// Opens a `.thon` project: picks, label scheme and session organization come from the file; micrographs from the session folders.
    func openProjectFile(_ url: URL) {
        let store = picks.store
        let ok = store.openProject(file: url)
        if !ok { loadError = store.lastError; store.lastError = nil; return }
        recents.note(url)
        rescanSessions(keepSelection: false)
    }

    /// Re-reads the session folders (after opening, adding, removing or relocating a session).
    func rescanSessions(keepSelection: Bool = true) {
        let store = picks.store
        let fm = FileManager.default
        var found: [ExposureItem] = []
        var missing: [String] = []
        for s in store.project.sessions {
            guard let folder = store.sessionFolder(s.id), PathUtil.isDirectory(folder) else { missing.append(s.name); continue }
            guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in en where Self.allowedExtensions.contains(f.pathExtension.lowercased()) {
                guard store.keyMap.sessionID(containing: f) == s.id else { continue }          // belongs to a nested session
                let rel = String(f.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                found.append(ExposureItem(url: f, rel: s.name + "/" + rel, session: store.effectiveSessionID(store.key(for: f)) ?? s.id))
            }
        }
        indexQueue.cancelAllOperations()
        thumbs = [:]; metas = [:]; pendingIndex = [:]
        let sel = keepSelection ? selection : nil
        items = found
        resort()
        selection = (sel.flatMap { u in items.contains { $0.url == u } ? u : nil }) ?? items.first?.url
        index(items)
        if !missing.isEmpty { loadError = "Session folder not found: \(missing.joined(separator: ", ")). Use Sessions… to locate it." }
        else if items.isEmpty && !store.project.sessions.isEmpty { loadError = "No .dm3 / .dm4 / .mrc files found in the session folders." }
    }

    func sessionItems(_ id: String) -> [ExposureItem] { items.filter { $0.session == id } }

    func presentOpenProjectPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.allowedContentTypes = [UTType(filenameExtension: PickStore.projectExtension)].compactMap { $0 }
        p.message = "Choose a Thon project (.thon)."
        if p.runModal() == .OK, let u = p.url { openProjectFile(u) }
    }

    /// Pick the session folders, then choose where to save the project file.
    func presentNewProjectPanels() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Use as sessions"
        p.message = "Choose one folder per session (grid / sample). Each becomes a session; you can rename and annotate them next."
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let folders = p.urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let sp = NSSavePanel()
        sp.allowedContentTypes = [UTType(filenameExtension: PickStore.projectExtension)].compactMap { $0 }
        sp.nameFieldStringValue = "project.\(PickStore.projectExtension)"
        sp.directoryURL = folders[0].deletingLastPathComponent()
        sp.message = "Save the project file. Picks and the session organization are stored in it."
        guard sp.runModal() == .OK, var u = sp.url else { return }
        if u.pathExtension.lowercased() != PickStore.projectExtension { u.appendPathExtension(PickStore.projectExtension) }
        let store = picks.store
        if !store.createProject(file: u, folders: folders) { loadError = store.lastError ?? "Could not save the project."; return }
        recents.note(u)
        rescanSessions(keepSelection: false)
        showSessions = true
    }

    func presentAddSessionPanel() {
        guard isProject else { presentNewProjectPanels(); return }
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Add session"
        for u in p.runModal() == .OK ? p.urls : [] {
            if picks.store.addSession(folder: u) == nil { loadError = picks.store.lastError; picks.store.lastError = nil }
        }
        rescanSessions()
    }

    func presentRelocateSessionPanel(_ id: String) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Use this folder"; p.message = "Choose the folder that now holds this session's micrographs (existing picks stay attached)."
        guard p.runModal() == .OK, let u = p.url else { return }
        picks.store.relocateSession(id: id, folder: u)
        rescanSessions()
    }

    /// Moves micrographs to another session (nil = back to the session whose folder holds them). Files stay where they are; picks stay attached.
    func moveMicrographs(_ urls: [URL], to id: String?) {
        let store = picks.store
        guard store.moveMicrographs(urls.map { store.key(for: $0) }, to: id) > 0 else { return }
        refreshItemSessions()
    }

    func refreshItemSessions() {
        let store = picks.store
        items = items.map { var i = $0; i.session = store.effectiveSessionID(store.key(for: $0.url)) ?? $0.session; return i }
        resort()
    }

    /// "Folder of folders": every sub-folder of the chosen parent that holds micrographs becomes a session.
    func presentNewProjectFromParentPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Use sub-folders as sessions"
        p.message = "Choose a folder whose sub-folders are the sessions (one per grid / sample)."
        guard p.runModal() == .OK, let parent = p.url else { return }
        let found = SessionDiscovery.subfolderSessions(of: parent)
        guard !found.folders.isEmpty else { loadError = "No sub-folders with .dm3 / .dm4 / .mrc files in \(parent.lastPathComponent)."; return }
        let sp = NSSavePanel()
        sp.allowedContentTypes = [UTType(filenameExtension: PickStore.projectExtension)].compactMap { $0 }
        sp.nameFieldStringValue = "\(parent.lastPathComponent).\(PickStore.projectExtension)"
        sp.directoryURL = parent
        sp.message = "Save the project file (\(found.folders.count) sessions)."
        guard sp.runModal() == .OK, var u = sp.url else { return }
        if u.pathExtension.lowercased() != PickStore.projectExtension { u.appendPathExtension(PickStore.projectExtension) }
        let store = picks.store
        if !store.createProject(file: u, name: parent.lastPathComponent, folders: found.folders) { loadError = store.lastError ?? "Could not save the project."; return }
        rescanSessions(keepSelection: false)
        showSessions = true
        if found.looseFiles > 0 { loadError = "\(found.looseFiles) micrographs lie directly in \(parent.lastPathComponent), not in a sub-folder, so they were not added." }
    }

    /// Adds every sub-folder of the chosen parent (that holds micrographs and is not yet a session) to the open project.
    func presentAddSubfolderSessionsPanel() {
        guard isProject else { presentNewProjectFromParentPanel(); return }
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Add sub-folders as sessions"
        p.message = "Choose a folder whose sub-folders should be added as sessions."
        guard p.runModal() == .OK, let parent = p.url else { return }
        let found = SessionDiscovery.subfolderSessions(of: parent)
        var added = 0, skipped = 0
        for f in found.folders { if picks.store.addSession(folder: f) != nil { added += 1 } else { skipped += 1 } }
        picks.store.lastError = nil
        rescanSessions()
        if found.folders.isEmpty { loadError = "No sub-folders with .dm3 / .dm4 / .mrc files in \(parent.lastPathComponent)." }
        else if skipped > 0 { loadError = "Added \(added) sessions; \(skipped) sub-folders were skipped because they are already sessions or overlap one." }
    }

    func removeSession(_ id: String) {
        picks.store.removeSession(id: id)
        rescanSessions()
    }

    private func sessionRank(_ i: ExposureItem) -> Int {
        i.session.flatMap { id in picks.store.project.sessions.firstIndex { $0.id == id } } ?? 0
    }
    /// Sessions keep their project order; within a session the chosen sort applies.
    private func itemLess(_ a: ExposureItem, _ b: ExposureItem) -> Bool {
        let ra = sessionRank(a), rb = sessionRank(b)
        if ra != rb { return ra < rb }
        switch sortKey {
        case .name: return a.rel.localizedStandardCompare(b.rel) == .orderedAscending
        case .time: return (metas[a.url]?.acquired ?? .distantPast) < (metas[b.url]?.acquired ?? .distantPast)
        case .mag: return (metas[a.url]?.indicatedMag ?? 0) < (metas[b.url]?.indicatedMag ?? 0)
        }
    }

    // Index results arrive one file at a time from the background queue. Publishing each one separately
    // makes the sidebar List reload per file (and re-sort per file), so collect them and publish in batches.
    private var pendingIndex: [URL: (ExposureMeta, NSImage?)] = [:]
    private var indexFlushScheduled = false

    private func scheduleIndexFlush() {
        guard !indexFlushScheduled else { return }
        indexFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flushIndex() }
    }

    private func flushIndex() {
        indexFlushScheduled = false
        guard !pendingIndex.isEmpty else { return }
        let batch = pendingIndex; pendingIndex = [:]
        var m = metas, t = thumbs
        for (url, r) in batch { m[url] = r.0; if let ns = r.1 { t[url] = ns } }
        metas = m; thumbs = t
        if sortKey != .name { resort() }
    }

    private func index(_ list: [ExposureItem]) {
        for item in list {
            indexQueue.addOperation { [weak self] in
                var meta = ExposureMeta()
                var thumb: CGImage?
                if AppModel.isMRC(item.url) {
                    guard let f = try? MRCFile(url: item.url) else { return }
                    meta.width = f.width; meta.height = f.height; meta.pixelSizeA = f.header.pixelSizeA; meta.dataType = f.header.modeName; meta.depth = f.depth
                    if let px = try? f.readPixels() { thumb = makeThumbnail(px, f.width, f.height) }
                } else {
                    guard let f = try? DMFile(url: item.url) else { return }
                    meta = f.quickMeta()
                    thumb = f.embeddedThumbnail()
                    if thumb == nil, let e = f.primaryImage, let px = try? f.readPixels(e) { thumb = makeThumbnail(px, e.width, e.height) }
                }
                let ns = thumb.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingIndex[item.url] = (meta, ns)
                    self.scheduleIndexFlush()
                }
            }
        }
    }

    private func resort() {
        let sel = selection
        items.sort(by: itemLess)
        if selection != sel { selection = sel }
    }

    var selectedIndex: Int? { items.firstIndex { $0.url == selection } }
    func step(_ d: Int) {
        let list = visibleItems(items)
        guard let i = list.firstIndex(where: { $0.url == selection }) ?? (tagFilter == nil ? nil : (d > 0 ? -1 : list.count)) else { return }
        let j = min(max(i + d, 0), list.count - 1)
        if list.indices.contains(j) { selection = list[j].url }
    }

    // MARK: loading

    func loadSelection() {
        guard let url = selection else { return }
        if frame < 0, !forcedAverage.contains(url),
           unpackedFiles.contains(url) || picks.store.hasFramePicks(base: picks.store.key(for: url)) { frame = 0 }
        loadToken += 1
        let token = loadToken, fr = frame
        isLoading = true; loadError = nil
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try LoadedExposure(url: url, frame: fr) }.value
                guard token == loadToken else { return }
                doc = loaded
                fft = nil
                view.displayStats = loaded.stats
                view.applyAuto()
                cursor.pixels = loaded.pixels; cursor.width = loaded.entry.width; cursor.height = loaded.entry.height
                picks.pixels = loaded.pixels; picks.currentURL = url
                let onFrame = loaded.entry.depth > 1 && fr >= 0 ? fr : nil
                measure.setImage(key: FrameKey.make(url.path, frame: onFrame))
                picks.setMicrograph(key: picks.store.key(for: url, frame: onFrame), width: loaded.entry.width, height: loaded.entry.height, pixelSizeA: loaded.entry.pixelSizeA)
                if loaded.entry.depth > 1, loaded.isSerialEM, fr < 0, !UserDefaults.standard.bool(forKey: Self.stackHintOffKey), hintedFiles.insert(url).inserted {
                    stackHint = StackHint(url: url, depth: loaded.entry.depth)
                    expireStackHint(for: url)
                } else if stackHint?.url != url { stackHint = nil }
                generation += 1
                isLoading = false
                if let kv = loaded.file?.quickMeta().voltageKV { ctfParams.voltageKV = kv }
                let px = loaded.pixels, w = loaded.entry.width, h = loaded.entry.height, tileSize = fftTile
                let ps = await Task.detached(priority: .utility) { computePowerSpectrum(pixels: px, width: w, height: h, tile: tileSize) }.value
                if token == loadToken { fft = ps; runCTFFit() }
            } catch {
                guard token == loadToken else { return }
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    func reloadFrame() { loadSelection() }

    /// The SerialEM banner goes away by itself after 20 s (a method, so the closure is the only capture of `self`).
    private func expireStackHint(for url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.stackHint?.url == url { self?.stackHint = nil }
        }
    }

    // MARK: sidebar: files and the frames of stacks

    /// Frames in a file (1 for a single image; known once the file has been indexed).
    func depth(of url: URL) -> Int { metas[url]?.depth ?? 1 }

    /// The sidebar row that is open now.
    var sidebarSelection: SidebarID? {
        guard let u = selection else { return nil }
        return frame >= 0 && depth(of: u) > 1 ? .frame(u, frame) : .file(u)
    }

    /// Open a sidebar row: a file opens as its average, a frame opens that frame on its own.
    func select(_ id: SidebarID?) {
        switch id {
        case nil: selection = nil
        case .file(let u)?:
            unpackedFiles.remove(u); forcedAverage.insert(u)
            if u == selection { if frame >= 0 { frame = -1; loadSelection() } } else { selection = u }
        case .frame(let u, let n)?:
            unpackedFiles.insert(u); forcedAverage.remove(u); expandedStacks.insert(u)
            if u == selection { if frame != n { frame = n; loadSelection() } } else { pendingFrame = n; selection = u }
        }
    }

    func toggleStack(_ url: URL) { if expandedStacks.contains(url) { expandedStacks.remove(url) } else { expandedStacks.insert(url) } }

    /// Frames of `item` the sidebar lists: all of them while the stack is expanded, only the tagged ones under a tag filter.
    func listedFrames(of url: URL, tagged: Set<String>?) -> [Int] {
        let n = depth(of: url)
        guard n > 1 else { return [] }
        let base = picks.store.key(for: url)
        if let tagged { return (0..<n).filter { tagged.contains(FrameKey.make(base, frame: $0)) } }
        return expandedStacks.contains(url) ? Array(0..<n) : []
    }

    /// Files the sidebar lists under the tag filter (all of them without one).
    func visibleItems(_ list: [ExposureItem]) -> [ExposureItem] {
        guard let f = tagFilter else { return list }
        let bases = Set(picks.store.keys(tagged: f).map(FrameKey.base))
        return list.filter { bases.contains(picks.store.key(for: $0.url)) }
    }

    /// Tags of the image on screen (the average or the open frame); ⌥⌘1…7 toggle them.
    func toggleTag(_ t: FinderTag) { if let k = picks.currentKey { picks.store.toggleTag(k, t) } }
    func clearTags() { if let k = picks.currentKey { picks.store.clearTags(k) } }

    /// Unpack the open stack into frames (each is picked on its own) or go back to the average of all frames.
    func setUnpacked(_ on: Bool) {
        guard let url = selection else { return }
        stackHint = nil
        if on { unpackedFiles.insert(url); forcedAverage.remove(url); expandedStacks.insert(url); frame = 0 }
        else { unpackedFiles.remove(url); forcedAverage.insert(url); frame = -1 }
        loadSelection()
    }

    func stepFrame(_ d: Int) {
        guard let depth = doc?.entry.depth, depth > 1, frame >= 0 else { return }
        let f = min(max(frame + d, 0), depth - 1)
        if f != frame { frame = f; loadSelection() }
    }
    /// Recompute the power spectrum for the current image (box size changed).
    func recomputeFFT() {
        guard let d = doc else { return }
        let token = loadToken, px = d.pixels, w = d.entry.width, h = d.entry.height, tileSize = fftTile
        fft = nil; ctf = nil; ctfContours = []
        Task {
            let ps = await Task.detached(priority: .utility) { computePowerSpectrum(pixels: px, width: w, height: h, tile: tileSize) }.value
            if token == loadToken, tileSize == fftTile { fft = ps; runCTFFit() }
        }
    }

    /// Fit defocus / astigmatism to the current spectrum (diagnostic only; the image is never CTF-corrected).
    func runCTFFit() {
        guard let ps = fft, let pa = doc?.entry.pixelSizeA else {
            ctf = nil; ctfContours = []
            ctfMessage = doc != nil && fft != nil ? "No pixel size in this file, so the CTF cannot be fitted." : nil
            return
        }
        let token = loadToken, params = ctfParams
        ctfBusy = true; ctfMessage = nil
        Task {
            let fit = await Task.detached(priority: .utility) { fitCTF(ps: ps, pixelSizeA: pa, params: params) }.value
            guard token == loadToken else { return }
            ctfBusy = false
            ctf = fit
            ctfContours = fit.map { ctfZeroContours($0) } ?? []
            if fit == nil { ctfMessage = "CTF fit failed (fit range too narrow for this pixel size?)." }
        }
    }

    /// Open the inspector on the FFT tab (Thon rings).
    func showThonRings() { inspectorTab = .fft; showInspector = true }

    func applyProcessedStats(_ st: ImageStats?) {
        view.displayStats = st ?? doc?.stats
        view.applyAuto()
    }

    // MARK: interaction

    /// Turns the crop editor on or off (⌥⌘T, the Picks tab, the Picks menu).
    func toggleCrops() { picks.crops.active.toggle() }

    /// Keys of the crop editor while it is on. Return = Done, Esc = deselect / leave, Delete = remove the selected circle,
    /// Tab = next type, ↑ ↓ , . = resize the selected circle, Z = undo, type hotkeys set the type of the selected circle.
    private func handleCropKey(_ e: NSEvent) -> Bool {
        let cs = picks.crops
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        let mods = e.modifierFlags
        if mods.contains(.command) { return false }
        switch e.keyCode {
        case 36, 76: if !cs.done { cs.commit() }; return true
        case 53: if cs.selected != nil { cs.selected = nil } else { cs.active = false }; return true
        case 51, 117: if let s = cs.selected { cs.remove(s) }; return true
        case 48: if let s = cs.selected { cs.cycleLabel(s) } else if let i = cs.typeLabels.firstIndex(where: { $0.id == cs.penLabelID }) { picks.activeLabel = cs.typeLabels[(i + 1) % cs.typeLabels.count].id }; return true
        case 126, 125:
            guard let s = cs.selected, let it = cs.items.first(where: { $0.id == s && !$0.removed }) else { return false }
            cs.beginEdit(); cs.setDiameter(s, nm: it.diameterNm * (e.keyCode == 126 ? 1.06 : 1 / 1.06)); return true
        default: break
        }
        if let l = picks.store.scheme.label(forKey: chars), l.exported { picks.activeLabel = l.id; if let s = cs.selected { cs.setLabel(s, l.id) }; return true }
        switch chars {
        case "z": cs.undo(); return true
        case ",", ".":
            guard let s = cs.selected, let it = cs.items.first(where: { $0.id == s && !$0.removed }) else { return true }
            cs.beginEdit(); cs.setDiameter(s, nm: max(1, it.diameterNm + (chars == "." ? 1 : -1))); return true
        case "s": cs.skip(); return true
        default: return false
        }
    }

    func handleKey(_ e: NSEvent) -> Bool {
        if picks.crops.active, handleCropKey(e) { return true }
        switch e.keyCode {
        case 123, 126: step(-1); return true
        case 124, 125: step(1); return true
        default: break
        }
        let chars = e.charactersIgnoringModifiers ?? ""
        let mods = e.modifierFlags
        if !mods.contains(.command), measure.handleKey(keyCode: e.keyCode) { return true }
        if !picks.crops.active, picks.handleKey(chars: chars, keyCode: e.keyCode, shift: mods.contains(.shift), command: mods.contains(.command)) { return true }
        switch chars.lowercased() {
        case "m": measure.enabled.toggle(); return true
        case "p": picks.enabled.toggle(); return true
        case "g": showGallery = true; return true
        case "v": picks.showMarkers.toggle(); return true
        case "b": picks.showBoxes.toggle(); return true
        case "f": view.fit(); return true
        case "1": view.setZoom(1); return true
        case "i": view.invert.toggle(); return true
        case "t": showThonRings(); return true
        case "=", "+": view.setZoom(view.zoom * 1.25); return true
        case "-": view.setZoom(view.zoom / 1.25); return true
        default: return false
        }
    }

    // MARK: open / export

    func presentOpenPanel(folders: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = !folders
        if !folders { p.allowedContentTypes = ["dm3", "dm4", "mrc", "mrcs"].compactMap { UTType(filenameExtension: $0) } }
        if p.runModal() == .OK { open(urls: p.urls) }
    }

    private func suggestedName(_ ext: String) -> String {
        (doc?.url.deletingPathExtension().lastPathComponent ?? "micrograph") + "." + ext
    }

    func exportPNG() {
        guard let doc, let px = renderer?.readProcessed() else { return }
        let sp = NSSavePanel(); sp.allowedContentTypes = [.png]; sp.nameFieldStringValue = suggestedName("png")
        guard sp.runModal() == .OK, let url = sp.url else { return }
        let w = doc.entry.width, h = doc.entry.height
        let lo = Float(view.lo), hi = Float(max(view.hi, view.lo + 1e-9)), g = Float(max(view.gamma, 0.05))
        var bytes = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var t = min(max((px[i] - lo) / (hi - lo), 0), 1)
            t = powf(t, g)
            if view.invert { t = 1 - t }
            bytes[i] = UInt8(t * 255 + 0.5)
        }
        guard let prov = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        if !CGImageDestinationFinalize(dest) { loadError = "Could not write PNG." }
    }

    func exportMRC(processed: Bool) {
        guard let doc else { return }
        let px: [Float] = processed ? (renderer?.readProcessed() ?? doc.pixels) : doc.pixels
        let sp = NSSavePanel(); sp.nameFieldStringValue = suggestedName("mrc")
        guard sp.runModal() == .OK, let url = sp.url else { return }
        let w = doc.entry.width, h = doc.entry.height
        let st = ImageStats.compute(px)
        let pa = Float(doc.entry.pixelSizeA ?? 1)
        var hdr = [UInt8](repeating: 0, count: 1024)
        func putI(_ i: Int, _ v: Int32) { withUnsafeBytes(of: v.littleEndian) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
        func putF(_ i: Int, _ v: Float) { withUnsafeBytes(of: v.bitPattern.littleEndian) { for k in 0..<4 { hdr[i * 4 + k] = $0[k] } } }
        putI(0, Int32(w)); putI(1, Int32(h)); putI(2, 1); putI(3, 2)
        putI(7, Int32(w)); putI(8, Int32(h)); putI(9, 1)
        putF(10, Float(w) * pa); putF(11, Float(h) * pa); putF(12, pa)
        putF(13, 90); putF(14, 90); putF(15, 90)
        putI(16, 1); putI(17, 2); putI(18, 3)
        putF(19, Float(st.min)); putF(20, Float(st.max)); putF(21, Float(st.mean))
        hdr[208] = 0x4D; hdr[209] = 0x41; hdr[210] = 0x50; hdr[211] = 0x20          // "MAP "
        hdr[212] = 0x44; hdr[213] = 0x44                                            // little-endian machine stamp
        putF(54, Float(st.std))
        var out = Data(hdr)
        var flipped = [Float](repeating: 0, count: w * h)       // MRC origin is bottom-left; DM data is top-down
        for y in 0..<h { flipped.replaceSubrange((h - 1 - y) * w ..< (h - y) * w, with: px[(y * w)..<((y + 1) * w)]) }
        flipped.withUnsafeBytes { out.append(contentsOf: $0) }
        do { try out.write(to: url) } catch { loadError = error.localizedDescription }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview", display = "Display", picks = "Picks", fft = "FFT", tags = "Tags"
    var id: String { rawValue }
}

/// 8-bit grayscale thumbnail with 1-99 percentile stretch (used when a file has no embedded thumbnail).
func makeThumbnail(_ px: [Float], _ w: Int, _ h: Int, maxSide: Int = 256) -> CGImage? {
    let f = max(1, max(w, h) / maxSide)
    let tw = w / f, th = h / f
    guard tw > 0, th > 0 else { return nil }
    var small = [Float](repeating: 0, count: tw * th)
    for y in 0..<th {
        for x in 0..<tw {
            var s: Float = 0
            for dy in 0..<f { for dx in 0..<f { s += px[(y * f + dy) * w + x * f + dx] } }
            small[y * tw + x] = s / Float(f * f)
        }
    }
    let sorted = small.sorted()
    let lo = sorted[Int(0.01 * Double(sorted.count - 1))], hi = max(sorted[Int(0.99 * Double(sorted.count - 1))], lo + 1e-9)
    let bytes = small.map { UInt8(max(0, min(255, ($0 - lo) / (hi - lo) * 255))) }
    guard let prov = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: tw, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
