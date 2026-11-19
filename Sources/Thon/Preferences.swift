import SwiftUI

/// Thon ▸ Settings… (⌘,).
struct PreferencesView: View {
    @ObservedObject var engines = EngineSettings.shared
    @ObservedObject var updates = UpdateController.shared
    @ObservedObject var relion = RelionSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Offer Topaz and CryoSegNet in the Picks tab", isOn: $engines.enabled)
                Text("Both run in a Python environment you installed yourself and are slow on a CPU (about a minute or more per micrograph). The built-in picker is always available and stays the default. After switching on, choose an engine under Picks ▸ Find particles and set up its environment there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Pickers") }
            Section {
                RelionFolderField(relion: relion)
                Stepper(value: $relion.config.threads, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)) { Text("Threads for 2D classification: \(relion.config.threads)") }
                Text("Used by Picks ▸ 2D Classification with RELION…. RELION runs at low priority; a few threads keep the Mac responsive.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("RELION") }
            Section {
                Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
                    .disabled(!updates.isActive)
                HStack {
                    Text("Thon \(UpdateController.versionText)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }.disabled(!updates.canCheck)
                }
                if !updates.isActive {
                    Text("Updates work in the packaged Thon.app from a release. They are off when Thon is run from the build folder.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("Updates") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }
}
