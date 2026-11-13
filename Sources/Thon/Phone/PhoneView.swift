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
            Text("Swipe through the candidates of the micrograph open in Thon on your phone. Decisions go straight into this project. The phone and this Mac need a network between them (same Wi-Fi, a phone hotspot or a USB cable); it does not need internet.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Allow phone connections", isOn: Binding(get: { ph.enabled }, set: { on in if on { ph.start(host: model) } else { ph.stop() } }))
                .toggleStyle(.switch)
            if let e = ph.error { Text(e).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }

            if ph.enabled { directBox; pairing } else { settings }

            Divider()
            troubleshooting
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
            Toggle("Direct link for the ThonSwipe iPhone app (Bluetooth / phone-to-Mac Wi-Fi, no router)", isOn: $ph.directLink)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Reset pairing…") { confirmReset() }.controlSize(.small)
        }
    }

    /// Pairing code and connected phones of the direct link (the ThonSwipe iPhone app).
    @ViewBuilder private var directBox: some View {
        if ph.directLink {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Direct link").font(.headline)
                    Text("ThonSwipe app, no Wi-Fi needed").font(.caption).foregroundStyle(.secondary)
                }
                if let e = ph.directError { Text(e).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Pairing code")
                    Text(ph.pairingCode.isEmpty ? "…" : ph.pairingCode).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                    Text("(use once, in the app)").font(.caption).foregroundStyle(.secondary)
                }
                Text(ph.directPhones.isEmpty ? "No phone connected." : "Connected: " + ph.directPhones.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
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
                Text(ph.running ? "No network address found. Join a Wi-Fi or hotspot, or plug in the phone (see \"Can't connect?\" below)." : "Starting…").foregroundStyle(.secondary)
            }
            ForEach(urls, id: \.self) { u in
                Text(u).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            }
            Text("Addresses by interface: " + PhoneController.lanInterfaces().map { "\($0.name) \($0.address)" }.joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy link") {
                    if let u = urls.first { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
                }.controlSize(.small).disabled(urls.isEmpty)
                Button("Test on this Mac") { if let u = ph.localTestURL { NSWorkspace.shared.open(u) } }.controlSize(.small)
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

    private var troubleshooting: some View {
        DisclosureGroup("Can't connect? Options without a router or internet") {
            VStack(alignment: .leading, spacing: 6) {
                Text("First press Test on this Mac. If the page opens there, Thon is fine and the network is blocking the phone (campus Wi-Fi often does). If the page does not open, turn the switch off and on, or change the port.")
                Text("1. iPhone hotspot (no internet needed): on the iPhone turn on Personal Hotspot, join it from this Mac's Wi-Fi menu, then turn the Phone switch off and on and scan the new code.")
                Text("2. USB cable: plug the iPhone in, turn on Personal Hotspot, and choose it in System Settings ▸ Network (iPhone USB). Thon lists its address above; type it into Safari if the code does not scan.")
                Text("3. This Mac as the network: System Settings ▸ General ▸ Sharing ▸ Internet Sharing, share to Wi-Fi, join that network from the phone. Needs an Ethernet or Thunderbolt source; the address shows here as bridge100.")
                Text("4. Firewall: if macOS asked to allow incoming connections for Thon, choose Allow. Check System Settings ▸ Network ▸ Firewall ▸ Options.")
                Text("5. iPhone: Settings ▸ Privacy & Security ▸ Local Network, allow Safari. Turn Private Relay off for this network; use http:// not https://.")
            }.font(.caption).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
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
