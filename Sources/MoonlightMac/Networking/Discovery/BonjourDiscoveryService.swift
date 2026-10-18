import Foundation
import Network

@MainActor
public final class BonjourDiscoveryService: ObservableObject, @unchecked Sendable {
    public static let shared = BonjourDiscoveryService()

    @Published public private(set) var discoveredHosts: [Host] = []
    @Published public private(set) var isSearching: Bool = false

    private var resolver: NetServiceResolver?
    private var probeTask: Task<Void, Never>?

    private init() {}

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true
        AppLogger.shared.info("Starting Bonjour mDNS host discovery (_nvstream._tcp)...", category: "DISCOVERY")

        let r = NetServiceResolver()
        r.onHostResolved = { [weak self] name, ip, port in
            AppLogger.shared.info("mDNS resolved host: \(name) at \(ip):\(port)", category: "DISCOVERY")
            Task { @MainActor [weak self] in
                self?.addOrUpdateDiscoveredHost(name: name, address: ip, httpPort: port)
            }
        }
        r.onSearchStopped = { [weak self] in
            AppLogger.shared.debug("mDNS search stopped", category: "DISCOVERY")
            Task { @MainActor [weak self] in
                self?.isSearching = false
            }
        }
        r.start()
        self.resolver = r

        // Active subnet probe fallback (for AP isolation / router multicast filtering)
        startActiveSubnetProbe()
    }

    public func stopDiscovery() {
        AppLogger.shared.info("Stopping host discovery", category: "DISCOVERY")
        resolver?.stop()
        resolver = nil
        probeTask?.cancel()
        probeTask = nil
        isSearching = false
    }

    // MARK: - Host Management

    public func addOrUpdateDiscoveredHost(name: String, address: String, httpPort: Int = 47989) {
        if let idx = discoveredHosts.firstIndex(where: { $0.address == address }) {
            discoveredHosts[idx].name = name
            discoveredHosts[idx].lastSeen = Date()
            discoveredHosts[idx].status = .online
        } else {
            let newHost = Host(
                name: name,
                address: address,
                httpsPort: 47984,
                httpPort: httpPort,
                status: .online
            )
            discoveredHosts.append(newHost)
            AppLogger.shared.info("Discovered new host candidate: \(name) at \(address)", category: "DISCOVERY")

            // Probe serverinfo in background to retrieve accurate hostname and https port
            Task {
                if let (verified, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: newHost) {
                    await MainActor.run {
                        if let i = self.discoveredHosts.firstIndex(where: { $0.address == address }) {
                            self.discoveredHosts[i] = verified
                            AppLogger.shared.info("Host \(verified.name) (\(address)) updated - Paired: \(verified.isPaired)", category: "DISCOVERY")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Active Subnet Probe Fallback

    private func startActiveSubnetProbe() {
        probeTask?.cancel()
        probeTask = Task.detached(priority: .utility) { [weak self] in
            // Find local network IP prefixes
            var localIps: [String] = []
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&ifaddr) == 0 {
                var ptr = ifaddr
                while ptr != nil {
                    defer { ptr = ptr?.pointee.ifa_next }
                    guard let interface = ptr?.pointee else { continue }
                    let addrFamily = interface.ifa_addr.pointee.sa_family
                    if addrFamily == UInt8(AF_INET) {
                        let name = String(cString: interface.ifa_name)
                        if name.hasPrefix("en") { // Wi-Fi / Ethernet
                            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            var sin = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                            inet_ntop(AF_INET, &sin.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                            ipBuffer[Int(INET_ADDRSTRLEN) - 1] = 0
                            ipBuffer.withUnsafeBufferPointer { ptr in
                                if let base = ptr.baseAddress {
                                    localIps.append(String(cString: base))
                                }
                            }
                        }
                    }
                }
                freeifaddrs(ifaddr)
            }

            // For each local IP (e.g. 192.168.1.84), check subnet
            for localIp in localIps {
                let parts = localIp.split(separator: ".")
                guard parts.count == 4 else { continue }
                let subnetPrefix = "\(parts[0]).\(parts[1]).\(parts[2])"

                // Check default gateway and common host IPs first
                let priorityEndings = [240, 187, 100, 101, 102, 150, 200, 1]
                for end in priorityEndings {
                    if Task.isCancelled { return }
                    let targetIp = "\(subnetPrefix).\(end)"
                    if targetIp == localIp { continue }

                    let candidate = Host(name: "Searching...", address: targetIp, httpPort: 47989)
                    if let (verified, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: candidate) {
                        await MainActor.run { [weak self] in
                            self?.addOrUpdateDiscoveredHost(name: verified.name, address: targetIp, httpPort: 47989)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dedicated NetService Delegate (Encapsulates non-Sendable NetService objects)

private final class NetServiceResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private var browser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []

    var onHostResolved: (@Sendable (String, String, Int) -> Void)?
    var onSearchStopped: (@Sendable () -> Void)?

    func start() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.schedule(in: .main, forMode: .common)
        b.searchForServices(ofType: "_nvstream._tcp.", inDomain: "")
        self.browser = b
    }

    func stop() {
        browser?.stop()
        browser?.remove(from: .main, forMode: .common)
        browser = nil
        resolvingServices.forEach {
            $0.stop()
            $0.remove(from: .main, forMode: .common)
        }
        resolvingServices.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5.0)
        resolvingServices.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.removeAll(where: { $0.name == service.name })
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        onSearchStopped?()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let port = sender.port > 0 ? sender.port : 47989
        guard let addresses = sender.addresses else { return }

        for addrData in addresses {
            addrData.withUnsafeBytes { ptr in
                let sockaddr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                if sockaddr.pointee.sa_family == UInt8(AF_INET) {
                    let sin = ptr.bindMemory(to: sockaddr_in.self).baseAddress!
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var inAddr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &inAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                    ipBuffer[Int(INET_ADDRSTRLEN) - 1] = 0
                    let ip = ipBuffer.withUnsafeBufferPointer { ptr in
                        ptr.baseAddress.map { String(cString: $0) } ?? ""
                    }
                    if !ip.isEmpty && ip != "0.0.0.0" && ip != "127.0.0.1" {
                        onHostResolved?(name, ip, port)
                    }
                }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        // Ignored
    }
}
