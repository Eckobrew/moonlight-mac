import SwiftUI

public struct AppGridView: View {
    public let host: Host
    public let apps: [StreamApp]
    public var focusedAppID: Int?
    /// Global settings, forwarded to each card for per-app overrides.
    public var globalSettings: StreamSettings = StreamSettings()
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
        focusedAppID: Int? = nil,
        globalSettings: StreamSettings = StreamSettings(),
        onLaunchApp: @escaping (StreamApp) -> Void,
        onQuitCurrentApp: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onRefresh: (() -> Void)? = nil
    ) {
        self.host = host
        self.apps = apps
        self.focusedAppID = focusedAppID
        self.globalSettings = globalSettings
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
                    Label(AppLocalization.text("Hosts"), systemImage: "chevron.left")
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
                        .help(AppLocalization.text("Refresh applications"))
                    }
                }

                Spacer()

                // Balancing element to keep center title symmetrically centered
                Label(AppLocalization.text("Hosts"), systemImage: "chevron.left")
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
                    Text(AppLocalization.text("No applications found on host"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(AppLocalization.text("Check your Sunshine or Apollo Applications configuration."))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(apps, id: \.stableIdentity) { app in
                                appCard(for: app)
                                    .id(app.id)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(focusedAppID == app.id ? Color.accentColor : .clear, lineWidth: 3))
                            }
                        }
                        .padding(24)
                    }
                    .onChange(of: focusedAppID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
    }

    /// Extracted so the grid body type-checks quickly; the inline closure was too complex.
    private func appCard(for app: StreamApp) -> some View {
        AppCardView(
            host: host,
            app: app,
            isStreaming: app.matchesRunning(on: host),
            globalSettings: globalSettings,
            onLaunch: { onLaunchApp(app) },
            onStop: { onQuitCurrentApp() }
        )
    }
}
