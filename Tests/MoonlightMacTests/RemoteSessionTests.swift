import Foundation
import Testing

@testable import MoonlightMac

@Test func remoteBitratePolicyPreservesFractionalMbps() throws {
    var settings = StreamSettings()
    #expect(settings.remoteBitrateMbps == 0)
    #expect(settings.validationMessage == nil)
    settings.bitrateMbps = 25
    #expect(settings.streamBitrateKbps(isRemote: true) == 25000)
    settings.enableRemoteBitrate = true
    #expect(settings.streamBitrateKbps(isRemote: true) == 6250)
    #expect(settings.streamBitrateKbps(isRemote: false) == 25000)
    settings.bitrateMbps = 1
    #expect(settings.streamBitrateKbps(isRemote: true) == 250)
    settings.remoteBitrateMbps = 12
    #expect(settings.streamBitrateKbps(isRemote: true) == 12000)
    #expect(settings.streamBitrateKbps(isRemote: false) == 1000)
    let restored = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.remoteBitrateMbps == 12)
    #expect(restored.streamBitrateKbps(isRemote: true) == 12000)
    settings.remoteBitrateMbps = -1
    #expect(settings.validationMessage != nil)
    settings.remoteBitrateMbps = 501
    #expect(settings.validationMessage != nil)
    var legacyValues = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(StreamSettings())) as? [String: Any])
    legacyValues.removeValue(forKey: "remoteBitrateMbps")
    let legacy = try JSONDecoder().decode(
        StreamSettings.self, from: JSONSerialization.data(withJSONObject: legacyValues))
    #expect(legacy.remoteBitrateMbps == 0)
}

@Test func remoteClassificationUsesActualRoute() {
    for local in [
        "192.168.1.4", "127.0.0.2", "10.1.2.3", "172.31.1.2", "[::1]", "fd00::4", "febf::4", "fe80::1%en0",
        "::ffff:192.168.1.4",
    ] {
        #expect(!NetworkReachability.isRemoteAddress(local), "Expected local: \(local)")
    }
    for remote in ["100.64.1.2", "100.127.1.2", "fd7a:115c:a1e0::4", "my-host.ts.net.", "203.0.113.2"] {
        #expect(NetworkReachability.isRemoteAddress(remote), "Expected remote: \(remote)")
    }
    #expect(!NetworkReachability.isLocalNetworkAddress(""))
    #expect(!NetworkReachability.isLocalNetworkAddress("10.1.999.4"))
    #expect(!NetworkReachability.isTailscaleAddress("100.64.999.4"))
    #expect(!NetworkReachability.isRemoteAddress("host.example", resolvedAddresses: ["192.168.1.4"]))
    #expect(NetworkReachability.isRemoteAddress("host.example", resolvedAddresses: ["192.168.1.4", "203.0.113.2"]))
    #expect(
        !NetworkReachability.isRemoteAddress(
            "host.example", resolvedAddresses: ["203.0.113.2"], clientExternalAddress: "203.0.113.2"))
    // An advertised WAN address matching our gateway must not make a different active WAN local.
    #expect(NetworkReachability.isRemoteAddress("203.0.113.3", clientExternalAddress: "203.0.113.2"))
    #expect(!NetworkReachability.isUsableRemoteAddress("0.0.0.0"))
    #expect(!NetworkReachability.isUsableRemoteAddress("::"))
    #expect(NetworkReachability.isUsableRemoteAddress(" 203.0.113.2 "))
}
