import SwiftUI

public struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let host: Host
    public let pin: String?
    public let error: String?
    public let isPairing: Bool
    public let onCancel: () -> Void

    public init(
        host: Host,
        pin: String?,
        error: String?,
        isPairing: Bool,
        onCancel: @escaping () -> Void
    ) {
        self.host = host
        self.pin = pin
        self.error = error
        self.isPairing = isPairing
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.blue.gradient)

            Text("Pairing with \(host.name)")
                .font(.title2)
                .fontWeight(.bold)

            if host.needsCertificatePairing {
                Text("Pair this PC again to save and verify its certificate. Your saved PC settings will be kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let pin = pin {
                VStack(spacing: 12) {
                    Text("Enter this PIN on your host PC:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ForEach(Array(pin.enumerated()), id: \.offset) { _, char in
                            Text(String(char))
                                .font(.system(size: 38, weight: .bold, design: .monospaced))
                                .frame(width: 52, height: 64)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1.5)
                                )
                        }
                    }

                    Text("Sunshine / Apollo Web UI: https://\(host.urlAddress):47990/pin")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }
            } else if isPairing {
                ProgressView("Initiating handshake...")
                    .progressViewStyle(.circular)
            }

            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 420)
    }
}
