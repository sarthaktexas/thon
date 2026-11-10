import SwiftUI
import Charts

// MARK: - App shell

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
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
            }
            ToolbarItemGroup(placement: .principal) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled((model.selectedIndex ?? 0) <= 0)
                Text(model.selectedIndex.map { "\($0 + 1) / \(model.items.count)" } ?? "–")
                    .monospacedDigit().frame(minWidth: 60)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled((model.selectedIndex ?? 0) >= model.items.count - 1)
            }
            ToolbarItemGroup {
                PickToggle(pc: model.picks)
                Button { model.view.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                Button { model.view.setZoom(1) } label: { Label("100%", systemImage: "1.magnifyingglass") }
                InvertToggle(vs: model.view)
                Menu {
                    Button("PNG (current contrast)…") { model.exportPNG() }
                    Button("MRC – raw float32…") { model.exportMRC(processed: false) }
                    Button("MRC – filtered float32…") { model.exportMRC(processed: true) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
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
        .alert("Thon", isPresented: Binding(get: { model.loadError != nil }, set: { if !$0 { model.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.loadError ?? "") }
    }
}

struct InvertToggle: View {
    @ObservedObject var vs: ViewState
    var body: some View {
        Toggle(isOn: $vs.invert) { Label("Invert", systemImage: "circle.lefthalf.filled") }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sortedItems) { item in
                ExposureRow(item: item, thumb: model.thumbs[item.url], meta: model.metas[item.url])
                    .tag(item.url)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack {
                Text("\(model.items.count) exposures").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort by", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(width: 210)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
        .overlay {
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Open or drop .dm3 / .dm4 files or a folder").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Folder…") { model.presentOpenPanel(folders: true) }
                }.padding()
            }
        }
    }
}

struct ExposureRow: View {
    let item: ExposureItem
    let thumb: NSImage?
    let meta: ExposureMeta?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 54, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
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
        return parts.joined(separator: " · ")
    }
}

// MARK: - Image pane

struct ImagePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            MicrographView(model: model)
            PickOverlay(pc: model.picks, vs: model.view, store: model.picks.store)
            if model.doc == nil && !model.isLoading {
                Text("No image loaded").foregroundStyle(.secondary)
            }
            if model.isLoading { ProgressView().controlSize(.large) }
        }
        .overlay(alignment: .topLeading) { HeaderOverlay(model: model).padding(10) }
        .overlay(alignment: .bottomLeading) { ScaleBar(vs: model.view, pixelSizeA: model.doc?.entry.pixelSizeA).padding(14) }
        .overlay(alignment: .bottomTrailing) { Readout(cursor: model.cursor, vs: model.view, model: model).padding(10) }
        .background(Color(red: 0.075, green: 0.078, blue: 0.086))
    }
}

struct HeaderOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let d = model.doc {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.url.lastPathComponent).font(.system(.callout, design: .monospaced).weight(.medium))
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
        let label: String
        if best >= 1e4 { label = String(format: "%g µm", best / 1e4) }
        else if best >= 10 { label = String(format: "%g nm", best / 10) }
        else { label = String(format: "%g Å", best) }
        return (best, label)
    }
}

struct Readout: View {
    @ObservedObject var cursor: CursorState
    @ObservedObject var vs: ViewState
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let x = cursor.x, let y = cursor.y {
                let pa = model.doc?.entry.pixelSizeA
                Text("x \(x)  y \(y)" + (pa.map { String(format: "   (%.1f, %.1f nm)", Double(x) * $0 / 10, Double(y) * $0 / 10) } ?? ""))
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
                                        Text(r.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                        Stepper("Frame \(model.frame + 1) / \(d.entry.depth)", value: $model.frame, in: 0...(d.entry.depth - 1))
                            .onChange(of: model.frame) { _, _ in model.reloadFrame() }
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
    private let rings: [Double] = [30, 20, 15, 10, 8, 6, 5, 4, 3, 2.5, 2]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let ps = model.fft, let doc = model.doc {
                    let pa = doc.entry.pixelSizeA
                    Card(title: "Power spectrum (\(ps.n)×\(ps.n) center crop, Hann window)") {
                        Toggle("Divide by radial mean (enhance rings)", isOn: $model.fftNormalize)
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
                            }.frame(width: s, height: s)
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
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
