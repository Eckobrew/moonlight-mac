import Foundation

enum AppLocalization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var selected = resourceBundle() ?? .main

    /// Packaged apps must resolve inside Contents/Resources, including after relocation.
    /// SwiftPM's generated accessor embeds a development path and may fatalError.
    static func resourceBundle(appBundle: Bundle? = nil) -> Bundle? {
        AppResources.bundle(appBundle: appBundle)
    }

    static func apply(language: String) {
        let code = language == "system" ? (Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en") : language
        let root = resourceBundle() ?? .main
        let path = root.path(forResource: code, ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:)) ?? root
        lock.withLock { selected = bundle }
    }
    static func text(_ key: String) -> String {
        lock.withLock { selected.localizedString(forKey: key, value: key, table: nil) }
    }
}
