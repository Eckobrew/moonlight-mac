import SwiftUI
import MoonlightCommonC

/// Read-only diagnostic view of everything known about a host.
///
/// Values come from the serverinfo response and the saved host record, which is what support
/// requests usually need: addresses, ports, pairing state, protocol versions and codec support.
struct HostDetailsSheet: View {
    let host: Host
    let appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identitySection
                    connectionSection
                    pairingSection
                    capabilitiesSection
                    if let refreshError = refreshError {
                        Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: host.status == .streaming ? "play.display" : "display")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(statusColor)
                .frame(width: 44, height: 44)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(.title3)
                    .fontWeight(.bold)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(host.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    private var identitySection: some View {
        detailGroup("Host") {
            row("Name", host.name)
            row("Address", host.address)
            if let remote = host.remoteAddress, !remote.isEmpty {
                row("Remote address", remote)
            }
            if let active = host.activeAddress, active != host.address {
                row("Active address", active)
            }
            row("Server ID", host.serverId ?? "Not reported", mono: true)
            row("MAC address", host.macAddress ?? "Not reported", mono: true)
        }
    }

    private var connectionSection: some View {
        detailGroup("Connection") {
            row("HTTPS port", "\(host.httpsPort)")
            row("HTTP port", "\(host.httpPort)")
            row("Last seen", host.lastSeen.formatted(date: .abbreviated, time: .standard))
            if let appId = host.currentAppId {
                let title = appState.appsForSelectedHost.first(where: { $0.id == appId })?.title
                row("Running app", title ?? "App #\(appId)")
            } else {
                row("Running app", "None")
            }
        }
    }

    private var pairingSection: some View {
        detailGroup("Pairing & Versions") {
            row("Paired", host.isPaired ? "Yes" : "No")
            row("Application version", host.appVersion.isEmpty ? "Unknown" : host.appVersion)
            row("GFE version", host.gfeVersion.isEmpty ? "Not reported" : host.gfeVersion)
            row("Server version", host.serverVersion.isEmpty ? "Unknown" : host.serverVersion)
        }
    }

    private var capabilitiesSection: some View {
        detailGroup("Codec support") {
            let mask = host.serverCodecModeSupport
            capabilityRow("H.264", supported: mask & Int32(SCM_H264) != 0)
            capabilityRow("HEVC (H.265)", supported: mask & Int32(SCM_HEVC) != 0)
            capabilityRow("HEVC 10-bit (HDR)", supported: mask & Int32(SCM_HEVC_MAIN10) != 0)
            capabilityRow("AV1", supported: mask & Int32(SCM_AV1_MAIN8 | SCM_AV1_MAIN10) != 0)
            capabilityRow("4:4:4 chroma", supported: mask & Int32(SCM_H264_HIGH8_444 | SCM_HEVC_REXT8_444 | SCM_HEVC_REXT10_444 | SCM_AV1_HIGH8_444 | SCM_AV1_HIGH10_444) != 0)
        }
    }

    private var footer: some View {
        HStack {
            if isRefreshing {
                ProgressView().controlSize(.small)
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { refresh() }
                .disabled(isRefreshing)
            Button("Copy Details") { copyToPasteboard() }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch host.status {
        case .online: return .green
        case .streaming: return .blue
        case .pairingRequired: return .orange
        case .offline: return .secondary
        case .unknown: return .secondary
        }
    }

    private func refresh() {
        isRefreshing = true
        refreshError = nil
        Task {
            do {
                let (updated, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
                await MainActor.run {
                    appState.addOrUpdateHost(updated)
                    isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    refreshError = error.localizedDescription
                    isRefreshing = false
                }
            }
        }
    }

    private func copyToPasteboard() {
        let text = """
        Host: \(host.name)
        Status: \(host.status.rawValue)
        Address: \(host.address)
        Remote: \(host.remoteAddress ?? "none")
        Active: \(host.activeAddress ?? "none")
        Server ID: \(host.serverId ?? "none")
        MAC: \(host.macAddress ?? "none")
        HTTPS: \(host.httpsPort)  HTTP: \(host.httpPort)
        Paired: \(host.isPaired)
        App version: \(host.appVersion)
        GFE version: \(host.gfeVersion)
        Codec mask: 0x\(String(format: "%08X", host.serverCodecModeSupport))
        Last seen: \(host.lastSeen.formatted())
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func detailGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .font(mono ? .system(.body, design: .monospaced) : .body)
            Spacer()
        }
        .font(.callout)
    }

    private func capabilityRow(_ label: String, supported: Bool) -> some View {
        HStack {
            Text(label)
                .frame(width: 150, alignment: .leading)
            Image(systemName: supported ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(supported ? Color.green : Color.secondary)
            Text(supported ? "Supported" : "Not advertised")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }
}
