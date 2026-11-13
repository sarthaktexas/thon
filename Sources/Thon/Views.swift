import SwiftUI
import Charts

// MARK: - App shell

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    /// Welcome screen until something is open (a project with no micrographs still gets the normal window).
    private var showWelcome: Bool { model.items.isEmpty && !model.isProject }

    var body: some View {
        Group {
            if showWelcome { WelcomeView(recents: model.recents) } else { mainWindow }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; group.leave() }
            }
            group.notify(queue: .main) { model.open(urls: urls) }
            return true
        }
        .sheet(isPresented: $model.showGallery) { GalleryView(model: model) }
        .sheet(isPresented: $model.showSwipe) { SwipeView(model: model) }
        .sheet(isPresented: $model.showSessions) { SessionsView(model: model, store: model.picks.store) }
        .alert("Thon", isPresented: Binding(get: { model.loadError != nil }, set: { if !$0 { model.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.loadError ?? "") }
    }

    private var mainWindow: some View {
        NavigationSplitView {
            SidebarView(tagChanges: model.picks.store.tagChanges)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
            ImagePane()
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 320, ideal: 360, max: 520)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.presentOpenPanel(folders: false) } label: { Label("Open files", systemImage: "doc") }
                Button { model.presentOpenPanel(folders: true) } label: { Label("Open folder", systemImage: "folder") }
                Button { model.presentOpenProjectPanel() } label: { Label("Open project", systemImage: "square.stack.3d.up") }.help("Open a .thon project (⌥⌘O)")
            }
            ToolbarItemGroup(placement: .principal) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canStep(-1))
                Text(model.positionTitle)
                    .monospacedDigit().frame(minWidth: 60)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canStep(1))
            }
            ToolbarItemGroup {
                PickToggle(pc: model.picks)
                MeasureToggle(measure: model.measure)
                Button { model.view.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                Button { model.view.setZoom(1) } label: { Label("100%", systemImage: "1.magnifyingglass") }
                InvertToggle(vs: model.view)
                Button { model.showThonRings() } label: { Label("Thon rings (FFT)", systemImage: "circle.dashed") }.help("Power spectrum / Thon rings (T)")
                Menu {
                    Button("PNG (current contrast)…") { model.exportPNG() }
                    Button("MRC – raw float32…") { model.exportMRC(processed: false) }
                    Button("MRC – filtered float32…") { model.exportMRC(processed: true) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
    }
}

struct InvertToggle: View {
    @ObservedObject var vs: ViewState
    var body: some View {
        Toggle(isOn: $vs.invert) { Label("Invert", systemImage: "circle.lefthalf.filled") }
    }
}

// MARK: - Sidebar

/// One file of the sidebar, followed by its frames when the stack is expanded (or by its tagged frames under a tag filter).
/// A stack row opens its average; a frame row opens that frame on its own. Both take colour tags.
@MainActor @ViewBuilder
func sidebarEntry(model: AppModel, store: PickStore, item: ExposureItem, tagged: Set<String>?, inProject: Bool) -> some View {
    let key = store.key(for: item.url)
    let depth = model.depth(of: item.url)
    let unpacked = model.isUnpacked(item.url)
    ExposureRow(item: item, thumb: model.thumbs[item.url], meta: model.metas[item.url], tags: store.tags(key), depth: depth,
                expanded: model.expandedStacks.contains(item.url) || tagged != nil || unpacked, unpacked: unpacked,
                toggle: unpacked ? nil : { model.toggleStack(item.url) })
        .tag(SidebarID.file(item.url))
        .contextMenu {
            Menu("Tags") { TagMenuItems(store: store, key: key) }
            if inProject {
                Menu("Move to Session") {
                    ForEach(store.project.sessions.filter { $0.id != item.session }) { t in
                        Button(t.name) { model.moveMicrographs([item.url], to: t.id) }
                    }
                }
                if store.originSessionID(key) != item.session {
                    Button("Back to Its Own Session") { model.moveMicrographs([item.url], to: nil) }
                }
            }
        }
    ForEach(model.listedFrames(of: item.url, tagged: tagged), id: \.self) { n in
        let fk = FrameKey.make(key, frame: n)
        FrameRow(n: n, tags: store.tags(fk))
            .tag(SidebarID.frame(item.url, n))
            .contextMenu { Menu("Tags") { TagMenuItems(store: store, key: fk) } }
    }
}

/// One frame of a stack in the sidebar.
struct FrameRow: View {
    let n: Int
    let tags: [FinderTag]
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
            Text("Frame \(n + 1)").font(.system(.callout, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 4)
            if !tags.isEmpty { TagDots(tags: tags) }
        }
        .padding(.leading, 64).padding(.vertical, 1)
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tagChanges: TagChanges      // redraw the dots when a tag changes

    private var selectionBinding: Binding<SidebarID?> { Binding(get: { model.sidebarSelection }, set: { model.select($0) }) }

    var body: some View {
        let store = model.picks.store
        let tagged = model.tagFilter.map { store.keys(tagged: $0) }
        Group {
            if model.isProject { ProjectList(store: store, tagChanges: tagChanges) }
            else {
                List(selection: selectionBinding) {
                    ForEach(model.visibleItems(model.sortedItems)) { item in
                        sidebarEntry(model: model, store: store, item: item, tagged: tagged, inProject: false)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if model.isProject {
                    HStack {
                        Text(model.picks.store.projectTitle).font(.headline).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Button("Sessions…") { model.showSessions = true }.controlSize(.small)
                    }
                    Text("\(model.picks.store.project.sessions.count) sessions · \(model.items.count) exposures").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                } else {
                Text("\(model.items.count) exposures").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                HStack {
                    Picker("Sort by", selection: $model.sortKey) {
                        ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button((model.tagFilter == nil ? "✓  " : "") + "All") { model.tagFilter = nil }
                        Divider()
                        ForEach(FinderTag.allCases) { t in
                            Button { model.tagFilter = t } label: {
                                Label { Text(t.name + (model.tagFilter == t ? "  ✓" : "")) } icon: { Image(nsImage: t.menuImage) }
                            }
                        }
                    } label: {
                        if let f = model.tagFilter { HStack(spacing: 4) { Circle().fill(f.color).frame(width: 9, height: 9); Text(f.name) } }
                        else { Image(systemName: "tag") }
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Show only micrographs and frames with a colour tag")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
        .overlay {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No micrographs found. Use Sessions… to add or locate session folders.").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Sessions…") { model.showSessions = true }
                }.padding()
            }
        }
    }
}

/// Sidebar of a .thon project: one collapsible section per session, in project order.
struct ProjectList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: PickStore
    @ObservedObject var tagChanges: TagChanges

    var body: some View {
        let tagged = model.tagFilter.map { store.keys(tagged: $0) }
        List(selection: Binding(get: { model.sidebarSelection }, set: { model.select($0) })) {
            ForEach(store.project.sessions) { s in
                Section(isExpanded: Binding(get: { !model.collapsedSessions.contains(s.id) },
                                            set: { if $0 { model.collapsedSessions.remove(s.id) } else { model.collapsedSessions.insert(s.id) } })) {
                    ForEach(model.visibleItems(model.sessionItems(s.id))) { item in
                        sidebarEntry(model: model, store: store, item: item, tagged: tagged, inProject: true)
                    }
                } header: {
                    SessionHeader(model: model, store: store, session: s)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SessionHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: PickStore
    let session: PickSession

    var body: some View {
        let st = store.sessionStats(session.id)
        let n = model.sessionItems(session.id).count
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if !store.sessionFolderExists(session.id) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help("Folder not found – use Sessions… to locate it")
                }
                Text(session.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            }
            let meta = [session.sample, session.date].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text("\(n) mics · \(st.picks) picks" + (st.candidates > 0 ? " · \(st.candidates) candidates" : "") + (st.done > 0 ? " · \(st.done) done" : ""))
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .textCase(nil)
        .contextMenu {
            Button("Edit Session…") { model.showSessions = true }
            Button("Locate Folder…") { model.presentRelocateSessionPanel(session.id) }
            if let f = store.sessionFolder(session.id) { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
        }
    }
}

struct ExposureRow: View {
    let item: ExposureItem
    let thumb: NSImage?
    let meta: ExposureMeta?
    var tags: [FinderTag] = []
    var depth = 1                       // frames in the file; a stack gets a chevron that lists them
    var expanded = false
    var unpacked = false                // an unpacked stack has no average to open: its frames are always listed
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 54, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if depth > 1, unpacked {
                        Image(systemName: "square.stack.3d.down.right").font(.caption).foregroundStyle(.secondary).frame(width: 12)
                            .help("Unpacked: pick on its frames; the average is hidden")
                    } else if depth > 1 {
                        Button { toggle?() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width: 12) }
                            .buttonStyle(.plain).help(expanded ? "Hide the frames" : "List the frames; pick each one separately")
                    }
                    Text(item.url.deletingPathExtension().lastPathComponent)
                        .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if !tags.isEmpty { TagDots(tags: tags) }
                }
                if let m = meta {
                    Text(rowLine(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let d = m.acquired {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                    }
                } else { Text("reading…").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 2)
    }

    func rowLine(_ m: ExposureMeta) -> String {
        var parts: [String] = []
        if let mag = m.indicatedMag { parts.append(mag >= 1000 ? String(format: "%gk×", mag / 1000) : String(format: "%g×", mag)) }
        if let p = m.pixelSizeA { parts.append(String(format: "%.3g Å/px", p)) }
        parts.append("\(m.width)×\(m.height)")
        if m.depth > 1 { parts.append("\(m.depth) frames" + (unpacked ? ", unpacked" : "")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Image pane

struct ImagePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            MicrographView(model: model)
            PickOverlay(pc: model.picks, vs: model.view, store: model.picks.store, cs: model.picks.crops)
                .opacity(model.overlaysHidden ? 0 : 1)
            CropOverlay(cs: model.picks.crops, pc: model.picks, vs: model.view, store: model.picks.store)
                .opacity(model.overlaysHidden ? 0 : 1)
            CropPenPreview(cs: model.picks.crops, pc: model.picks, vs: model.view, store: model.picks.store, cursor: model.cursor)
                .opacity(model.overlaysHidden ? 0 : 1)
            MeasureOverlay(measure: model.measure, vs: model.view, pixelSizeA: model.doc?.entry.pixelSizeA)
                .opacity(model.overlaysHidden ? 0 : 1)
            if model.doc == nil && !model.isLoading {
                Text("No image loaded").foregroundStyle(.secondary)
            }
            if model.isLoading { ProgressView().controlSize(.large) }
        }
        .overlay(alignment: .top) { StackHintBanner(model: model).padding(.top, 14) }
        .animation(.default, value: model.stackHint)
        .overlay(alignment: .bottom) { CropHUD(model: model, cs: model.picks.crops, pc: model.picks, store: model.picks.store).padding(.bottom, 14) }
        .overlay(alignment: .topLeading) { HeaderOverlay(model: model, tagChanges: model.picks.store.tagChanges).padding(10).opacity(model.overlaysHidden ? 0 : 1) }
        .overlay(alignment: .bottomLeading) { ScaleBar(vs: model.view, pixelSizeA: model.doc?.entry.pixelSizeA).padding(14).opacity(model.overlaysHidden ? 0 : 1) }
        .overlay(alignment: .bottomTrailing) { Readout(cursor: model.cursor, vs: model.view, model: model).padding(10).opacity(model.overlaysHidden ? 0 : 1) }
        .background(Color(red: 0.075, green: 0.078, blue: 0.086))
    }
}

/// "This looks like a SerialEM stack": offered once per file when it opens as the average of its frames.
struct StackHintBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let h = model.stackHint {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SerialEM stack, \(h.depth) frames").font(.callout.weight(.medium))
                    Text("Shown as the average of its frames. Unpack it to pick each frame separately; the average is then hidden.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Unpack") { model.setUnpacked(true) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Keep average") { model.stackHint = nil }.controlSize(.small)
                Menu {
                    Button("Don't suggest this again") { UserDefaults.standard.set(true, forKey: AppModel.stackHintOffKey); model.stackHint = nil }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct HeaderOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tagChanges: TagChanges
    var body: some View {
        if let d = model.doc {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.url.lastPathComponent + (d.entry.depth > 1 ? (d.frame >= 0 ? "  ·  frame \(d.frame + 1)/\(d.entry.depth)" : "  ·  average of \(d.entry.depth) frames") : "")).font(.system(.callout, design: .monospaced).weight(.medium))
                    if let k = model.picks.currentKey { TagDots(tags: model.picks.store.tags(k), size: 11) }
                }
                Text("\(d.entry.width) × \(d.entry.height) · \(d.entry.dataTypeName)" + (d.entry.pixelSizeA.map { String(format: " · %.4g Å/px", $0) } ?? " · uncalibrated"))
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.white)
        }
    }
}

struct ScaleBar: View {
    @ObservedObject var vs: ViewState
    @ObservedObject var units = UnitSettings.shared
    let pixelSizeA: Double?

    var body: some View {
        if let p = pixelSizeA, vs.zoom > 0 {
            let ptsPerA = vs.zoom / (vs.backingScale == 0 ? 2 : vs.backingScale) / p
            let (lenA, label) = nice(targetPts: 130, ptsPerA: ptsPerA)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(.caption, design: .monospaced).weight(.semibold))
                Rectangle().frame(width: lenA * ptsPerA, height: 4)
            }
            .foregroundStyle(.white)
            .shadow(color: .black, radius: 2)
        }
    }

    func nice(targetPts: Double, ptsPerA: Double) -> (Double, String) {
        let targetA = targetPts / ptsPerA
        let mag = pow(10, floor(log10(targetA)))
        var best = mag
        for m in [1.0, 2.0, 5.0, 10.0] where m * mag <= targetA { best = m * mag }
        return (best, LengthUnits.scaleBarLabel(angstroms: best, useAngstroms: units.angstroms))
    }
}

struct Readout: View {
    @ObservedObject var cursor: CursorState
    @ObservedObject var vs: ViewState
    @ObservedObject var model: AppModel
    @ObservedObject var units = UnitSettings.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let x = cursor.x, let y = cursor.y {
                let pa = model.doc?.entry.pixelSizeA
                Text("x \(x)  y \(y)" + (pa.map { p in
                    units.angstroms ? String(format: "   (%.0f, %.0f Å)", Double(x) * p, Double(y) * p)
                                    : String(format: "   (%.1f, %.1f nm)", Double(x) * p / 10, Double(y) * p / 10)
                } ?? ""))
                if let v = cursor.value { Text("value \(String(format: "%.6g", v))") }
            }
            Text(String(format: "zoom %.0f%%", vs.zoom * 100))
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(.white)
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch model.inspectorTab {
            case .overview: OverviewTab(model: model)
            case .display: DisplayTab(model: model, vs: model.view)
            case .picks: PicksTab(model: model, pc: model.picks, store: model.picks.store)
            case .fft: FFTTab(model: model)
            case .tags: TagsTab(model: model)
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct OverviewTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var units = UnitSettings.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let d = model.doc {
                    Card(title: "Histogram") { HistogramView(fallback: d.stats, vs: model.view) }
                    ForEach(d.sections) { sec in
                        Card(title: sec.title) {
                            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                                ForEach(sec.rows) { r in
                                    GridRow {
                                        Text(r.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                        Text(r.text(angstroms: units.angstroms)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }.font(.callout)
                        }
                    }
                } else {
                    Text("No image loaded").foregroundStyle(.secondary).padding(.top, 40)
                }
            }.padding(10)
        }
    }
}

struct HistogramView: View {
    let fallback: ImageStats
    @ObservedObject var vs: ViewState
    var body: some View {
        let h = (vs.displayStats ?? fallback).histogram()
        let binW = (h.hi - h.lo) / Double(h.counts.count)
        Chart {
            ForEach(Array(h.counts.enumerated()), id: \.offset) { i, c in
                BarMark(x: .value("Value", h.lo + (Double(i) + 0.5) * binW), y: .value("Count", c), width: .fixed(1.5))
                    .foregroundStyle(.secondary)
            }
            RuleMark(x: .value("lo", vs.lo)).foregroundStyle(.orange)
            RuleMark(x: .value("hi", vs.hi)).foregroundStyle(.orange)
        }
        .chartXScale(domain: h.lo...h.hi)
        .chartYAxis(.hidden)
        .frame(height: 110)
    }
}

struct DisplayTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var vs: ViewState

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Card(title: "Contrast") {
                    Toggle("Auto contrast", isOn: $vs.autoContrast).onChange(of: vs.autoContrast) { _, _ in vs.applyAuto() }
                    Picker("Mode", selection: $vs.autoMode) { ForEach(AutoMode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().onChange(of: vs.autoMode) { _, _ in vs.applyAuto() }
                    if vs.autoMode == .percentile {
                        sliderRow("Low percentile", $vs.lowPct, 0...20, "%.2f") { vs.applyAuto() }
                        sliderRow("High percentile", $vs.highPct, 80...100, "%.2f") { vs.applyAuto() }
                    } else {
                        sliderRow("n σ", $vs.sigmaN, 0.5...8, "%.1f") { vs.applyAuto() }
                    }
                    if let s = vs.displayStats {
                        let lo = s.percentile(0.01), hi = s.percentile(99.99), pad = (hi - lo) * 0.25
                        sliderRow("Black point", manual($vs.lo), (lo - pad)...(hi + pad), "%.5g") {}
                        sliderRow("White point", manual($vs.hi), (lo - pad)...(hi + pad), "%.5g") {}
                    }
                    sliderRow("Gamma", $vs.gamma, 0.3...3, "%.2f") {}
                    Toggle("Invert contrast", isOn: $vs.invert)
                }
                Card(title: "Filters (GPU)") {
                    let pa = model.doc?.entry.pixelSizeA
                    sliderRow("Low-pass σ (px)", $vs.lowpassSigma, 0...30, "%.1f") {}
                    if let pa, vs.lowpassSigma > 0 { Text(String(format: "σ = %.1f Å", vs.lowpassSigma * pa)).font(.caption).foregroundStyle(.secondary) }
                    sliderRow("Flatten background σ (px)", $vs.flattenSigma, 0...400, "%.0f") {}
                    Text("Flatten subtracts a heavily blurred copy (uneven stain / illumination). Both filters affect display, histogram and filtered exports only; the cursor value and FFT use the raw data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let d = model.doc, d.entry.depth > 1 {
                    Card(title: "Stack") {
                        Picker("", selection: Binding(get: { model.frame >= 0 }, set: { model.setUnpacked($0) })) {
                            Text("Average").tag(false)
                            Text("Frames").tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                        if model.frame >= 0 {
                            Stepper("Frame \(model.frame + 1) / \(d.entry.depth)", value: $model.frame, in: 0...(d.entry.depth - 1))
                                .onChange(of: model.frame) { _, _ in model.reloadFrame() }
                            Text("Unpacked: each frame has its own picks, and the average is hidden and cannot be picked on. ⌥[ and ⌥] step through the frames. Choose Average to show it again. Either choice is saved in the project.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Mean of all \(d.entry.depth) frames. Picks made here belong to the whole file." + (d.isSerialEM ? " This is a SerialEM stack: choose Frames to pick each frame separately." : " Choose Frames to pick each frame separately."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Card(title: "Keys") {
                    Text("Drag: pan · wheel / pinch: zoom · double-click or F: fit · 1: 100% · I: invert · ←/→: prev/next")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10)
        }
    }

    func manual(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; vs.autoContrast = false })
    }

    func sliderRow(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String, _ onEdit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.callout); Spacer(); Text(String(format: f, v.wrappedValue)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) }
            Slider(value: v, in: r).onChange(of: v.wrappedValue) { _, _ in onEdit() }
        }
    }
}

struct FFTTab: View {
    @ObservedObject var model: AppModel
    private let rings: [Double] = [100, 60, 40, 30, 20, 15, 10, 8, 6, 5, 4, 3, 2.5, 2]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let ps = model.fft, let doc = model.doc {
                    let pa = doc.entry.pixelSizeA
                    Card(title: "Power spectrum (\(ps.n)×\(ps.n) box, mean of \(ps.tiles) tiles)") {
                        Toggle("Flatten background (enhance rings)", isOn: $model.fftNormalize)
                        Picker("Box size", selection: $model.fftTile) {
                            ForEach([256, 512, 1024, 2048], id: \.self) { Text("\($0) px").tag($0) }
                        }.pickerStyle(.segmented)
                        GeometryReader { geo in
                            let s = geo.size.width
                            ZStack {
                                if let cg = model.fftNormalize ? ps.imageNorm : ps.imageLog {
                                    Image(decorative: cg, scale: 1).resizable().interpolation(.medium).frame(width: s, height: s)
                                }
                                if let pa {
                                    Canvas { ctx, size in
                                        for d in rings {
                                            let r = Double(ps.n) * pa / d * Double(s) / Double(ps.n)
                                            guard r < Double(s) / 2 - 2 else { continue }
                                            let c = CGPoint(x: size.width / 2, y: size.height / 2)
                                            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                                       with: .color(.orange.opacity(0.55)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                                            ctx.draw(Text(d == d.rounded() ? "\(Int(d)) Å" : "\(d) Å").font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange),
                                                     at: CGPoint(x: c.x + r * 0.7071 + 2, y: c.y - r * 0.7071 - 2), anchor: .bottomLeading)
                                        }
                                    }.allowsHitTesting(false)
                                }
                                if let pa, model.showCTFZeros, !model.ctfContours.isEmpty {
                                    Canvas { ctx, size in
                                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                                        for line in model.ctfContours {
                                            var path = Path()
                                            for (i, p) in line.enumerated() {
                                                let r = p.k * pa * Double(s)
                                                let pt = CGPoint(x: c.x + r * cos(p.theta), y: c.y + r * sin(p.theta))
                                                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                                            }
                                            ctx.stroke(path, with: .color(.cyan.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8))
                                        }
                                    }.allowsHitTesting(false)
                                }
                            }.frame(width: s, height: s)
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                    CTFCard(model: model)
                    Card(title: "Radial profile (log₁₀ mean power)") { ProfileChart(ps: ps, pixelSizeA: pa) }
                } else if model.doc != nil {
                    ProgressView("Computing FFT…").padding(.top, 40)
                } else {
                    Text("No image loaded").foregroundStyle(.secondary).padding(.top, 40)
                }
            }.padding(10)
        }
    }
}

struct CTFCard: View {
    @ObservedObject var model: AppModel

    private func field(_ title: String, _ value: Binding<Double>, _ fmt: String) -> some View {
        HStack {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
                .onSubmit { model.runCTFFit() }
        }
    }

    var body: some View {
        Card(title: "CTF fit (diagnostic, not applied)") {
            Toggle("Show fitted zeros on spectrum", isOn: $model.showCTFZeros)
            field("Voltage (kV)", $model.ctfParams.voltageKV, "%.0f")
            field("Cs (mm)", $model.ctfParams.csMM, "%.1f")
            field("Amplitude contrast", $model.ctfParams.ampContrast, "%.2f")
            field("Fit from (Å)", $model.ctfParams.minResA, "%.0f")
            field("Fit to (Å)", $model.ctfParams.maxResA, "%.0f")
            HStack {
                Button("Refit") { model.runCTFFit() }.disabled(model.ctfBusy)
                if model.ctfBusy { ProgressView().controlSize(.small) }
            }
            if let f = model.ctf {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow { Text("Defocus").foregroundStyle(.secondary); Text(String(format: "%.2f / %.2f µm", f.df1 / 1e4, f.df2 / 1e4)) }
                    GridRow { Text("Astigmatism").foregroundStyle(.secondary); Text(f.astigA < 1 ? "none detected" : String(format: "%.0f Å at %.0f°", f.astigA, f.astigDeg)) }
                    GridRow { Text("Fit range").foregroundStyle(.secondary); Text(String(format: "%.0f – %.0f Å", Double(f.n) * f.pixelSizeA / Double(f.rMin), Double(f.n) * f.pixelSizeA / Double(f.rMax))) }
                    GridRow { Text("Correlation").foregroundStyle(.secondary); Text(String(format: "%.2f", f.cc)) }
                }.font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                CTFFitChart(fit: f)
                Text("Spectrum (black) vs model CTF² (orange), both with the slow trend removed. Defocus is only as good as the pixel size and voltage in the file header; Cs and amplitude contrast are assumptions. Astigmatism is shown only if it clearly improves the fit.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let msg = model.ctfMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CTFFitChart: View {
    let fit: CTFFit
    var body: some View {
        let kPer = 1 / (Double(fit.n) * fit.pixelSizeA)
        Chart {
            ForEach(Array(fit.rMin...fit.rMax), id: \.self) { r in
                LineMark(x: .value("freq", Double(r) * kPer), y: .value("z", Double(fit.radData[r])), series: .value("s", "spectrum"))
                    .foregroundStyle(.primary).lineStyle(StrokeStyle(lineWidth: 1))
                LineMark(x: .value("freq", Double(r) * kPer), y: .value("z", Double(fit.radModel[r])), series: .value("s", "model"))
                    .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxis {
            AxisMarks { v in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let f = v.as(Double.self), f > 0 { Text(String(format: "%.0f Å", 1 / f)).font(.caption2) } }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 130)
    }
}

struct ProfileChart: View {
    let ps: PowerSpectrum
    let pixelSizeA: Double?

    var body: some View {
        let step = max(1, ps.profile.count / 400)
        let pts: [(Double, Double)] = stride(from: 1, to: ps.profile.count, by: step).compactMap { r in
            let v = Double(ps.profile[r]); guard v > 0 else { return nil }
            let x = pixelSizeA.map { Double(r) / (Double(ps.n) * $0) } ?? Double(r) / Double(ps.n)
            return (x, log10(v))
        }
        let nyq = pixelSizeA.map { 0.5 / $0 } ?? 0.5
        let marks: [Double] = pixelSizeA == nil ? [0.1, 0.2, 0.3, 0.4] : [30, 15, 10, 6, 4, 3, 2].map { 1 / $0 }.filter { $0 <= nyq }
        Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("freq", p.0), y: .value("log power", p.1)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: 0...nyq)
        .chartXAxis {
            AxisMarks(values: marks) { v in
                AxisGridLine(); AxisTick()
                AxisValueLabel {
                    if let f = v.as(Double.self) {
                        Text(pixelSizeA == nil ? String(format: "%.1f", f) : String(format: "%g Å", (1 / f * 10).rounded() / 10)).font(.caption2)
                    }
                }
            }
        }
        .frame(height: 150)
    }
}

struct TagsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter tags…", text: $model.tagQuery).textFieldStyle(.roundedBorder).padding(8)
            if let d = model.doc {
                let query = model.tagQuery
                let rows = query.isEmpty ? d.tags : d.tags.filter { $0.path.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
                Text("\(rows.count) of \(d.tags.count) tags").font(.caption).foregroundStyle(.secondary)
                List(rows) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                        Text(r.value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                    }.padding(.vertical, 1)
                }.listStyle(.plain)
            } else { Spacer() }
        }
    }
}
