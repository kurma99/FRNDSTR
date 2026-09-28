import FriendsterAPI
import SwiftUI
import UserNotifications

/// Per-type notification switches, plus the system permission state.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            if status == .denied {
                Section {
                    Label("Notifications are turned off for Friendster.", systemImage: "bell.slash")
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                    }
                }
            } else if status == .notDetermined {
                Section {
                    Button("Allow notifications") {
                        Task {
                            await Notifier.shared.requestAuthorizationIfNeeded()
                            await refreshStatus()
                        }
                    }
                }
            }

            Section {
                ForEach([NotificationSettings.Kind.moments, .posts, .commentsAndReactions, .friendRequests]) { kind in
                    SettingToggle(kind: kind)
                }
            } header: {
                Text("Tell me about")
            } footer: {
                Text("Friendster checks for news when you open it and from time to time in the background. iOS decides how often, so alerts can arrive late until push notifications are added.")
            }

            Section {
                SettingToggle(kind: .dailyMomentTime)
                SettingToggle(kind: .streakReminder)
            } header: {
                Text("Reminders")
            } footer: {
                Text("The moment time is the same for the whole family and changes every day (\(app.momentWindow.startHour):00–\(app.momentWindow.endHour):00). The streak reminder only comes if a streak would end at midnight.")
            }
        }
        .navigationTitle("Notifications")
        .task { await refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshStatus() } }
        }
    }

    private func refreshStatus() async {
        status = await Notifier.shared.authorizationStatus()
    }
}

private struct SettingToggle: View {
    let kind: NotificationSettings.Kind
    @Environment(AppModel.self) private var app
    @AppStorage private var isOn: Bool

    init(kind: NotificationSettings.Kind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.defaultValue, kind.key)
    }

    var body: some View {
        Toggle(String(localized: kind.title), isOn: $isOn)
            .onChange(of: isOn) {
                // Re-plan the reminders right away.
                Task { await Notifier.shared.sync(using: app) }
            }
            .accessibilityIdentifier("notify-\(kind.rawValue)")
    }
}
