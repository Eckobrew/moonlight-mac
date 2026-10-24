import Foundation

public enum VirtualDisplayMode: String, Codable, CaseIterable, Sendable {
    case hostDefault = "Host default", virtual = "Virtual display", physical = "Physical display"
}

public struct HostCapabilities: Codable, Equatable, Hashable, Sendable {
    public var permission: UInt32?
    public var virtualDisplayCapable: Bool
    public var virtualDisplayReady: Bool
    public var virtualDisplayHDR: Bool
    public var hardwareMetricsVersion: Int
    public var sleepAvailable: Bool
    public var commands: [String]

    public func allows(_ permission: UInt32) -> Bool { self.permission.map { $0 & permission != 0 } ?? true }
    public var canView: Bool { allows((1 << 25) | (1 << 26)) }
    public var canLaunch: Bool { allows(1 << 26) }
    public var canRunCommands: Bool { allows(1 << 20) }

    static func parse(_ values: [String: String], commands: [String]) -> Self {
        func flag(_ key: String) -> Bool { ["1", "true"].contains(values[key]?.lowercased() ?? "") }
        return Self(permission: values["Permission"].flatMap(UInt32.init),
                    virtualDisplayCapable: flag("VirtualDisplayCapable"),
                    virtualDisplayReady: flag("VirtualDisplayDriverReady"), virtualDisplayHDR: flag("VirtualDisplayHDRCapable"),
                    hardwareMetricsVersion: Int(values["HardwareMetricsVersion"] ?? "0") ?? 0,
                    sleepAvailable: values["PowerActionVersion"] == "1" && flag("SleepSupported") && flag("SleepAllowed"),
                    commands: commands)
    }
}

/// Repeated XML elements cannot be represented by the legacy flat dictionary.
final class HostXMLValues: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var values: [String: [String]] = [:]
    static func elements(_ name: String, data: Data) -> [String] {
        let reader = HostXMLValues()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { return [] }
        return reader.values[name] ?? []
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count == 2 { values[name, default: []].append(text) }
        stack.removeLast(); text = ""
    }
}

public struct HostHardwareMetrics: Decodable, Sendable, Equatable {
    public struct CPU: Decodable, Sendable, Equatable { public var cpu_usage_percent: Double? }
    public struct GPU: Decodable, Sendable, Equatable {
        public var id: Int
        public var name: String
        public var metrics: [String: Double]
    }
    public var version: Int
    public var sampled_at_unix_ms: Double
    public var interval_ms: Int
    public var cpu: CPU
    public var gpus: [GPU]
}

public struct OTPPairing: Sendable {
    public let code: String
    public let passphrase: String
    public init(code: String, passphrase: String) { self.code = code; self.passphrase = passphrase }
    public var isValid: Bool { code.count == 4 && passphrase.utf8.count >= 4 && code.utf8.allSatisfy { (48...57).contains($0) } }
    func authentication(saltHex: String) -> String {
        CryptoUtils.hexString(CryptoUtils.sha256(Data((code + saltHex + passphrase).utf8))).uppercased()
    }
}
