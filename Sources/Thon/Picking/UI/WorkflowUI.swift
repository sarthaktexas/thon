import SwiftUI
import AppKit

// The Picks tab as a workflow: find automatically, check section by section (and pick by hand there), export.

/// Two handles on one track: the smallest and the largest particle size. Log scale, so 10 → 20 nm takes as much room as 40 → 80 nm.
struct RangeSlider: View {
    @Binding var lo: Double
    @Binding var hi: Double
    var bounds: ClosedRange<Double>
    var snap = 0.5
    @State private var active: Handle?
    private enum Handle { case lo, hi }
    private let r: CGFloat = 9

    private func frac(_ v: Double) -> CGFloat {
        CGFloat(log(min(max(v, bounds.lowerBound), bounds.upperBound) / bounds.lowerBound) / log(bounds.upperBound / bounds.lowerBound))
    }
    private func value(_ f: CGFloat) -> Double {
        let v = bounds.lowerBound * pow(bounds.upperBound / bounds.lowerBound, Double(min(max(f, 0), 1)))
        return min(max((v / snap).rounded() * snap, bounds.lowerBound), bounds.upperBound)
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - 2 * r, 1)
            let x0 = r + frac(lo) * w, x1 = r + frac(hi) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 4).padding(.horizontal, r)
                Capsule().fill(Color.accentColor).frame(width: max(x1 - x0, 0), height: 4).offset(x: x0)
                knob.position(x: x0, y: geo.size.height / 2)
                knob.position(x: x1, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if active == nil {
                        let sx = g.startLocation.x
                        let dlo = abs(sx - x0), dhi = abs(sx - x1)
                        if dlo < dhi - 0.5 { active = .lo }
                        else if dhi < dlo - 0.5 { active = .hi }
                        else if abs(g.translation.width) > 1 { active = g.translation.width < 0 ? .lo : .hi }   // handles on top of each other: the drag direction decides
                        else { return }
                    }
                    let v = value((g.location.x - r) / w)
                    if active == .lo { lo = min(v, hi) } else { hi = max(v, lo) }
                }
                .onEnded { _ in active = nil })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Particle size range")
        .accessibilityValue(String(format: "%.1f to %.1f nm", lo, hi))
    }

    private var knob: some View {
        Circle().fill(Color.white).frame(width: 2 * r, height: 2 * r)
            .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

extension PicksTab {
    // MARK: the card

    var workflowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PICKING").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if pc.averageBlocked {
                Label("This is the average of an unpacked stack. Pick on its frames (listed in the sidebar), or choose Average in the Stack card.", systemImage: "square.stack.3d.up")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(FlowStep.allCases) { step in stepBlock(step) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stepBlock(_ step: FlowStep) -> some View {
        let open = pc.flowStep == step
        return VStack(alignment: .leading, spacing: 8) {
            Button { pc.flowStep = step } label: {
                HStack(spacing: 8) {
                    stepBadge(step)
                    Text(step.title).font(.callout.weight(open ? .semibold : .regular))
                    Spacer(minLength: 4)
                    if let s = statusText(step) { Text(s).font(.caption).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                Group {
                    switch step {
                    case .auto: autoBody
                    case .review: reviewBody
                    case .export: exportBody
                    }
                }
                .padding(.leading, 28)
                .disabled(pc.averageBlocked && step != .export)
            }
        }
        .padding(.vertical, 2)
    }

    private func stepBadge(_ step: FlowStep) -> some View {
        let mark = pc.flow.mark(step)
        let reviewed = step == .review && (key.map { store.record($0).done } ?? false)
        let isDone = mark == .done || reviewed
        return ZStack {
            Circle().fill(isDone ? Color.green : (pc.flowStep == step ? Color.accentColor : Color.secondary.opacity(0.35)))
            if isDone { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            else if mark == .skipped { Image(systemName: "forward.fill").font(.system(size: 8)).foregroundStyle(.white) }
            else { Text("\(step.number)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
        }.frame(width: 20, height: 20)
    }

    private func statusText(_ step: FlowStep) -> String? {
        switch pc.flow.mark(step) {
        case .done?: return "done"
        case .skipped?: return "skipped"
        case nil: break
        }
        if step == .review, let k = key {
            if store.record(k).done { return "done" }
            if pc.crops.active, pc.crops.tilesTotal > 0 { return "\(pc.crops.reviewedCount) of \(pc.crops.tilesTotal)" }
        }
        return nil
    }

    // MARK: 1. automatic

    private var autoBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            sizeRangeControl
            boxControl
            Toggle("Particles are brighter than background", isOn: $pc.autoParams.bright)
            HStack {
                Button { pc.runFind() } label: { Label(pc.autoBusy ? "Working…" : "Find particles", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).disabled(pc.autoBusy || key == nil)
                if pc.autoBusy { ProgressView().controlSize(.small) }
            }
            if let m = pc.autoMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            candidateControls
            advancedFind
            stepButtons(.auto, doneTitle: "Continue", doneDisabled: (key.map { store.candidates($0).isEmpty && store.accepted($0).isEmpty } ?? true))
            Text("Skip this to pick everything by hand: the check then visits every section, not only those with candidates.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Smallest and largest particle: two handles on one slider. Equal ends = every particle about the same size.
    private var sizeRangeControl: some View {
        let p = store.project.params
        let a = units.angstroms
        let (lo, hi) = p.sizeRangeNm
        let ladder = p.sweepDiametersNm
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Particle size").font(.callout)
                Spacer()
                Text(p.hasSizeRange ? "\(LengthUnits.format(nm: lo, useAngstroms: a)) – \(LengthUnits.format(nm: hi, useAngstroms: a))"
                                    : LengthUnits.format(nm: lo, useAngstroms: a))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            RangeSlider(lo: Binding(get: { store.project.params.sizeRangeNm.min }, set: { pc.setSizeRange(min: $0, max: store.project.params.sizeRangeNm.max) }),
                        hi: Binding(get: { store.project.params.sizeRangeNm.max }, set: { pc.setSizeRange(min: store.project.params.sizeRangeNm.min, max: $0) }),
                        bounds: SizeRange.bounds)
            Text(sizeHint(p, ladder: ladder, angstroms: a)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sizeHint(_ p: ProjectParams, ladder: [Double], angstroms a: Bool) -> String {
        if pc.sweepOn { return "Using the exact sizes typed under More settings." }
        if !p.hasSizeRange { return "All particles about this size. Drag the two handles apart if they differ." }
        if ladder.isEmpty { return "The two sizes are close, so one size in between is searched." }
        return "Searches \(ladder.count) sizes: " + ladder.map { LengthUnits.format(nm: $0, useAngstroms: a).replacingOccurrences(of: " nm", with: "").replacingOccurrences(of: " Å", with: "") }.joined(separator: ", ")
            + " " + LengthUnits.name(a) + ". Each candidate keeps the size it matched."
    }

    /// Box size: set from the diameter, or typed in. The menu is where it can be changed.
    private var boxControl: some View {
        let p = store.project.params
        let a = units.angstroms
        let custom = p.isBoxCustom
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Box size").font(.callout)
                Spacer()
                Menu {
                    Button((custom ? "" : "✓  ") + "Automatic (\(String(format: "%.2g", p.boxRatio)) × the diameter)") { pc.setBox(custom: nil) }
                    Button((custom ? "✓  " : "") + "Set it myself…") { pc.setBox(custom: p.boxNm) }
                } label: {
                    Text(custom ? "Custom, \(LengthUnits.format(nm: p.boxNm, useAngstroms: a))"
                                : "Automatic, \(LengthUnits.format(nm: p.boxNm, useAngstroms: a))")
                        .font(.callout)
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if custom {
                lengthSlider("Box", Binding(get: { store.project.params.boxNm }, set: { pc.setBox(custom: $0) }), 5...150, nmFormat: "%.1f")
            }
            let pa = pc.effectiveAngpix
            Text(String(format: "%.0f px marker, %.0f px box at %.4g Å/px", p.diameterNm * 10 / pa, p.boxNm * 10 / pa, pa)
                 + (pc.pixelSizeA == nil ? " (uncalibrated: 1 Å/px assumed)" : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Cut-off on the candidates' score, and accepting what is shown.
    @ViewBuilder private var candidateControls: some View {
        let cands = key.map { store.candidates($0) } ?? []
        if !cands.isEmpty {
            let shown = cands.filter { ($0.score ?? .infinity) >= pc.scoreCutoff }.count
            Divider()
            slider("Show candidates with score ≥", Binding(get: { Double(pc.scoreCutoff) }, set: { pc.scoreCutoff = Float($0) }), 0...Double(pc.maxScore), "%.1f")
            Text("\(shown) of \(cands.count) candidates shown").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Dismiss hidden") { pc.dismissBelowCutoff() }
                Button("Accept all shown (A)") { pc.acceptAllCandidates() }
                Spacer()
                Toggle("Scores", isOn: $pc.showScores).toggleStyle(.checkbox)
            }.controlSize(.small)
            Text("You can also leave this to the section-by-section check: circles you leave alone there count as confirmed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Everything that used to sit in the Find particles card and is rarely needed.
    private var advancedFind: some View {
        DisclosureGroup("More settings") {
            VStack(alignment: .leading, spacing: 8) {
                let ap = $pc.autoParams
                let engine = pc.effectiveEngine
                if engines.enabled {
                    Picker("Engine", selection: $pc.engine) { ForEach(PickEngine.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                        .onChange(of: pc.engine) { _, _ in pc.autoLive = false; pc.autoMessage = nil }
                }
                if engine == .builtin {
                    Picker("Method", selection: ap.method) { ForEach(PickMethod.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    slider("Score threshold (robust z)", ap.zThreshold, 2...12, "%.1f")
                    Toggle("Live: re-run when a setting changes", isOn: $pc.autoLive).toggleStyle(.checkbox)
                    slider("Min separation × diameter", Binding(get: { pc.autoParams.minSepNm == 0 ? 0.9 : pc.autoParams.minSepNm / max(store.project.params.diameterNm, 1) },
                                                                set: { pc.autoParams.minSepNm = $0 * store.project.params.diameterNm }), 0.3...2, "%.2f")
                    lengthSlider("Flatten background σ", ap.flattenNm, 0...400, nmFormat: "%.0f", note: ", 0 = off")
                    lengthSlider("Smoothing σ", ap.smoothNm, 0...20, nmFormat: "%.1f", note: ", 0 = auto")
                    HStack {
                        Text("Max picks").font(.callout)
                        Stepper(value: ap.maxPicks, in: 10...5000, step: 50) { Text("\(pc.autoParams.maxPicks)").monospacedDigit() }
                    }
                    exactSizes
                } else {
                    EngineSetupView(engine: engine)
                }
                Text("External picker command").font(.callout.weight(.medium))
                TextField("script.py {mic} {angpix}", text: $pc.externalCommand).textFieldStyle(.roundedBorder)
                Text("Must print JSON: [{\"x\":..,\"y\":..,\"score\":..}] (pixel coordinates, origin top-left). Results appear as candidates.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Run command") { pc.runExternalPicker() }.disabled(pc.autoBusy || pc.externalCommand.isEmpty).controlSize(.small)
            }.padding(.top, 4)
        }
    }

    /// The old typed list of sizes; when on it replaces the range slider.
    private var exactSizes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use exact sizes instead of the range", isOn: $pc.sweepOn).toggleStyle(.checkbox).onChange(of: pc.sweepOn) { _, _ in pc.applySweepText() }
            TextField("Diameters (nm): 12, 16, 20  or  10:30:5", text: $pc.sweepDiameterText)
                .textFieldStyle(.roundedBorder).disabled(!pc.sweepOn).onSubmit { pc.applySweepText() }
            TextField("Boxes (nm): blank = follow diameter", text: $pc.sweepBoxText)
                .textFieldStyle(.roundedBorder).disabled(!pc.sweepOn).onSubmit { pc.applySweepText() }
            if let e = pc.sweepError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    // MARK: 2. check

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !pc.crops.active {
                Text("Go through the micrograph one section at a time: confirm, move, resize or delete the circles, and click empty ground to add one the picker missed. Circles you leave alone count as confirmed.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { pc.crops.active = true } label: { Label("Start checking", systemImage: "viewfinder.circle") }
                    .buttonStyle(.borderedProminent)
            } else {
                CropPanel(model: model, pc: pc, cs: pc.crops, store: store, embedded: true)
            }
            HStack {
                if let k = key {
                    Toggle("Micrograph done", isOn: Binding(get: { store.record(k).done }, set: { store.setDone(k, $0) })).toggleStyle(.checkbox)
                }
                Spacer()
                Button(model.nextTitle) {
                    if let k = key { store.setDone(k, true) }
                    model.step(1)
                }.disabled(!model.canStep(1)).controlSize(.small)
            }
        }
    }

    // MARK: 3. export

    private var exportBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(ExportFormat.allCases) { f in
                    Toggle(f.rawValue, isOn: Binding(get: { pc.exportFormats.contains(f) },
                                                     set: { if $0 { pc.exportFormats.insert(f) } else { pc.exportFormats.remove(f) } }))
                        .toggleStyle(.checkbox)
                }
            }
            if store.project.isSessionProject {
                Picker("Sessions", selection: $pc.exportSessionID) {
                    Text("All sessions (one dataset folder each)").tag(String?.none)
                    ForEach(store.project.sessions) { Text($0.name).tag(Optional($0.id)) }
                }.controlSize(.small)
            }
            Toggle("Only micrographs marked done", isOn: $pc.exportOnlyDone).toggleStyle(.checkbox)
            if store.project.params.maybeFlag { Toggle("Leave out picks flagged maybe", isOn: $pc.exportExcludeMaybe).toggleStyle(.checkbox) }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Export to").font(.callout)
                if let d = pc.exportDestination {
                    Text(d.path).font(.system(.caption, design: .monospaced)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    Text(pc.exportFolder == nil ? "Next to the project (the default)." : "A folder you chose.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Open a folder or project first.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose folder…") { PickPanels.chooseExportFolder(model: model) }
                    if pc.exportFolder != nil { Button("Use default") { pc.exportFolder = nil } }
                }.controlSize(.small)
            }
            let totals = store.totalCounts()
            let n = store.scheme.labels.filter { $0.exported }.reduce(0) { $0 + totals[$1.id, default: 0] }
            HStack {
                Button { if let d = pc.exportDestination { pc.exportPicks(to: d) } } label: { Label("Export \(n) picks", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(pc.exportDestination == nil || pc.exportFormats.isEmpty)
                if let d = pc.exportDestination, FileManager.default.fileExists(atPath: d.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d]) }.controlSize(.small)
                }
            }
            if let m = pc.ioMessage { Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Layout: <dataset>/<label>/<micrograph>.star, coords_list_<label>.star, all_picks.csv. Only accepted picks of exported labels are written." + (store.project.isSessionProject ? " In a .thon project <dataset> is the session name." : ""))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: shared

    /// Skip (left) and Continue (right) of the automatic step.
    private func stepButtons(_ step: FlowStep, doneTitle: String, doneDisabled: Bool) -> some View {
        HStack {
            Button("Skip") { pc.skip(step) }.disabled(!pc.canSkip(step) || key == nil)
                .help("Leave this step out for this micrograph and pick by hand in the check")
            Spacer()
            Button(doneTitle) { pc.finish(step) }.buttonStyle(.borderedProminent).disabled(doneDisabled || key == nil)
        }.controlSize(.small)
    }
}

extension PickPanels {
    /// Chooses the folder the Export step writes to (kept for this project while the app is open).
    static func chooseExportFolder(model: AppModel) {
        let pc = model.picks
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Export here"
        p.message = "Choose the folder for the exported picks (files from a previous export in it are replaced; other files are left alone)."
        if let d = pc.exportDestination {
            let start = FileManager.default.fileExists(atPath: d.path) ? d : d.deletingLastPathComponent()
            p.directoryURL = start
        }
        if p.runModal() == .OK, let u = p.url { pc.exportFolder = u }
    }
}
