import Foundation

/// Non-blocking TCP reachability probe used before issuing TLS or RTSP work.
///
/// Shared by session startup (waiting for the host's RTSP listener) and host refresh (skipping the
/// full HTTPS/HTTP timeout pair for hosts that are asleep or unreachable).
enum TCPProbe {
    /// Attempts a TCP connect to `address:port` and returns whether the port accepted the connection.
    /// This is a bounded, single-shot probe: it never waits longer than `timeoutMilliseconds`.
    static func canConnect(address: String, port: UInt16, timeoutMilliseconds: Int32 = 200) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &res) == 0, let res = res else {
            return false
        }
        defer { freeaddrinfo(res) }

        let sock = socket(res.pointee.ai_family, res.pointee.ai_socktype, res.pointee.ai_protocol)
        if sock < 0 { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let ret = connect(sock, res.pointee.ai_addr, res.pointee.ai_addrlen)
        if ret == 0 { return true }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollRet = poll(&pfd, 1, timeoutMilliseconds)
            if pollRet > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                return err == 0
            }
        }
        return false
    }
}
