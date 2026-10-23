import SwiftUI

public struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var hostName: String = ""
    @State private var hostAddress: String = ""
    @State private var httpPort: String = "47989"
    @State private var isTesting: Bool = false
    @State private var errorMessage: String?

    public let onAddHost: (Host) -> Void

    public init(onAddHost: @escaping (Host) -> Void) {
        self.onAddHost = onAddHost
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text(AppLocalization.text("Add Sunshine / Apollo Host"))
                .font(.title2)
                .fontWeight(.bold)

            Text(AppLocalization.text("Enter the IP address or hostname of your PC running Sunshine or Apollo."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Form {
                TextField(AppLocalization.text("Host Name (optional):"), text: $hostName, prompt: Text(AppLocalization.text("e.g. Gaming PC")))
                TextField(AppLocalization.text("IP Address / Hostname:"), text: $hostAddress, prompt: Text(AppLocalization.text("192.168.1.100")))
                TextField(AppLocalization.text("Port (optional):"), text: $httpPort, prompt: Text(AppLocalization.text("47989")))
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(AppLocalization.text("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(AppLocalization.text("Add Host")) {
                    submitHost()
                }
                .buttonStyle(.borderedProminent)
                .disabled(hostAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func submitHost() {
        let cleanAddress = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let portInt = Int(httpPort) ?? 47989
        let name = hostName.isEmpty ? cleanAddress : hostName

        isTesting = true
        errorMessage = nil

        let newHost = Host(
            name: name,
            address: cleanAddress,
            httpsPort: 47984,
            httpPort: portInt,
            status: .unknown
        )

        Task {
            do {
                let (verifiedHost, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: newHost)
                await MainActor.run {
                    onAddHost(verifiedHost)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    // Still add host even if offline right now
                    onAddHost(newHost)
                    dismiss()
                }
            }
        }
    }
}
