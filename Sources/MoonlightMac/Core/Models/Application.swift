import Foundation

public struct StreamApp: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var isAppCollectorGame: Bool
    public var boxArtUrl: URL?
    public var uuid: String?
    public var hostOrder: Int?
    public var artVersion: String?
    public var stableIdentity: String { uuid.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? String(id) }
    public enum Control: Int, Sendable { case resume = 1, disconnectMonitor, disconnectInput, terminate, monitor, input, runningGame }
    public var control: Control? {
        let roles = [2147483501: Control.resume, 2147483502: .disconnectMonitor, 2147483503: .disconnectInput,
                     2147483504: .terminate, 2147483505: .monitor, 2147483506: .input, 2147483507: .runningGame,
                     2147483511: .resume, 2147483514: .terminate, 2147483515: .monitor, 2147483516: .input]
        if let role = roles[id] { return role }
        // Earlier Vibepollo builds used the 2147483601–3606 control range.
        if (2147483601...2147483606).contains(id) { return Control(rawValue: id - 2147483600) }
        if let uuid, uuid.lowercased().hasPrefix("9a1c5a25-58fe-40e0-b9aa-7d3f0000000"),
           let digit = uuid.last.flatMap({ Int(String($0)) }), let control = Control(rawValue: digit) { return control }
        return nil
    }
    public var isHostAction: Bool { [.disconnectMonitor, .disconnectInput, .terminate].contains(control) }
    public var isRemoteMonitor: Bool { control == .monitor }
    public func matchesRunning(on host: Host) -> Bool {
        if let running = host.currentAppUUID, let uuid {
            return running.caseInsensitiveCompare(uuid) == .orderedSame
        }
        return host.currentAppId == id
    }

    public init(id: Int, title: String, isAppCollectorGame: Bool = false, boxArtUrl: URL? = nil) {
        self.id = id
        self.title = title
        self.isAppCollectorGame = isAppCollectorGame
        self.boxArtUrl = boxArtUrl
    }
}
