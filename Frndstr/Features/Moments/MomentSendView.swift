import FrndstrAPI
import SwiftUI

/// Capture → edit → send, as one full-screen flow.
struct MomentFlowView: View {
    let model: MomentsModel
    let friends: FriendsModel

    private enum Step { case capture, edit, send }

    @State private var step: Step = .capture
    @State private var photos: (back: UIImage, front: UIImage)?
    // Kept here so Back/Next never lose what the user chose.
    @State private var draft = MomentDraft.fromSettings()
    @State private var options = ShareOptions.fromSettings()

    var body: some View {
        switch step {
        case .capture:
            MomentCaptureView { back, front in
                photos = (back, front)
                step = .edit
            }
        case .edit:
            if let photos {
                MomentEditView(original: photos, draft: $draft, onRetake: {
                    draft = .fromSettings()
                    step = .capture
                }, onNext: { step = .send })
            }
        case .send:
            if let photos {
                MomentSendView(moment: draft.apply(to: photos), options: $options, model: model, friends: friends) {
                    step = .edit
                }
            }
        }
    }
}

/// Share choices, kept by the flow while the user goes back to edit.
struct ShareOptions {
    var audience: MomentSettings.Audience
    var selected: Set<UUID>
    var shareAsPost: Bool
    var saveToPhotos: Bool

    /// Starts from the defaults in Settings and last time's selection.
    static func fromSettings() -> ShareOptions {
        let defaults = UserDefaults.standard
        return ShareOptions(
            audience: defaults.string(forKey: MomentSettings.audienceKey).flatMap(MomentSettings.Audience.init(rawValue:)) ?? .allFriends,
            selected: MomentSettings.lastSelected,
            shareAsPost: defaults.bool(forKey: MomentSettings.shareAsPostKey),
            saveToPhotos: defaults.object(forKey: MomentSettings.saveToPhotosKey) as? Bool ?? true
        )
    }
}

/// Step 3: who gets it (all friends or selected friends), and what else happens with it.
struct MomentSendView: View {
    let moment: EditedMoment
    @Binding var options: ShareOptions
    let model: MomentsModel
    let friends: FriendsModel
    var onBack: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var warnings: [String] = []

    private var allFriends: [UserDTO] { friends.overview.friends }
    private var recipients: [UserDTO] {
        options.audience == .allFriends ? allFriends : allFriends.filter { options.selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 14) {
                        MomentPhotos(source: .local(back: moment.back, front: moment.front), layout: moment.layout,
                                     cornerRadius: 14, insetFraction: 0.34)
                            .frame(width: 110)
                            .allowsHitTesting(false)
                        Text(moment.caption.isEmpty ? String(localized: "No caption") : moment.caption)
                            .font(.subheadline)
                            .foregroundStyle(moment.caption.isEmpty ? .secondary : .primary)
                    }

                    audienceSection
                    optionsSection
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) { sendBar }
            .navigationTitle("Share moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", systemImage: "chevron.backward", action: onBack)
                        .disabled(isSending)
                        .accessibilityIdentifier("sendBackButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .disabled(isSending)
                }
            }
            .task {
                await friends.refresh(using: app)
                // Drop people who are no longer friends.
                options.selected.formIntersection(allFriends.map(\.id))
            }
            .alert("Couldn't send", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Sent, with a note", isPresented: Binding(
                get: { !warnings.isEmpty }, set: { if !$0 { warnings = []; dismiss() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(warnings.joined(separator: "\n\n"))
            }
        }
    }

    // MARK: Sections

    private var audienceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share with").font(.headline)

            Picker("Share with", selection: $options.audience.animation(.snappy)) {
                ForEach(MomentSettings.Audience.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("audiencePicker")

            if !friends.hasLoaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if allFriends.isEmpty {
                Text("You don't have friends yet. Add family members in Friends to send them moments.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if options.audience == .allFriends {
                Text("All ^[\(allFriends.count) friend](inflect: true): \(allFriends.map(\.displayName).formatted(.list(type: .and)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                friendList
            }
        }
    }

    private var friendList: some View {
        VStack(spacing: 0) {
            ForEach(allFriends) { friend in
                Button {
                    withAnimation(.snappy) {
                        if options.selected.contains(friend.id) { options.selected.remove(friend.id) } else { options.selected.insert(friend.id) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(user: friend, size: 38, showsRing: false)
                        Text(friend.displayName).font(.body)
                        if let streak = friends.streaks[friend.id], streak.count > 0 {
                            StreakBadge(streak: streak)
                        }
                        Spacer()
                        Image(systemName: options.selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(options.selected.contains(friend.id) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    }
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(options.selected.contains(friend.id) ? "Selected" : "Not selected")
                .accessibilityIdentifier("recipient-\(friend.username)")
            }
        }
        .padding(.horizontal, 14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
    }

    private var optionsSection: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $options.shareAsPost) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share as a post when it's over")
                    Text("After 24 hours it appears in the feed for everyone on \(app.instanceName), dated to when you took it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .accessibilityIdentifier("sharePostToggle")
            Divider()
            Toggle(isOn: $options.saveToPhotos) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save to my Photos")
                    Text("Your friends can't save it. It disappears for them after 24 hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 10)
            .accessibilityIdentifier("saveMomentToggle")
        }
        .padding(.horizontal, 14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
    }

    private var sendBar: some View {
        Button(action: send) {
            Group {
                if isSending {
                    ProgressView()
                } else if recipients.isEmpty {
                    Text(options.audience == .selectedFriends ? "Choose who gets it" : "No friends yet")
                } else if options.audience == .allFriends {
                    Text("Send to all friends")
                } else {
                    Text("Send to ^[\(recipients.count) friend](inflect: true)")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .primaryButtonStyle()
        .controlSize(.large)
        .disabled(recipients.isEmpty || isSending)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // Fade the content out under the button so rows never show through it.
        .background {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("sendMomentButton")
    }

    private func send() {
        if options.audience == .selectedFriends { MomentSettings.lastSelected = options.selected }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let result = try await model.send(moment, to: recipients, shareAsPost: options.shareAsPost,
                                                  saveToPhotos: options.saveToPhotos, using: app)
                if result.warnings.isEmpty { dismiss() } else { warnings = result.warnings }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
