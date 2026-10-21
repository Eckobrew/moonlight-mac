import Foundation
import Network

public enum WakeOnLAN {
    /// Sends a Wake-on-LAN magic packet.
    ///
    /// The packet goes to the caller-supplied address plus the machine's own subnet-directed
    /// broadcast addresses. Many hosts and routers drop 255.255.255.255 (especially over Wi-Fi),
    /// while still accepting the directed broadcast for their own subnet.
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

        var destinations = [broadcastAddress]
        for address in subnetBroadcastAddresses() where !destinations.contains(address) {
            destinations.append(address)
        }

        // Best effort: succeed if at least one destination accepted the packet.
        var lastError: Error?
        var sent = false
        for destination in destinations {
            do {
                try await send(packetData, to: destination, port: port)
                sent = true
            } catch {
                lastError = error
            }
        }

        if !sent, let error = lastError {
            throw error
        }
    }

    private static func send(_ packetData: Data, to broadcastAddress: String, port: UInt16) async throws {
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

    /// Computes `<network>.255`-style directed broadcast addresses for the machine's active
    /// non-loopback IPv4 interfaces (e.g. 192.168.1.255).
    private static func subnetBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return [] }
        defer { freeifaddrs(ifaddrPointer) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoopback,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let broadcast = (flags & IFF_BROADCAST) != 0
            guard broadcast, let ifaBroadcast = current.pointee.ifa_dstaddr else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                ifaBroadcast,
                socklen_t(ifaBroadcast.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let value = host.withUnsafeBufferPointer { buffer in
                    String(cString: buffer.baseAddress!)
                }
                if !value.isEmpty, value != "0.0.0.0" {
                    addresses.append(value)
                }
            }
        }

        return addresses
    }
}
