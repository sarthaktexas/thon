import SwiftUI

/// Swipe assistant: learns from the decisions made so far and reorders the cards still waiting. It never decides anything.
struct AssistView: View {
    @ObservedObject var rr: Reranker

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Assist").font(.caption.weight(.semibold))
                Picker("", selection: $rr.mode) { ForEach(Reranker.Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Toggle("Core ML image features", isOn: $rr.useEmbedding).toggleStyle(.checkbox).font(.caption)
                    .help("Adds Apple's Vision image embedding (may run on the Neural Engine) to the hand-made features. Experimental: compare the agreement figure with it on and off.")
                Spacer()
                Button("Forget") { rr.reset() }.controlSize(.small).disabled(rr.status.positives + rr.status.negatives == 0)
            }
            Text(rr.status.summary).font(.caption2).foregroundStyle(.secondary)
            Text("Only the order of cards you have not seen yet changes; every fifth card is random so it keeps seeing cases it would not choose.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
