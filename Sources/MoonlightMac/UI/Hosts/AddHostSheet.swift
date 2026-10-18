import SwiftUI

public struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var hostName: String = ""
    @State private var hostAddress: String = ""
    @State private var httpsPort: String = "47989"
    @State private var isTesting: Bool = false
    @State private var errorMessage: String?

    public let onAddHost: (Host) -> Void

    public init(onAddHost: @escaping (Host) -> Void) {
        self.onAddHost = onAddHost
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("Add Sunshine / Apollo Host")
                .font(.title2)
                .fontWeight(.bold)

            Text("Enter the IP address or hostname of your PC running Sunshine or Apollo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Form {
                TextField("Host Name (optional):", text: $hostName, prompt: Text("e.g. Gaming PC"))
                TextField("IP Address / Hostname:", text: $hostAddress, prompt: Text("192.168.1.100"))
                TextField("HTTPS Port:", text: $httpsPort, prompt: Text("47989"))
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Host") {
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
        let portInt = Int(httpsPort) ?? 47989
        let name = hostName.isEmpty ? cleanAddress : hostName

        isTesting = true
        errorMessage = nil

        let newHost = Host(
            name: name,
            address: cleanAddress,
            httpsPort: portInt,
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
