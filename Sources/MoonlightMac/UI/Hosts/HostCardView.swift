import SwiftUI

public struct HostCardView: View {
    public let host: Host
    public let isSelected: Bool
    public let onSelect: () -> Void
    public let onPair: () -> Void
    public let onWakeOnLan: () -> Void
    public let onDelete: () -> Void

    public init(
        host: Host,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void,
        onPair: @escaping () -> Void,
        onWakeOnLan: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.host = host
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onPair = onPair
        self.onWakeOnLan = onWakeOnLan
        self.onDelete = onDelete
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
                if !host.isPaired {
                    Button(action: onPair) {
                        Label("Pair", systemImage: "link")
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
                    if host.macAddress != nil {
                        Button(action: onWakeOnLan) {
                            Label("Wake on LAN", systemImage: "bolt.fill")
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
        .padding(14)
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
        .onTapGesture {
            onSelect()
        }
    }

    private var statusColor: Color {
        switch host.status {
        case .online:
            return host.isPaired ? .green : .orange
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
            return host.isPaired ? "Online" : "Needs Pairing"
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
