import Foundation

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
            try Task.checkCancellation()
            do {
                try send(packetData, to: destination, port: port)
                sent = true
            } catch {
                lastError = error
            }
        }

        if !sent, let error = lastError {
            throw error
        }
    }

    /// UDP does not need a connection handshake. A nonblocking send avoids
    /// waiting indefinitely for NWConnection to become ready on an offline network.
    static func send(_ packetData: Data, to broadcastAddress: String, port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var broadcast: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, broadcastAddress, &address.sin_addr) == 1 else { throw URLError(.badURL) }
        let count = packetData.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard count == packetData.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
