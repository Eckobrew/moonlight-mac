import Foundation
import Network

public enum WakeOnLAN {
    public static func wake(macAddress: String, broadcastAddress: String = "255.255.255.255", port: UInt16 = 9) async throws {
        // Normalize MAC address: remove colons/dashes
        let cleanMac = macAddress.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleanMac.count == 12, let macBytes = CryptoUtils.dataFromHex(cleanMac) else {
            throw NSError(domain: "WakeOnLAN", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid MAC address format"])
        }

        // Magic packet = 6 bytes of 0xFF followed by 16 repetitions of the target MAC address
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(macBytes)
        }
        let packetData = packet

        let host = NWEndpoint.Host(broadcastAddress)
        let portEndpoint = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let connection = NWConnection(host: host, port: portEndpoint, using: params)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packetData, completion: .contentProcessed { error in
                        connection.cancel()
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                    })
                case .failed(let error):
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
}
