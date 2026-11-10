import Foundation

enum MarkerShape: String, Codable, CaseIterable, Identifiable {
    case circle, box, cross, ring
    var id: String { rawValue }
}

struct PickLabel: Codable, Identifiable, Equatable {
    var id: String                   // stable identifier used in exports (e.g. "ring_top")
    var name: String
    var key: String                  // single-character hotkey ("1"…"9", letters)
    var color: String                // "#rrggbb"
    var shape: MarkerShape = .circle
    var exported = true              // false = kept in the project but not written as picks (e.g. reject)

    init(id: String, name: String, key: String, color: String, shape: MarkerShape = .circle, exported: Bool = true) {
        self.id = id; self.name = name; self.key = key; self.color = color; self.shape = shape; self.exported = exported
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#ffffff"
        shape = try c.decodeIfPresent(MarkerShape.self, forKey: .shape) ?? .circle
        exported = try c.decodeIfPresent(Bool.self, forKey: .exported) ?? true
    }
}

struct LabelScheme: Codable, Equatable {
    var labels: [PickLabel]

    /// Default for new projects: a quality / confidence rating that works on any micrograph.
    static let quality = LabelScheme(labels: [
        PickLabel(id: "good",   name: "Good",   key: "1", color: "#4dff6a"),
        PickLabel(id: "maybe",  name: "Maybe",  key: "2", color: "#ffd400"),
        PickLabel(id: "reject", name: "Reject", key: "3", color: "#9a9a9a", exported: false),
    ])

    /// Particle views (the web picker's six labels; ids are kept so web picks.json imports and old projects resolve).
    static let views = LabelScheme(labels: [
        PickLabel(id: "ring_top",   name: "Ring (top view)",   key: "1", color: "#ff4d4d"),
        PickLabel(id: "side",       name: "Side / edge-on",    key: "2", color: "#ffd400"),
        PickLabel(id: "tilted",     name: "Tilted ring",       key: "3", color: "#35e0ff"),
        PickLabel(id: "oligomer",   name: "Other oligomer",    key: "4", color: "#4dff6a"),
        PickLabel(id: "uncertain",  name: "Uncertain",         key: "5", color: "#ff7bf5"),
        PickLabel(id: "reject",     name: "Reject / negative", key: "6", color: "#9a9a9a", exported: false),
    ])

    static let `default` = quality

    /// Presets offered in the label editor.
    static let presets: [(name: String, scheme: LabelScheme)] = [
        ("Quality: Good / Maybe / Reject", quality),
        ("Views: ring, side, tilted, other, uncertain, reject", views),
    ]

    /// Suggested destination for picks whose label is missing from a new scheme (nil = no sensible guess).
    /// Only ever proposes a label that exists in `self`; the user confirms or changes it in the editor.
    func suggestedTarget(forMissing id: String) -> String? {
        let candidates: [String]
        switch id {
        case "reject": candidates = ["reject"]
        case "uncertain": candidates = ["maybe"]
        case "maybe": candidates = ["uncertain"]
        case "ring_top", "side", "tilted", "oligomer": candidates = ["good"]
        default: candidates = []
        }
        return candidates.first { label($0) != nil }
    }

    /// Keys the viewer itself uses while picking.
    static let reservedKeys: Set<String> = ["a", "b", "f", "g", "i", "p", "s", "v", ",", ".", "=", "+", "-", "?", "/"]

    func label(_ id: String) -> PickLabel? { labels.first { $0.id == id } }
    func label(forKey k: String) -> PickLabel? { labels.first { $0.key.lowercased() == k.lowercased() } }
    var firstID: String { labels.first?.id ?? "particle" }

    /// Problems that would make the scheme unusable (duplicate ids / hotkeys, bad colors, empty).
    func validate() -> [String] {
        var errs: [String] = []
        if labels.isEmpty { errs.append("no labels") }
        var ids = Set<String>(), keys = Set<String>()
        for l in labels {
            if l.id.isEmpty || l.id.contains(where: { $0.isWhitespace || $0 == "/" }) { errs.append("bad id '\(l.id)'") }
            if !ids.insert(l.id).inserted { errs.append("duplicate id '\(l.id)'") }
            if LabelScheme.reservedKeys.contains(l.key.lowercased()) { errs.append("hotkey '\(l.key)' is reserved") }
            if !l.key.isEmpty && !keys.insert(l.key.lowercased()).inserted { errs.append("duplicate hotkey '\(l.key)'") }
            if parseHexColor(l.color) == nil { errs.append("bad color '\(l.color)' for \(l.id)") }
        }
        return errs
    }

    static func load(from url: URL) throws -> LabelScheme {
        // accept both {"labels":[…]} and the web picker's manifest-style list [{key,id,name,color}]
        let d = try Data(contentsOf: url)
        if let s = try? JSONDecoder().decode(LabelScheme.self, from: d) { return s }
        let arr = try JSONDecoder().decode([PickLabel].self, from: d)
        return LabelScheme(labels: arr)
    }

    func save(to url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeFileAtomically(try e.encode(self), to: url)
    }
}

/// "#rrggbb" -> (r, g, b) in 0…1.
func parseHexColor(_ s: String) -> (Double, Double, Double)? {
    var h = s.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}
