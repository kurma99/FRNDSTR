import Foundation
import FrndstrAPI

/// Moment defaults, changeable in Settings and used to preselect the send flow.
enum MomentSettings {
    static let saveToPhotosKey = "moments.saveToPhotos"
    static let shareAsPostKey = "moments.shareAsPost"
    static let audienceKey = "moments.audience"
    static let mirrorSelfieKey = "moments.mirrorSelfie"
    static let insetCornerKey = "moments.insetCorner"
    static let lastSelectedKey = "moments.lastSelectedFriends"

    enum Audience: String, CaseIterable, Identifiable {
        case allFriends, selectedFriends
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .allFriends: "All friends"
            case .selectedFriends: "Selected friends"
            }
        }
    }

    /// Friends picked last time "Selected friends" was used.
    static var lastSelected: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: lastSelectedKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: lastSelectedKey) }
    }
}

extension MomentLayout.Corner {
    var title: LocalizedStringResource {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }
}
