import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
enum PickPanels {
    static func chooseExport(model: AppModel) {
        let pc = model.picks
        guard pc.store.root != nil else { pc.ioMessage = "Open a folder of micrographs first."; return }
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Export here"
        p.message = "Choose the folder for the exported picks (files from a previous export in it are replaced; other files are left alone)."
        if let d = pc.defaultExportFolder {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            p.directoryURL = d
        }
        if p.runModal() == .OK, let u = p.url { pc.exportPicks(to: u) }
    }

    static func chooseClasses(model: AppModel) {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.allowedContentTypes = ["star"].compactMap { UTType(filenameExtension: $0) }
        p.directoryURL = model.picks.store.root
        p.message = "Choose a RELION run_itNNN_data.star (2D/3D classification) to map classes back onto the picks."
        if p.runModal() == .OK, let u = p.url { model.picks.loadClasses(star: u) }
    }

    static func chooseImport(model: AppModel, asCandidates: Bool) {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.allowedContentTypes = ["star", "csv", "json"].compactMap { UTType(filenameExtension: $0) }
        p.directoryURL = model.picks.store.root
        p.message = "Choose RELION coordinate .star files (or coords_list.star), CSV with x/y columns, or a web-picker picks.json / swipe.json."
        guard p.runModal() == .OK else { return }
        let keys = model.items.map { model.picks.store.key(for: $0.url) }
        model.picks.importPicks(files: p.urls, knownKeys: keys, asCandidates: asCandidates)
    }
}
