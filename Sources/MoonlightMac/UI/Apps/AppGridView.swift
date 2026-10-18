import SwiftUI

public struct AppGridView: View {
    public let host: Host
    public let apps: [StreamApp]
    public let onLaunchApp: (StreamApp) -> Void
    public let onQuitCurrentApp: () -> Void
    public let onBack: () -> Void
    public let onRefresh: (() -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)
    ]

    public init(
        host: Host,
        apps: [StreamApp],
        onLaunchApp: @escaping (StreamApp) -> Void,
        onQuitCurrentApp: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onRefresh: (() -> Void)? = nil
    ) {
        self.host = host
        self.apps = apps
        self.onLaunchApp = onLaunchApp
        self.onQuitCurrentApp = onQuitCurrentApp
        self.onBack = onBack
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button(action: onBack) {
                    Label("Hosts", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Spacer()

                HStack(spacing: 8) {
                    Text(host.name)
                        .font(.headline)

                    if let onRefresh = onRefresh {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Refresh applications")
                    }
                }

                Spacer()

                // Balancing element to keep center title symmetrically centered
                Label("Hosts", systemImage: "chevron.left")
                    .opacity(0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            // Grid
            if apps.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "app.dashed")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No applications found on host")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Check your Sunshine or Apollo Applications configuration.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(apps) { app in
                            AppCardView(
                                host: host,
                                app: app,
                                isStreaming: host.currentAppId == app.id,
                                onLaunch: {
                                    onLaunchApp(app)
                                },
                                onStop: {
                                    onQuitCurrentApp()
                                }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
}
