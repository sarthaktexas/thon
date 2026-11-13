import Foundation
import MultipeerConnectivity
import UIKit

/// How the app talks to Thon. Both links carry the same requests.

struct LinkResponse {
    var status: Int
    var body: Data
}

enum LinkError: Error { case offline, timeout, badURL }

protocol ThonLink: AnyObject {
    /// `path` is the plain path ("/api/card/grid3/m.mrc@k1.jpg"), not percent-encoded.
    func request(_ method: String, _ path: String, query: [String: String], body: Data?) async throws -> LinkResponse
}

extension ThonLink {
    func get(_ path: String, query: [String: String] = [:]) async throws -> LinkResponse { try await request("GET", path, query: query, body: nil) }
    func post<T: Encodable>(_ path: String, _ json: T) async throws -> LinkResponse {
        try await request("POST", path, query: [:], body: try JSONEncoder().encode(json))
    }
    func post(_ path: String) async throws -> LinkResponse { try await request("POST", path, query: [:], body: Data("{}".utf8)) }
}

// MARK: - HTTP over Wi-Fi / hotspot / USB (the Mac's existing web server)

final class HTTPLink: ThonLink {
    let base: URL          // http://host:port
    let token: String
    private let session: URLSession

    init(base: URL, token: String) {
        self.base = base; self.token = token
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8; c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    /// Accepts the link shown in Thon's Phone panel, `http://192.168.1.5:8431/?t=<token>`.
    static func parse(_ text: String) -> (base: URL, token: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: s), c.scheme == "http", let host = c.host,
              let t = c.queryItems?.first(where: { $0.name == "t" })?.value, !t.isEmpty else { return nil }
        var b = URLComponents(); b.scheme = "http"; b.host = host; b.port = c.port
        guard let url = b.url else { return nil }
        return (url, t)
    }

    func request(_ method: String, _ path: String, query: [String: String], body: Data?) async throws -> LinkResponse {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = path
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw LinkError.badURL }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(token, forHTTPHeaderField: "X-Thon-Token")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (d, resp) = try await session.data(for: r)
            return LinkResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: d)
        } catch { throw LinkError.offline }
    }
}

// MARK: - Direct link (MultipeerConnectivity): Bluetooth or phone-to-Mac Wi-Fi, no router, no internet

final class MultipeerLink: NSObject, ObservableObject, ThonLink, MCSessionDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "thon-swipe"          // keep in sync with Mac Sources/Thon/Phone/PhoneDirectLink.swift and Info.plist

    enum Status: Equatable { case idle, searching, inviting(String), connected(String), failed(String) }

    @Published private(set) var macs: [String] = []            // nearby Macs running Thon with the Phone panel on
    @Published private(set) var status: Status = .idle

    /// Main queue: the Mac sent its token after a pairing code was accepted.
    var onPaired: (_ mac: String, _ token: String) -> Void = { _, _ in }
    /// A Mac the app should reconnect to by itself when it appears (name and token from an earlier pairing).
    var preferred: (name: String, token: String)?

    private let q = DispatchQueue(label: "thon.swipe.link")
    private let me = MCPeerID(displayName: String(UIDevice.current.name.prefix(60)))
    private lazy var session: MCSession = {
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required); s.delegate = self; return s
    }()
    private lazy var browser: MCNearbyServiceBrowser = {
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType); b.delegate = self; return b
    }()
    private var found: [String: MCPeerID] = [:]
    private var server: MCPeerID?
    private var waiting: [UInt32: CheckedContinuation<LinkResponse, Error>] = [:]
    private var nextID: UInt32 = 1
    private var assembler = PhoneReassembler()

    func startBrowsing() {
        q.async { self.browser.startBrowsingForPeers(); self.setStatus(self.server == nil ? .searching : self.status) }
    }

    func stop() {
        q.async {
            self.browser.stopBrowsingForPeers(); self.session.disconnect()
            self.found = [:]; self.server = nil; self.failAll(); self.publishMacs(); self.setStatus(.idle)
        }
    }

    /// Invite `mac`, with the long-lived token if we have one, else the one-time code from the Phone panel.
    func connect(to mac: String, token: String?, code: String?) {
        q.async {
            guard let peer = self.found[mac] else { self.setStatus(.failed("\(mac) is not in range")); return }
            var ctx: [String: String] = [:]
            if let token { ctx["t"] = token } else if let code { ctx["code"] = code }
            self.setStatus(.inviting(mac))
            self.browser.invitePeer(peer, to: self.session, withContext: try? JSONSerialization.data(withJSONObject: ctx), timeout: 25)
        }
    }

    private func setStatus(_ s: Status) { DispatchQueue.main.async { if self.status != s { self.status = s } } }
    private func publishMacs() { let n = found.keys.sorted(); DispatchQueue.main.async { self.macs = n } }

    private func failAll() {
        let w = waiting; waiting = [:]
        for (_, c) in w { c.resume(throwing: LinkError.offline) }
        assembler = PhoneReassembler()
    }

    // MARK: ThonLink

    func request(_ method: String, _ path: String, query: [String: String], body: Data?) async throws -> LinkResponse {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LinkResponse, Error>) in
            q.async {
                guard let srv = self.server, self.session.connectedPeers.contains(srv) else { cont.resume(throwing: LinkError.offline); return }
                var id = self.nextID; self.nextID &+= 1; if id == 0 { id = 1 }
                self.waiting[id] = cont
                let head = PhoneWireHead(kind: "req", id: id, method: method, path: path, query: query.isEmpty ? nil : query)
                do {
                    for f in PhoneWire.frames(of: PhoneWire.pack(head, body: body ?? Data()), id: id) {
                        try self.session.send(f, toPeers: [srv], with: .reliable)
                    }
                } catch {
                    self.waiting[id] = nil; cont.resume(throwing: LinkError.offline); return
                }
                self.q.asyncAfter(deadline: .now() + 25) { if let c = self.waiting.removeValue(forKey: id) { c.resume(throwing: LinkError.timeout) } }
            }
        }
    }

    // MARK: browser

    func browser(_ b: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        q.async {
            self.found[peer.displayName] = peer; self.publishMacs()
            if let p = self.preferred, p.name == peer.displayName, self.server == nil {
                self.connect(to: p.name, token: p.token, code: nil)
            }
        }
    }

    func browser(_ b: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {
        q.async { self.found[peer.displayName] = nil; self.publishMacs() }
    }

    func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        setStatus(.failed("Search failed: \(error.localizedDescription)"))
    }

    // MARK: session

    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        q.async {
            switch state {
            case .connected: self.server = peer; self.setStatus(.connected(peer.displayName))
            case .notConnected:
                if self.server == peer { self.server = nil; self.failAll(); self.setStatus(.searching) }
                else if case .inviting = self.status { self.setStatus(.failed("Mac refused the connection. Check the pairing code.")) }
            default: break
            }
        }
    }

    func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        q.async {
            guard peer == self.server, let msg = self.assembler.feed(data), let (head, body) = PhoneWire.unpack(msg) else { return }
            switch head.kind {
            case "res":
                if let c = self.waiting.removeValue(forKey: head.id) { c.resume(returning: LinkResponse(status: head.status ?? 0, body: body)) }
            case "paired":
                if let t = head.token { let n = peer.displayName; DispatchQueue.main.async { self.onPaired(n, t) } }
            default: break
            }
        }
    }

    func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}
