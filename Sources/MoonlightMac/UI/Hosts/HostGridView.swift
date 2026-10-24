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
            if let host = appState.connectingHost {
                VStack(spacing: 16) {
                    Image(systemName: "display").font(.system(size: 48, weight: .light))
                    ProgressView()
                    Text(appState.hostConnectionStatus).font(.headline)
                    Text(host.name).foregroundStyle(.secondary)
                    Button("Cancel") { appState.cancelHostConnection() }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let selectedHost = appState.selectedHost, selectedHost.isSecurelyPaired {
                AppGridView(
                    host: selectedHost,
                    apps: appState.appsForSelectedHost,
                    focusedAppID: appState.controllerAppFocus,
                    globalSettings: appState.settings,
                    onLaunchApp: { app in
                        appState.launchStream(host: selectedHost, app: app)
                    },
                    onQuitCurrentApp: {
                        Task {
                            try? await SunshineHTTPClient.shared.quitApp(host: selectedHost)
                            try? await Task.sleep(for: .milliseconds(300))
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
                    Label(AppLocalization.text("Add Host"), systemImage: "plus")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await appState.refreshHosts()
                    }
                } label: {
                    Label(AppLocalization.text("Refresh"), systemImage: "arrow.clockwise")
                }
            }

            #if DEBUG
            ToolbarItem(placement: .automatic) {
                Button {
                    appState.isShowingLogs = true
                } label: {
                    Label(AppLocalization.text("Logs"), systemImage: "terminal")
                }
                .help(AppLocalization.text("View live logs and diagnostics"))
            }
            #endif

            ToolbarItem(placement: .automatic) {
                Button {
                    appState.isShowingSettings = true
                } label: {
                    Label(AppLocalization.text("Settings"), systemImage: "gear")
                }
            }
        }
        .alert("Couldn’t connect to PC", isPresented: Binding(
            get: { appState.hostConnectionError != nil },
            set: { if !$0 { appState.hostConnectionError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.hostConnectionError = nil }
        } message: {
            Text(appState.hostConnectionError ?? "")
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
        #if DEBUG
        .sheet(isPresented: $appState.isShowingLogs) {
            LogViewerSheet()
        }
        #endif
        .sheet(isPresented: $appState.isShowingPairing) {
            if let host = appState.selectedHost {
                PairingSheet(
                    host: host,
                    pin: appState.pairingPin,
                    error: appState.pairingError,
                    isPairing: appState.isPairingInProgress,
                    onCancel: {
                        appState.cancelPairing()
                    }
                )
            }
        }
        .task {
            // Start mDNS discovery on launch
            if appState.settings.features.enableMdns { BonjourDiscoveryService.shared.startDiscovery() }
            await appState.refreshHosts()

            // Periodic auto-refresh every 4 seconds for hosts and apps
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }

                // Avoid competing with low-latency streaming UDP traffic when active
                guard !StreamSessionController.shared.isStreaming, appState.connectingHost == nil else { continue }

                if let selectedHost = appState.selectedHost, selectedHost.isSecurelyPaired {
                    // On the apps screen: refresh apps and host status (running app, etc.)
                    await appState.loadApps(for: selectedHost)
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
        ScrollViewReader { proxy in
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
                                isSelected: appState.selectedHost?.id == host.id || appState.controllerHostFocus == host.id,
                                appState: appState,
                                onSelect: { selectHost(host) },
                                onPair: { pairHost(host) },
                                onWakeOnLan: { wakeHost(host) },
                                onDelete: { appState.removeHost(host) },
                                onUnpair: { unpairHost(host) }
                            ).id(host.id)
                        }
                    }
                    .padding(24)
                }
            }
            .onChange(of: appState.controllerHostFocus) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }

    }

    private func selectHost(_ host: Host) {
        appState.connectToHost(host)
    }

    private func pairHost(_ host: Host) {
        appState.selectedHost = host
        Task {
            await appState.startPairing(for: host)
        }
    }

    private func wakeHost(_ host: Host) {
        appState.connectToHost(host)
    }

    private func unpairHost(_ host: Host) {
        Task {
            await appState.unpairHost(host)
        }
    }
}
