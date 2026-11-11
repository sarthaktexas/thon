import SwiftUI

// Views shared by swipe review, sort mode and grid triage: what the pixels are (badge, caption) and the display controls.

/// Always-visible statement of what the pixels are: RAW, or the denoiser and its settings.
struct SwipeBadge: View {
    @ObservedObject var sw: SwipeSession
    @ObservedObject var pc: PickController
    @ObservedObject var units = UnitSettings.shared
    var compact = false

    var body: some View {
        let d = sw.display
        let title = compact ? (d.isDenoised ? "DENOISED" : "RAW") : d.processingTitle(pixelA: pc.pixelSizeA, useAngstroms: units.angstroms)
        return HStack(spacing: 5) {
            Text(title).font(.system(size: compact ? 10 : 12, weight: .bold, design: .monospaced))
            if !compact && !d.toneIsDefault { Text("· tone adjusted").font(.system(size: 11, design: .monospaced)) }
        }
        .foregroundStyle(d.isDenoised ? Color.black : Color.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(d.isDenoised ? Color.orange : Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
        .padding(compact ? 0 : 8)
        .allowsHitTesting(false)
    }
}

/// Plain-text details under the image (does not move with it): pixel size, resampling and tone settings.
struct SwipeCaption: View {
    @ObservedObject var sw: SwipeSession
    @ObservedObject var pc: PickController
    var out: Int
    var width: CGFloat

    var body: some View {
        let d = sw.display
        let px = pc.pixelSizeA.map { String(format: "%.2f Å/px", $0) } ?? "pixel size unknown"
        let rs = swipeResampleNote(boxPx: sw.windowPx, out: out, pixelated: d.pixelated)
        return Text("\(d.isDenoised ? d.denoise.fullName : "raw pixels, no denoising") · \(px) · \(rs)\n\(d.toneSummary())")
            .font(.caption2.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: width)
    }
}

/// Brightness / contrast / gamma / denoise controls. Shared state lives in `SwipeSession.display`.
struct DisplayPanel: View {
    @ObservedObject var sw: SwipeSession
    @AppStorage("swipe.showDisplay") private var showDisplay = true
    var keysHint = "V denoise on/off · , . brightness · - = contrast · I invert · 0 reset"

    var body: some View {
        DisclosureGroup(isExpanded: $showDisplay) {
            VStack(spacing: 5) {
                HStack {
                    Picker("", selection: Binding(get: { sw.display.denoise }, set: { sw.display.select($0) })) {
                        ForEach(SwipeDenoise.allCases) { Text($0.menuName).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
                    Toggle("Keep on next cards", isOn: $sw.pinProcessing).toggleStyle(.checkbox).font(.caption)
                        .help("Off: every new card or page starts raw. Brightness and contrast always carry over.")
                    Spacer()
                    Button("Reset display (0)") { sw.display.resetTone(); sw.display.denoise = .none }.controlSize(.small)
                }
                if sw.display.isDenoised {
                    HStack(spacing: 14) {
                        if sw.display.denoise.usesSize {
                            sliderRow(sw.display.denoise == .median ? "Radius" : "Size σ", $sw.display.size, sw.display.denoise.sizeRange,
                                      step: sw.display.denoise == .median ? 1 : 0.1,
                                      text: sw.display.denoise == .median ? String(format: "%d px", sw.display.medianRadius) : String(format: "%.1f px", sw.display.size))
                        }
                        if sw.display.denoise.usesH {
                            sliderRow(sw.display.denoise == .bilateral ? "Range" : "Strength h", $sw.display.h, 0.3...3, step: 0.1, text: String(format: "%.1f σn", sw.display.h))
                        }
                        if let n = sw.cardNoiseSigma { Text(String(format: "σn ≈ %.3g", n)).font(.caption2).foregroundStyle(.secondary).help("Noise σ estimated from this crop's raw pixels (assumes uncorrelated noise, so it is a lower bound).") }
                        Spacer()
                    }
                }
                HStack(spacing: 14) {
                    sliderRow("Brightness", $sw.display.brightness, -1...1, step: 0.01, text: String(format: "%+.2f", sw.display.brightness))
                    sliderRow("Contrast", Binding(get: { log2(sw.display.contrast) }, set: { sw.display.contrast = pow(2, $0) }), -2...2, step: 0.05,
                              text: String(format: "×%.2f", sw.display.contrast))
                    sliderRow("Gamma", $sw.display.gamma, 0.4...2.5, step: 0.05, text: String(format: "%.2f", sw.display.gamma))
                }
                HStack(spacing: 14) {
                    Picker("Window from", selection: $sw.display.tone) { ForEach(SwipeTone.allCases) { Text($0.menuName).tag($0) } }
                        .pickerStyle(.menu).controlSize(.small).font(.caption).frame(width: 250)
                        .help("Whole micrograph: the same window on every card, so brightness is comparable between cards. This card: stretch each crop to its own 0.5–99.5 % range.")
                    Toggle("Invert (I)", isOn: $sw.display.invert).toggleStyle(.checkbox).font(.caption)
                    Toggle("Show true pixels", isOn: $sw.display.pixelated).toggleStyle(.checkbox).font(.caption)
                        .help("Nearest-neighbour: every image pixel is a visible square, nothing interpolated.")
                    Spacer()
                }
            }.padding(.top, 4)
        } label: {
            HStack(spacing: 8) { Text("Display").font(.caption.bold()); Text(keysHint).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func sliderRow(_ name: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double, text: String) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.caption).frame(width: 62, alignment: .trailing)
            Slider(value: v, in: r, step: step).frame(minWidth: 70)
            Text(text).font(.caption).monospacedDigit().frame(width: 46, alignment: .leading)
        }
    }
}
