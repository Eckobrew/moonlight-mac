import Foundation
import CryptoKit

/// Only replace bundles bearing the exact identity generated for this host/app.
enum ShortcutBundleStore {
    static func identifier(host: Host, appID: Int) -> String {
        let identity = "\(host.serverId?.lowercased() ?? host.address.lowercased())|\(appID)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.moonlight-stream.shortcut.\(digest)"
    }

    static func identifier(host: Host, app: StreamApp) -> String {
        guard app.uuid != nil else { return identifier(host: host, appID: app.id) }
        let identity = "\(host.serverId?.lowercased() ?? host.address.lowercased())|\(app.stableIdentity)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.moonlight-stream.shortcut.\(digest)"
    }

    static func filename(title: String, hostName: String, identifier: String) -> String {
        func safe(_ text: String) -> String {
            let value = String(text.prefix(70)).replacingOccurrences(of: "[^\\p{L}\\p{N} ._()-]", with: "_", options: .regularExpression)
            return value.isEmpty ? "Game" : value
        }
        return "\(safe(title)) (\(safe(hostName))) \(identifier.suffix(12)).app"
    }

    private static func isOwnedBundle(_ url: URL, identifier: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["CFBundleIdentifier"] as? String == identifier
    }

    static func install(staged: URL, destination: URL, identifier: String) throws {
        let fm = FileManager.default
        guard isOwnedBundle(staged, identifier: identifier) else {
            throw NSError(domain: "ShortcutBundleStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The new shortcut is incomplete. The existing shortcut has been preserved."])
        }
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil {
            guard isOwnedBundle(destination, identifier: identifier) else {
                throw NSError(domain: "ShortcutBundleStore", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "An unrelated item already exists at \(destination.lastPathComponent). It has been preserved."])
            }
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }
}
