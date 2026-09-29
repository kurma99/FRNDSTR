import BackgroundTasks
import SwiftUI

@main
struct FrndstrApp: App {
    @State private var app = AppModel()
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                // Gold/yellow instead of system blue for tabs, links, toggles and the text cursor.
                .tint(Theme.accent)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { Notifier.shared.app = app }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await Notifier.shared.sync(using: app) }
            case .background: Self.scheduleBackgroundRefresh()
            default: break
            }
        }
        // iOS decides when this runs (often hours apart, never after a force-quit); APNs (M9) removes the delay.
        .backgroundTask(.appRefresh(Notifier.refreshTaskID)) {
            await Self.backgroundRefresh()
        }
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Notifier.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        if let app = Notifier.shared.app {
            await Notifier.shared.sync(using: app)
        }
    }
}
