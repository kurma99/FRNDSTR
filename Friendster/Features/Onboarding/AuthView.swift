import SwiftUI

/// Log in, or sign up with an invite code from the server admin.
struct AuthView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case login = "Log in"
        case signUp = "Sign up"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var app
    @State private var mode: Mode = .login
    @State private var inviteCode = ""
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        let base = !username.isEmpty && password.count >= (mode == .signUp ? 8 : 1)
        return mode == .login ? base : base && !inviteCode.isEmpty && !displayName.isEmpty
    }

    var body: some View {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 4) {
                        Wordmark(size: 52)
                        Text(app.instanceName)
                            .font(.subheadline.weight(.semibold))
                            .opacity(0.85)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 60)

                    Picker("Mode", selection: $mode.animation(.snappy)) {
                        ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            if mode == .signUp {
                                field("Invite code", text: $inviteCode)
                                    .textInputAutocapitalization(.characters)
                                    .accessibilityIdentifier("inviteField")
                                field("Your name", text: $displayName)
                                    .textContentType(.name)
                                    .textInputAutocapitalization(.words)
                                    .accessibilityIdentifier("nameField")
                            }
                            field("Username", text: $username)
                                .textContentType(.username)
                                .accessibilityIdentifier("usernameField")
                            SecureField(text: $password, prompt: Text("Password").foregroundStyle(Theme.ink.opacity(0.55))) { Text("Password") }
                                .textContentType(mode == .signUp ? .newPassword : .password)
                                .modifier(GlassFieldStyle())
                                .accessibilityIdentifier("passwordField")
                        }
                    }

                    Button(action: submit) {
                        Group {
                            if isWorking { ProgressView() } else { Text(LocalizedStringKey(mode.rawValue)) }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                    }
                    .primaryButtonStyle()
                    .controlSize(.large)
                    .disabled(!canSubmit || isWorking)
                    .accessibilityIdentifier("submitButton")

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.tint(.red.opacity(0.2)), in: .rect(cornerRadius: 16))
                            .foregroundStyle(Theme.ink)
                            .transition(.blurReplace)
                    }

                    if mode == .signUp {
                        Text("Ask the person who runs the server for an invite code. Passwords need at least 8 characters.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.ink.opacity(0.8))
                    }

                    Button {
                        app.disconnectServer()
                    } label: {
                        Label("Change server", systemImage: "server.rack")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.glass)
                    .padding(.top, 8)
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(text: text, prompt: Text(title).foregroundStyle(Theme.ink.opacity(0.55))) { Text(title) }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .modifier(GlassFieldStyle())
    }

    private func submit() {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                switch mode {
                case .login:
                    try await app.login(username: username, password: password)
                case .signUp:
                    try await app.register(inviteCode: inviteCode, username: username,
                                           displayName: displayName, password: password)
                }
            } catch {
                withAnimation { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct GlassFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .frame(height: 52)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

#Preview {
    AuthView()
        .environment(AppModel())
}
