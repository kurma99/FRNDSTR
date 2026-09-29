import SwiftUI

/// First screen: enter the address of the family's self-hosted server.
struct ConnectServerView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var usesCloudflareAccess = false
    @State private var accessClientID = ""
    @State private var accessClientSecret = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            BrandBackground()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 6) {
                    Wordmark(size: 64)
                    Text("Your family's private feed")
                        .font(.headline)
                        .opacity(0.9)
                }
                .foregroundStyle(Theme.ink)

                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        TextField("Server address", text: $address, prompt: Text(verbatim: "192.168.1.20:8080").foregroundStyle(Theme.ink.opacity(0.55)))
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($fieldFocused)
                            .onSubmit(connect)
                            .padding(.horizontal, 20)
                            .frame(height: 54)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .accessibilityIdentifier("serverAddressField")

                        if usesCloudflareAccess {
                            credentialField("Client ID", text: $accessClientID, isSecret: false)
                                .accessibilityIdentifier("cfAccessClientIDField")
                            credentialField("Client Secret", text: $accessClientSecret, isSecret: true)
                                .accessibilityIdentifier("cfAccessClientSecretField")
                        }

                        Button(action: connect) {
                            Group {
                                if isConnecting {
                                    ProgressView()
                                } else {
                                    Text("Connect")
                                }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                        }
                        .primaryButtonStyle()
                        .controlSize(.large)
                        .disabled(!canConnect)
                        .accessibilityIdentifier("connectButton")
                    }
                }

                Toggle(isOn: $usesCloudflareAccess.animation()) {
                    Label("Cloudflare Access", systemImage: "lock.shield")
                        .font(.subheadline.weight(.medium))
                }
                .tint(Theme.ink.opacity(0.7))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .accessibilityHint("Turn on if your server is published through a Cloudflare Tunnel protected by Cloudflare Access.")
                .accessibilityIdentifier("cfAccessToggle")

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

                Spacer()

                Text(usesCloudflareAccess
                     ? LocalizedStringKey("Enter your tunnel's address (e.g. https://frndstr.example.com) and a service token from Cloudflare Zero Trust › Access › Service Auth. Your Access policy needs a Service Auth rule for that token.")
                     : "Enter the address and port of your Frndstr server. Plain http works fine on your home network or over Tailscale (e.g. 100.x.y.z:8080).")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink.opacity(0.8))
            }
            .padding(24)
        }
        .onAppear {
            if let url = app.serverURL { address = ServerAddress.displayString(for: url) }
            if let access = app.cloudflareAccess {
                usesCloudflareAccess = true
                accessClientID = access.clientID
                accessClientSecret = access.clientSecret
            }
        }
    }

    private var accessToken: CloudflareAccess? {
        usesCloudflareAccess ? CloudflareAccess(clientID: accessClientID, clientSecret: accessClientSecret) : nil
    }

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !isConnecting
            && (!usesCloudflareAccess || accessToken != nil)
    }

    private func credentialField(_ title: LocalizedStringKey, text: Binding<String>, isSecret: Bool) -> some View {
        Group {
            if isSecret {
                SecureField(title, text: text, prompt: Text(title).foregroundStyle(Theme.ink.opacity(0.55)))
            } else {
                TextField(title, text: text, prompt: Text(title).foregroundStyle(Theme.ink.opacity(0.55)))
            }
        }
        .textContentType(.none)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($fieldFocused)
        .padding(.horizontal, 20)
        .frame(height: 54)
        .glassEffect(.regular.interactive(), in: .capsule)
        .transition(.blurReplace)
    }

    private func connect() {
        guard canConnect else { return }
        fieldFocused = false
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await app.connect(to: address, access: accessToken)
                errorMessage = nil
            } catch {
                withAnimation { errorMessage = error.localizedDescription }
            }
        }
    }
}

#Preview {
    ConnectServerView()
        .environment(AppModel())
}
