import SwiftUI

public struct PerformanceHUDView: View {
    public let metrics: PerformanceMetrics

    public init(metrics: PerformanceMetrics) {
        self.metrics = metrics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusIndicatorColor)
                    .frame(width: 8, height: 8)

                Text("PERFORMANCE HUD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("⌘⇧H to hide")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .background(Color.white.opacity(0.2))

            Group {
                metricRow(label: "FPS", value: String(format: "%.1f / %d", metrics.currentFps, metrics.targetFps))
                metricRow(label: "Decode Time", value: String(format: "%.2f ms", metrics.decodeTimeMs))
                metricRow(label: "RTT Latency", value: String(format: "%.1f ms", metrics.roundTripTimeMs))
                metricRow(label: "Bitrate", value: String(format: "%.1f Mbps", metrics.bitrateMbps))
                metricRow(
                    label: "Packet Loss",
                    value: String(format: "%.1f%% (%d)", metrics.packetLossPercentage, metrics.networkDroppedFrames),
                    isWarning: metrics.packetLossPercentage > 0.5
                )
                metricRow(label: "Codec", value: metrics.currentCodec)
                metricRow(label: "Resolution", value: metrics.resolution)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .frame(width: 220)
    }

    private var statusIndicatorColor: Color {
        if metrics.packetLossPercentage > 2.0 || metrics.roundTripTimeMs > 60 {
            return .red
        } else if metrics.packetLossPercentage > 0.5 || metrics.roundTripTimeMs > 30 {
            return .orange
        } else {
            return .green
        }
    }

    private func metricRow(label: String, value: String, isWarning: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isWarning ? Color.orange : Color.primary)
        }
    }
}
