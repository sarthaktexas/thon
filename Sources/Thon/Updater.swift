import SwiftUI
import Combine
import Sparkle

/// Self-update through Sparkle. The feed (`SUFeedURL`) and the EdDSA public key (`SUPublicEDKey`)
/// live in Info.plist. The updater only starts inside a packaged Thon.app that has a key, so
/// `swift run`, `.build/release/Thon --selftest` and the other command-line modes never touch it.
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController
    private var bag = Set<AnyCancellable>()

    /// True once Sparkle has been started (packaged app with a public key).
    @Published private(set) var isActive = false
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check or install is already running).
    @Published private(set) var canCheck = false
    @Published var automaticChecks: Bool {
        didSet {
            guard isActive, controller.updater.automaticallyChecksForUpdates != automaticChecks else { return }
            controller.updater.automaticallyChecksForUpdates = automaticChecks
        }
    }

    static var isConfigured: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }

    private init() {
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        automaticChecks = c.updater.automaticallyChecksForUpdates
    }

    /// Call once at launch. Sparkle then checks in the background on its own schedule
    /// (`SUScheduledCheckInterval`) and shows its own window when an update is found.
    func start() {
        guard Self.isConfigured, !isActive else { return }
        controller.startUpdater()
        isActive = true
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &bag)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// Thon ▸ Check for Updates…
struct CheckForUpdatesButton: View {
    @ObservedObject var updates = UpdateController.shared
    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
    }
}
