import SwiftUI
import AppKit

/// Setup and options of the Topaz / CryoSegNet engines, shown under the engine picker.
struct EngineSetupView: View {
    let engine: PickEngine
    @ObservedObject var settings = EngineSettings.shared
    @State private var open = false

    var body: some View {
        let problems = EngineCommand.problems(engine, settings.config)
        VStack(alignment: .leading, spacing: 6) {
            if problems.isEmpty {
                Label("\(engine.rawValue) is set up", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            switch engine {
            case .topaz:
                lengthless("Score cutoff (log-likelihood)", Binding(get: { settings.config.topazThreshold }, set: { settings.config.topazThreshold = $0 }), -6...3, "%.1f")
                Text("Runs the pretrained Topaz model on the CPU, about a minute per 4k micrograph. Scores shown are Topaz's log-likelihood minus the cutoff.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .cryosegnet:
                Text("Stock mode resizes the whole micrograph to 1024 px, which loses small particles. Set a tile size (native pixels, about 6× the particle) to keep native scale.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Text("Tile size (px, 0 = whole micrograph)").font(.callout)
                    Stepper(value: Binding(get: { settings.config.csnTile }, set: { settings.config.csnTile = $0 }), in: 0...4096, step: 128) {
                        Text("\(settings.config.csnTile)").monospacedDigit() }
                }
            case .builtin: EmptyView()
            }
            DisclosureGroup("Environment", isExpanded: $open) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Detect environments") { settings.detect() }.controlSize(.small)
                    if engine == .topaz {
                        pathField("Python (topaz env)", Binding(get: { settings.config.topazPython }, set: { settings.config.topazPython = $0 }), folder: false)
                    } else if engine == .cryosegnet {
                        pathField("Python (cryosegnet env)", Binding(get: { settings.config.csnPython }, set: { settings.config.csnPython = $0 }), folder: false)
                        pathField("CryoSegNet folder", Binding(get: { settings.config.csnRepo }, set: { settings.config.csnRepo = $0 }), folder: true)
                        pathField("Weights folder", Binding(get: { settings.config.csnWeights }, set: { settings.config.csnWeights = $0 }), folder: true)
                        HStack {
                            Text("Device").font(.callout)
                            Picker("", selection: Binding(get: { settings.config.csnDevice }, set: { settings.config.csnDevice = $0 })) {
                                Text("Auto").tag("auto"); Text("MPS (GPU)").tag("mps"); Text("CPU").tag("cpu")
                            }.labelsHidden().frame(width: 110)
                        }
                    }
                    HStack {
                        Text("CPU threads").font(.callout)
                        Stepper(value: Binding(get: { settings.config.threads }, set: { settings.config.threads = $0 }), in: 1...6) {
                            Text("\(settings.config.threads)").monospacedDigit() }
                    }
                }.padding(.top, 4)
            }
        }
        .onAppear { if problems.contains(where: { $0.contains("not set") }) { settings.detect() } }
    }

    private func lengthless(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.callout); Spacer(); Text(String(format: f, v.wrappedValue)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) }
            Slider(value: v, in: r)
        }
    }

    private func pathField(_ title: String, _ b: Binding<String>, folder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("", text: b).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseFiles = !folder; p.canChooseDirectories = folder; p.allowsMultipleSelection = false
                    p.showsHiddenFiles = true
                    if p.runModal() == .OK, let u = p.url { b.wrappedValue = u.path }
                }.controlSize(.small)
            }
        }
    }
}
