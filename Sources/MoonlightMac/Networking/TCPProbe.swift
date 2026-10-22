import Foundation

/// Bounded TCP reachability checks used before TLS and RTSP work.
enum TCPProbe {
    /// Tries every resolved address, sharing a connection timeout across them.
    /// DNS resolution itself is synchronous and is not covered by the timeout.
    static func canConnect(address: String, port: UInt16, timeoutMilliseconds: Int32 = 200) -> Bool {
        guard timeoutMilliseconds > 0, port > 0 else { return false }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &result) == 0, let result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var addresses: [UnsafeMutablePointer<addrinfo>] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let entry = current {
            addresses.append(entry)
            current = entry.pointee.ai_next
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        for (index, entry) in addresses.enumerated() {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remainingMilliseconds = Int32(clamping: (deadline - now) / 1_000_000)
            let budget = max(1, remainingMilliseconds / Int32(addresses.count - index))
            if connect(to: entry.pointee, timeoutMilliseconds: budget) { return true }
        }
        return false
    }

    private static func connect(to address: addrinfo, timeoutMilliseconds: Int32) -> Bool {
        let sock = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        guard flags >= 0, fcntl(sock, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        let status = Darwin.connect(sock, address.ai_addr, address.ai_addrlen)
        if status == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptor = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) > 0,
              descriptor.revents & Int16(POLLOUT) != 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }
}
