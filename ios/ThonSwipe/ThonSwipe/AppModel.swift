import Foundation
import SwiftUI
import UIKit
import Combine

/// App state and the swipe logic. Port of Resources/phone/app.js: the Mac owns the deck, scheme and undo; this holds only the last state,
/// the images and the outbox of decisions the Mac has not confirmed.
@MainActor
final class AppModel: ObservableObject {
    enum Via: Equatable { case none, direct(String), wifi(String), demo }

    @Published private(set) var state: PhoneState?
    @Published private(set) var via: Via = .none
    @Published private(set) var online = true
    @Published private(set) var authBad = false
    @Published private(set) var outbox = Outbox.load()
    @Published var selectedLabel: String?
    @Published var cross = CGPoint(x: 0.5, y: 0.5)
    @Published var toast: String?
    @Published private(set) var images: [String: UIImage] = [:]
    @Published var pairingProblem: String?

    let direct = MultipeerLink()
    private var link: ThonLink?
    private var busy = false
    private var shownAt = Date()
    private var currentRef: String?
    private var lastServerActive: String?
    private var loop: Task<Void, Never>?
    private var inflight = Set<String>()
    private var order: [String] = []
    private var retry: Task<Void, Never>?
    private var stashed: Outbox?
    private var cancellables = Set<AnyCancellable>()
    var active = true                      // scene is in the foreground
    var animating = false                  // a card is flying off; do not poll or take another decision

    private let defaults = UserDefaults.standard
    private enum K { static let mac = "mac", wifi = "wifi", tokenPrefix = "mac:", wifiToken = "wifi-token" }

    init() {
        direct.onPaired = { [weak self] mac, token in self?.paired(mac: mac, token: token) }
        direct.$status.receive(on: DispatchQueue.main).sink { [weak self] s in self?.directStatus(s) }.store(in: &cancellables)
        direct.$macs.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        resume()
    }

    // MARK: connecting

    /// Reconnects to whatever was used last.
    func resume() {
        if let w = defaults.string(forKey: K.wifi), let t = Keychain.get(K.wifiToken), let u = URL(string: w) {
            use(HTTPLink(base: u, token: t), via: .wifi(w)); return
        }
        if let mac = defaults.string(forKey: K.mac), let t = Keychain.get(K.tokenPrefix + mac) {
            direct.preferred = (mac, t)
        }
        direct.startBrowsing()
    }

    func connectDirect(mac: String, code: String) {
        pairingProblem = nil
        let known = Keychain.get(K.tokenPrefix + mac)
        direct.connect(to: mac, token: code.isEmpty ? known : nil, code: code.isEmpty ? nil : code)
    }

    private func paired(mac: String, token: String) {
        Keychain.set(token, for: K.tokenPrefix + mac); defaults.set(mac, forKey: K.mac)
        direct.preferred = (mac, token)
    }

    private func directStatus(_ s: MultipeerLink.Status) {
        switch s {
        case .connected(let mac):
            defaults.set(mac, forKey: K.mac)
            if case .wifi = via { return }
            if case .demo = via { return }
            use(direct, via: .direct(mac))
        case .failed(let m): pairingProblem = m
        case .searching, .idle, .inviting:
            if case .direct = via { link = nil; via = .none; loop?.cancel(); online = false }
        }
    }

    /// `text` is the link from Thon's Phone panel, http://<address>:<port>/?t=<token>
    func connectWiFi(_ text: String) -> Bool {
        guard let (base, token) = HTTPLink.parse(text) else { pairingProblem = "That is not a Thon link. Copy the link from the Phone panel."; return false }
        defaults.set(base.absoluteString, forKey: K.wifi); Keychain.set(token, for: K.wifiToken)
        direct.stop()
        use(HTTPLink(base: base, token: token), via: .wifi(base.absoluteString))
        return true
    }

    /// Made-up cards and an in-memory Thon, to try the app or take Simulator screenshots without a Mac.
    func startDemo() {
        direct.stop()
        stashed = outbox                                     // real decisions waiting for a Mac stay safe; demo decisions are never saved
        outbox = Outbox(); selectedLabel = nil; currentRef = nil; state = nil; images = [:]; order = []; inflight = []
        use(DemoLink(), via: .demo)
    }

    private func saveOutbox() { if via != .demo { outbox.save() } }

    func disconnect(forget: Bool) {
        if via == .demo { outbox = stashed ?? Outbox(); stashed = nil }
        loop?.cancel(); link = nil; via = .none; state = nil; images = [:]; order = []; inflight = []
        direct.stop()
        if forget {
            if let mac = defaults.string(forKey: K.mac) { Keychain.remove(K.tokenPrefix + mac) }
            Keychain.remove(K.wifiToken); defaults.removeObject(forKey: K.mac); defaults.removeObject(forKey: K.wifi); direct.preferred = nil
        }
        direct.startBrowsing()
    }

    private func use(_ l: ThonLink, via v: Via) {
        link = l; via = v; authBad = false; online = true; pairingProblem = nil
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.poll(); await self?.flush()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000); await self?.poll() }
        }
    }

    // MARK: requests

    private struct Reply { var status: Int; var data: Data }

    private func call(_ path: String, body: Encodable? = nil, query: [String: String] = [:]) async -> Reply? {
        guard let link else { return nil }
        do {
            let r: LinkResponse
            if let body { r = try await link.request("POST", path, query: [:], body: try JSONEncoder().encode(AnyEncodable(body))) }
            else { r = try await link.request("GET", path, query: query, body: nil) }
            if r.status == 401 { authBad = true; return Reply(status: 401, data: r.body) }
            authBad = false; online = true
            return Reply(status: r.status, data: r.body)
        } catch { online = false; return nil }
    }

    private func decodeState(_ r: Reply?) -> PhoneState? {
        guard let r, r.status == 200 else { return nil }
        return try? JSONDecoder().decode(PhoneState.self, from: r.data)
    }

    func poll() async {
        guard active, !busy, !animating, outbox.items.isEmpty, link != nil else { return }
        if let s = decodeState(await call("/api/state")) { apply(s) }
    }

    private func apply(_ s: PhoneState) {
        state = s
        if s.activeLabel != lastServerActive { lastServerActive = s.activeLabel; selectedLabel = s.activeLabel }
        if !s.exportedLabels.contains(where: { $0.id == selectedLabel }) { selectedLabel = s.activeLabel }
        syncCurrent()
        prefetch()
    }

    // MARK: deck

    var deck: [String] { state.map { outbox.deck(from: $0) } ?? [] }

    private func syncCurrent() {
        guard let first = deck.first, first != currentRef else { return }
        currentRef = first; shownAt = Date()
        if let c = state?.card, c.ref == first, c.cross.count == 2 { cross = CGPoint(x: c.cross[0], y: c.cross[1]) } else { cross = CGPoint(x: 0.5, y: 0.5) }
    }

    func decide(_ kind: Decision) {
        guard let ref = deck.first else { return }
        let b = Outbox.decision(ref: ref, kind: kind, label: selectedLabel, cross: (Double(cross.x), Double(cross.y)),
                                dwellMs: Int(Date().timeIntervalSince(shownAt) * 1000))
        outbox.enqueue(b); saveOutbox()
        syncCurrent(); prefetch()
        UIImpactFeedbackGenerator(style: kind == .pick ? .medium : .light).impactOccurred()
        Task { await flush() }
    }

    func flush() async {
        guard !busy, link != nil else { return }
        busy = true; retry?.cancel()
        defer { busy = false }
        while let it = outbox.items.first {
            guard let r = await call("/api/decision", body: it), r.status != 401 else { scheduleRetry(); return }
            let reply = try? JSONDecoder().decode(DecisionReply.self, from: r.data)
            outbox.complete(status: r.status, reason: reply?.reason); saveOutbox()
            if let s = reply?.state { apply(s) }
        }
        syncCurrent()
    }

    private func scheduleRetry() {
        retry = Task { [weak self] in try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { await self?.flush() } }
    }

    func undo() async {
        guard outbox.items.isEmpty, !busy else { show("Syncing first"); return }
        guard let r = await call("/api/undo", body: EmptyBody()) else { return }
        let reply = try? JSONDecoder().decode(DecisionReply.self, from: r.data)
        if reply?.applied == false { show("Nothing to undo") }
        if let s = reply?.state { apply(s) }
    }

    func chooseLabel(_ id: String) {
        selectedLabel = id
        Task { if let r = await call("/api/label", body: LabelBody(id: id)), let s = (try? JSONDecoder().decode(StateReply.self, from: r.data))?.state { lastServerActive = s.activeLabel } }
    }

    func level(_ action: String) async {
        guard outbox.items.isEmpty else { show("Syncing first"); return }
        guard let r = await call("/api/level", body: ActionBody(action: action)) else { return }
        if r.status == 409 { show("No further micrograph") }
        if let s = (try? JSONDecoder().decode(StateReply.self, from: r.data))?.state { apply(s) }
    }

    func autopick() async {
        if let r = await call("/api/autopick", body: EmptyBody()), let s = (try? JSONDecoder().decode(StateReply.self, from: r.data))?.state { apply(s) }
    }

    func show(_ m: String) {
        toast = m
        Task { try? await Task.sleep(nanoseconds: 2_200_000_000); if toast == m { toast = nil } }
    }

    // MARK: images

    func cardURLPath(_ ref: String) -> String { "/api/card/\(ref).jpg" }

    private func prefetch() {
        let claimed = deck.prefix(6).filter { images[$0] == nil && !inflight.contains($0) }
        guard !claimed.isEmpty else { return }
        inflight.formUnion(claimed)
        Task { [weak self] in
            for ref in claimed {
                guard let self else { return }
                let r = await self.call(self.cardURLPath(ref), query: ["out": "480"])
                self.inflight.remove(ref)
                if let r, r.status == 200, let img = UIImage(data: r.data) {
                    self.images[ref] = img; self.order.append(ref)
                    if self.order.count > 40 { self.images[self.order.removeFirst()] = nil }
                }
            }
        }
    }
}

private struct EmptyBody: Encodable {}
private struct LabelBody: Encodable { var id: String }
private struct ActionBody: Encodable { var action: String }
private struct AnyEncodable: Encodable {
    let wrapped: Encodable
    init(_ w: Encodable) { wrapped = w }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}
