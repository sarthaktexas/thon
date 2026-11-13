import SwiftUI

/// Thon ▸ Settings… (⌘,).
struct PreferencesView: View {
    @ObservedObject var engines = EngineSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Offer Topaz and CryoSegNet in the Picks tab", isOn: $engines.enabled)
                Text("Both run in a Python environment you installed yourself and are slow on a CPU (about a minute or more per micrograph). The built-in picker is always available and stays the default. After switching on, choose an engine under Picks ▸ Find particles and set up its environment there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Pickers") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }
}
