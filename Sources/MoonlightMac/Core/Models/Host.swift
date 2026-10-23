import Foundation

public enum HostStatus: String, Codable, Sendable {
    case online
    case offline
    case pairingRequired
    case streaming
    case unknown
}

public struct Host: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var remoteAddress: String?
    public var activeAddress: String?
    public var httpsPort: Int
    public var httpPort: Int
    public var status: HostStatus
    public var serverVersion: String
    public var gfeVersion: String
    public var appVersion: String
    public var macAddress: String?
    public var serverId: String?
    public var serverCodecModeSupport: Int32
    public var serverCertificateDER: Data?
    public var isPaired: Bool
    public var currentAppId: Int?
    public var lastSeen: Date

    public init(
        id: UUID = UUID(),
        name: String,
        address: String,
        remoteAddress: String? = nil,
        activeAddress: String? = nil,
        httpsPort: Int = 47984,
        httpPort: Int = 47989,
        status: HostStatus = .unknown,
        serverVersion: String = "",
        gfeVersion: String = "",
        appVersion: String = "",
        macAddress: String? = nil,
        serverId: String? = nil,
        serverCodecModeSupport: Int32 = 0,
        isPaired: Bool = false,
        serverCertificateDER: Data? = nil,
        currentAppId: Int? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.remoteAddress = remoteAddress
        self.activeAddress = activeAddress
        self.httpsPort = httpsPort
        self.httpPort = httpPort
        self.status = status
        self.serverVersion = serverVersion
        self.gfeVersion = gfeVersion
        self.appVersion = appVersion
        self.macAddress = macAddress
        self.serverId = serverId
        self.serverCodecModeSupport = serverCodecModeSupport
        self.isPaired = isPaired
        self.serverCertificateDER = serverCertificateDER
        self.currentAppId = currentAppId
        self.lastSeen = lastSeen
    }

    /// Matches common-c’s negative fourth application-version component.
    var supportsExtendedControllers: Bool {
        let parts = appVersion.split(separator: ".")
        return parts.count == 4 && (Int(parts[3]) ?? 0) < 0
    }

    public var isSecurelyPaired: Bool { isPaired && serverCertificateDER != nil }
    public var needsCertificatePairing: Bool { isPaired && serverCertificateDER == nil }

    public var effectiveAddress: String {
        activeAddress ?? address
    }

    /// IPv6 literals need brackets in URL authorities, but not in socket addresses.
    static func urlHost(_ address: String) -> String {
        guard address.contains(":"), !address.hasPrefix("[") else { return address }
        return "[\(address)]"
    }

    var urlAddress: String { Self.urlHost(effectiveAddress) }

    public var baseUrlHttps: URL? {
        URL(string: "https://\(urlAddress):\(httpsPort)")
    }

    public var baseUrlHttp: URL? {
        URL(string: "http://\(urlAddress):\(httpPort)")
    }

    public var isOnline: Bool {
        status == .online || status == .streaming
    }
}
