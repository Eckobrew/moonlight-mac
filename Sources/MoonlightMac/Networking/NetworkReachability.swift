import Foundation
import MoonlightCommonC

public enum NetworkReachability {
    /// Determines whether the given IP address or hostname belongs to Tailscale.
    /// Tailscale uses the Carrier-Grade NAT (CGNAT) block 100.64.0.0/10 for IPv4,
    /// the fd7a:115c:a1e0::/48 ULA prefix for IPv6, or .ts.net MagicDNS domains.
    public static func isTailscaleAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.hasSuffix(".ts.net") {
            return true
        }

        if trimmed.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }

        let parts = trimmed.split(separator: ".")
        if parts.count == 4,
           let first = Int(parts[0]),
           let second = Int(parts[1]),
           first == 100,
           (64...127).contains(second) {
            return true
        }

        return false
    }

    /// Determines whether the given IP address belongs to standard private/LAN ranges:
    /// - 10.0.0.0/8
    /// - 172.16.0.0/12
    /// - 192.168.0.0/16
    /// - 169.254.0.0/16 (link-local)
    /// - Loopback (127.0.0.1, ::1, localhost)
    /// - Bonjour/mDNS .local hostnames
    public static func isLocalNetworkAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed == "localhost" || trimmed == "127.0.0.1" || trimmed == "::1" || trimmed.hasSuffix(".local") {
            return true
        }

        if trimmed.hasPrefix("fe80:") {
            return true
        }

        let parts = trimmed.split(separator: ".")
        guard parts.count == 4,
              let b0 = Int(parts[0]),
              let b1 = Int(parts[1]) else {
            return false
        }

        if b0 == 10 {
            return true
        }
        if b0 == 172 && (16...31).contains(b1) {
            return true
        }
        if b0 == 192 && b1 == 168 {
            return true
        }
        if b0 == 169 && b1 == 254 {
            return true
        }

        return false
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

    /// Determines whether connecting to this host is considered a remote session.
    ///
    /// Rules:
    /// 1. Tailscale connections (100.64.0.0/10, fd7a:115c:a1e0::/48, .ts.net) are ALWAYS remote.
    /// 2. If connecting to a local LAN address (192.168.x.x, 10.x.x.x, 172.16-31.x.x), it is local.
    /// 3. If connecting to a public WAN IP or host's remoteAddress:
    ///    We perform a STUN lookup to detect NAT Hairpinning (NAT Loopback).
    ///    If the client's public WAN IP matches the host's WAN IP, the client and host share
    ///    the same local gateway and traffic is routed locally via NAT loopback -> treat as local.
    /// 4. Otherwise, it is a remote connection over the Internet.
    public static func isRemoteSession(host: Host) async -> Bool {
        let activeAddr = host.effectiveAddress

        // 1. Tailscale is always treated as remote
        if isTailscaleAddress(activeAddr) {
            AppLogger.shared.info("Host address \(activeAddr) is in Tailscale network. Treating session as REMOTE.", category: "NETWORK")
            return true
        }

        // 2. Direct local LAN addresses
        if isLocalNetworkAddress(activeAddr) {
            AppLogger.shared.info("Host address \(activeAddr) is on local LAN. Treating session as LOCAL.", category: "NETWORK")
            return false
        }

        // 3. Check for NAT Hairpinning if host has a remote address or activeAddr is public
        let targetWan = host.remoteAddress ?? activeAddr
        if let clientWan = queryClientExternalAddress() {
            if clientWan == targetWan {
                AppLogger.shared.info("Detected NAT hairpinning for \(host.name): client WAN [\(clientWan)] matches host WAN [\(targetWan)]. Treating connection as LOCAL.", category: "NETWORK")
                return false
            } else {
                AppLogger.shared.info("Host WAN [\(targetWan)] does not match client WAN [\(clientWan)]. Treating session as REMOTE.", category: "NETWORK")
                return true
            }
        }

        // 4. Default: non-local IP without matching hairpinning is remote
        AppLogger.shared.info("Host address \(activeAddr) is non-local and STUN was inconclusive. Treating session as REMOTE.", category: "NETWORK")
        return true
    }
}
