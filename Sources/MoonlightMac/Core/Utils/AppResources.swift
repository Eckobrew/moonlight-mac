import Foundation

private final class ResourceBundleAnchor: NSObject {}

/// Resolve resources relative to the running executable. SwiftPM's generated
/// Bundle.module accessor can probe an absolute build path inside Documents.
enum AppResources {
    static func bundle(appBundle: Bundle? = nil) -> Bundle? {
        let appBundle = appBundle ?? Bundle(for: ResourceBundleAnchor.self)
        let name = "MoonlightMac_MoonlightMac.bundle"
        if let url = appBundle.resourceURL?.appendingPathComponent(name),
            FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url)
        {
            return bundle
        }
        guard appBundle.bundleURL.pathExtension != "app" else { return nil }
        // Swift Testing links this module into an .xctest bundle; SwiftPM places
        // resources alongside that bundle rather than inside it.
        if appBundle.bundleURL.pathExtension == "xctest" {
            let url = appBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? Bundle(url: url) : nil
        }
        guard let executable = appBundle.executableURL else { return nil }
        // `swift run` keeps its resource bundle beside the executable. Never
        // fall back to a build-machine path when an installed app lacks resources.
        let url = executable.deletingLastPathComponent().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Bundle(url: url)
    }
}
