import Foundation

/// Per-application streaming overrides.
///
/// Each field is optional: `nil` means "inherit the global setting", so adding new global options
/// does not require touching this type. Resolution happens once when a session starts.
public struct AppStreamOverrides: Codable, Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var bitrateMbps: Int?
    public var codec: VideoCodec?
    public var audioMode: AudioConfigurationMode?
    public var enableHdr: Bool?
    public var enableVsync: Bool?
    public var enableFramePacing: Bool?
    public var mouseCaptureMode: Bool?
    public var windowMode: WindowMode?
    public var quitAppOnStop: Bool?
    public var optimizeGameSettings: Bool?

    public init() {}

    /// True when nothing is overridden (used to hide the badge in the UI).
    public var isEmpty: Bool {
        width == nil && height == nil && fps == nil && bitrateMbps == nil && codec == nil &&
        audioMode == nil && enableHdr == nil && enableVsync == nil && enableFramePacing == nil &&
        mouseCaptureMode == nil && windowMode == nil && quitAppOnStop == nil &&
        optimizeGameSettings == nil
    }
}

public extension StreamSettings {
    /// Returns a copy with this app's overrides applied on top of the global settings.
    func applying(_ overrides: AppStreamOverrides) -> StreamSettings {
        var result = self
        if let value = overrides.width { result.width = value }
        if let value = overrides.height { result.height = value }
        if let value = overrides.fps { result.fps = value }
        if let value = overrides.bitrateMbps { result.bitrateMbps = value }
        if let value = overrides.codec { result.codec = value }
        if let value = overrides.audioMode { result.audioMode = value }
        if let value = overrides.enableHdr { result.enableHdr = value }
        if let value = overrides.enableVsync { result.enableVsync = value }
        if let value = overrides.enableFramePacing { result.enableFramePacing = value }
        if let value = overrides.mouseCaptureMode { result.mouseCaptureMode = value }
        if let value = overrides.windowMode { result.windowMode = value }
        if let value = overrides.quitAppOnStop { result.quitAppOnStop = value }
        if let value = overrides.optimizeGameSettings { result.optimizeGameSettings = value }
        return result
    }
}

/// Persists per-app overrides keyed by host + app id.
@MainActor
public final class PerAppSettingsStore {
    public static let shared = PerAppSettingsStore()

    private let storageKey = "com.moonlight.mac.perAppOverrides"
    private var cache: [String: AppStreamOverrides] = [:]

    private init() {
        load()
    }

    /// Host identity is the stable server ID when available, otherwise the address, so overrides
    /// survive a host being rediscovered with a new UUID.
    private func primaryKey(host: Host, appId: Int) -> String {
        let hostKey = host.serverId?.isEmpty == false ? host.serverId! : host.address
        return "\(hostKey.lowercased())|\(appId)"
    }

    /// Every key an app's overrides could live under.
    ///
    /// A host that has not completed a serverinfo probe yet has no `serverId`, so overrides saved
    /// then are stored under the address. Once the ID arrives the primary key changes, so lookups
    /// fall back to the address key rather than appearing to lose the settings.
    private func candidateKeys(host: Host, appId: Int) -> [String] {
        var keys = [primaryKey(host: host, appId: appId)]
        let addressKey = "\(host.address.lowercased())|\(appId)"
        if !keys.contains(addressKey) { keys.append(addressKey) }
        return keys
    }

    public func overrides(for host: Host, appId: Int) -> AppStreamOverrides {
        for key in candidateKeys(host: host, appId: appId) {
            if let value = cache[key] { return value }
        }
        return AppStreamOverrides()
    }

    public func setOverrides(_ overrides: AppStreamOverrides, for host: Host, appId: Int) {
        // Write once, under the canonical key, and drop any stale address-keyed entry so the two
        // cannot diverge.
        for key in candidateKeys(host: host, appId: appId) {
            cache.removeValue(forKey: key)
        }
        let canonical = primaryKey(host: host, appId: appId)
        if !overrides.isEmpty {
            cache[canonical] = overrides
        }
        save()
    }

    public func clear(for host: Host, appId: Int) {
        for key in candidateKeys(host: host, appId: appId) {
            cache.removeValue(forKey: key)
        }
        save()
    }

    private func load() {
        guard let data = UserDefaults.sharedApp.data(forKey: storageKey) ?? UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: AppStreamOverrides].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.sharedApp.set(encoded, forKey: storageKey)
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
}
