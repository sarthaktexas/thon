import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = args.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { Task { @MainActor in AppModel.shared.open(urls: urls) } }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls: urls) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.picks.store.flush() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ThonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Thon", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files…") { model.presentOpenPanel(folders: false) }.keyboardShortcut("o")
                Button("Open Folder…") { model.presentOpenPanel(folders: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Export PNG…") { model.exportPNG() }.keyboardShortcut("e")
                Button("Export MRC (raw)…") { model.exportMRC(processed: false) }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Picks") {
                Button("Undo Pick Edit") { model.picks.undo() }.keyboardShortcut("z")
                Button("Redo Pick Edit") { model.picks.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Select All Picks") { model.picks.selectAll() }.keyboardShortcut("a")
                Button("Delete Selected Picks") { model.picks.deleteSelection() }
                Button("Accept All Candidates") { model.picks.acceptAllCandidates() }
                Button("Dismiss All Candidates") { model.picks.dismissAllCandidates() }
                Divider()
                Button("Edit Labels…") { model.picks.openLabelEditor() }
                Button("Swipe Mode…") { model.showSwipe = true }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Gallery…") { model.showGallery = true }.keyboardShortcut("g", modifiers: [.command, .option])
                Button("Load RELION Classification…") { PickPanels.chooseClasses(model: model) }
                Divider()
                Button("Import Picks…") { PickPanels.chooseImport(model: model, asCandidates: false) }
                Button("Import Picks as Candidates…") { PickPanels.chooseImport(model: model, asCandidates: true) }
                Button("Export Picks…") { PickPanels.chooseExport(model: model) }.keyboardShortcut("e", modifiers: [.command, .option])
                Divider()
                Button("Save Picks Now") { model.picks.store.save(forceBackup: true) }.keyboardShortcut("s")
            }
            CommandMenu("Navigate") {
                Button("Next Exposure") { model.step(1) }.keyboardShortcut("]")
                Button("Previous Exposure") { model.step(-1) }.keyboardShortcut("[")
            }
            CommandGroup(after: .toolbar) {
                Button("Fit to Window") { model.view.fit() }.keyboardShortcut("0")
                Button("Actual Pixels") { model.view.setZoom(1) }.keyboardShortcut("1")
                Button("Zoom In") { model.view.setZoom(model.view.zoom * 1.25) }.keyboardShortcut("+")
                Button("Zoom Out") { model.view.setZoom(model.view.zoom / 1.25) }.keyboardShortcut("-")
                Button("Invert Contrast") { model.view.invert.toggle() }.keyboardShortcut("i")
                Button("Toggle Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
