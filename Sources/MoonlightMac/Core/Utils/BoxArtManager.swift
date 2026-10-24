import AppKit
import Foundation
import CryptoKit

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

    static func identity(host: Host, app: StreamApp) -> String {
        let value = "\(host.serverId?.lowercased() ?? host.address.lowercased())|\(app.stableIdentity)|\(app.artVersion ?? "")"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func getBoxArt(host: Host, app: StreamApp) async -> NSImage? {
        let key = Self.identity(host: host, app: app) as NSString

        // 1. Check in-memory cache
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        // 2. Check disk cache
        let fileUrl = cacheDirectory.appendingPathComponent("\(key).png")
        if fileManager.fileExists(atPath: fileUrl.path),
           let data = try? Data(contentsOf: fileUrl),
           let image = NSImage(data: data) {
            memoryCache.setObject(image, forKey: key)
            return image
        }

        // 3. Fetch from host over authenticated mTLS
        do {
            let data = try await SunshineHTTPClient.shared.fetchBoxArt(host: host, appId: app.id, appUUID: app.uuid)
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
