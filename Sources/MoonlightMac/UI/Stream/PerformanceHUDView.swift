import SwiftUI

public struct PerformanceHUDView: View {
    @ObservedObject public var session: StreamSessionController
    private var metrics: PerformanceMetrics { session.metrics }

    public init(session: StreamSessionController) { self.session = session }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusIndicatorColor)
                    .frame(width: 8, height: 8)

                Text(AppLocalization.text("PERFORMANCE HUD"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("⌃⌥⇧S")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .background(Color.white.opacity(0.2))

            Group {
                metricRow(label: "FPS", value: String(format: "%.1f / %d", metrics.currentFps, metrics.targetFps))
                metricRow(label: "Decode Time", value: String(format: "%.2f ms", metrics.decodeTimeMs))
                metricRow(label: "RTT Latency", value: String(format: "%.1f ms", metrics.roundTripTimeMs))
                metricRow(label: "RTT Variation", value: String(format: "%.1f ms", metrics.roundTripTimeVarianceMs))
                metricRow(label: "Bitrate target", value: String(format: "%.1f Mbps", metrics.bitrateMbps))
                metricRow(
                    label: "Packet Loss",
                    value: String(format: "%.1f%% (%d)", metrics.packetLossPercentage, metrics.networkDroppedFrames),
                    isWarning: metrics.packetLossPercentage > 0.5
                )
                metricRow(label: "Codec", value: metrics.currentCodec)
                metricRow(label: "Resolution", value: metrics.resolution)
                metricRow(label: "V-Sync", value: metrics.vsyncEnabled ? "On" : "Off (Unlocked)")
                metricRow(label: "Pacing", value: metrics.pacingEnabled ? "On (CVDisplayLink)" : "Off (Immediate)")
            }
            if session.showHostStatistics, session.activeHost?.capabilities?.hardwareMetricsVersion == 1 {
                if let sample = session.hostStatistics {
                    metricRow(label: "Host CPU", value: percent(sample.cpu.cpu_usage_percent))
                    ForEach(sample.gpus, id: \.id) { gpu in
                        Text(gpu.name).font(.caption2).lineLimit(1)
                        metricRow(label: "Host GPU", value: percent(gpu.metrics["gpu_usage_percent"]))
                        metricRow(label: "Host encoder", value: percent(gpu.metrics["gpu_encoder_percent"]))
                        if let temperature = gpu.metrics["gpu_temperature_c"] {
                            metricRow(label: "Host GPU temp", value: String(format: "%.0f °C", temperature))
                        }
                        if let vram = gpu.metrics["gpu_vram_used_mb"] {
                            metricRow(label: "Host VRAM", value: String(format: "%.0f MiB", vram))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .frame(width: 300)
        .allowsHitTesting(false)
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "Unavailable"
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
