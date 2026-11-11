import SwiftUI
import AppKit

/// Organize a .thon project: the Sessions tab edits names, sample / date / notes, order, folders and removal;
/// the Micrographs tab moves micrographs between sessions (only the organization changes, never the files).
struct SessionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: PickStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var selected: String?
    @State private var confirmRemove: String?

    private var sessions: [PickSession] { store.project.sessions }

    private func bind(_ id: String, _ kp: WritableKeyPath<PickSession, String>) -> Binding<String> {
        Binding(get: { store.project.sessions.first { $0.id == id }?[keyPath: kp] ?? "" },
                set: { v in if var s = store.project.sessions.first(where: { $0.id == id }) { s[keyPath: kp] = v; store.updateSession(s) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project").font(.headline)
                TextField("Project name", text: Binding(get: { store.project.name ?? "" }, set: { store.setProjectName($0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("", selection: $tab) { Text("Sessions").tag(0); Text("Micrographs").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                Text(store.projectURL?.path ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
            }.padding(12)
            Divider()
            if tab == 0 { sessionsTab } else { MicrographOrganizer(model: model, store: store) }
            Divider()
            HStack {
                Text("Everything is saved into the project file automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .frame(width: 780, height: 500)
        .onAppear { if selected == nil || !sessions.contains(where: { $0.id == selected }) { selected = sessions.first?.id } }
        .alert("Remove session?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove session and its picks", role: .destructive) {
                if let id = confirmRemove { model.removeSession(id); selected = store.project.sessions.first?.id }
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: {
            let st = confirmRemove.map { store.originStats($0) } ?? .init()
            Text("This deletes \(st.picks) picks and the notes of \(st.micrographs) micrographs that live in this session's folder (even those you moved to other sessions) from the project file; a backup is written first. Micrographs moved INTO this session from elsewhere go back to their own session. The micrograph files themselves are not touched.")
        }
    }

    private var idx: Int? { sessions.firstIndex { $0.id == selected } }

    private var sessionsTab: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(sessions) { s in
                        HStack {
                            if !store.sessionFolderExists(s.id) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).lineLimit(1)
                                Text(s.sample.isEmpty ? s.id : s.sample).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.tag(s.id)
                    }
                }
                Divider()
                HStack {
                    Menu {
                        Button("Add Session Folder…") { model.presentAddSessionPanel() }
                        Button("Add Sub-folders as Sessions…") { model.presentAddSubfolderSessionsPanel() }
                    } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Add sessions")
                    Button { if let i = idx { store.moveSession(from: i, to: i - 1) } } label: { Image(systemName: "arrow.up") }
                        .disabled((idx ?? 0) <= 0).help("Move up")
                    Button { if let i = idx { store.moveSession(from: i, to: i + 1) } } label: { Image(systemName: "arrow.down") }
                        .disabled(idx == nil || idx! >= sessions.count - 1).help("Move down")
                    Spacer()
                }.padding(8).buttonStyle(.borderless)
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
            detail.frame(minWidth: 380)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selected, let s = sessions.first(where: { $0.id == id }) {
            let st = store.sessionStats(id), ost = store.originStats(id)
            Form {
                TextField("Name", text: bind(id, \.name))
                TextField("Sample / grid", text: bind(id, \.sample))
                TextField("Date", text: bind(id, \.date))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: bind(id, \.notes)).font(.body).frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
                LabeledContent("Folder") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(store.sessionFolder(id)?.path ?? s.folder).font(.system(.caption, design: .monospaced))
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        HStack {
                            if !store.sessionFolderExists(id) { Text("not found").font(.caption).foregroundStyle(.yellow) }
                            Button("Locate…") { model.presentRelocateSessionPanel(id) }.controlSize(.small)
                        }
                    }
                }
                LabeledContent("Micrographs") { Text("\(model.sessionItems(id).count) in this session · \(st.micrographs) with picks or notes · \(st.done) done") }
                LabeledContent("Picks") { Text("\(st.picks) accepted" + (st.maybe > 0 ? " (\(st.maybe) maybe)" : "") + " · \(st.candidates) candidates") }
                LabeledContent("Session id") { Text(id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Remove session…", role: .destructive) {
                        if ost.picks > 0 || ost.micrographs > 0 { confirmRemove = id } else { model.removeSession(id); selected = store.project.sessions.first?.id }
                    }.controlSize(.small)
                }
            }
            .formStyle(.grouped)
        } else {
            Text("No sessions").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// All micrographs of the project with their session; select any number and move them to another session.
struct MicrographOrganizer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: PickStore
    @State private var filter: String?          // session id, nil = all
    @State private var search = ""
    @State private var selection = Set<URL>()

    private var rows: [ExposureItem] {
        model.items.filter { it in
            (filter == nil || it.session == filter) &&
            (search.isEmpty || it.url.lastPathComponent.localizedCaseInsensitiveContains(search))
        }
    }

    private func sessionName(_ id: String?) -> String { id.flatMap { i in store.project.sessions.first { $0.id == i }?.name } ?? "–" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    Text("All sessions").tag(String?.none)
                    ForEach(store.project.sessions) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 260)
                TextField("Filter by name", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Spacer()
                Text("\(rows.count) shown · \(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Select all shown") { selection = Set(rows.map { $0.url }) }.controlSize(.small)
                Menu("Move selected to…") {
                    ForEach(store.project.sessions) { s in
                        Button(s.name) { move(to: s.id) }
                    }
                    Divider()
                    Button("Back to the session of its folder") { move(to: nil) }
                }
                .controlSize(.small).fixedSize().disabled(selection.isEmpty)
            }.padding(10)
            Divider()
            List(rows, selection: $selection) { it in
                let key = store.key(for: it.url)
                let origin = store.originSessionID(key)
                HStack {
                    Text(it.url.lastPathComponent).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    let n = store.accepted(key).count
                    if n > 0 { Text("\(n) picks").font(.caption).foregroundStyle(.secondary) }
                    if origin != it.session { Text("from \(sessionName(origin))").font(.caption).foregroundStyle(.orange) }
                    Text(sessionName(it.session)).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing).lineLimit(1)
                }
            }
            Text("Moving only changes which session a micrograph is listed and exported under; the files stay where they are and their picks stay attached.")
                .font(.caption2).foregroundStyle(.secondary).padding(8)
        }
    }

    private func move(to id: String?) {
        model.moveMicrographs(Array(selection), to: id)
    }
}
