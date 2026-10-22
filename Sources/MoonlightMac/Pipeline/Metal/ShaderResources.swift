import Foundation

/// SwiftPM's generated accessor assumes resources next to the executable. A
/// packaged macOS app keeps them under Contents/Resources instead.
enum ShaderResources {
    static func source(appBundle: Bundle = .main) -> String? {
        let name = "MoonlightMac_MoonlightMac.bundle"
        if let resources = appBundle.resourceURL {
            let shader = resources.appendingPathComponent(name).appendingPathComponent("Shaders.metal")
            if let source = try? String(contentsOf: shader, encoding: .utf8) { return source }
        }
        // A distributed app must never resolve resources through the developer's
        // absolute SwiftPM build path. The renderer retains its embedded fallback.
        guard appBundle.bundleURL.pathExtension != "app" else { return nil }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        #endif
        return nil
    }
}
