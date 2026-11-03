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
        let root = resourceBundle() ?? .main
        let code: String
        if language == "system" {
            let matched = Bundle.preferredLocalizations(from: root.localizations, forPreferences: Locale.preferredLanguages).first
            code = matched ?? Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en"
        } else {
            code = language
        }
        let path = root.path(forResource: code, ofType: "lproj")
            ?? root.path(forResource: code.lowercased(), ofType: "lproj")
            ?? (code.contains("-") ? root.path(forResource: String(code.split(separator: "-").first ?? ""), ofType: "lproj") : nil)
            ?? (code.contains("-") ? root.path(forResource: String(code.split(separator: "-").first ?? "").lowercased(), ofType: "lproj") : nil)
        let bundle = path.flatMap(Bundle.init(path:)) ?? root
        lock.withLock { selected = bundle }
    }
    static func text(_ key: String) -> String {
        lock.withLock { selected.localizedString(forKey: key, value: key, table: nil) }
    }
}
