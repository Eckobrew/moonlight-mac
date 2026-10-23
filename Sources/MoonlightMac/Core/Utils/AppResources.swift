import Foundation

/// A distributed app resolves resources inside its bundle, never through the
/// absolute development path embedded in SwiftPM's generated accessor.
enum AppResources {
    static func bundle(appBundle: Bundle = .main) -> Bundle? {
        if let url = appBundle.resourceURL?.appendingPathComponent("MoonlightMac_MoonlightMac.bundle"),
           FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) { return bundle }
        guard appBundle.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module
    }
}
