import SwiftUI

@main
struct ThonSwipeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if case .none = model.via { ConnectView(model: model) } else { SwipeView(model: model) }
            }
            .preferredColorScheme(.dark)
            .onChange(of: phase) { _, p in
                model.active = (p == .active)
                UIApplication.shared.isIdleTimerDisabled = (p == .active)
                if p == .active { Task { await model.poll(); await model.flush() } }
            }
        }
    }
}
