import Foundation

/// Wait for serverinfo, rather than a port opening, before exposing a host's apps.
@MainActor
enum HostWakeConnection {
    enum Failure: LocalizedError {
        case missingMAC, timedOut
        var errorDescription: String? {
            switch self {
            case .missingMAC:
                return
                    "This PC is unreachable and has no saved MAC address. Wake it manually, then connect once to save its MAC address."
            case .timedOut:
                return
                    "The PC did not respond after waking. Check that Wake-on-LAN is enabled on the PC and supported by the network."
            }
        }
    }

    static func resolve(
        host: Host,
        attempts: Int = 30,
        probe: (Host) async throws -> Host = { try await SunshineHTTPClient.shared.fetchServerInfo(host: $0).0 },
        wake: (String) async throws -> Void = { try await WakeOnLAN.wake(macAddress: $0) },
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        onWaking: () -> Void
    ) async throws -> Host {
        try Task.checkCancellation()
        do {
            let current = try await probe(host)
            guard current.isOnline || current.status == .pairingRequired else { throw URLError(.cannotConnectToHost) }
            try Task.checkCancellation()
            return current
        } catch {
            try Task.checkCancellation()
            // A trust failure is not evidence that the PC is asleep.
            if error is HostTrustError { throw error }
        }
        guard let mac = host.macAddress, SunshineHTTPClient.isValidMacAddress(mac) else { throw Failure.missingMAC }
        onWaking()
        try await wake(mac)
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        for _ in 0..<attempts {
            guard ContinuousClock.now < deadline else { break }
            try await pause()
            try Task.checkCancellation()
            do {
                let current = try await probe(host)
                guard current.isOnline || current.status == .pairingRequired else {
                    throw URLError(.cannotConnectToHost)
                }
                try Task.checkCancellation()
                return current
            } catch {
                try Task.checkCancellation()
                if error is HostTrustError { throw error }
            }
        }
        throw Failure.timedOut
    }
}
