import SwiftUI

struct SessionControlsView: View {
    @ObservedObject var session: StreamSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var bitrate = 20.0
    @State private var command: Int?
    @State private var confirmMonitorDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Session controls").font(.title2).bold()
            if session.runtimeBitrateSupported {
                GroupBox("Live bitrate") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Applied target: \(String(format: "%.1f", Double(session.runtimeBitrateKbps) / 1000)) Mbps")
                        HStack {
                            TextField("Mbps", value: $bitrate, format: .number).frame(width: 100)
                            Text("Mbps")
                            Button(session.bitrateRequestInProgress ? "Applying…" : "Apply") {
                                Task { await session.applyRuntimeBitrate(mbps: bitrate) }
                            }.disabled(session.bitrateRequestInProgress || !bitrate.isFinite || !(0.001...500).contains(bitrate))
                        }
                        Slider(value: $bitrate, in: 1...500, step: 1)
                        Text("Changes this session only. The host may apply a lower limit.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }
            Toggle("Show statistics", isOn: $session.showPerformanceOverlay)
            if session.activeHost?.capabilities?.hardwareMetricsVersion == 1 {
                Toggle("Include host hardware statistics", isOn: $session.showHostStatistics)
                Text("Samples the host only while the statistics overlay is visible.").font(.caption).foregroundStyle(.secondary)
            }
            if let host = session.activeHost, host.capabilities?.canRunCommands == true,
               let commands = host.capabilities?.commands, !commands.isEmpty {
                Menu("Server commands…") {
                    ForEach(Array(commands.prefix(256).enumerated()), id: \.offset) { index, name in
                        Button(name) { command = index }
                    }
                }
            }
            if session.isRemoteMonitorSession {
                Button("Release remote monitor…") { confirmMonitorDisconnect = true }
                Text("Closing the stream normally follows the host's monitor retention setting. Release removes the retained monitor explicitly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = session.hostControlMessage { Text(message).font(.callout).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 460)
        .onAppear { bitrate = max(1, Double(session.runtimeBitrateKbps) / 1000) }
        .confirmationDialog("Run host command?", isPresented: Binding(
            get: { command != nil }, set: { if !$0 { command = nil } })) {
                if let index = command, let names = session.activeHost?.capabilities?.commands, names.indices.contains(index) {
                    Button("Run \(names[index])") {
                        let name = names[index]; command = nil
                        Task { await session.runServerCommand(index: index, name: name) }
                    }
                }
                Button("Cancel", role: .cancel) { command = nil }
            }
        .confirmationDialog("Release this remote monitor?", isPresented: $confirmMonitorDisconnect) {
            Button("Release monitor") { Task { await session.disconnectRemoteMonitor() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The PC's main game and other clients remain connected.") }
    }
}
