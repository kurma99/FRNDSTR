import SwiftUI

/// First screen: enter the address of the family's self-hosted server.
struct ConnectServerView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            BrandBackground()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 6) {
                    Wordmark(size: 60)
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
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                        .accessibilityIdentifier("connectButton")
                    }
                }

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

                Text("Enter the address and port of your Friendster server. Plain http works fine on your home network or over Tailscale (e.g. 100.x.y.z:8080).")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink.opacity(0.8))
            }
            .padding(24)
        }
        .onAppear {
            if let url = app.serverURL { address = ServerAddress.displayString(for: url) }
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        fieldFocused = false
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await app.connect(to: address)
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
