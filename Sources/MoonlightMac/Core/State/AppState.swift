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

    private let hostsKey = "com.moonlight.mac.savedHosts"
    private let settingsKey = "com.moonlight.mac.savedSettings"

    public init() {
        loadSettings()
        loadHosts()
    }

    public func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            self.settings = decoded
        }
    }

    public func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
    }

    public func loadHosts() {
        if let data = UserDefaults.standard.data(forKey: hostsKey),
           let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            // Filter out any phantom or corrupt hosts (must be paired or have valid appVersion)
            self.hosts = decoded.filter { host in
                host.isPaired || !host.appVersion.isEmpty
            }
            saveHosts()
        }
    }

    public func saveHosts() {
        if let encoded = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(encoded, forKey: hostsKey)
        }
    }

    public func addOrUpdateHost(_ host: Host) {
        if let idx = hosts.firstIndex(where: { $0.address == host.address }) {
            var merged = host
            if host.name == "Searching..." && hosts[idx].name != "Searching..." && !hosts[idx].name.isEmpty {
                merged.name = hosts[idx].name
            }
            hosts[idx] = merged
            if selectedHost?.address == host.address {
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
        var updated = host
        updated.isPaired = false
        updated.status = .pairingRequired
        addOrUpdateHost(updated)
        if selectedHost?.id == host.id {
            selectedHost = updated
            appsForSelectedHost.removeAll()
        }
        AppLogger.shared.info("Host \(host.name) unpaired", category: "PAIRING")
    }

    public func refreshHosts() async {
        for idx in hosts.indices {
            let host = hosts[idx]
            do {
                let (updatedHost, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
                await MainActor.run {
                    self.hosts[idx] = updatedHost
                    if self.selectedHost?.id == updatedHost.id {
                        self.selectedHost = updatedHost
                    }
                }
            } catch {
                await MainActor.run {
                    self.hosts[idx].status = .offline
                }
            }
        }
        saveHosts()
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
                    var updated = host
                    updated.isPaired = false
                    updated.status = .pairingRequired
                    self.addOrUpdateHost(updated)
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
        Task {
            await StreamSessionController.shared.startSession(host: host, app: app, settings: settings)
        }
    }

    public func stopActiveStream() {
        StreamSessionController.shared.stopSession()
        self.activeHost = nil
        self.activeApp = nil
    }
}
