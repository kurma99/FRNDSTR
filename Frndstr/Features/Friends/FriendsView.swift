import FrndstrAPI
import SwiftUI

/// Requests, friends and the rest of the family. Friends are who you'll share Moments with.
struct FriendsView: View {
    let model: FriendsModel

    @Environment(AppModel.self) private var app

    var body: some View {
        let others = model.others(excluding: app.currentUser?.id)
        List {
            if !model.overview.incoming.isEmpty {
                Section("Requests") {
                    ForEach(model.overview.incoming) { user in
                        PersonRow(user: user) {
                            HStack(spacing: 8) {
                                Button("Accept") { Task { await model.add(user, using: app) } }
                                    .primaryButtonStyle()
                                    .accessibilityIdentifier("accept-\(user.username)")
                                Button("Decline", systemImage: "xmark") { Task { await model.remove(user, using: app) } }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.circle)
                            }
                        }
                    }
                }
            }

            Section("Friends") {
                if model.overview.friends.isEmpty {
                    Text(others.isEmpty
                         ? "No friends yet. Friends are who you'll share your daily moments with."
                         : "No friends yet. Add family members below to share your daily moments with them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.overview.friends) { user in
                    PersonRow(user: user, streak: model.streaks[user.id]) {
                        Menu {
                            Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) {
                                Task { await model.remove(user, using: app) }
                            }
                        } label: {
                            Label("Friends", systemImage: "checkmark")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.glass)
                    }
                }
            }

            if !model.overview.outgoing.isEmpty {
                Section("Sent requests") {
                    ForEach(model.overview.outgoing) { user in
                        PersonRow(user: user) {
                            Button("Requested") { Task { await model.remove(user, using: app) } }
                                .buttonStyle(.glass)
                                .accessibilityHint("Cancels the request")
                        }
                    }
                }
            }

            if !others.isEmpty {
                Section("Family on \(app.instanceName)") {
                    ForEach(others) { user in
                        PersonRow(user: user) {
                            Button { Task { await model.add(user, using: app) } } label: {
                                Label("Add", systemImage: "person.badge.plus")
                                    .foregroundStyle(.white)
                            }
                                .primaryButtonStyle()
                                .accessibilityIdentifier("add-\(user.username)")
                        }
                    }
                }
            }
        }
        .overlay {
            if !model.hasLoaded { ProgressView() }
        }
        .refreshable { await model.refresh(using: app) }
        .task { await model.refresh(using: app) }
        .navigationTitle("Friends")
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct PersonRow<Accessory: View>: View {
    let user: UserDTO
    var streak: StreakDTO? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: user) {
                HStack(spacing: 12) {
                    AvatarView(user: user, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName).font(.body.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(verbatim: "@\(user.username)").font(.caption).foregroundStyle(.secondary)
                            if let streak, streak.count > 0 { StreakBadge(streak: streak) }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            accessory
                .controlSize(.small)
        }
    }
}

/// 🔥 count, turning orange with an hourglass when it would end at midnight.
struct StreakBadge: View {
    let streak: StreakDTO

    var body: some View {
        HStack(spacing: 2) {
            Text("🔥")
            Text(streak.count, format: .number).monospacedDigit()
            if streak.isAtRisk { Image(systemName: "hourglass") }
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(streak.isAtRisk ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(streak.isAtRisk
                            ? "\(streak.count) day streak, ends at midnight unless you both share a moment"
                            : "\(streak.count) day streak")
    }
}
