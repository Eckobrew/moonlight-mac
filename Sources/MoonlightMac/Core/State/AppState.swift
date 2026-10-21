import Foundation
import SwiftUI

@MainActor
@Observable
public final class AppState: @unchecked Sendable {
    public var hosts: [Host] = []
    public var selectedHost: Host?
    public var appsForSelectedHost: [StreamApp] = []
    public var settings: StreamSettings = StreamSettings()

    public var isShowingAddHost: Bool = false
    public var isShowingSettings: Bool = false
    public var isShowingLogs: Bool = false
    public var isShowingPairing: Bool = false
    public var pairingPin: String?
    public var pairingError: String?
    public var isPairingInProgress: Bool = false

    public var activeHost: Host?
    public var activeApp: StreamApp?
    public var isStreaming: Bool = false

    // Shortcut / CLI Launch State
    public var isShortcutLaunch: Bool = false
    public var hasStartedStreaming: Bool = false
    public var cliStreamStatus: String = "Connecting..."
    public var cliStreamError: String? = nil
    public var cliGameTitle: String = ""
    public var cliHostName: String = ""
    public var cliIcon: NSImage? = nil

    private let hostsKey = "com.moonlight.mac.savedHosts"
    private let settingsKey = "com.moonlight.mac.savedSettings"

    /// Last array written to `UserDefaults`, used to skip no-op saves during periodic refreshes.
    private var lastPersistedHosts: [Host] = []

    public init() {
        StreamSessionController.shared.onSessionStopped = { [weak self] in
            Task { @MainActor in
                self?.isStreaming = false
                self?.activeHost = nil
                self?.activeApp = nil
            }
        }

        loadSettings()
        loadHosts()

        let args = CommandLine.arguments
        if let streamIdx = args.firstIndex(of: "stream"), streamIdx + 2 < args.count {
            self.isShortcutLaunch = true
            self.cliHostName = args[streamIdx + 1]
            self.cliGameTitle = args[streamIdx + 2]
            self.cliStreamStatus = "Connecting to \(self.cliHostName)..."
            if let iconIdx = args.firstIndex(of: "--icon"), iconIdx + 1 < args.count {
                let iconPath = args[iconIdx + 1]
                if FileManager.default.fileExists(atPath: iconPath), let img = NSImage(contentsOfFile: iconPath) {
                    self.cliIcon = img
                }
            }
        }
    }

    public func loadSettings() {
        if let data = UserDefaults.sharedApp.data(forKey: settingsKey) ?? UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            self.settings = decoded
        }
    }

    public func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.sharedApp.set(encoded, forKey: settingsKey)
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
        DisplaySleepManager.shared.update(keepScreenActive: settings.keepScreenActive)
    }

    public func loadHosts() {
        if let data = UserDefaults.sharedApp.data(forKey: hostsKey) ?? UserDefaults.standard.data(forKey: hostsKey),
           let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            // Only restore legitimately paired hosts from persistent storage.
            // On startup, paired hosts start in .offline status until Bonjour or refreshHosts probes them.
            self.hosts = decoded.filter { $0.isPaired }.map { host in
                var restored = host
                restored.status = .offline
                return restored
            }
            // Seeding the snapshot prevents the first refresh from rewriting the same data.
            lastPersistedHosts = hosts
            saveHosts()
        }
    }

    public func saveHosts(ifChanged onlyWhenChanged: Bool = false) {
        // Only persist paired hosts to storage so unpaired or transient PCs are never saved to disk
        let pairedOnly = hosts.filter { $0.isPaired }

        // The UI refreshes hosts every few seconds; most refreshes change nothing. Comparing against
        // the last persisted snapshot avoids a JSON encode + two cross-process UserDefaults writes
        // on every single refresh tick.
        if onlyWhenChanged, pairedOnly == lastPersistedHosts {
            return
        }
        lastPersistedHosts = pairedOnly

        if let encoded = try? JSONEncoder().encode(pairedOnly) {
            UserDefaults.sharedApp.set(encoded, forKey: hostsKey)
            UserDefaults.standard.set(encoded, forKey: hostsKey)
        }
    }

    private func isSameHost(_ a: Host, _ b: Host) -> Bool {
        if a.id == b.id {
            return true
        }
        if let uidA = a.serverId, let uidB = b.serverId,
           !uidA.isEmpty, !uidB.isEmpty {
            return uidA.caseInsensitiveCompare(uidB) == .orderedSame
        }
        if a.address.caseInsensitiveCompare(b.address) == .orderedSame {
            return true
        }
        if let macA = a.macAddress, let macB = b.macAddress,
           SunshineHTTPClient.isValidMacAddress(macA),
           SunshineHTTPClient.isValidMacAddress(macB) {
            return macA.caseInsensitiveCompare(macB) == .orderedSame
        }
        return false
    }

    public func addOrUpdateHost(_ host: Host) {
        if let idx = hosts.firstIndex(where: { isSameHost($0, host) }) {
            var merged = host
            merged.id = hosts[idx].id
            if merged.serverId == nil || merged.serverId?.isEmpty == true {
                merged.serverId = hosts[idx].serverId
            }
            if merged.remoteAddress == nil || merged.remoteAddress?.isEmpty == true {
                merged.remoteAddress = hosts[idx].remoteAddress
            }
            if merged.macAddress == nil || merged.macAddress?.isEmpty == true {
                merged.macAddress = hosts[idx].macAddress
            }
            if merged.appVersion.isEmpty && !hosts[idx].appVersion.isEmpty {
                merged.appVersion = hosts[idx].appVersion
            }
            if merged.gfeVersion.isEmpty && !hosts[idx].gfeVersion.isEmpty {
                merged.gfeVersion = hosts[idx].gfeVersion
            }
            if host.name == "Searching..." && hosts[idx].name != "Searching..." && !hosts[idx].name.isEmpty {
                merged.name = hosts[idx].name
            }

            // CRITICAL: Pairing is cryptographically persistent.
            // Never allow a candidate probe, mDNS announcement, or unauthenticated HTTP probe to unpair a paired host.
            if hosts[idx].isPaired {
                merged.isPaired = true
                if merged.status == .pairingRequired {
                    merged.status = hosts[idx].status == .offline ? .offline : .online
                }
            }

            hosts[idx] = merged
            if selectedHost?.id == merged.id || selectedHost?.address == host.address {
                selectedHost = merged
            }
        } else {
            hosts.append(host)
        }
        saveHosts()
    }

    public func removeHost(_ host: Host) {
        hosts.removeAll(where: { $0.id == host.id })
        if selectedHost?.id == host.id {
            selectedHost = nil
            appsForSelectedHost.removeAll()
        }
        saveHosts()
    }

    public func unpairHost(_ host: Host) async {
        AppLogger.shared.info("Unpairing host \(host.name) (\(host.address))...", category: "PAIRING")
        await SunshineHTTPClient.shared.unpair(host: host)
        if let idx = hosts.firstIndex(where: { $0.id == host.id || $0.address == host.address }) {
            hosts[idx].isPaired = false
            hosts[idx].status = .pairingRequired
            if selectedHost?.id == host.id {
                selectedHost = hosts[idx]
                appsForSelectedHost.removeAll()
            }
            saveHosts()
        }
        AppLogger.shared.info("Host \(host.name) unpaired", category: "PAIRING")
    }

    public func refreshHosts() async {
        let currentHosts = hosts
        guard !currentHosts.isEmpty else { return }

        await withTaskGroup(of: (UUID, Host?, (any Error)?).self) { group in
            for host in currentHosts {
                group.addTask {
                    do {
                        let (updated, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
                        return (host.id, updated, nil)
                    } catch {
                        return (host.id, nil, error)
                    }
                }
            }

            for await (hostId, updatedHost, _) in group {
                await MainActor.run {
                    guard let idx = self.hosts.firstIndex(where: { $0.id == hostId }) else { return }
                    if let updated = updatedHost {
                        var merged = updated
                        if self.hosts[idx].isPaired {
                            merged.isPaired = true
                            if merged.status == .pairingRequired {
                                merged.status = .online
                            }
                        }
                        if merged.serverId == nil || merged.serverId?.isEmpty == true {
                            merged.serverId = self.hosts[idx].serverId
                        }
                        if merged.macAddress == nil || merged.macAddress?.isEmpty == true {
                            merged.macAddress = self.hosts[idx].macAddress
                        }
                        if merged.remoteAddress == nil || merged.remoteAddress?.isEmpty == true {
                            merged.remoteAddress = self.hosts[idx].remoteAddress
                        }
                        if merged.appVersion.isEmpty && !self.hosts[idx].appVersion.isEmpty {
                            merged.appVersion = self.hosts[idx].appVersion
                        }
                        if merged.gfeVersion.isEmpty && !self.hosts[idx].gfeVersion.isEmpty {
                            merged.gfeVersion = self.hosts[idx].gfeVersion
                        }
                        self.hosts[idx] = merged
                        if self.selectedHost?.id == merged.id {
                            self.selectedHost = merged
                        }
                    } else {
                        self.hosts[idx].status = .offline
                        if self.selectedHost?.id == self.hosts[idx].id {
                            self.selectedHost = self.hosts[idx]
                        }
                    }
                }
            }
        }
        saveHosts(ifChanged: true)
    }

    public func loadApps(for host: Host) async {
        do {
            let apps = try await SunshineHTTPClient.shared.fetchAppList(host: host)
            await MainActor.run {
                self.appsForSelectedHost = apps
            }
        } catch {
            AppLogger.shared.error("Failed to load apps for \(host.name): \(error.localizedDescription)", category: "HTTP")
            if let nsError = error as NSError?, nsError.code == 401 {
                await MainActor.run {
                    if let idx = self.hosts.firstIndex(where: { $0.id == host.id || $0.address == host.address }) {
                        self.hosts[idx].isPaired = false
                        self.hosts[idx].status = .pairingRequired
                        self.saveHosts()
                    }
                    self.selectedHost = nil
                }
            }
        }
    }

    public func startPairing(for host: Host) async {
        isPairingInProgress = true
        pairingPin = nil
        pairingError = nil
        isShowingPairing = true

        do {
            let success = try await PairingService.shared.pair(host: host) { [weak self] pin in
                Task { @MainActor [weak self] in
                    self?.pairingPin = pin
                }
            }

            await MainActor.run {
                self.isPairingInProgress = false
                if success {
                    self.isShowingPairing = false
                    var updated = host
                    updated.isPaired = true
                    updated.status = .online
                    self.addOrUpdateHost(updated)
                    self.selectedHost = updated
                    Task {
                        await self.loadApps(for: updated)
                    }
                } else {
                    self.pairingError = "Pairing failed or timed out."
                }
            }
        } catch {
            await MainActor.run {
                self.isPairingInProgress = false
                self.pairingError = error.localizedDescription
            }
        }
    }

    public func launchStream(host: Host, app: StreamApp) {
        self.activeHost = host
        self.activeApp = app
        self.isStreaming = true
        self.hasStartedStreaming = true
        StreamSessionController.shared.isShortcutMode = self.isShortcutLaunch
        Task {
            await StreamSessionController.shared.startSession(host: host, app: app, settings: settings)
        }
    }

    public func stopActiveStream() {
        self.isStreaming = false
        StreamSessionController.shared.stopSession()
        self.activeHost = nil
        self.activeApp = nil
    }

    public func cancelShortcutLaunch() {
        self.isStreaming = false
        for window in NSApp.windows {
            window.alphaValue = 0
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            window.orderOut(nil)
            window.setIsVisible(false)
        }
        NSApp.hide(nil)

        let host = activeHost ?? hosts.first(where: { $0.name.localizedCaseInsensitiveCompare(cliHostName) == .orderedSame })
        Task {
            if let host = host {
                try? await SunshineHTTPClient.shared.quitApp(host: host)
            }
            await MainActor.run {
                exit(0)
            }
        }
    }

    public func handleCLIStream(hostQuery: String, appQuery: String) async {
        AppLogger.shared.info("CLI Stream invocation requested for host: '\(hostQuery)', app: '\(appQuery)'", category: "CLI")

        self.cliStreamStatus = "Locating host '\(hostQuery)'..."

        // 1. Locate host in saved hosts or by IP/name
        var targetHost: Host? = hosts.first(where: {
            $0.name.localizedCaseInsensitiveCompare(hostQuery) == .orderedSame ||
            $0.address == hostQuery ||
            $0.remoteAddress == hostQuery
        })

        if targetHost == nil {
            targetHost = hosts.first(where: {
                $0.name.localizedCaseInsensitiveContains(hostQuery)
            })
        }

        if targetHost == nil {
            let address = hostQuery.contains(".") ? hostQuery : "\(hostQuery).local"
            targetHost = Host(name: hostQuery, address: address)
        }

        guard var host = targetHost else {
            self.cliStreamError = "Could not find host '\(hostQuery)'."
            return
        }

        // 2. Connect to host (with automatic Wake-on-LAN recovery if sleeping or unreachable)
        self.cliStreamStatus = "Connecting to '\(host.name)'..."
        do {
            let (updated, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
            host = updated
            self.addOrUpdateHost(updated)
        } catch {
            if let mac = host.macAddress {
                self.cliStreamStatus = "Host unreachable. Waking '\(host.name)' via Wake-on-LAN..."
                AppLogger.shared.info("Initial connection failed for '\(host.name)'. Attempting Wake-on-LAN recovery...", category: "CLI")
                var recovered = false
                for i in 0..<24 {
                    self.cliStreamStatus = "Waking up '\(host.name)' (\(24 - i) attempts remaining)..."
                    try? await WakeOnLAN.wake(macAddress: mac)
                    try? await Task.sleep(for: .milliseconds(2500))
                    if let (updated, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: host), updated.isOnline {
                        host = updated
                        self.addOrUpdateHost(updated)
                        recovered = true
                        break
                    }
                }
                if !recovered {
                    self.cliStreamError = "Failed to connect to host '\(host.name)': Host did not respond to Wake-on-LAN."
                    return
                }
            } else {
                self.cliStreamError = "Failed to connect to host '\(host.name)': \(error.localizedDescription)"
                return
            }
        }

        // 4. Fetch apps and find matching app
        self.cliStreamStatus = "Loading game list..."
        do {
            let apps = try await SunshineHTTPClient.shared.fetchAppList(host: host)
            let matchedApp = apps.first(where: {
                $0.title.localizedCaseInsensitiveCompare(appQuery) == .orderedSame ||
                String($0.id) == appQuery
            }) ?? apps.first(where: {
                $0.title.localizedCaseInsensitiveContains(appQuery)
            })

            guard let app = matchedApp else {
                let available = apps.map(\.title).joined(separator: ", ")
                self.cliStreamError = "Game '\(appQuery)' not found on host '\(host.name)'. Available games: \(available)"
                return
            }

            self.cliStreamStatus = "Launching '\(app.title)'..."
            AppLogger.shared.info("Found app '\(app.title)' (ID: \(app.id)) on '\(host.name)'. Starting stream...", category: "CLI")
            self.launchStream(host: host, app: app)
        } catch {
            self.cliStreamError = "Failed to fetch games from '\(host.name)': \(error.localizedDescription)"
        }
    }
}
