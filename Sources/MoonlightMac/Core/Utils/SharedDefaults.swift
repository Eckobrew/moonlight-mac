import Foundation

public extension UserDefaults {
    /// Shared defaults suite accessible by both the main Moonlight app and standalone shortcut bundles.
    nonisolated(unsafe) static let sharedApp: UserDefaults = {
        UserDefaults(suiteName: "com.eckobrew.moonlight-mac") ?? .standard
    }()
}
