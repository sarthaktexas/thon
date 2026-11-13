import Foundation
import Network
import Security
import AppKit
import SwiftUI

/// Owns the phone server: the listening socket, the pairing token and the port. The request logic lives in `PhoneAPI`.
/// The server only listens while `running` is true (the Phone panel's switch); nothing starts at launch.
final class PhoneController: ObservableObject {
    static let shared = PhoneController()

    @Published var showPanel = false
    @Published private(set) var enabled = false          // the switch in the Phone panel
    @Published private(set) var running = false          // the socket is listening
    private var window: NSWindow?
    @Published private(set) var error: String?
    @Published private(set) var token: String
    @Published private(set) var lastSeen: Date?
    @Published private(set) var requests = 0
    @Published private(set) var directPhones: [String] = []     // phones connected over the direct link
    @Published private(set) var pairingCode = ""                // one-time code for a new phone on the direct link
    @Published private(set) var directError: String?
    @Published var directLink: Bool {                           // advertise to the ThonSwipe iPhone app
        didSet { UserDefaults.standard.set(directLink, forKey: Self.directKey) }
    }
    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Self.portKey) }
    }

    static let portKey = "phone.port", tokenKey = "phone.token", directKey = "phone.direct"
    static let defaultPort = 8431

    private var listener: NWListener?
    private var direct: PhoneDirectLink?
    private var api: PhoneAPI?
    private let netQueue = DispatchQueue(label: "thon.phone.net", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "thon.phone.render", qos: .userInitiated)    // one render at a time (CPU cap)

    private init() {
        let p = UserDefaults.standard.integer(forKey: Self.portKey)
        port = (1024...65535).contains(p) ? p : Self.defaultPort
        directLink = UserDefaults.standard.object(forKey: Self.directKey) as? Bool ?? true
        if let t = UserDefaults.standard.string(forKey: Self.tokenKey), t.count >= 32 { token = t }
        else { token = Self.makeToken(); UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    static func makeToken() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) != errSecSuccess { b = (0..<16).map { _ in UInt8.random(in: 0...255) } }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: control

    func start(host: PhoneHost) {
        stop()
        error = nil
        enabled = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { error = "Invalid port"; enabled = false; return }
        let api = PhoneAPI(host: host, token: token)
        api.iconPNG = { PhoneController.iconData() }
        self.api = api
        do {
            let l = try NWListener(using: .tcp, on: nwPort)
            l.service = NWListener.Service(name: "Thon", type: "_http._tcp")
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch st {
                    case .ready: self.running = true
                    case .failed(let e): self.error = "Server failed: \(e.localizedDescription)"; self.running = false; self.enabled = false; self.listener?.cancel(); self.listener = nil
                    case .cancelled: self.running = false
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener = l
            l.start(queue: netQueue)
            if directLink {
                let d = PhoneDirectLink(api: api, render: renderQueue)
                d.onChange = { [weak self] phones, code, err in self?.directPhones = phones; self?.pairingCode = code; self?.directError = err }
                direct = d
                d.start()
            }
        } catch {
            self.error = "Could not listen on port \(port): \(error.localizedDescription)"; enabled = false
        }
    }

    func stop() {
        listener?.cancel(); listener = nil; api = nil
        direct?.stop(); direct = nil; directPhones = []; pairingCode = ""; directError = nil
        running = false; enabled = false
    }

    /// Opens (or raises) the Phone panel as its own window.
    func openPanel(model: AppModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: PhoneView(model: model)))
        w.title = "Phone swiper"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 460, height: 640)); w.center()
        window = w; w.makeKeyAndOrderFront(nil)
    }

    /// New token: phones paired with the old one stop working.
    func resetPairing() {
        token = Self.makeToken()
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        api?.token = token
    }

    // MARK: addresses

    /// IPv4 addresses a phone could reach, with the interface they belong to.
    /// en* = Wi-Fi, Ethernet, iPhone USB / Personal Hotspot; bridge* = this Mac's own shared network (Internet Sharing) or Thunderbolt Bridge.
    static func lanInterfaces() -> [(name: String, address: String)] {
        var out: [(name: String, address: String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let i = a.pointee
            p = i.ifa_next
            let name = String(cString: i.ifa_name)
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0,
                  (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out.append((name, String(cString: host))) }
        }
        func rank(_ s: String) -> Int { s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.hasPrefix("172.") ? 0 : (s.hasPrefix("169.254.") ? 2 : 1) }
        return out.sorted { rank($0.address) < rank($1.address) }
    }

    static func lanAddresses() -> [String] { lanInterfaces().map { $0.address } }

    /// URLs a phone can open (with the token), best first.
    var urls: [String] {
        var u = Self.lanAddresses().map { "http://\($0):\(port)/?t=\(token)" }
        let hn = ProcessInfo.processInfo.hostName
        if hn.hasSuffix(".local") { u.append("http://\(hn):\(port)/?t=\(token)") }
        return u
    }

    /// Link that opens in a browser on this Mac; if it works the server is fine and any failure on the phone is the network.
    var localTestURL: URL? { URL(string: "http://127.0.0.1:\(port)/?t=\(token)") }

    static func iconData() -> Data? {
        guard let img = NSApp?.applicationIconImage else { return nil }
        let size = NSSize(width: 180, height: 180)
        let out = NSImage(size: size)
        out.lockFocus(); img.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: connections

    private func accept(_ c: NWConnection) {
        c.start(queue: netQueue)
        netQueue.asyncAfter(deadline: .now() + 20) { c.cancel() }          // idle / slow clients
        var buf = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, err in
                guard let self else { c.cancel(); return }
                if let d = data { buf.append(d) }
                switch parsePhoneRequest(buf) {
                case .incomplete: if done || err != nil { c.cancel() } else { receive() }
                case .failure(let s): self.send(PhoneResponse(status: s, contentType: "text/plain", body: Data()), on: c)
                case .request(let req): self.dispatch(req, on: c)
                }
            }
        }
        receive()
    }

    private func dispatch(_ req: PhoneRequest, on c: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let api = self.api else { self?.send(PhoneResponse(status: 503, contentType: "text/plain", body: Data()), on: c); return }
            api.serve(req, render: self.renderQueue, reply: self.netQueue, handled: { [weak self] resp in
                if resp.status != 401 { self?.lastSeen = Date(); self?.requests += 1 }
            }) { [weak self] r in self?.send(r, on: c) }
        }
    }

    private func send(_ r: PhoneResponse, on c: NWConnection) {
        c.send(content: r.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}
