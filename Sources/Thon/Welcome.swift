import SwiftUI
import AppKit

/// Most recently opened projects, folders and files, newest first. Stored as paths in UserDefaults.
@MainActor
final class RecentStore: ObservableObject {
    private static let key = "recentItems"
    private static let limit = 10
    @Published private(set) var paths: [String]

    init() { paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? [] }

    /// Recents that still exist on disk.
    var existing: [URL] {
        paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func note(_ url: URL) {
        let p = url.standardizedFileURL.path
        paths = Array(([p] + paths.filter { $0 != p }).prefix(Self.limit))
        save()
    }
    func remove(_ url: URL) { paths.removeAll { $0 == url.standardizedFileURL.path }; save() }
    func clear() { paths = []; save() }
    private func save() { UserDefaults.standard.set(paths, forKey: Self.key) }
}

/// First screen: shown while nothing is open. Actions on the left, recent items on the right.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recents: RecentStore

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                Text("Thon").font(.system(size: 34, weight: .bold)).padding(.top, 10)
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    WelcomeAction(symbol: "doc", title: "Open Files…", detail: "DM3, DM4, MRC or MRCS micrographs") { model.presentOpenPanel(folders: false) }
                    WelcomeAction(symbol: "folder", title: "Open Folder…", detail: "Scan a folder for DM3 / DM4 / MRC files") { model.presentOpenPanel(folders: true) }
                    WelcomeAction(symbol: "square.stack.3d.up", title: "Open Project…", detail: "A .thon project with sessions and picks") { model.presentOpenProjectPanel() }
                    WelcomeAction(symbol: "plus.square.on.square", title: "New Project from Folders…", detail: "One session per folder") { model.presentNewProjectPanels() }
                    WelcomeAction(symbol: "folder.badge.gearshape", title: "New Project from Folder of Folders…", detail: "Every sub-folder becomes a session") { model.presentNewProjectFromParentPanel() }
                }
                .padding(.top, 28)
                Text("or drop files or a folder anywhere in this window").font(.caption).foregroundStyle(.tertiary).padding(.top, 14)
                Spacer(minLength: 0)
            }
            .frame(width: 400)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Recent").font(.headline).padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 8)
                let items = recents.existing
                if items.isEmpty {
                    Text("Nothing opened yet.").foregroundStyle(.secondary).padding(.horizontal, 20)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(items, id: \.path) { u in
                                RecentRow(url: u) { model.open(urls: [u]) }
                                    .contextMenu {
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                        Button("Remove from Recent") { recents.remove(u) }
                                    }
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeAction: View {
    let symbol: String, title: String, detail: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hover = false

    private var symbol: String {
        if url.pathExtension.lowercased() == PickStore.projectExtension { return "square.stack.3d.up" }
        return PathUtil.isDirectory(url) ? "folder" : "doc"
    }
    private var parent: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(parent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
