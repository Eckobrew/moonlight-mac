import Foundation
import Network

@MainActor
public final class BonjourDiscoveryService: ObservableObject {
    public static let shared = BonjourDiscoveryService()

    @Published public private(set) var discoveredHosts: [Host] = []
    @Published public private(set) var isSearching: Bool = false

    private var browser: NWBrowser?
    private var resolveConnections: [String: NWConnection] = [:]

    private init() {}

    public func startDiscovery() {
        guard !isSearching else { return }
        isSearching = true

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        // Sunshine and GameStream advertise via _nvstream._tcp
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_nvstream._tcp", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed(let error):
                    print("Bonjour discovery failed: \(error)")
                    self?.isSearching = false
                case .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            switch result.endpoint {
            case .service(let name, _, _, _):
                resolveEndpoint(result.endpoint, serviceName: name)
            default:
                break
            }
        }
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, serviceName: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            switch state {
            case .ready:
                if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = innerEndpoint {
                    let hostString: String
                    switch host {
                    case .ipv4(let addr):
                        hostString = "\(addr)"
                    case .ipv6(let addr):
                        hostString = "\(addr)"
                    case .name(let name, _):
                        hostString = name
                    @unknown default:
                        hostString = "\(host)"
                    }
                    Task { @MainActor in
                        self.addOrUpdateDiscoveredHost(name: serviceName, address: hostString, httpsPort: Int(port.rawValue))
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    public func addOrUpdateDiscoveredHost(name: String, address: String, httpsPort: Int = 47989) {
        if let idx = discoveredHosts.firstIndex(where: { $0.address == address }) {
            discoveredHosts[idx].name = name
            discoveredHosts[idx].lastSeen = Date()
        } else {
            let newHost = Host(
                name: name,
                address: address,
                httpsPort: httpsPort,
                status: .online
            )
            discoveredHosts.append(newHost)
        }
    }
}
