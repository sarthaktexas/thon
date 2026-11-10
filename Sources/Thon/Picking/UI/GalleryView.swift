import SwiftUI

struct GalleryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pc: PickController
    @ObservedObject var g: GalleryModel
    @ObservedObject var store: PickStore
    @FocusState private var focused: Bool

    init(model: AppModel) {
        self.model = model; self.pc = model.picks; self.g = model.picks.gallery; self.store = model.picks.store
    }

    var body: some View {
        let items = g.items
        VStack(spacing: 0) {
            controls(items.count)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    if g.groupByLabel {
                        ForEach(store.scheme.labels) { l in
                            let sec = items.filter { $0.label == l.id }
                            if !sec.isEmpty {
                                Section {
                                    grid(sec)
                                } header: {
                                    HStack {
                                        Circle().fill(swiftUIColor(l.color)).frame(width: 10, height: 10)
                                        Text(l.name).font(.headline)
                                        Text("\(sec.count)").foregroundStyle(.secondary)
                                        Button("Select all") { g.selectAll(label: l.id) }.controlSize(.small)
                                        Spacer()
                                    }.padding(.vertical, 4).background(.bar)
                                }
                            }
                        }
                        let known = Set(store.scheme.labels.map { $0.id })
                        let rest = items.filter { !known.contains($0.label) }
                        if !rest.isEmpty { grid(rest) }
                    } else { grid(items) }
                    if items.isEmpty { Text("No picks to show.").foregroundStyle(.secondary).padding(40) }
                }.padding(12)
            }
            Divider()
            footer(items.count)
        }
        .frame(minWidth: 900, minHeight: 640)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true; g.refresh() }
    }

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        if p.key == .delete || p.key == .deleteForward { g.deleteSelected(); return .handled }
        if p.key == .escape { if g.selection.isEmpty { model.showGallery = false } else { g.selection = [] }; return .handled }
        let c = p.characters.lowercased()
        if let l = store.scheme.label(forKey: c) { g.relabelSelected(l.id); return .handled }
        if c == "a", p.modifiers.isEmpty { g.acceptSelected(); return .handled }
        if c == "z", p.modifiers.contains(.command) { g.undo(); return .handled }
        return .ignored
    }

    private func controls(_ n: Int) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: $g.scope) { ForEach(GalleryScope.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            Picker("Sort", selection: $g.sort) {
                ForEach(GallerySort.allCases.filter { $0 != .cls || pc.classes != nil }) { Text($0.rawValue).tag($0) }
            }.frame(width: 160)
            Toggle("Group by label", isOn: $g.groupByLabel)
            Toggle("Candidates", isOn: $g.showCandidates)
            Toggle("Invert", isOn: $g.invert)
            HStack { Text("Smooth"); Slider(value: $g.smooth, in: 0...3, step: 0.5).frame(width: 80) }
            HStack { Text("Size"); Slider(value: $g.thumbPx, in: 56...200).frame(width: 90) }
            Spacer()
            if let p = g.progress { ProgressView().controlSize(.small); Text(p).font(.caption).foregroundStyle(.secondary) }
            Button("Done") { model.showGallery = false }.keyboardShortcut(.cancelAction)
        }.padding(10)
    }

    private func footer(_ n: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(n) crops" + (n >= GalleryModel.cap ? " (capped)" : "") + " · \(g.selection.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Relabel selection:").font(.caption)
            ForEach(store.scheme.labels) { l in
                Button { g.relabelSelected(l.id) } label: {
                    HStack(spacing: 4) { Circle().fill(swiftUIColor(l.color)).frame(width: 9, height: 9); Text(l.key) }
                }.help(l.name).disabled(g.selection.isEmpty)
            }
            Button("Accept") { g.acceptSelected() }.disabled(g.selection.isEmpty)
            Button("Delete") { g.deleteSelected() }.disabled(g.selection.isEmpty)
            Button("Undo") { g.undo() }.disabled(!g.canUndo)
        }.controlSize(.small).padding(10)
    }

    private func grid(_ items: [GalleryItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: g.thumbPx, maximum: g.thumbPx + 4), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items) { it in
                GalleryCell(it: it, size: g.thumbPx, selected: g.selection.contains(it.id),
                            color: store.scheme.label(it.label).map { swiftUIColor($0.color) } ?? .gray,
                            classColor: pc.showClassColors ? it.cls.map { swiftUIColor(ClassMapping.color($0)) } : nil)
                    .onTapGesture(count: 2) { g.goTo(it.id) }
                    .onTapGesture {
                        let m = NSEvent.modifierFlags
                        if m.contains(.command) || m.contains(.shift) {
                            if g.selection.contains(it.id) { g.selection.remove(it.id) } else { g.selection.insert(it.id) }
                        } else { g.selection = [it.id] }
                    }
                    .contextMenu {
                        Button("Go to in micrograph") { g.goTo(it.id) }
                        Menu("Relabel") { ForEach(store.scheme.labels) { l in Button(l.name) { g.selection = g.selection.contains(it.id) ? g.selection : [it.id]; g.relabelSelected(l.id) } } }
                        Button("Delete") { g.selection = g.selection.contains(it.id) ? g.selection : [it.id]; g.deleteSelected() }
                    }
            }
        }
    }
}

struct GalleryCell: View {
    let it: GalleryItem
    let size: Double
    let selected: Bool
    let color: Color
    let classColor: Color?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let b = it.thumb, let img = grayCGImage(b, width: GalleryModel.outPx, height: GalleryModel.outPx) {
                Image(decorative: img, scale: 1).interpolation(.medium).resizable().frame(width: size, height: size)
            } else {
                Rectangle().fill(.quaternary).frame(width: size, height: size).overlay(ProgressView().controlSize(.small))
            }
            if let s = it.score {
                Text(String(format: "%.1f", s)).font(.system(size: 9, design: .monospaced)).padding(2)
                    .background(.black.opacity(0.55)).foregroundStyle(.white)
            }
            if let c = classColor, let n = it.cls {
                Text("\(n)").font(.system(size: 9, weight: .bold, design: .monospaced)).padding(.horizontal, 3).padding(.vertical, 1)
                    .background(c).foregroundStyle(.black).frame(width: size, height: size, alignment: .bottomTrailing)
            }
        }
        .overlay(Rectangle().strokeBorder(selected ? Color.white : color, style: StrokeStyle(lineWidth: selected ? 3 : 1.5, dash: it.status == .candidate ? [4, 3] : [])))
        .frame(width: size, height: size)
    }
}
