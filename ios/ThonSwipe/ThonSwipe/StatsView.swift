import SwiftUI

struct StatsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private func pct(_ x: Double?) -> String { x.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    var body: some View {
        NavigationStack {
            List {
                if let st = model.state?.stats {
                    Section("This micrograph") {
                        row("Picked", st.level.pick); row("Rejected", st.level.reject); row("Unsure", st.level.unsure)
                    }
                    Section {
                        row("Cards decided", st.all.cards)
                        LabeledContent("Picked, real candidates", value: pct(st.all.pickRateReal))
                        LabeledContent("Picked, random-spot control", value: "\(pct(st.all.pickRateDecoy)) (\(st.all.decoySeen ?? 0) seen)")
                    } header: { Text("All micrographs") } footer: {
                        Text("About 8% of cards are random positions. A pick rate near the real-candidate rate means the candidates are not much better than random spots.")
                    }
                }
                Section("Micrograph") {
                    Button("Previous micrograph") { Task { await model.level("prev"); dismiss() } }
                    Button("Next micrograph") { Task { await model.level("next"); dismiss() } }
                    Button("Rebuild deck") { Task { await model.level("rebuild"); dismiss() } }
                }
                Section("Connection") {
                    LabeledContent("Link", value: via)
                    LabeledContent("Mac", value: model.online ? "connected" : "offline")
                    LabeledContent("Waiting to sync", value: "\(model.outbox.items.count)")
                    LabeledContent("Dropped decisions", value: "\(model.outbox.dropped.count)")
                    ForEach(Array(model.outbox.dropped.suffix(8).enumerated()), id: \.offset) { _, d in
                        Text("\(d.decision.rawValue): \(d.reason)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Disconnect") { dismiss(); model.disconnect(forget: false) }
                    Button("Disconnect and forget this Mac", role: .destructive) { dismiss(); model.disconnect(forget: true) }
                }
            }
            .navigationTitle("Stats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var via: String {
        switch model.via { case .none: return "none"; case .direct(let m): return "direct, \(m)"; case .wifi(let u): return "network, \(u)"; case .demo: return "demo (no Mac)" }
    }

    private func row(_ title: String, _ n: Int?) -> some View { LabeledContent(title, value: "\(n ?? 0)") }
}
