import SwiftUI

/// First screen: pick the Mac found over the direct link and enter the one-time code once; or paste the Wi-Fi link.
struct ConnectView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var link: MultipeerLink
    @State private var code = ""
    @State private var chosen: String?
    @State private var pasted = ""

    init(model: AppModel) { self.model = model; self.link = model.direct }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if link.macs.isEmpty {
                        HStack { ProgressView(); Text("Looking for Thon on a nearby Mac…").foregroundStyle(.secondary) }
                        Text("On the Mac: open a micrograph, then Picks ▸ Phone Swiper, and switch Allow phone connections on. Bluetooth and Wi-Fi must be on here, but no router or internet is needed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(link.macs, id: \.self) { mac in
                        Button { chosen = mac; model.connectDirect(mac: mac, code: "") } label: {
                            HStack { Image(systemName: "desktopcomputer"); Text(mac); Spacer(); if chosen == mac { statusView } }
                        }
                    }
                    if chosen != nil {
                        TextField("6-digit code from the Mac (first time only)", text: $code).keyboardType(.numberPad)
                        Button("Pair with code") { if let m = chosen { model.connectDirect(mac: m, code: code.trimmingCharacters(in: .whitespaces)) } }
                            .disabled(code.count != 6)
                    }
                } header: { Text("Direct link (no Wi-Fi needed)") }

                Section {
                    TextField("http://192.168.1.5:8431/?t=…", text: $pasted).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Connect over network") { _ = model.connectWiFi(pasted) }.disabled(pasted.isEmpty)
                } header: { Text("Same network instead") } footer: {
                    Text("Copy the link from Thon's Phone panel (Copy link) and paste it here. Works on Wi-Fi, an iPhone hotspot or USB.")
                }

                Section {
                    Button("Try the demo (made-up cards, no Mac needed)") { model.startDemo() }
                }

                if let p = model.pairingProblem { Section { Text(p).foregroundStyle(.red) } }
            }
            .navigationTitle("Thon Swipe")
        }
    }

    @ViewBuilder private var statusView: some View {
        switch link.status {
        case .inviting: ProgressView()
        case .connected: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: EmptyView()
        }
    }
}
