import SwiftUI

struct PicksTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var store: PickStore

    private var key: String? { pc.currentKey }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                modeCard
                autoCard
                labelsCard
                markerCard
                micrographCard
                LoupeCard(model: model, pc: pc, cursor: model.cursor)
                classesCard
                ioCard
                projectCard
                helpCard
            }.padding(10)
        }
        .sheet(isPresented: $pc.showLabelEditor) { LabelEditor(pc: pc) }
    }

    // MARK: cards

    private var modeCard: some View {
        Card(title: "Picker") {
            HStack {
                Toggle("Pick mode (P)", isOn: $pc.enabled)
                Spacer()
                Button { model.showSwipe = true } label: { Label("Swipe mode (S)", systemImage: "rectangle.stack") }.controlSize(.small)
            }
            HStack {
                Toggle("Markers (V)", isOn: $pc.showMarkers)
                Toggle("Boxes (B)", isOn: $pc.showBoxes)
            }
            HStack {
                Button { pc.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(key.map { !store.canUndo($0) } ?? true)
                Button { pc.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(key.map { !store.canRedo($0) } ?? true)
                Spacer()
                if let k = key, let n = store.undoName(k) { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var autoCard: some View {
        Card(title: "Auto-pick") {
            let ap = $pc.autoParams
            Picker("Method", selection: ap.method) { ForEach(PickMethod.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Toggle("Particles are brighter than background", isOn: ap.bright)
            slider("Score threshold (robust z)", ap.zThreshold, 2...12, "%.1f")
            slider("Min separation × diameter", Binding(get: { pc.autoParams.minSepNm == 0 ? 0.9 : pc.autoParams.minSepNm / max(store.project.params.diameterNm, 1) },
                                                        set: { pc.autoParams.minSepNm = $0 * store.project.params.diameterNm }), 0.3...2, "%.2f")
            slider("Flatten background σ (nm, 0 = off)", ap.flattenNm, 0...400, "%.0f")
            slider("Smoothing σ (nm, 0 = auto)", ap.smoothNm, 0...20, "%.1f")
            HStack {
                Text("Max picks").font(.callout)
                Stepper(value: ap.maxPicks, in: 10...5000, step: 50) { Text("\(pc.autoParams.maxPicks)").monospacedDigit() }
            }
            Text("Uses the particle diameter under Size.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { pc.runAutoPick() } label: { Label(pc.autoBusy ? "Working…" : "Find particles", systemImage: "sparkles") }
                    .disabled(pc.autoBusy || key == nil)
                Toggle("Live", isOn: $pc.autoLive).toggleStyle(.checkbox).help("Re-run automatically when a setting changes")
                if pc.autoBusy { ProgressView().controlSize(.small) }
            }
            if let m = pc.autoMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            Divider()
            slider("Show candidates with score ≥", Binding(get: { Double(pc.scoreCutoff) }, set: { pc.scoreCutoff = Float($0) }), 0...Double(pc.maxScore), "%.1f")
            Toggle("Show scores", isOn: $pc.showScores)
            HStack {
                Button("Accept all shown (A)") { pc.acceptAllCandidates() }
                Button("Dismiss hidden") { pc.dismissBelowCutoff() }
            }.controlSize(.small)
            HStack {
                Button("Remove overlaps") { pc.removeOverlapping() }
                Button("Remove edge picks") { pc.removeEdgePicks() }
                Button("Clear candidates") { pc.dismissAllCandidates() }
            }.controlSize(.small)
            DisclosureGroup("External picker command") {
                TextField("script.py {mic} {angpix}", text: $pc.externalCommand).textFieldStyle(.roundedBorder)
                Text("Must print JSON: [{\"x\":..,\"y\":..,\"score\":..}] (pixel coordinates, origin top-left). Results appear as candidates.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Run command") { pc.runExternalPicker() }.disabled(pc.autoBusy || pc.externalCommand.isEmpty).controlSize(.small)
            }
        }
    }

    private var labelsCard: some View {
        Card(title: "Labels") {
            let counts = key.map { store.counts($0) } ?? [:]
            let totals = store.totalCounts()
            ForEach(store.scheme.labels) { l in
                let active = pc.activeLabel == l.id
                HStack(spacing: 8) {
                    Circle().fill(swiftUIColor(l.color)).frame(width: 12, height: 12)
                    Text(l.name).lineLimit(1)
                    if !l.exported { Text("not exported").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(counts[l.id, default: 0])").monospacedDigit()
                    Text("/ \(totals[l.id, default: 0])").monospacedDigit().foregroundStyle(.secondary).font(.caption)
                    Text(l.key).font(.system(.caption, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    Button {
                        if pc.hiddenLabels.contains(l.id) { pc.hiddenLabels.remove(l.id) } else { pc.hiddenLabels.insert(l.id) }
                        pc.pruneSelection()
                    } label: { Image(systemName: pc.hiddenLabels.contains(l.id) ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.28) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { pc.setActiveLabel(l.id) }
            }
            if store.project.params.maybeFlag {
                HStack {
                    Text("? flagged maybe").font(.callout)
                    Spacer()
                    Text("\(key.map { store.maybeCount($0) } ?? 0)").monospacedDigit()
                    Text("/ \(store.project.mics.values.reduce(0) { $0 + $1.picks.filter { $0.status == .accepted && $0.isMaybe }.count })")
                        .monospacedDigit().foregroundStyle(.secondary).font(.caption)
                    Text("?").font(.system(.caption, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
            HStack {
                Text("this micrograph / all").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit labels…") { pc.openLabelEditor() }.controlSize(.small)
            }
            if !pc.selection.isEmpty {
                Text("\(pc.selection.count) selected — pressing a label key or clicking a label relabels them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var markerCard: some View {
        Card(title: "Size") {
            let params = store.project.params
            let diam = Binding(get: { store.project.params.diameterNm }, set: { v in var p = store.project.params; p.diameterNm = v; store.setParams(p) })
            let box = Binding(get: { store.project.params.boxNm }, set: { v in var p = store.project.params; p.boxNm = v; store.setParams(p) })
            slider("Particle diameter (nm)", diam, 3...80, "%.1f")
            slider("Extraction box (nm)", box, 5...150, "%.1f")
            let pa = pc.effectiveAngpix
            Text(String(format: "= %.0f px marker, %.0f px box at %.4g Å/px", params.diameterNm * 10 / pa, params.boxNm * 10 / pa, pa)
                 + (pc.pixelSizeA == nil ? " (uncalibrated: 1 Å/px assumed)" : ""))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Resize all to default") { if let k = key { store.setDiameter(nil, nm: nil, in: k) } }.controlSize(.small)
                Spacer()
                Text(", / . : resize selection (or default)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var micrographCard: some View {
        Card(title: "This micrograph") {
            if let k = key {
                let done = Binding(get: { store.record(k).done }, set: { store.setDone(k, $0) })
                let note = Binding(get: { store.record(k).note }, set: { store.setNote(k, $0) })
                let c = store.accepted(k).count, cand = store.candidates(k).count
                Text("\(c) picks" + (cand > 0 ? " · \(cand) candidates" : "")).font(.callout)
                Toggle("Done", isOn: done)
                TextField("Note", text: note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            } else { Text("No micrograph").foregroundStyle(.secondary) }
        }
    }

    private var classesCard: some View {
        Card(title: "RELION classes") {
            HStack {
                Button("Load classification…") { PickPanels.chooseClasses(model: model) }
                Button("Gallery… (G)") { model.showGallery = true }
            }.controlSize(.small)
            if let m = pc.classes {
                Text("\(m.source): \(m.matchedRows) of \(m.rows) particles matched · \(m.unclassifiedPicks) picks have no class")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Color picks by class", isOn: $pc.showClassColors)
                    Spacer()
                    Stepper("tol \(Int(pc.classTolerance)) px", value: $pc.classTolerance, in: 1...30).onChange(of: pc.classTolerance) { _, _ in pc.reloadClasses() }
                        .font(.caption)
                }
                ForEach(m.classes, id: \.self) { n in
                    HStack(spacing: 8) {
                        if let a = m.averages[n], let img = grayCGImage(a.bytes, width: a.size, height: a.size) {
                            Image(decorative: img, scale: 1).resizable().interpolation(.medium).frame(width: 44, height: 44)
                                .overlay(Rectangle().strokeBorder(swiftUIColor(ClassMapping.color(n)), lineWidth: 2))
                        } else { Rectangle().fill(swiftUIColor(ClassMapping.color(n))).frame(width: 14, height: 14) }
                        Text("class \(n)").font(.callout)
                        Text("\(m.counts[n, default: 0])").monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button { if pc.hiddenClasses.contains(n) { pc.hiddenClasses.remove(n) } else { pc.hiddenClasses.insert(n) }; pc.pruneSelection() } label: {
                            Image(systemName: pc.hiddenClasses.contains(n) ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                        Button("Select") { pc.selectClass(n) }.controlSize(.mini)
                        Menu("→") {
                            ForEach(store.scheme.labels) { l in Button("Relabel all as \(l.name)") { pc.relabelClass(n, to: l.id) } }
                            Divider()
                            Button("Remove all picks of this class", role: .destructive) { pc.removeClass(n) }
                        }.menuStyle(.borderlessButton).frame(width: 30)
                    }
                }
                Button("Clear classification") { pc.clearClasses() }.controlSize(.small)
            } else {
                Text("Load a RELION run_itNNN_data.star to color picks by the class they landed in; class averages are shown if run_itNNN_classes.mrcs is next to it. Junk classes can be selected, relabeled or removed on all micrographs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var ioCard: some View {
        Card(title: "Import / export") {
            ForEach(ExportFormat.allCases) { f in
                Toggle(f.rawValue, isOn: Binding(get: { pc.exportFormats.contains(f) },
                                                 set: { if $0 { pc.exportFormats.insert(f) } else { pc.exportFormats.remove(f) } }))
            }
            Toggle("Only micrographs marked Done", isOn: $pc.exportOnlyDone)
            if store.project.params.maybeFlag { Toggle("Leave out picks flagged maybe", isOn: $pc.exportExcludeMaybe) }
            HStack {
                Button("Export…") { PickPanels.chooseExport(model: model) }
                Button("Import…") { PickPanels.chooseImport(model: model, asCandidates: false) }
                Button("Import as candidates…") { PickPanels.chooseImport(model: model, asCandidates: true) }
            }.controlSize(.small)
            if let m = pc.ioMessage { Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Export layout = the web picker's picks_export/: <dataset>/<label>/<micrograph>.star, coords_list_<label>.star, all_picks.csv. Only accepted picks of exported labels are written.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var projectCard: some View {
        Card(title: "Project") {
            Text(store.projectURL?.path ?? "–").font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle)
            HStack {
                Text(store.dirty ? "unsaved changes" : (store.lastSaved.map { "saved " + $0.formatted(date: .omitted, time: .standard) } ?? "no changes yet"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save now") { store.save(forceBackup: true) }.controlSize(.small)
            }
            if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private var helpCard: some View {
        Card(title: "Mouse and keys") {
            Text("Click: add / select · drag a pick: move · drag empty: pan · shift-drag: box select · right-click: delete · ⌫: delete selection · 1–6: label · ⌘Z / ⇧⌘Z: undo / redo · Esc: deselect")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.callout); Spacer(); Text(String(format: f, v.wrappedValue)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) }
            Slider(value: v, in: r)
        }
    }
}

struct PickToggle: View {
    @ObservedObject var pc: PickController
    var body: some View {
        Toggle(isOn: $pc.enabled) { Label("Pick", systemImage: "scope") }
            .toggleStyle(.button).help("Particle picking mode (P)")
    }
}

// MARK: loupe

struct LoupeCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var cursor: CursorState
    @ObservedObject var vs: ViewState

    init(model: AppModel, pc: PickController, cursor: CursorState) {
        self.model = model; self.pc = pc; self.cursor = cursor; self.vs = model.view
    }

    var body: some View {
        Card(title: "Loupe") {
            if let doc = model.doc, let x = cursor.x, let y = cursor.y {
                let half = 40
                let bytes = renderCrop(pixels: doc.pixels, width: doc.entry.width, height: doc.entry.height, cx: Double(x), cy: Double(y), half: half,
                                       lo: vs.lo, hi: vs.hi, gamma: vs.gamma, invert: vs.invert)
                if let img = grayCGImage(bytes, width: 2 * half, height: 2 * half) {
                    let side: CGFloat = 240
                    ZStack {
                        Image(decorative: img, scale: 1).interpolation(.none).resizable().frame(width: side, height: side)
                        let d = pc.diameterPx(Pick(x: 0, y: 0, label: pc.activeLabel)) * Double(side) / Double(2 * half)
                        Circle().stroke(swiftUIColor(pc.store.scheme.label(pc.activeLabel)?.color ?? "#ffffff"), lineWidth: 1.2)
                            .frame(width: d, height: d)
                        Path { p in
                            p.move(to: CGPoint(x: side / 2 - 6, y: side / 2)); p.addLine(to: CGPoint(x: side / 2 + 6, y: side / 2))
                            p.move(to: CGPoint(x: side / 2, y: side / 2 - 6)); p.addLine(to: CGPoint(x: side / 2, y: side / 2 + 6))
                        }.stroke(.white.opacity(0.8), lineWidth: 1).frame(width: side, height: side)
                    }
                    .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity)
                    Text("80 × 80 px around the cursor; circle = active marker size (raw data, current contrast)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Move the cursor over the image.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: label editor

struct LabelEditor: View {
    @ObservedObject var pc: PickController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit labels").font(.headline)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(pc.draftScheme.labels.indices, id: \.self) { i in
                        let l = pc.draftScheme.labels[i]
                        HStack(spacing: 8) {
                            ColorPicker("", selection: Binding(get: { swiftUIColor(l.color) }, set: { pc.draftScheme.labels[i].color = hexString($0) }), supportsOpacity: false)
                                .labelsHidden()
                            TextField("Name", text: Binding(get: { l.name }, set: { pc.draftScheme.labels[i].name = $0 })).frame(minWidth: 150)
                            TextField("Key", text: Binding(get: { l.key }, set: { pc.draftScheme.labels[i].key = String($0.prefix(1)) })).frame(width: 36)
                            Picker("", selection: Binding(get: { l.shape }, set: { pc.draftScheme.labels[i].shape = $0 })) {
                                ForEach(MarkerShape.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 90)
                            Toggle("export", isOn: Binding(get: { l.exported }, set: { pc.draftScheme.labels[i].exported = $0 }))
                            Text(l.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                            Button { pc.draftScheme.labels.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }.frame(minHeight: 200)
            HStack {
                Button("Add label") { pc.addDraftLabel() }
                Menu("Presets") {
                    ForEach(Array(LabelScheme.presets.enumerated()), id: \.offset) { _, p in
                        Button(p.name) { pc.loadDraftPreset(p.scheme) }
                    }
                }.fixedSize()
                Button("Load labels.json…") { pc.loadDraftSchemeFromFile() }
                Button("Save labels.json") { pc.saveDraftSchemeToFile() }
            }
            Toggle("Enable the per-pick \"maybe\" flag (key ?), independent of the label", isOn: $pc.draftMaybeFlag)
            let missing = pc.draftMissingLabels
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These labels are dropped but still have picks. Choose where those picks go:").font(.caption).foregroundStyle(.orange)
                    ForEach(missing, id: \.id) { m in
                        HStack {
                            Text("\(m.count) × \(m.id)").font(.system(.caption, design: .monospaced)).frame(width: 150, alignment: .leading)
                            Image(systemName: "arrow.right")
                            Picker("", selection: Binding(get: { pc.draftRemap[m.id] ?? "" }, set: { pc.draftRemap[m.id] = $0 })) {
                                Text("choose…").tag("")
                                ForEach(pc.draftScheme.labels) { Text($0.name).tag($0.id) }
                            }.labelsHidden().frame(width: 220)
                        }
                    }
                }
            }
            Text("Label ids are fixed once created (they appear in exports); rename the display name freely. Hotkeys A, B, F, G, I, P, S, V and , . = + - ? / are reserved.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = pc.schemeError { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { pc.showLabelEditor = false }.keyboardShortcut(.cancelAction)
                Button("Apply") { pc.applyDraftScheme() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 760, height: 500)
    }
}
