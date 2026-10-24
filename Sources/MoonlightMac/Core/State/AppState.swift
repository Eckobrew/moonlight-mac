import Foundation
import SwiftUI

@MainActor
@Observable
public final class AppState: @unchecked Sendable {
    public var hosts: [Host] = []
    public var selectedHost: Host?
    public var controllerHostFocus: UUID?
    public var controllerAppFocus: Int?
    public var appsForSelectedHost: [StreamApp] = []
    public private(set) var connectingHost: Host?
    public private(set) var hostConnectionStatus = ""
    public var hostConnectionError: String?
    private var hostConnectionTask: Task<Void, Never>?
    private var hostConnectionID = UUID()
    public var settings: StreamSettings = StreamSettings()

    public var isShowingAddHost: Bool = false
    public var isShowingSettings: Bool = false
    public var isShowingLogs: Bool = false
    public var isShowingPairing: Bool = false
    public var pairingPin: String?
    public var pairingError: String?
    public var isPairingInProgress: Bool = false
    private var cliLaunchTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var pairingTask: Task<Host, any Error>?

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
            self?.isStreaming = false
            self?.activeHost = nil
            self?.activeApp = nil
        }

        loadSettings()
        loadHosts()
        AppLocalization.apply(language: settings.features.language)

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
        if settings.features.enableMdns { BonjourDiscoveryService.shared.startDiscovery() }
        else { BonjourDiscoveryService.shared.stopDiscovery() }

        // Apply audio changes to a running session without requiring a reconnect.
        if StreamSessionController.shared.isStreaming {
            StreamSessionEngine.shared.audioEngine.configureOutput(
                deviceUID: settings.audioOutputDeviceUID,
                muteOnFocusLoss: settings.muteAudioOnFocusLoss
            )
            StreamSessionEngine.shared.audioEngine.applyOutputDevice()
        }
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
            // Unauthenticated discovery cannot replace metadata or trust for a
            // pinned PC. The regular refresh probes it using the saved pin.
            if hosts[idx].isSecurelyPaired && host.serverCertificateDER == nil { return }
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
            if merged.serverCertificateDER == nil {
                merged.serverCertificateDER = hosts[idx].serverCertificateDER
            }
            if hosts[idx].isPaired {
                merged.isPaired = true
                if merged.status == .pairingRequired && merged.isSecurelyPaired {
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
        if connectingHost?.id == host.id { cancelHostConnection() }
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
            hosts[idx].serverCertificateDER = nil
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
                    guard let original = currentHosts.first(where: { $0.id == hostId }),
                          self.hosts[idx].isPaired == original.isPaired,
                          self.hosts[idx].serverCertificateDER == original.serverCertificateDER else { return }
                    if let updated = updatedHost {
                        var merged = updated
                        if self.hosts[idx].isPaired {
                            merged.isPaired = true
                            if merged.status == .pairingRequired && merged.isSecurelyPaired {
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

    /// Publish the app screen only after a live host has supplied a fresh list.
    public func connectToHost(_ host: Host) {
        guard !isStreaming, connectingHost?.id != host.id else { return }
        cancelHostConnection()
        selectedHost = nil
        appsForSelectedHost.removeAll()
        controllerAppFocus = nil
        hostConnectionError = nil
        connectingHost = host
        hostConnectionStatus = "Connecting to \(host.name)…"
        let request = hostConnectionID
        hostConnectionTask = Task {
            do {
                let resolved = try await HostWakeConnection.resolve(host: host) {
                    guard self.hostConnectionID == request else { return }
                    self.hostConnectionStatus = "Waking \(host.name)…"
                }
                guard self.hostConnectionID == request, !Task.isCancelled else { return }
                self.addOrUpdateHost(resolved)
                if resolved.isSecurelyPaired {
                    self.hostConnectionStatus = "Loading apps from \(resolved.name)…"
                    let apps = try await SunshineHTTPClient.shared.fetchAppList(host: resolved)
                    guard self.hostConnectionID == request, !Task.isCancelled else { return }
                    self.appsForSelectedHost = apps
                    self.selectedHost = resolved
                    self.connectingHost = nil
                } else {
                    self.selectedHost = resolved
                    self.connectingHost = nil
                    await self.startPairing(for: resolved)
                }
            } catch {
                guard self.hostConnectionID == request, !Task.isCancelled else { return }
                self.connectingHost = nil
                self.markPairingRequiredIfUnauthorized(host: host, error: error)
                self.hostConnectionError = error.localizedDescription
            }
            if self.hostConnectionID == request { self.hostConnectionTask = nil }
        }
    }

    public func cancelHostConnection() {
        hostConnectionID = UUID()
        hostConnectionTask?.cancel()
        hostConnectionTask = nil
        connectingHost = nil
        hostConnectionStatus = ""
    }

    public func loadApps(for host: Host) async {
        let request = hostConnectionID
        do {
            let (resolvedHost, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
            guard hostConnectionID == request, !Task.isCancelled else { return }
            addOrUpdateHost(resolvedHost)
            let apps = try await SunshineHTTPClient.shared.fetchAppList(host: resolvedHost)
            await MainActor.run {
                guard self.selectedHost?.id == host.id, self.hostConnectionID == request, !Task.isCancelled else { return }
                self.appsForSelectedHost = apps
            }
        } catch {
            guard hostConnectionID == request, !Task.isCancelled else { return }
            AppLogger.shared.error("Failed to load apps for \(host.name): \(error.localizedDescription)", category: "HTTP")
            markPairingRequiredIfUnauthorized(host: host, error: error)
        }
    }

    private func markPairingRequiredIfUnauthorized(host: Host, error: Error) {
        let error = error as NSError
        guard error.domain == "SunshineHTTPClient", error.code == 401 else { return }
        if let index = hosts.firstIndex(where: { $0.id == host.id || $0.address == host.address }) {
            hosts[index].isPaired = false
            hosts[index].status = .pairingRequired
            saveHosts()
        }
        if selectedHost?.id == host.id {
            selectedHost = nil
            appsForSelectedHost.removeAll()
        }
    }

    public func startPairing(for host: Host) async {
        guard !isPairingInProgress else { return }
        isPairingInProgress = true
        pairingPin = nil
        pairingError = nil
        isShowingPairing = true

        let task = Task {
            try await PairingService.shared.pair(host: host) { [weak self] pin in
                Task { @MainActor [weak self] in
                    guard let self, self.isShowingPairing else { return }
                    self.pairingPin = pin
                }
            }
        }
        pairingTask = task
        defer { pairingTask = nil }
        do {
            let updated = try await task.value
            guard !task.isCancelled else {
                isPairingInProgress = false
                return
            }
            await MainActor.run {
                self.isPairingInProgress = false
                self.isShowingPairing = false
                self.addOrUpdateHost(updated)
                self.selectedHost = self.hosts.first { $0.id == host.id } ?? updated
                if let selectedHost = self.selectedHost {
                    Task { await self.loadApps(for: selectedHost) }
                }
            }
        } catch {
            await MainActor.run {
                self.isPairingInProgress = false
                if !task.isCancelled { self.pairingError = error.localizedDescription }
            }
        }
    }

    public func cancelPairing() {
        pairingTask?.cancel()
        isShowingPairing = false
        pairingPin = nil
        // Keep the attempt in progress until its host cleanup finishes, so a
        // retry cannot race an old /unpair request.
    }

    public func launchStream(host: Host, app: StreamApp) {
        guard !isStreaming else { return }
        guard host.isSecurelyPaired else {
            Task { await self.startPairing(for: host) }
            return
        }
        self.activeHost = host
        self.activeApp = app
        self.isStreaming = true
        self.hasStartedStreaming = true
        StreamSessionController.shared.isShortcutMode = self.isShortcutLaunch

        // Apply any per-app overrides on top of the global settings.
        let overrides = PerAppSettingsStore.shared.overrides(for: host, appId: app.id)
        let effectiveSettings = settings.applying(overrides)

        launchTask = Task {
            await StreamSessionController.shared.startSession(host: host, app: app, settings: effectiveSettings)
        }
    }

    public func stopActiveStream() {
        launchTask?.cancel()
        self.isStreaming = false
        StreamSessionController.shared.stopSession()
        self.activeHost = nil
        self.activeApp = nil
    }

    /// Called when a stream fails to start while launched from a desktop shortcut (CLI mode).
    ///
    /// Restore the launch UI so a failed shortcut remains reachable and can show
    /// its error without activating the app over another application.
    public func failShortcutLaunch() {
        self.isStreaming = false
        self.activeHost = nil
        self.activeApp = nil

        WindowManager.shared.restoreWindowAfterStream()
        if NSApp.isActive { WindowManager.shared.showCurrentWindow() }
        hasStartedStreaming = false
    }

    public func cancelShortcutLaunch() {
        cliLaunchTask?.cancel()
        launchTask?.cancel()
        if StreamSessionController.shared.isStreaming {
            StreamSessionController.shared.stopSession()
        } else {
            // Negotiation has not launched a host app. Cancelling it must never
            // send the host-wide /cancel command to an existing game.
            NSApp.terminate(nil)
        }
    }

    public func beginCLIStream(hostQuery: String, appQuery: String) {
        guard cliLaunchTask == nil else { return }
        cliLaunchTask = Task { await handleCLIStream(hostQuery: hostQuery, appQuery: appQuery) }
    }

    public func handleCLIStream(hostQuery: String, appQuery: String) async {
        guard !Task.isCancelled else { return }
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

        // Use the same wake/readiness flow as a normal host click.
        self.cliStreamStatus = "Connecting to '\(host.name)'..."
        do {
            host = try await HostWakeConnection.resolve(host: host) {
                self.cliStreamStatus = "Waking '\(host.name)' via Wake-on-LAN…"
            }
            guard !Task.isCancelled else { return }
            self.addOrUpdateHost(host)
        } catch {
            guard !Task.isCancelled else { return }
            self.cliStreamError = "Failed to connect to host '\(host.name)': \(error.localizedDescription)"
            return
        }

        guard !Task.isCancelled else { return }
        // 4. Fetch apps and find matching app
        self.cliStreamStatus = "Loading game list..."
        do {
            let apps = try await SunshineHTTPClient.shared.fetchAppList(host: host)
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            self.cliStreamError = "Failed to fetch games from '\(host.name)': \(error.localizedDescription)"
        }
    }
}
