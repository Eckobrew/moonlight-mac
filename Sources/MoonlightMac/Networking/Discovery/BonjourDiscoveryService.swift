import Foundation
import Network

@MainActor
public final class BonjourDiscoveryService: ObservableObject, @unchecked Sendable {
    public static let shared = BonjourDiscoveryService()

    @Published public private(set) var discoveredHosts: [Host] = []
    @Published public private(set) var isSearching: Bool = false

    private var resolver: NetServiceResolver?

    private init() {}

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true
        AppLogger.shared.info("Starting Bonjour mDNS host discovery (_nvstream._tcp)...", category: "DISCOVERY")

        let r = NetServiceResolver()
        r.onHostResolved = { [weak self] name, ip, port in
            AppLogger.shared.info("mDNS resolved host: \(name) at \(ip):\(port)", category: "DISCOVERY")
            Task { @MainActor [weak self] in
                self?.verifyAndAddDiscoveredHost(name: name, address: ip, httpPort: port)
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
    }

    public func stopDiscovery() {
        AppLogger.shared.info("Stopping host discovery", category: "DISCOVERY")
        resolver?.stop()
        resolver = nil
        isSearching = false
    }

    // MARK: - Verified Host Management (Matches Moonlight-Qt)

    public func verifyAndAddDiscoveredHost(name: String, address: String, httpPort: Int = 47989) {
        // Probe serverinfo first to ensure it's a real Sunshine / GameStream host before publishing
        let candidate = Host(
            name: name,
            address: address,
            httpsPort: 47984,
            httpPort: httpPort,
            status: .unknown,
            isPaired: false
        )

        Task {
            guard let (verified, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: candidate) else {
                AppLogger.shared.debug("Ignored unverified candidate at \(address)", category: "DISCOVERY")
                return
            }

            await MainActor.run {
                if let idx = self.discoveredHosts.firstIndex(where: {
                    $0.address == address ||
                    ($0.serverId != nil && verified.serverId != nil && $0.serverId == verified.serverId)
                }) {
                    self.discoveredHosts[idx] = verified
                } else {
                    self.discoveredHosts.append(verified)
                    AppLogger.shared.info("Added verified host: \(verified.name) (\(address)) - Paired: \(verified.isPaired)", category: "DISCOVERY")
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
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }

        for addrData in addresses {
            var storage = sockaddr_storage()
            (addrData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)

            if storage.ss_family == sa_family_t(AF_INET) {
                var addr4 = withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr4.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                ipBuffer[Int(INET_ADDRSTRLEN) - 1] = 0

                let ipString = ipBuffer.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
                guard !ipString.isEmpty else { continue }
                let port = Int(sender.port > 0 ? sender.port : 47989)
                onHostResolved?(sender.name, ipString, port)
                break
            }
        }
    }
}
