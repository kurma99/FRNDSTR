import SwiftUI

/// Routes between onboarding and the main app based on the session state.
struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .connect:
                ConnectServerView()
                    .transition(.opacity)
            case .auth:
                AuthView()
                    .transition(.opacity)
            case .signedIn:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: app.phase)
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
