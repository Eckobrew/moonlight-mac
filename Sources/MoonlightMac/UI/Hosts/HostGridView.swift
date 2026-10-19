import SwiftUI

public struct HostGridView: View {
    @Bindable public var appState: AppState

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 20)
    ]

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let selectedHost = appState.selectedHost, selectedHost.isPaired {
                AppGridView(
                    host: selectedHost,
                    apps: appState.appsForSelectedHost,
                    onLaunchApp: { app in
                        appState.launchStream(host: selectedHost, app: app)
                    },
                    onQuitCurrentApp: {
                        Task {
                            try? await SunshineHTTPClient.shared.quitApp(host: selectedHost)
                            try? await Task.sleep(for: .milliseconds(300))
                            if let (updatedHost, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: selectedHost) {
                                appState.addOrUpdateHost(updatedHost)
                            }
                            await appState.loadApps(for: selectedHost)
                            await appState.refreshHosts()
                        }
                    },
                    onBack: {
                        appState.selectedHost = nil
                    },
                    onRefresh: {
                        Task {
                            await appState.loadApps(for: selectedHost)
                        }
                    }
                )
            } else {
                hostGridContent
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isShowingAddHost = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await appState.refreshHosts()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    appState.isShowingLogs = true
                } label: {
                    Label("Logs", systemImage: "terminal")
                }
                .help("View live logs and diagnostics")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    appState.isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $appState.isShowingAddHost) {
            AddHostSheet { newHost in
                appState.addOrUpdateHost(newHost)
            }
        }
        .sheet(isPresented: $appState.isShowingSettings) {
            SettingsView(settings: $appState.settings) {
                appState.saveSettings()
            }
        }
        .sheet(isPresented: $appState.isShowingLogs) {
            LogViewerSheet()
        }
        .sheet(isPresented: $appState.isShowingPairing) {
            if let host = appState.selectedHost {
                PairingSheet(
                    host: host,
                    pin: appState.pairingPin,
                    error: appState.pairingError,
                    isPairing: appState.isPairingInProgress,
                    onCancel: {
                        appState.isShowingPairing = false
                    }
                )
            }
        }
        .task {
            // Start mDNS discovery on launch
            BonjourDiscoveryService.shared.startDiscovery()
            await appState.refreshHosts()

            // Periodic auto-refresh every 4 seconds for hosts and apps
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }

                // Avoid competing with low-latency streaming UDP traffic when active
                guard !StreamSessionController.shared.isStreaming else { continue }

                if let selectedHost = appState.selectedHost, selectedHost.isPaired {
                    // On the apps screen: refresh apps and host status (running app, etc.)
                    await appState.loadApps(for: selectedHost)
                    if let (updatedHost, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: selectedHost) {
                        appState.addOrUpdateHost(updatedHost)
                    }
                } else {
                    // On the hosts screen: refresh all hosts
                    await appState.refreshHosts()
                }
            }
        }
        .onReceive(BonjourDiscoveryService.shared.$discoveredHosts) { discovered in
            for host in discovered {
                appState.addOrUpdateHost(host)
            }
        }
    }

    private var displayedHosts: [Host] {
        if appState.settings.hideUnpairedHosts {
            return appState.hosts.filter { $0.isPaired }
        }
        return appState.hosts
    }

    private var hostGridContent: some View {
        ScrollView {
            if displayedHosts.isEmpty {
                VStack(spacing: 16) {
                    Spacer(minLength: 80)
                    Image(systemName: appState.hosts.isEmpty ? "desktopcomputer.trianglebadge.exclamationmark" : "eye.slash")
                        .font(.system(size: 54))
                        .foregroundStyle(.secondary)
                    Text(appState.hosts.isEmpty ? "No Sunshine or Apollo Hosts Found" : "All Discovered PCs Are Unpaired")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(appState.hosts.isEmpty
                         ? "Moonlight is searching your local network via Bonjour/mDNS.\nYou can also add a host manually by IP."
                         : "Unpaired PCs are currently hidden by your streaming preferences.\nYou can disable 'Hide unpaired PCs' in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button(appState.hosts.isEmpty ? "Add Host Manually" : "Change Setting") {
                        if appState.hosts.isEmpty {
                            appState.isShowingAddHost = true
                        } else {
                            appState.isShowingSettings = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedHosts) { host in
                        HostCardView(
                            host: host,
                            isSelected: appState.selectedHost?.id == host.id,
                            onSelect: { selectHost(host) },
                            onPair: { pairHost(host) },
                            onWakeOnLan: { wakeHost(host) },
                            onDelete: { appState.removeHost(host) },
                            onUnpair: { unpairHost(host) }
                        )
                    }
                }
                .padding(24)
            }
        }
    }

    private func selectHost(_ host: Host) {
        appState.selectedHost = host
        if host.isPaired {
            Task {
                await appState.loadApps(for: host)
            }
        } else {
            Task {
                await appState.startPairing(for: host)
            }
        }
    }

    private func pairHost(_ host: Host) {
        appState.selectedHost = host
        Task {
            await appState.startPairing(for: host)
        }
    }

    private func wakeHost(_ host: Host) {
        guard let mac = host.macAddress else { return }
        Task {
            AppLogger.shared.info("Sending Wake-on-LAN magic packet to \(host.name) (\(mac))...", category: "WOL")
            try? await WakeOnLAN.wake(macAddress: mac)
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(2))
                await appState.refreshHosts()
                if let current = appState.hosts.first(where: { $0.id == host.id }), current.isOnline {
                    break
                }
            }
        }
    }

    private func unpairHost(_ host: Host) {
        Task {
            await appState.unpairHost(host)
        }
    }
}
