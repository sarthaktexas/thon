import SwiftUI
import AppKit

/// Sheet: 2D classification of the picks with RELION (File ▸ Picks ▸ 2D Classification…).
struct Class2DView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var store: PickStore
    @ObservedObject var c: Class2DSession
    @ObservedObject var relion = RelionSettings.shared
    @ObservedObject var units = UnitSettings.shared
    @State private var advanced = false
    @State private var version: String?
    var scrollable = true            // false: plain stack (used to render the sheet to an image)

    init(model: AppModel) {
        self.model = model; self.pc = model.picks; self.store = model.picks.store; self.c = model.picks.class2D
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("2D classification with RELION").font(.headline)
                Spacer()
                Button("Done") { model.showClass2D = false }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if scrollable { ScrollView { content } } else { content }
        }
        .frame(width: 720, height: 700)
        .onAppear {
            relion.detect()
            if !c.running { c.seedParameters(); c.scan() }
            loadVersion()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            relionBox
            particlesBox
            parametersBox
            runBox
            if !c.averages.isEmpty { resultsBox }
            if !c.jobs.isEmpty { jobsBox }
        }.padding(14)
    }

    // MARK: sections

    private func box<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var relionBox: some View {
        box("RELION") {
            let problems = RelionLocator.problems(relion.config.binFolder)
            if problems.isEmpty {
                Label((version ?? "RELION") + " · " + relion.config.binFolder, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            RelionFolderField(relion: relion, onChange: loadVersion)
        }
    }

    private var particlesBox: some View {
        box("Particles") {
            HStack(spacing: 14) {
                ForEach(store.scheme.labels) { l in
                    Toggle(isOn: Binding(get: { Class2DInventory.labels(c.params, scheme: store.scheme).contains(l.id) }, set: { on in
                        var s = Class2DInventory.labels(c.params, scheme: store.scheme)
                        if on { s.insert(l.id) } else { s.remove(l.id) }
                        c.params.labels = store.scheme.labels.map { $0.id }.filter { s.contains($0) }
                        c.scan()
                    })) {
                        HStack(spacing: 4) { Circle().fill(swiftUIColor(l.color)).frame(width: 9, height: 9); Text(l.name) }
                    }.toggleStyle(.checkbox)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                Toggle("Leave out “maybe”", isOn: Binding(get: { c.params.excludeMaybe }, set: { c.params.excludeMaybe = $0; c.scan() })).toggleStyle(.checkbox)
                Toggle("Only micrographs marked done", isOn: Binding(get: { c.params.onlyDone }, set: { c.params.onlyDone = $0; c.scan() })).toggleStyle(.checkbox)
                Spacer()
                if c.scanning { ProgressView().controlSize(.small) }
                Button("Rescan") { c.scan() }.controlSize(.small).disabled(c.scanning)
            }.font(.callout)
            HStack(spacing: 14) {
                Toggle("Include candidates (unreviewed auto-picks)", isOn: Binding(get: { c.params.includeCandidates }, set: { c.params.includeCandidates = $0; c.scan() })).toggleStyle(.checkbox)
                if c.params.includeCandidates {
                    Stepper(value: Binding(get: { Double(c.params.minScore) }, set: { c.params.minScore = Float($0); c.scan() }), in: -20...Double(max(pc.maxScore, 10)), step: 0.5) {
                        Text(String(format: "score ≥ %.1f", c.params.minScore)).monospacedDigit()
                    }
                }
                Spacer()
            }.font(.callout)
            if c.params.includeCandidates {
                Text("Candidates have not been reviewed, so some of them are not particles. Classify them, then accept the good classes and dismiss the junk ones in Picks ▸ RELION classes.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Particles of one size go together, within ±").font(.callout)
                Stepper(value: Binding(get: { Int((c.params.sizeTolerance * 100).rounded()) }, set: { c.params.sizeTolerance = Double($0) / 100; c.scan() }), in: 5...50, step: 5) {
                    Text("\(Int((c.params.sizeTolerance * 100).rounded())) %").monospacedDigit().frame(width: 40, alignment: .trailing)
                }.font(.callout)
                Spacer()
            }
            if let inv = c.inventory {
                if inv.groups.isEmpty {
                    Text("No accepted picks that RELION can read.").font(.callout).foregroundStyle(.orange)
                } else {
                    Text("Classes are made for one group at a time. Different particle sizes (or pixel sizes) are never combined in one classification.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    let sel = c.selectedGroup?.id
                    ForEach(inv.groups) { g in
                        Button { c.params.angpix = g.angpix; c.params.sizeNm = g.sizeNm } label: {
                            HStack(spacing: 8) {
                                Image(systemName: g.id == sel ? "largecircle.fill.circle" : "circle")
                                Text(g.sizeText(angstroms: units.angstroms)).monospacedDigit()
                                Text(String(format: "%d picks%@ · %d micrographs · %.3g Å/px", g.pickCount, g.candidateCount > 0 ? " (\(g.candidateCount) candidates)" : "", g.mics.count, g.angpix)).foregroundStyle(.secondary).font(.caption)
                                if g.pickCount < Class2DSession.minPicks { Text("too few").font(.caption).foregroundStyle(.orange) }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).font(.callout)
                    }
                }
                if let s = inv.skippedText { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var parametersBox: some View {
        box("Parameters") {
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Scaled box").font(.callout)
                    Picker("", selection: $c.params.targetBoxPx) { ForEach([32, 48, 64, 80, 96, 128, 192, 256], id: \.self) { Text("\($0) px").tag($0) } }
                        .labelsHidden().frame(width: 84)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                HStack(spacing: 4) { Text("Classes").font(.callout); Stepper(value: $c.params.classes, in: 2...100) { Text("\(c.params.classes)").monospacedDigit().frame(width: 28, alignment: .trailing) } }
                HStack(spacing: 4) { Text("Iterations").font(.callout); Stepper(value: $c.params.iterations, in: 5...400, step: 5) { Text("\(c.params.iterations)").monospacedDigit().frame(width: 34, alignment: .trailing) } }
                HStack(spacing: 4) { Text("Threads").font(.callout); Stepper(value: $c.params.threads, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)) { Text("\(c.params.threads)").monospacedDigit().frame(width: 22, alignment: .trailing) } }
            }
            Toggle("Particles are dark on a lighter background (invert contrast)", isOn: $c.params.invertContrast).toggleStyle(.checkbox).font(.callout)
            if let g = c.geometry {
                Text("Cut out \(g.extractPx) px (\(LengthUnits.format(angstroms: Double(g.extractPx) * g.angpix, useAngstroms: units.angstroms))), scaled to \(g.scaledPx) px at \(String(format: "%.2f", g.scaledAngpix)) Å/px · mask \(LengthUnits.format(angstroms: g.diameterA, useAngstroms: units.angstroms)) · background radius \(g.bgRadiusPx) px")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                ForEach(g.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            DisclosureGroup("More settings", isExpanded: $advanced) {
                HStack(spacing: 16) {
                    field("Mask ÷ diameter", $c.params.maskMargin, width: 44)
                    field("Box ×", $c.params.boxScale, width: 44)
                    field("Angular step (°)", $c.params.psiStep, width: 44)
                    field("Regularisation T", $c.params.tau2Fudge, width: 44)
                    HStack(spacing: 4) { Text("Max shift (px)").font(.callout); Stepper(value: $c.params.maxOffsetPx, in: 1...30) { Text("\(c.params.maxOffsetPx)").monospacedDigit() } }
                }.padding(.top, 4)
                Text("Gradient-driven (VDAM) 2D classification on the CPU, no CTF correction. Each group's box and mask come from its own picks: the box of the picks (or the project's box : diameter ratio) and the median diameter × the mask factor.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.font(.callout)
        }
    }

    private var runBox: some View {
        box("Run") {
            HStack {
                if c.running {
                    Button("Stop") { c.cancel() }
                } else {
                    Button(c.selectedGroup.map { "Run \($0.sizeText(angstroms: units.angstroms))" } ?? "Run 2D classification") { c.start() }.disabled(!c.canStart).keyboardShortcut(.defaultAction)
                    if c.canStartAll { Button("Run every group (\(c.runnableGroups.count))") { c.startAll() }.help("One separate classification per size group, one after another") }
                }
                if c.phase == .classifying {
                    ProgressView(value: Double(c.iteration), total: Double(max(c.totalIterations, 1))).frame(maxWidth: 220)
                    Text("iteration \(c.iteration) / \(c.totalIterations)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if c.running { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let m = c.message { Text(m).font(.caption).foregroundStyle(c.phase == .failed ? Color.red : Color.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let w = c.warning { Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if c.phase == .idle || c.phase == .finished {
                Text("Runs relion_preprocess and relion_refine at low priority with \(c.params.threads) thread\(c.params.threads == 1 ? "" : "s"). Files go to a hidden folder next to the project.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var resultsBox: some View {
        box(c.phase == .classifying ? "Class averages so far" : "Class averages") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(c.averages.keys.sorted(), id: \.self) { n in
                    VStack(spacing: 2) {
                        if let a = c.averages[n], let img = grayCGImage(a.bytes, width: a.size, height: a.size) {
                            Image(decorative: img, scale: 1).resizable().interpolation(.medium).frame(width: 96, height: 96)
                                .overlay(Rectangle().strokeBorder(swiftUIColor(ClassMapping.color(n)), lineWidth: 2))
                        }
                        Text("class \(n)" + (c.counts[n].map { " · \($0)" } ?? "")).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if c.phase == .finished {
                HStack {
                    Text("The picks are coloured by class now (Picks tab ▸ RELION classes): select, relabel or remove whole classes there.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Gallery…") { model.showClass2D = false; model.showGallery = true }.controlSize(.small)
                }
            }
        }
    }

    private var jobsBox: some View {
        box("Earlier runs") {
            ForEach(c.jobs) { j in
                HStack(spacing: 8) {
                    Text(j.folderName).font(.system(.callout, design: .monospaced))
                    Text(j.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text("\(LengthUnits.format(nm: j.sizeNm, useAngstroms: units.angstroms)) · \(j.particles ?? j.picks) particles · \(j.params.classes) classes · \(j.status)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Load") { c.loadJob(j.number) }.controlSize(.small).disabled(j.finalIteration == nil && j.status != "cancelled")
                    Button("Show") { if let b = c.base { NSWorkspace.shared.activateFileViewerSelecting([Class2DJobs.jobDir(b, j.number)]) } }.controlSize(.small)
                }
            }
        }
    }

    // MARK: helpers

    private func field(_ title: String, _ v: Binding<Double>, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.callout)
            TextField("", value: v, format: .number).textFieldStyle(.roundedBorder).frame(width: width).multilineTextAlignment(.trailing)
        }
    }

    private func loadVersion() {
        let f = relion.config.binFolder
        DispatchQueue.global(qos: .utility).async {
            let v = RelionLocator.version(f)
            DispatchQueue.main.async { version = v }
        }
    }
}

/// Folder of the RELION programs: typed, chosen, or detected. Used in the sheet and in Settings.
struct RelionFolderField: View {
    @ObservedObject var relion: RelionSettings
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Folder with relion_refine and relion_preprocess").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("~/relion/bin", text: $relion.config.binFolder).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .onSubmit(onChange)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false; p.showsHiddenFiles = true
                    if p.runModal() == .OK, let u = p.url { relion.config.binFolder = u.path; onChange() }
                }.controlSize(.small)
                Button("Detect") {
                    if let f = RelionLocator.detect() { relion.config.binFolder = f }
                    onChange()
                }.controlSize(.small)
            }
        }
    }
}
