import Foundation

enum ShaderResources {
    static func source(appBundle: Bundle = .main) -> String? {
        guard let bundle = AppResources.bundle(appBundle: appBundle),
              let url = bundle.url(forResource: "Shaders", withExtension: "metal") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
