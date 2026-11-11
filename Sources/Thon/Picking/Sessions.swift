import Foundation

/// One imaging session (a grid / sample / day) inside a Thon project file (`*.thon`).
/// Micrographs belong to the session whose folder contains them; their project key is `<session id>/<path inside the folder>`,
/// so renaming a session or relocating its folder never invalidates picks.
struct PickSession: Codable, Equatable, Identifiable {
    var id: String                    // stable key prefix (letters, digits, - _ only)
    var name: String
    var sample = ""                   // sample / grid description
    var date = ""                     // free text (e.g. 2026-10-28)
    var notes = ""
    var folder: String                // relative to the project file's folder (may start with ../)
    var absFolder: String?            // absolute path at the time it was last resolved; fallback if the project file was moved

    init(id: String, name: String, sample: String = "", date: String = "", notes: String = "", folder: String, absFolder: String? = nil) {
        self.id = id; self.name = name; self.sample = sample; self.date = date; self.notes = notes; self.folder = folder; self.absFolder = absFolder
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        sample = try c.decodeIfPresent(String.self, forKey: .sample) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        absFolder = try c.decodeIfPresent(String.self, forKey: .absFolder)
    }

    /// `id` made of safe characters, unique among `taken`.
    static func makeID(from name: String, taken: Set<String>) -> String {
        var s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if s.isEmpty { s = "session" }
        if s.count > 40 { s = String(s.prefix(40)) }
        if !taken.contains(s) { return s }
        var n = 2
        while taken.contains("\(s)_\(n)") { n += 1 }
        return "\(s)_\(n)"
    }
}

enum PathUtil {
    /// `target` as a path relative to the directory `base` (uses `..` where needed).
    static func relative(from base: URL, to target: URL) -> String {
        let b = base.standardizedFileURL.pathComponents, t = target.standardizedFileURL.pathComponents
        var i = 0
        while i < b.count && i < t.count && b[i] == t[i] { i += 1 }
        let parts = Array(repeating: "..", count: b.count - i) + Array(t[i...])
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
    static func isDirectory(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }
}

/// Maps micrograph files <-> project keys. Value type, safe to capture in background work.
///  - no sessions (a folder project): key = path relative to `root` (or the absolute path outside it)
///  - sessions (a .thon project): key = "<session id>/<path inside the session folder>" (or the absolute path outside every session)
struct PickKeyMap {
    var root: URL?
    var roots: [(id: String, url: URL)] = []
    var isSessions: Bool { !roots.isEmpty }

    init(root: URL?, sessions: [PickSession] = []) {
        self.root = root
        guard let root else { return }
        roots = sessions.map { ($0.id, Self.folder(of: $0, projectDir: root)) }
    }

    /// Where a session's folder is: the stored relative path if it exists, else the stored absolute path if it exists,
    /// else the relative path (a missing folder keeps a stable best-guess location).
    static func folder(of s: PickSession, projectDir: URL) -> URL {
        let rel = projectDir.appendingPathComponent(s.folder).standardizedFileURL
        if PathUtil.isDirectory(rel) { return rel }
        if let a = s.absFolder, PathUtil.isDirectory(URL(fileURLWithPath: a)) { return URL(fileURLWithPath: a).standardizedFileURL }
        return rel
    }

    /// Session id of the deepest session folder containing `url`.
    func sessionID(containing url: URL) -> String? {
        let p = url.standardizedFileURL.path
        var best: (String, Int)?
        for r in roots {
            let rp = r.url.path
            if p.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/"), rp.count > (best?.1 ?? -1) { best = (r.id, rp.count) }
        }
        return best?.0
    }

    func key(for url: URL) -> String {
        let p = url.standardizedFileURL.path
        if isSessions {
            if let id = sessionID(containing: url), let r = roots.first(where: { $0.id == id }) {
                let rp = r.url.path
                return id + "/" + String(p.dropFirst(rp.hasSuffix("/") ? rp.count : rp.count + 1))
            }
            return p
        }
        guard let root else { return p }
        let r = root.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    func sessionID(ofKey key: String) -> String? {
        guard isSessions, let i = key.firstIndex(of: "/") else { return nil }
        let id = String(key[..<i])
        return roots.contains { $0.id == id } ? id : nil
    }

    func url(forKey key: String) -> URL {
        if key.hasPrefix("/") { return URL(fileURLWithPath: key) }
        if let id = sessionID(ofKey: key), let r = roots.first(where: { $0.id == id }) {
            return r.url.appendingPathComponent(String(key.dropFirst(id.count + 1)))
        }
        return (root ?? URL(fileURLWithPath: "/")).appendingPathComponent(key)
    }
}

extension PickProject {
    var isSessionProject: Bool { !sessions.isEmpty }
}

enum SessionDiscovery {
    static let extensions: Set<String> = ["dm3", "dm4", "mrc", "mrcs"]

    /// True if `folder` holds at least one micrograph at any depth.
    static func hasMicrographs(_ folder: URL) -> Bool {
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let f as URL in en where extensions.contains(f.pathExtension.lowercased()) { return true }
        return false
    }

    /// For a "folder of folders": the immediate sub-folders of `parent` that contain micrographs (naturally sorted), and the number of
    /// micrograph files lying directly in `parent` itself (these belong to no sub-folder session).
    static func subfolderSessions(of parent: URL) -> (folders: [URL], looseFiles: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).filter { !$0.hasPrefix(".") }
        var folders: [URL] = [], loose = 0
        for n in names {
            let k = parent.appendingPathComponent(n)
            if PathUtil.isDirectory(k) {
                if ["app", "bundle", "pkg", "photoslibrary"].contains(k.pathExtension.lowercased()) { continue }
                if hasMicrographs(k) { folders.append(k) }
            } else if extensions.contains(k.pathExtension.lowercased()) { loose += 1 }
        }
        folders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (folders, loose)
    }
}
