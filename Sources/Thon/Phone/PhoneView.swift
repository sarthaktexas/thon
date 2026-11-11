import SwiftUI
import AppKit
import CoreImage

/// QR code for `text` as an image (nil if CoreImage cannot make one).
func phoneQRImage(_ text: String, scale: CGFloat = 8) -> NSImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
}

/// The Phone panel: switch, QR code for pairing, connection status, label scheme the phone will show.
struct PhoneView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ph = PhoneController.shared
    @ObservedObject var store: PickStore

    init(model: AppModel) { self.model = model; self.store = model.picks.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Phone swiper").font(.title2.bold())
            Text("Swipe through the candidates of the micrograph open in Thon on your phone. Decisions go straight into this project. The phone and this Mac must be on the same Wi-Fi.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Allow phone connections", isOn: Binding(get: { ph.enabled }, set: { on in if on { ph.start(host: model) } else { ph.stop() } }))
                .toggleStyle(.switch)
            if let e = ph.error { Text(e).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }

            if ph.enabled { pairing } else { settings }

            Divider()
            labelsPreview
            Text("Traffic between phone and Mac is plain HTTP on your local network, protected by a pairing code in the link. Do not use it on a network you do not trust; turn the switch off when you are done.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Port")
                TextField("Port", value: $ph.port, format: .number.grouping(.never)).frame(width: 80).textFieldStyle(.roundedBorder)
                Text("(1024 to 65535)").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset pairing…") { confirmReset() }.controlSize(.small)
        }
    }

    private var pairing: some View {
        let urls = ph.urls
        return VStack(alignment: .leading, spacing: 10) {
            if let first = urls.first, let qr = phoneQRImage(first) {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 190, height: 190)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Scan the code with the phone's Camera app.").fixedSize(horizontal: false, vertical: true)
                        Text("2. In Safari, tap Share, then Add to Home Screen, to keep it as an app.").fixedSize(horizontal: false, vertical: true)
                        Text("3. Open a micrograph that has candidates (Find particles) on the Mac.").fixedSize(horizontal: false, vertical: true)
                    }.font(.callout)
                }
            } else {
                Text(ph.running ? "No Wi-Fi address found. Connect this Mac to Wi-Fi." : "Starting…").foregroundStyle(.secondary)
            }
            ForEach(urls, id: \.self) { u in
                Text(u).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            }
            HStack {
                Button("Copy link") {
                    if let u = urls.first { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
                }.controlSize(.small).disabled(urls.isEmpty)
                Button("Reset pairing…") { confirmReset() }.controlSize(.small)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(statusText(ctx.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusText(_ now: Date) -> String {
        guard ph.running else { return "Starting…" }
        guard let t = ph.lastSeen else { return "Listening on port \(ph.port) · no phone yet" }
        let s = Int(now.timeIntervalSince(t))
        return s < 10 ? "Phone connected" : "Last phone request \(s < 120 ? "\(s) s" : "\(s / 60) min") ago"
    }

    private var labelsPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Labels on the phone").font(.headline)
            Text("The phone uses this project's label scheme. Edit it under Picks ▸ Edit Labels…; the phone updates within a few seconds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(store.scheme.labels.filter { $0.exported }) { l in
                    HStack(spacing: 4) { Circle().fill(swiftUIColor(l.color)).frame(width: 9, height: 9); Text("\(l.key) \(l.name)").lineLimit(1) }
                        .font(.callout)
                }
            }
        }
    }

    private func confirmReset() {
        let a = NSAlert()
        a.messageText = "Reset pairing?"
        a.informativeText = "A new pairing code is made. Phones paired before (including Home Screen icons) stop working until you scan the new code."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            ph.resetPairing()
            if ph.enabled { ph.start(host: model) }
        }
    }
}
