import SwiftUI

public struct HostCardView: View {
    public let host: Host
    public let isSelected: Bool
    public let onSelect: () -> Void
    public let onPair: () -> Void
    public let onWakeOnLan: () -> Void
    public let onDelete: () -> Void
    public let onUnpair: (() -> Void)?
    /// Provided so the details sheet can resolve the running app's title.
    public var appState: AppState?
    @State private var showingDetails = false

    public init(
        host: Host,
        isSelected: Bool = false,
        appState: AppState? = nil,
        onSelect: @escaping () -> Void,
        onPair: @escaping () -> Void,
        onWakeOnLan: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onUnpair: (() -> Void)? = nil
    ) {
        self.host = host
        self.isSelected = isSelected
        self.appState = appState
        self.onSelect = onSelect
        self.onPair = onPair
        self.onWakeOnLan = onWakeOnLan
        self.onDelete = onDelete
        self.onUnpair = onUnpair
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                // Host icon container
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 120)
                    .overlay(
                        Image(systemName: host.status == .streaming ? "play.display" : "display")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(statusColor.gradient)
                    )

                // Status indicator pill
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(host.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if host.status == .offline {
                    Button(action: onWakeOnLan) {
                        Label("Wake Up", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else if !host.isSecurelyPaired {
                    Button(action: onPair) {
                        Label(host.needsCertificatePairing ? "Pair Again" : "Pair", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    Button(action: onSelect) {
                        Label("Apps", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Menu {
                    Button {
                        showingDetails = true
                    } label: {
                        Label("Host Details...", systemImage: "info.circle")
                    }
                    if host.macAddress != nil {
                        Button(action: onWakeOnLan) {
                            Label("Wake on LAN", systemImage: "bolt.fill")
                        }
                    }
                    if let onUnpair = onUnpair {
                        Button(action: onUnpair) {
                            Label("Unpair Host", systemImage: "link.badge.plus")
                        }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Remove Host", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(16)
        .sheet(isPresented: $showingDetails) {
            if let appState = appState {
                HostDetailsSheet(host: host, appState: appState)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.15), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if host.status == .offline {
                onWakeOnLan()
            } else if host.isSecurelyPaired {
                onSelect()
            } else {
                onPair()
            }
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
    }

    private var statusColor: Color {
        switch host.status {
        case .online:
            return host.isSecurelyPaired ? .green : .orange
        case .pairingRequired:
            return .orange
        case .streaming:
            return .blue
        case .offline:
            return .gray
        case .unknown:
            return .secondary
        }
    }

    private var statusText: String {
        switch host.status {
        case .online:
            return host.isSecurelyPaired ? "Online" : "Needs Pairing"
        case .pairingRequired:
            return "Unpaired"
        case .streaming:
            return "Streaming"
        case .offline:
            return "Offline"
        case .unknown:
            return "Checking"
        }
    }
}
