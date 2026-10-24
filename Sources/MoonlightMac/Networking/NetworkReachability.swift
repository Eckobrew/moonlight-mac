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
