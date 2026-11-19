import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

typealias SizeHist = (bins: [SizeBin], lo: Double, width: Double, count: Int)

/// Picks tab ▸ Particle sizes: histogram of the particle diameters, as set on the picks or measured from the image.
struct SizeHistogramCard: View {
    @ObservedObject var pc: PickController
    @ObservedObject var store: PickStore
    @ObservedObject var sizes: SizeModel
    @ObservedObject var units = UnitSettings.shared
    private var f: Double { LengthUnits.fromNm(1, angstroms: units.angstroms) }          // stored nm -> display unit
    private var unit: String { LengthUnits.name(units.angstroms) }

    var body: some View {
        CollapsibleCard(title: "Particle sizes", id: "sizes") {
            let samples = sizes.samples()
            let sum = SizeStats.summary(samples.map { $0.nm })
            Picker("", selection: $sizes.source) { ForEach(SizeSource.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            HStack {
                Toggle("This micrograph only", isOn: $sizes.thisMicrographOnly)
                Spacer()
                Toggle("Candidates", isOn: $sizes.includeCandidates)
            }.font(.callout)
            if sizes.source == .measured { measureRow }
            if samples.isEmpty {
                Text(sizes.source == .measured ? "No measured sizes yet. Press Measure." : "No accepted picks in scope.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                chart(samples, sum)
                stats(sum)
                controls(samples)
            }
            if let m = sizes.message { Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text(sizes.source == .set
                 ? "Set diameter: what is stored with each pick (a size sweep, ↑/↓ resizing, or the project default). It is the size the picker used, not a measurement."
                 : "Measured: half-maximum radius of the radial intensity profile around the pick. An estimate that is good for isolated, round particles; it sees sizes up to about 1.5 × the set diameter. Picks near the border or without contrast are skipped.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var measureRow: some View {
        HStack {
            if sizes.busy {
                ProgressView().controlSize(.small)
                Text(sizes.progress ?? "Measuring…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { sizes.cancelMeasure() }.controlSize(.small)
            } else {
                let n = sizes.unmeasuredCount()
                Button(n > 0 ? "Measure \(n) pick\(n == 1 ? "" : "s")" : "Measure again") { if n == 0 { sizes.clearMeasured() }; sizes.measure() }.controlSize(.small)
                Spacer()
                if !sizes.measured.isEmpty { Button("Forget") { sizes.clearMeasured() }.controlSize(.small).help("Discard the measured sizes") }
            }
        }
    }

    @ViewBuilder private func chart(_ samples: [SizeSample], _ sum: SizeSummary) -> some View {
        let h = sizes.histogram(samples)
        if sizes.colorBy == .none { plainChart(h, sum) } else { groupedChart(h, sum) }
    }

    @ChartContentBuilder private func bar(_ b: SizeBin) -> some ChartContent {
        RectangleMark(xStart: .value("From", b.lo * f), xEnd: .value("To", b.hi * f), yStart: .value("Below", b.yLo), yEnd: .value("Particles", b.yHi))
    }

    private func xDomain(_ h: SizeHist) -> ClosedRange<Double> { (h.lo * f)...((h.lo + Double(max(h.count, 1)) * h.width) * f) }

    private func plainChart(_ h: SizeHist, _ sum: SizeSummary) -> some View {
        Chart {
            ForEach(h.bins) { b in
                bar(b).foregroundStyle(Color.accentColor)
            }
            RuleMark(x: .value("Median", sum.median * f)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
        }
        .chartXScale(domain: xDomain(h))
        .chartXAxisLabel("Diameter (\(unit))")
        .chartYAxisLabel("Particles")
        .frame(height: 170)
    }

    private func groupedChart(_ h: SizeHist, _ sum: SizeSummary) -> some View {
        let names: [String] = Array(Set(h.bins.map { $0.group })).sorted()
        let colors: [Color] = names.map { color(for: $0) }
        return Chart {
            ForEach(h.bins) { b in
                bar(b).foregroundStyle(by: .value("Group", b.group))
            }
            RuleMark(x: .value("Median", sum.median * f)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
        }
        .chartXScale(domain: xDomain(h))
        .chartXAxisLabel("Diameter (\(unit))")
        .chartYAxisLabel("Particles")
        .chartForegroundStyleScale(domain: names, range: colors)
        .frame(height: 170)
    }

    private func color(for group: String) -> Color {
        switch sizes.colorBy {
        case .label: return store.scheme.label(group).map { swiftUIColor($0.color) } ?? .gray
        case .cls:
            if group.hasPrefix("class "), let n = Int(group.dropFirst(6)) { return swiftUIColor(ClassMapping.color(n)) }
            return .gray
        case .none: return .accentColor
        }
    }

    private func stats(_ s: SizeSummary) -> some View {
        let k = f, fmt = units.angstroms ? "%.0f" : "%.1f"
        let g = { (v: Double) in String(format: fmt, v * k) }
        return Text("n \(s.n) · median \(g(s.median)) \(unit) · mean \(g(s.mean)) ± \(g(s.sd)) · 5–95 %: \(g(s.p5))–\(g(s.p95)) · range \(g(s.min))–\(g(s.max))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize(horizontal: false, vertical: true)
    }

    private func controls(_ samples: [SizeSample]) -> some View {
        let auto = SizeStats.autoBinWidth(samples.map { $0.nm })
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Colour by").font(.callout)
                Picker("", selection: $sizes.colorBy) {
                    ForEach(SizeColorBy.allCases.filter { $0 != .cls || pc.classes != nil }) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 110)
                Spacer()
                Button("Export CSV…") { exportCSV() }.controlSize(.small)
            }
            HStack {
                Toggle("Automatic bins", isOn: Binding(get: { sizes.binWidthNm == nil }, set: { sizes.binWidthNm = $0 ? nil : auto }))
                    .font(.callout)
                if let w = sizes.binWidthNm {
                    Stepper(String(format: "%g %@", w * f, unit), value: Binding(get: { w * f }, set: { sizes.binWidthNm = max(0.1, $0 / f) }), in: (0.1 * f)...(100 * f), step: max(0.1 * f, auto * f / 4))
                        .font(.callout).monospacedDigit()
                } else {
                    Text(String(format: "%g %@", auto * f, unit)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func exportCSV() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType.commaSeparatedText]
        p.nameFieldStringValue = "particle_sizes.csv"
        p.directoryURL = store.root
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(sizes.csvText().utf8).write(to: u); sizes.message = "Wrote \(sizes.samples().count) sizes to \(u.lastPathComponent)." }
        catch { sizes.message = "Could not write the CSV: \(error.localizedDescription)" }
    }
}
