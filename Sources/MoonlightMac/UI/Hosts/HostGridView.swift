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
                            await appState.refreshHosts()
                        }
                    },
                    onBack: {
                        appState.selectedHost = nil
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
        }
        .onReceive(BonjourDiscoveryService.shared.$discoveredHosts) { discovered in
            for host in discovered {
                if !appState.hosts.contains(where: { $0.address == host.address }) {
                    appState.addOrUpdateHost(host)
                }
            }
        }
    }

    private var hostGridContent: some View {
        ScrollView {
            if appState.hosts.isEmpty {
                VStack(spacing: 16) {
                    Spacer(minLength: 80)
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 54))
                        .foregroundStyle(.secondary)
                    Text("No Sunshine or Apollo Hosts Found")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Moonlight is searching your local network via Bonjour/mDNS.\nYou can also add a host manually by IP.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Add Host Manually") {
                        appState.isShowingAddHost = true
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(appState.hosts) { host in
                        HostCardView(
                            host: host,
                            isSelected: appState.selectedHost?.id == host.id,
                            onSelect: {
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
                            },
                            onPair: {
                                appState.selectedHost = host
                                Task {
                                    await appState.startPairing(for: host)
                                }
                            },
                            onWakeOnLan: {
                                if let mac = host.macAddress {
                                    Task {
                                        try? await WakeOnLAN.wake(macAddress: mac)
                                    }
                                }
                            },
                            onDelete: {
                                appState.removeHost(host)
                            }
                        )
                    }
                }
                .padding(24)
            }
        }
    }
}
