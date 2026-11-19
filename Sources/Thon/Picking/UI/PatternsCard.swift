import SwiftUI
import AppKit
import UniformTypeIdentifiers

private func patternColor(_ k: PatternKind) -> Color {
    switch k {
    case .aggregates: return .orange
    case .lines: return .cyan
    case .rings: return .pink
    case .hexagonal: return .yellow
    case .square: return .mint
    case .patchiness: return .white
    default: return .gray
    }
}

/// Picks tab ▸ Pattern suggestions: looks for arrangements in the saved picks that are unlikely by chance, and says so in words.
struct PatternsCard: View {
    @ObservedObject var pc: PickController
    @ObservedObject var store: PickStore
    @ObservedObject var model: PatternModel

    var body: some View {
        CollapsibleCard(title: "Pattern suggestions", id: "patterns") {
            Picker("", selection: $model.scopeAll) {
                Text("This micrograph").tag(false)
                Text("All micrographs").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Compare types by").font(.callout)
                Picker("", selection: $model.groupBy) {
                    ForEach(PatternGroupBy.allCases.filter { $0 != .cls || pc.classes != nil }) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100)
                Spacer()
            }
            Toggle("Allow for uneven density", isOn: $model.allowUnevenDensity).font(.callout)
                .help("Random positions follow each micrograph's own smooth density, so a crowded corner is not reported as clustering. Turn off to ask whether the particles are random on a flat background.")
            Toggle("Include candidates", isOn: $model.includeCandidates).font(.callout)
                .help("Also use the auto-picker's candidates above the Review score cutoff. They are not checked by you, so a pattern may come from the picker.")
            runRow
            if let rep = model.report { results(rep) }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Uses the saved, accepted, exported picks (and candidates above the score cutoff when ticked; never hidden labels). Each shape is compared with random positions of the same number of particles, keeping the closest spacing your picks already have, and the list is corrected for the twelve questions asked. A pattern here is a suggestion about positions; it says nothing about what the particles are.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runRow: some View {
        HStack {
            if model.busy {
                ProgressView().controlSize(.small)
                Text(model.progress ?? "Working…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.cancel() }.controlSize(.small)
            } else {
                Button(model.report == nil ? "Look for patterns" : "Look again") { model.run() }
                    .controlSize(.small)
                    .disabled(model.scopeKeys.isEmpty)
                Spacer()
                if model.isStale() { Text("Picks changed since this result").font(.caption).foregroundStyle(.orange) }
                if model.report != nil { Button("Clear") { model.clear() }.controlSize(.small) }
            }
        }
    }

    @ViewBuilder private func results(_ rep: PatternReport) -> some View {
        Divider()
        Text("\(model.reportScope): \(rep.picks) picks on \(rep.micrographs.count) micrograph\(rep.micrographs.count == 1 ? "" : "s"), each compared with \(rep.nSim) random arrangements")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        let found = rep.findings
        if found.isEmpty {
            Text(rep.rows.isEmpty ? "Nothing could be tested." : "Nothing stands out beyond chance after allowing for \(rep.testsRun) questions.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(found) { row($0) }
        }
        if !rep.hints.isEmpty {
            DisclosureGroup("Hints that did not survive correction (\(rep.hints.count))") {
                VStack(alignment: .leading, spacing: 8) { ForEach(rep.hints) { row($0) } }.padding(.top, 4)
            }.font(.caption)
        }
        DisclosureGroup("All \(rep.testsRun) questions") { allTests(rep) }.font(.caption)
        ForEach(Array(rep.notes.enumerated()), id: \.offset) { _, n in
            Text(n).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !rep.skipped.isEmpty {
            Text("Left out: " + rep.skipped.prefix(3).map { "\(($0.key as NSString).lastPathComponent) (\($0.why))" }.joined(separator: "; ") + (rep.skipped.count > 3 ? " and \(rep.skipped.count - 3) more" : ""))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack { Spacer(); Button("Export CSV…") { exportCSV() }.controlSize(.small) }
    }

    private func row(_ r: PatternRow) -> some View {
        let drawable = model.drawable(forKey: pc.currentKey).contains(r.kind)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(r.level.label.uppercased()).font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(r.level == .strong ? Color.accentColor : Color.secondary.opacity(0.35), in: Capsule())
                    .foregroundStyle(r.level == .strong ? Color.white : Color.primary)
                Text(r.kind.title).font(.callout.weight(.semibold))
                Spacer()
                if drawable {
                    Toggle("Show", isOn: Binding(get: { model.shown.contains(r.kind) }, set: { if $0 { model.shown.insert(r.kind) } else { model.shown.remove(r.kind) } }))
                        .toggleStyle(.checkbox).controlSize(.small).font(.caption)
                        .help("Draw this pattern over the micrograph on screen")
                }
            }
            Text(r.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let c = r.caveat { Text(c).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(statLine(r)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func statLine(_ r: PatternRow) -> String {
        var s = "p \(fmtP(r.p)) · corrected \(fmtP(r.pAdj))"
        if r.micrographs > 1 { s += " · \(r.significantIn) of \(r.micrographs) micrographs on their own" }
        return s
    }

    private func fmtP(_ p: Double) -> String { p < 0.001 ? "<0.001" : String(format: "%.3f", p) }

    private func allTests(_ rep: PatternReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rep.rows) { r in
                HStack {
                    Text(r.kind.title).font(.caption)
                    Spacer()
                    Text("\(fmtP(r.p)) → \(fmtP(r.pAdj))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("p = chance of seeing this much or more in random positions; corrected = after allowing for all questions (Holm). Micrographs are combined with Fisher's method.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }.padding(.top, 4)
    }

    private func exportCSV() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType.commaSeparatedText]
        p.nameFieldStringValue = "pattern_suggestions.csv"
        p.directoryURL = store.root
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(model.csvText().utf8).write(to: u); model.message = "Wrote \(u.lastPathComponent)." }
        catch { model.message = "Could not write the CSV: \(error.localizedDescription)" }
    }
}

/// Draws the patterns that are ticked in the card over the micrograph on screen. Display only.
struct PatternOverlay: View {
    @ObservedObject var model: PatternModel
    @ObservedObject var pc: PickController
    @ObservedObject var vs: ViewState

    var body: some View {
        Canvas { ctx, size in
            guard let key = pc.currentKey, vs.zoom > 0, !model.shown.isEmpty else { return }
            let layers = model.overlay(forKey: key)
            guard !layers.isEmpty else { return }
            let bs = vs.backingScale == 0 ? 2 : vs.backingScale
            let g = ViewGeometry(zoom: vs.zoom, center: vs.center, viewPixels: CGSize(width: size.width * bs, height: size.height * bs), backingScale: bs)
            let ppp = g.pointsPerPixel
            for (kind, geo) in layers {
                let color = patternColor(kind)
                for r in geo.rects {
                    let a = g.pickToView(x: r.x0, y: r.y0), z = g.pickToView(x: r.x1, y: r.y1)
                    let rect = CGRect(x: min(a.x, z.x), y: min(a.y, z.y), width: abs(z.x - a.x), height: abs(z.y - a.y))
                    ctx.fill(Path(rect), with: .color(color.opacity(0.10)))
                    ctx.stroke(Path(rect), with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
                for s in geo.segments {
                    var path = Path()
                    path.move(to: g.pickToView(x: s.x0, y: s.y0)); path.addLine(to: g.pickToView(x: s.x1, y: s.y1))
                    ctx.stroke(path, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                for c in geo.circles {
                    let m = g.pickToView(x: c.x, y: c.y), r = c.r * ppp
                    let path = Path(ellipseIn: CGRect(x: m.x - r, y: m.y - r, width: 2 * r, height: 2 * r))
                    ctx.stroke(path, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 4, dash: [8, 5]))
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                }
                for d in geo.dots {
                    let m = g.pickToView(x: d.x, y: d.y)
                    let r = CGRect(x: m.x - 4, y: m.y - 4, width: 8, height: 8)
                    ctx.fill(Path(ellipseIn: r), with: .color(color))
                    ctx.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.7)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
