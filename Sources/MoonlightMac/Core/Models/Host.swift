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
    public var serverCodecModeSupport: Int32
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
        serverCodecModeSupport: Int32 = 0,
        isPaired: Bool = false,
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
        self.serverCodecModeSupport = serverCodecModeSupport
        self.isPaired = isPaired
        self.currentAppId = currentAppId
        self.lastSeen = lastSeen
    }

    public var effectiveAddress: String {
        activeAddress ?? address
    }

    public var baseUrlHttps: URL? {
        URL(string: "https://\(effectiveAddress):\(httpsPort)")
    }

    public var baseUrlHttp: URL? {
        URL(string: "http://\(effectiveAddress):\(httpPort)")
    }

    public var isOnline: Bool {
        status == .online || status == .streaming
    }
}
