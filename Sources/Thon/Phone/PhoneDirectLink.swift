import Foundation
import MultipeerConnectivity
import Security

/// Direct link to the ThonSwipe iPhone app over MultipeerConnectivity: Bluetooth or phone-to-Mac Wi-Fi, no router and no internet.
/// Requests from the phone are the same `PhoneRequest`s the web client sends over HTTP and go through the same `PhoneAPI`.
///
/// Pairing: the phone is let in when its invitation carries the long-lived token (`t`) or the one-time code shown in the Phone panel (`code`).
/// A phone that used the code is then sent the token, so it never needs the code again. Five wrong codes lock pairing by codes for a minute
/// (doubling each time) and make a new code. The MCSession is encrypted (`.required`).
final class PhoneDirectLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate {
    static let serviceType = "thon-swipe"          // keep in sync with the iOS app and the two NSBonjourServices entries

    /// Called on the main queue: names of connected phones, the code to show, and an error text (nil if none).
    var onChange: (_ phones: [String], _ code: String, _ error: String?) -> Void = { _, _, _ in }

    private let api: PhoneAPI
    private let render: DispatchQueue
    private let q = DispatchQueue(label: "thon.phone.direct", qos: .userInitiated)
    private let me: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private var code = ""
    private var failures = 0, lockouts = 0
    private var lockedUntil = Date.distantPast
    private var partial: [MCPeerID: PhoneReassembler] = [:]
    private var byCode: Set<MCPeerID> = []
    private var lastError: String?

    init(api: PhoneAPI, render: DispatchQueue) {
        self.api = api; self.render = render
        let name = Host.current().localizedName ?? "Mac"
        me = MCPeerID(displayName: String(name.prefix(60)))
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    func start() {
        q.async { self.newCode(); self.lastError = nil; self.notify() }
        advertiser.startAdvertisingPeer()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
    }

    static func makeCode() -> String {
        var v: UInt32 = 0
        if SecRandomCopyBytes(kSecRandomDefault, 4, &v) != errSecSuccess { v = UInt32.random(in: 0...UInt32.max) }
        return String(format: "%06d", Int(v % 1_000_000))
    }

    // MARK: state (queue `q`)

    private func newCode() { code = Self.makeCode() }

    private func notify() {
        let phones = session.connectedPeers.map { $0.displayName }, c = code, e = lastError
        DispatchQueue.main.async { self.onChange(phones, c, e) }
    }

    // MARK: invitations

    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID, withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        q.async {
            let ctx = (context.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            var ok = false
            if let t = ctx["t"] as? String, phoneTokenEqual(t, self.api.token) { ok = true }
            else if let c = ctx["code"] as? String, Date() >= self.lockedUntil {
                if phoneTokenEqual(c, self.code) {
                    ok = true; self.byCode.insert(peer); self.failures = 0; self.newCode()       // one-time code
                } else {
                    self.failures += 1
                    if self.failures >= 5 {
                        self.failures = 0; self.lockouts += 1
                        self.lockedUntil = Date().addingTimeInterval(60 * pow(2, Double(min(self.lockouts - 1, 6))))
                        self.newCode()
                    }
                }
            }
            invitationHandler(ok, ok ? self.session : nil)
            self.notify()
        }
    }

    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        q.async { self.lastError = "Direct link could not start: \(error.localizedDescription)"; self.notify() }
    }

    // MARK: session

    func session(_ s: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        q.async {
            switch state {
            case .connected:
                if self.byCode.remove(peer) != nil {
                    let m = PhoneWire.pack(PhoneWireHead(kind: "paired", token: self.api.token))
                    self.send(m, id: 0, to: peer)
                }
            case .notConnected:
                self.partial[peer] = nil; self.byCode.remove(peer)
            default: break
            }
            self.notify()
        }
    }

    func session(_ s: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        q.async {
            let ra = self.partial[peer] ?? PhoneReassembler()
            self.partial[peer] = ra
            guard let msg = ra.feed(data), let (head, body) = PhoneWire.unpack(msg), head.kind == "req",
                  let method = head.method, let path = head.path else { return }
            let id = head.id
            if body.count > PhoneLimits.maxBody { self.reply(PhoneResponse.error(413, "too large"), id: id, to: peer); return }
            var headers = (head.headers ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
            headers["x-thon-token"] = self.api.token                  // the invitation already authenticated this phone
            let req = PhoneRequest(method: method.uppercased(), path: path, query: head.query ?? [:], headers: headers, body: body)
            self.api.serve(req, render: self.render, reply: self.q) { resp in self.reply(resp, id: id, to: peer) }
        }
    }

    private func reply(_ r: PhoneResponse, id: UInt32, to peer: MCPeerID) {
        let head = PhoneWireHead(kind: "res", id: id, status: r.status, contentType: r.contentType)
        send(PhoneWire.pack(head, body: r.body), id: id, to: peer)
    }

    private func send(_ message: Data, id: UInt32, to peer: MCPeerID) {
        guard session.connectedPeers.contains(peer) else { return }
        for f in PhoneWire.frames(of: message, id: id) {
            do { try session.send(f, toPeers: [peer], with: .reliable) } catch { return }
        }
    }

    func session(_ s: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension PhoneAPI {
    /// Runs `req` through `handle` on the main thread (the API touches PickStore), renders deferred JPEGs on `render`, and delivers the
    /// response on `queue`. `handled` runs on the main thread with the response before any rendering.
    func serve(_ req: PhoneRequest, render: DispatchQueue, reply queue: DispatchQueue,
               handled: @escaping (PhoneResponse) -> Void = { _ in }, done: @escaping (PhoneResponse) -> Void) {
        let go = {
            let resp = self.handle(req)
            handled(resp)
            if let job = resp.deferred { render.async { let r = job(); queue.async { done(r) } } }
            else { queue.async { done(resp) } }
        }
        if Thread.isMainThread { go() } else { DispatchQueue.main.async(execute: go) }
    }
}
