import AppKit
import Foundation

@MainActor
public final class BoxArtManager {
    public static let shared = BoxArtManager()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default

    private init() {
        memoryCache.countLimit = 200
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private var cacheDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MoonlightMac/BoxArt", isDirectory: true)
    }

    private func cacheKey(host: Host, appId: Int) -> NSString {
        return "\(host.address)_\(appId)" as NSString
    }

    private func diskURL(host: Host, appId: Int) -> URL {
        let safeHost = host.address.replacingOccurrences(of: ":", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeHost)_\(appId).png")
    }

    public func getBoxArt(host: Host, app: StreamApp) async -> NSImage? {
        let key = cacheKey(host: host, appId: app.id)

        // 1. Check in-memory cache
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        // 2. Check disk cache
        let fileUrl = diskURL(host: host, appId: app.id)
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: key)
            return image
        }

        // 3. Fetch from host over authenticated mTLS
        do {
            let data = try await SunshineHTTPClient.shared.fetchBoxArt(host: host, appId: app.id)
            if let image = NSImage(data: data) {
                memoryCache.setObject(image, forKey: key)
                try? data.write(to: fileUrl, options: .atomic)
                return image
            }
        } catch {
            AppLogger.shared.debug("Could not fetch box art for app \(app.title) (id \(app.id)): \(error.localizedDescription)", category: "HTTP")
        }

        return nil
    }
}
