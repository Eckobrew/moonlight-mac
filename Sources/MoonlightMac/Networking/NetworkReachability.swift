import Foundation
import MoonlightCommonC
import Network

public enum NetworkReachability {
    static func normalizedAddress(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func isUsableRemoteAddress(_ address: String) -> Bool {
        let value = normalizedAddress(address)
        if let ip = IPv4Address(value) { return ip.rawValue.contains(where: { $0 != 0 }) }
        if let ip = IPv6Address(value) { return ip.rawValue.contains(where: { $0 != 0 }) }
        return false
    }

    public static func isTailscaleAddress(_ address: String) -> Bool {
        let value = normalizedAddress(address)
        if value.hasSuffix(".ts.net") { return true }
        if let ip = IPv4Address(value) {
            let bytes = Array(ip.rawValue)
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        if let ip = IPv6Address(value) {
            return Array(ip.rawValue.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }

    public static func isLocalNetworkAddress(_ address: String) -> Bool {
        let value = normalizedAddress(address)
        if isTailscaleAddress(value) { return false }
        if value == "localhost" || value.hasSuffix(".local") { return true }
        if let ip = IPv4Address(value) {
            let b = Array(ip.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        let literal = String(value.prefix(while: { $0 != "%" }))
        if let ip = IPv6Address(literal) {
            let b = Array(ip.rawValue)
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 255, b[11] == 255 {
                return isLocalNetworkAddress(b.suffix(4).map(String.init).joined(separator: "."))
            }
            return b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1
                || b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80)
        }
        return false
    }

    /// Use the actual route, never an unrelated WAN address advertised by the host.
    static func isRemoteAddress(
        _ address: String, resolvedAddresses: [String] = [], clientExternalAddress: String? = nil
    ) -> Bool {
        if isTailscaleAddress(address) { return true }
        let targets =
            resolvedAddresses.isEmpty ? [normalizedAddress(address)] : resolvedAddresses.map(normalizedAddress)
        if targets.contains(where: isTailscaleAddress) { return true }
        if isLocalNetworkAddress(address) || targets.allSatisfy(isLocalNetworkAddress) { return false }
        if let wan = clientExternalAddress.map(normalizedAddress), !targets.isEmpty,
            targets.allSatisfy({ $0 == wan })
        {
            return false
        }
        return true
    }

    private static func resolve(_ address: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(normalizedAddress(address), nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }
        var values: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let entry = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
                NI_NUMERICHOST) == 0
            {
                values.append(
                    String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            current = entry.pointee.ai_next
        }
        return values
    }

    /// Queries client public WAN IPv4 address via STUN.
    public static func queryClientExternalAddress() -> String? {
        var clientWanNetworkOrder: UInt32 = 0
        let res = LiFindExternalAddressIP4("stun.moonlight-stream.org", 3478, &clientWanNetworkOrder)
        guard res == 0 else {
            AppLogger.shared.warning("STUN public WAN query failed with error: \(res)", category: "NETWORK")
            return nil
        }

        var inAddr = in_addr(s_addr: clientWanNetworkOrder)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }

        return buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        }
    }

    public static func isRemoteSession(host: Host) async -> Bool {
        let address = host.effectiveAddress
        // DNS and common-c's blocking STUN lookup must not occupy the UI thread.
        return await Task.detached(priority: .utility) {
            if isTailscaleAddress(address) { return true }
            if isLocalNetworkAddress(address) { return false }
            let targets = resolve(address)
            if targets.contains(where: isTailscaleAddress) { return true }
            if !isRemoteAddress(address, resolvedAddresses: targets) { return false }
            return isRemoteAddress(
                address, resolvedAddresses: targets, clientExternalAddress: queryClientExternalAddress())
        }.value
    }
}

/// STUN discovers the client's address. Only infer a host address when its IPv4
/// is on a physical local subnet; a private address reached through a VPN is insufficient.
extension NetworkReachability {
    static func isDirectlyConnectedIPv4(_ address: String) -> Bool {
        guard isLocalNetworkAddress(address), !isTailscaleAddress(address) else { return false }
        var target = in_addr()
        guard inet_pton(AF_INET, normalizedAddress(address), &target) == 1 else { return false }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let interface = entry.pointee
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  String(cString: interface.ifa_name).hasPrefix("en"),
                  let addr = interface.ifa_addr, addr.pointee.sa_family == AF_INET,
                  let mask = interface.ifa_netmask else { continue }
            let local = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let subnet = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            if subnet != 0, target.s_addr & subnet == local & subnet { return true }
        }
        return false
    }
}

actor RemoteAddressDiscovery {
    static let shared = RemoteAddressDiscovery()
    typealias Verifier = @Sendable (String, Int, Int, Host) async -> Bool
    private struct Key: Hashable {
        let id: UUID
        let certificate: Data?
        let serverID: String?
        let address: String
        let httpsPort: Int
        let httpPort: Int
        let reportedAddress: String?
        let reportedHTTPPort: Int?
    }
    private struct Result: Sendable {
        var address: String?
        var candidate: String?
        var httpsPort: Int?
        var httpPort: Int?
        var status: String
    }
    private struct Attempt {
        let id = UUID()
        let date: Date
        let task: Task<Result, Never>
        var lifetime: TimeInterval = 15
    }
    private var attempts: [Key: Attempt] = [:]
    private struct STUNAttempt {
        let id: UUID
        let date: Date
        let task: Task<String?, Never>
        var lifetime: TimeInterval = 15
    }
    private var stun: STUNAttempt?
    private let now: @Sendable () -> Date
    private let query: @Sendable () async -> String?
    private let isLocal: @Sendable (String) -> Bool

    init(query: @escaping @Sendable () async -> String? = {
        await Task.detached(priority: .utility) { NetworkReachability.queryClientExternalAddress() }.value
    }, isLocal: @escaping @Sendable (String) -> Bool = { NetworkReachability.isDirectlyConnectedIPv4($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        self.query = query
        self.isLocal = isLocal
    }

    func update(host: Host, reportedAddress: String?, reportedHTTPPort: Int?, force: Bool = false, verify: @escaping Verifier) async -> Host {
        var updated = host
        guard host.isSecurelyPaired, let identity = host.serverId, !identity.isEmpty else {
            updated.remoteAddressVerification = "Pair with this PC to verify remote access."
            return updated
        }
        let key = Key(id: host.id, certificate: host.serverCertificateDER, serverID: host.serverId,
                      address: host.address, httpsPort: host.httpsPort, httpPort: host.httpPort,
                      reportedAddress: reportedAddress, reportedHTTPPort: reportedHTTPPort)
        let task: Task<Result, Never>
        let attemptID: UUID
        if !force, let existing = attempts[key], now().timeIntervalSince(existing.date) < existing.lifetime {
            task = existing.task
            attemptID = existing.id
        } else {
            // Share one STUN request across hosts and cache failures too.
            let stunTask: Task<String?, Never>?
            if reportedAddress.map(NetworkReachability.isUsableRemoteAddress) != true && isLocal(host.address) {
                if !force, let existing = stun, now().timeIntervalSince(existing.date) < existing.lifetime {
                    stunTask = existing.task
                } else {
                    let id = UUID()
                    let pending = Task {
                        let value = await query()
                        if self.stun?.id == id { self.stun?.lifetime = value == nil ? 15 : 300 }
                        return value
                    }
                    stun = STUNAttempt(id: id, date: now(), task: pending)
                    stunTask = pending
                }
            } else {
                stunTask = nil
            }
            task = Task {
                let reported = reportedAddress.flatMap { NetworkReachability.isUsableRemoteAddress($0) ? NetworkReachability.normalizedAddress($0) : nil }
                let discovered = await stunTask?.value
                guard let address = reported ?? discovered, NetworkReachability.isUsableRemoteAddress(address) else {
                    return Result(status: "No remote address available from the host or local STUN discovery.")
                }
                let httpPort = reportedHTTPPort.flatMap { (1...65535).contains($0) ? $0 : nil } ?? host.httpPort
                // GameStream normally maps HTTPS five ports below HTTP. This is
                // only a candidate: never accept the derived port without pinned TLS.
                var ports = [host.remoteHTTPSPort ?? host.httpsPort]
                if !ports.contains(host.httpsPort) { ports.append(host.httpsPort) }
                if httpPort > 5 && !ports.contains(httpPort - 5) { ports.append(httpPort - 5) }
                for port in ports where (1...65535).contains(port) {
                    if await verify(address, port, httpPort, host) {
                        return Result(address: address, candidate: address, httpsPort: port, httpPort: httpPort,
                                      status: "Verified: HTTPS certificate and server ID match; HTTP server ID matches (\(reported == nil ? "STUN" : "host-reported")).")
                    }
                }
                return Result(candidate: address, status: "Could not verify \(address) on HTTP port \(httpPort) and HTTPS ports \(ports.map(String.init).joined(separator: ", ")). The endpoint may be unreachable, or its identity did not match. Router loopback may be unavailable.")
            }
            attempts = attempts.filter { now().timeIntervalSince($0.value.date) < 300 }
            let attempt = Attempt(date: now(), task: task)
            attemptID = attempt.id
            attempts[key] = attempt
        }
        let result = await task.value
        if attempts[key]?.id == attemptID { attempts[key]?.lifetime = result.address == nil ? 15 : 300 }
        updated.remoteAddressCandidate = result.candidate
        // Failed candidates never overwrite a previously saved route. Every use
        // of that route still rechecks the pin and server ID in fetchServerInfo.
        if let address = result.address {
            updated.remoteAddress = address
            updated.remoteHTTPSPort = result.httpsPort
            updated.remoteHTTPPort = result.httpPort
        }
        updated.remoteAddressVerification = result.status
        return updated
    }
}
