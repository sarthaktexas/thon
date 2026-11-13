import SwiftUI
import AppKit

/// Colour tags on micrographs and on the frames of a stack, like the Finder's tags. A micrograph or frame can carry several.
enum FinderTag: String, CaseIterable, Identifiable, Codable {
    case red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var hex: String {
        switch self {
        case .red: return "#FF3B30"; case .orange: return "#FF9500"; case .yellow: return "#FFCC00"; case .green: return "#34C759"
        case .blue: return "#0A84FF"; case .purple: return "#AF52DE"; case .gray: return "#8E8E93"
        }
    }
    var color: Color { swiftUIColor(hex) }
    /// ⌥⌘1 ... ⌥⌘7 in the Tag menu.
    var shortcutDigit: String { String((FinderTag.allCases.firstIndex(of: self) ?? 0) + 1) }

    /// A filled circle for menus (SwiftUI colours do not reach menu icons, an NSImage does).
    var menuImage: NSImage {
        let s: CGFloat = 12
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
            let c = NSColor(calibratedRed: CGFloat(Int(self.hex.dropFirst().prefix(2), radix: 16) ?? 0) / 255,
                            green: CGFloat(Int(self.hex.dropFirst(3).prefix(2), radix: 16) ?? 0) / 255,
                            blue: CGFloat(Int(self.hex.dropFirst(5).prefix(2), radix: 16) ?? 0) / 255, alpha: 1)
            c.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// Bumped when a tag changes, so the sidebar redraws its dots without listening to every pick edit.
final class TagChanges: ObservableObject {
    @Published private(set) var rev = 0
    func bump() { rev &+= 1 }
}

/// Overlapping dots, one per tag (like the Finder's).
struct TagDots: View {
    let tags: [FinderTag]
    var size: CGFloat = 10
    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(tags) { t in
                Circle().fill(t.color).frame(width: size, height: size)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
            }
        }
    }
}

/// Toggle items for one micrograph / frame key (context menus).
struct TagMenuItems: View {
    let store: PickStore
    let key: String
    var body: some View {
        let have = Set(store.tags(key))
        ForEach(FinderTag.allCases) { t in
            Button { store.toggleTag(key, t) } label: {
                Label { Text(t.name + (have.contains(t) ? "  ✓" : "")) } icon: { Image(nsImage: t.menuImage) }
            }
        }
        Divider()
        Button("Clear Tags") { store.clearTags(key) }.disabled(have.isEmpty)
    }
}
