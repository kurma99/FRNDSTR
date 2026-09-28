import FriendsterAPI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SaveSettings.askEachTimeKey) private var askEachTime = true
    @AppStorage(SaveSettings.includeCaptionKey) private var includeCaption = true
    @AppStorage(SaveSettings.includeLocationKey) private var includeLocation = true
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system
    @AppStorage(MomentSettings.saveToPhotosKey) private var saveMomentsToPhotos = true
    @AppStorage(MomentSettings.shareAsPostKey) private var shareMomentsAsPost = false
    @AppStorage(MomentSettings.audienceKey) private var momentAudience: MomentSettings.Audience = .allFriends
    @AppStorage(MomentSettings.mirrorSelfieKey) private var mirrorSelfie = false
    @AppStorage(MomentSettings.insetCornerKey) private var insetCorner: MomentLayout.Corner = .topLeading
    @State private var confirmLogout = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearancePicker")
            }

            Section {
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    Label("Notifications", systemImage: "bell.badge")
                }
                .accessibilityIdentifier("notificationSettingsLink")
            }

            Section {
                Toggle("Ask every time", isOn: $askEachTime)
                    .accessibilityIdentifier("askEachTimeToggle")
                Toggle("Include caption", isOn: $includeCaption)
                Toggle("Include location", isOn: $includeLocation)
            } header: {
                Text("Saving to Photos")
            } footer: {
                Text(askEachTime
                     ? "You'll choose what to include each time you save. These are the preselected options."
                     : "Saved photos and videos get these details written into the file.")
            }

            Section {
                Picker("Share with", selection: $momentAudience) {
                    ForEach(MomentSettings.Audience.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Picker("Small photo", selection: $insetCorner) {
                    ForEach(MomentLayout.Corner.allCases, id: \.self) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
                Toggle("Flip selfie", isOn: $mirrorSelfie)
                Toggle("Share as a post when it's over", isOn: $shareMomentsAsPost)
                Toggle("Save my moments to Photos", isOn: $saveMomentsToPhotos)
            } header: {
                Text("Moment defaults")
            } footer: {
                Text("These are preselected each time; you can still change them before sending. Your moments are always kept in Memories on this iPhone.")
            }

            if app.isAdmin, let dashboard = app.adminDashboardURL {
                Section {
                    Link(destination: dashboard) {
                        Label("Open admin dashboard", systemImage: "safari")
                    }
                    .accessibilityIdentifier("adminDashboardLink")
                } header: {
                    Text("Admin")
                } footer: {
                    Text("People, invite codes, storage, reaction emoji and the moment time are managed in the browser.")
                }
            }

            DataExportSection()

            Section("Server") {
                LabeledContent("Name", value: app.instanceName)
                if let url = app.serverURL {
                    LabeledContent("Address", value: ServerAddress.displayString(for: url))
                }
                if let user = app.currentUser {
                    LabeledContent("Signed in as", value: "@\(user.username)")
                }
            }

            Section {
                Button("Log out", role: .destructive) { confirmLogout = true }
                    .accessibilityIdentifier("logoutButton")
                    .confirmationDialog("Log out of Friendster?", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("Log out", role: .destructive) { Task { await app.logout() } }
                    }
            }
        }
        .navigationTitle("Settings")
    }
}
