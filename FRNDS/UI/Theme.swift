import SwiftUI
import FRNDSAPI

enum Theme {
    /// Yellow-centred lime → citrus gradient (kept soft) for avatar rings, backgrounds and accents.
    static let brandColors: [Color] = [
        Color(red: 0.82, green: 0.87, blue: 0.45), // lime-yellow
        Color(red: 0.98, green: 0.88, blue: 0.42), // lemon
        Color(red: 0.98, green: 0.79, blue: 0.32), // sunflower
        Color(red: 0.96, green: 0.65, blue: 0.33), // citrus
    ]

    static let brandGradient = LinearGradient(colors: brandColors, startPoint: .bottomLeading, endPoint: .topTrailing)

    /// The primary colour: sunflower yellow, used as the fill of prominent buttons.
    static let primary = Color(red: 0.99, green: 0.80, blue: 0.22)
    /// Labels on `primary` (yellow needs dark text for contrast).
    static let onPrimary = Color(red: 0.17, green: 0.13, blue: 0.02)
    /// App tint for text-like controls (links, toggles, checkmarks): a deep gold in light mode
    /// (yellow text on white is unreadable) and the bright yellow in dark mode.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.84, blue: 0.30, alpha: 1)
            : UIColor(red: 0.56, green: 0.42, blue: 0.0, alpha: 1)
    })
    /// Dark text for use on top of the light brand gradient.
    static let ink = Color(red: 0.17, green: 0.14, blue: 0.04)
}

extension View {
    /// Filled yellow Liquid Glass button with dark label: the app's primary action style.
    func primaryButtonStyle() -> some View {
        buttonStyle(.glassProminent)
            .tint(Theme.primary)
            .foregroundStyle(Theme.onPrimary)
    }
}

/// Light / dark / follow the system; chosen in Settings.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"
    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Script wordmark, like Instagram's logo.
struct Wordmark: View {
    var size: CGFloat = 30

    var body: some View {
        Text("FRNDS")
            .font(.custom("SnellRoundhand-Black", size: size, relativeTo: .title))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Animated brand gradient behind onboarding screens; gives the Liquid Glass controls something to refract.
struct BrandBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 20) / 20 * 2 * .pi)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.15 * sin(t), 0.5 + 0.15 * cos(t)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Theme.brandColors[0], Theme.brandColors[1], Theme.brandColors[2],
                    Theme.brandColors[1], Theme.brandColors[2], Theme.brandColors[3],
                    Theme.brandColors[2], Theme.brandColors[3], Theme.brandColors[3],
                ]
            )
        }
        .ignoresSafeArea()
    }
}

/// Initials in a circle with the gradient story ring.
struct AvatarView: View {
    let user: UserDTO
    var size: CGFloat = 36
    var showsRing = true

    private var initials: String {
        let parts = user.displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(user.username.prefix(1)).uppercased() : letters.uppercased()
    }

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .overlay {
                if let path = user.avatarPath {
                    RemoteImage(path: path, showsFailureIcon: false)
                        .clipShape(.circle)
                }
            }
            .padding(showsRing ? size * 0.07 : 0)
            .background {
                if showsRing {
                    Circle().strokeBorder(Theme.brandGradient, lineWidth: max(2, size * 0.045))
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
