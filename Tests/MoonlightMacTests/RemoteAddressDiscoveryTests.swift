import Foundation
import Testing
@testable import MoonlightMac

private func remoteTestHost() -> MoonlightMac.Host {
    MoonlightMac.Host(name: "PC", address: "192.168.1.20", serverId: "expected-host",
         isPaired: true, serverCertificateDER: Data([1, 2, 3]))
}

private actor DiscoveryCalls {
    var queries = 0
    var ports: [Int] = []
    func query() -> String { queries += 1; return "203.0.113.20" }
    func verify(_ port: Int) -> Bool { ports.append(port); return port == 49995 }
}

@Test func stunCandidateRequiresVerificationAndCachesDiscovery() async {
    let calls = DiscoveryCalls()
    let discovery = RemoteAddressDiscovery(query: { await calls.query() }, isLocal: { _ in true })
    let host = remoteTestHost()
    let first = await discovery.update(host: host, reportedAddress: "0.0.0.0", reportedHTTPPort: 50000) {
        address, httpsPort, httpPort, expected in
        #expect(address == "203.0.113.20")
        #expect(httpPort == 50000)
        #expect(expected.serverId == host.serverId)
        return await calls.verify(httpsPort)
    }
    #expect(first.remoteAddress == "203.0.113.20")
    #expect(first.remoteHTTPSPort == 49995)
    #expect(first.remoteHTTPPort == 50000)
    #expect(first.httpPort == 47989)
    #expect(first.httpsPort == 47984)
    #expect(first.effectiveHTTPSPort == 47984)
    var remote = first
    remote.activeAddress = first.remoteAddress
    #expect(remote.effectiveHTTPSPort == 49995)
    #expect(remote.effectiveHTTPPort == 50000)
    #expect(remote.baseUrlHttps?.port == 49995)
    _ = await discovery.update(host: first, reportedAddress: "0.0.0.0", reportedHTTPPort: 50000) { _, _, _, _ in
        Issue.record("A cached endpoint must not be probed again")
        return false
    }
    #expect(await calls.queries == 1)
    #expect(await calls.ports == [47984, 49995])
}

@Test func wrongRemoteEndpointIsNeverSaved() async {
    let discovery = RemoteAddressDiscovery(query: {
        Issue.record("Reported address should take precedence over STUN")
        return nil
    }, isLocal: { _ in true })
    let host = remoteTestHost()
    let result = await discovery.update(host: host, reportedAddress: "203.0.113.21", reportedHTTPPort: 47989) { _, _, _, _ in false }
    #expect(result.remoteAddress == nil)
    #expect(result.remoteHTTPSPort == nil)
    #expect(result.remoteAddressVerification?.contains("Could not verify") == true)
    let retry = await discovery.update(host: host, reportedAddress: "203.0.113.21", reportedHTTPPort: 47989, force: true) { _, _, _, _ in true }
    #expect(retry.remoteAddress == "203.0.113.21")
}

@Test func failedDiscoveryPreservesPreviousRouteAndRemotePorts() async {
    let discovery = RemoteAddressDiscovery(query: { nil }, isLocal: { _ in true })
    var host = remoteTestHost()
    host.remoteAddress = "203.0.113.22"
    host.remoteHTTPSPort = 49995
    host.remoteHTTPPort = 50000
    let result = await discovery.update(host: host, reportedAddress: "203.0.113.21", reportedHTTPPort: 47989) { _, _, _, _ in false }
    #expect(result.remoteAddress == host.remoteAddress)
    #expect(result.remoteHTTPSPort == host.remoteHTTPSPort)
    #expect(result.remoteHTTPPort == host.remoteHTTPPort)
}

@Test func unpairedAndOffLinkHostsDoNotInferClientWANAddress() async {
    let discovery = RemoteAddressDiscovery(query: {
        Issue.record("STUN should not run without a directly connected paired host")
        return nil
    }, isLocal: { _ in false })
    var host = remoteTestHost()
    _ = await discovery.update(host: host, reportedAddress: nil, reportedHTTPPort: nil) { _, _, _, _ in
        Issue.record("No candidate should be checked")
        return false
    }
    host.isPaired = false
    _ = await discovery.update(host: host, reportedAddress: "203.0.113.20", reportedHTTPPort: 47989) { _, _, _, _ in
        Issue.record("An unpaired endpoint cannot be authenticated")
        return false
    }
}

@Test func savedHostsDecodeWithoutRemotePortFields() throws {
    let data = try JSONEncoder().encode(remoteTestHost())
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "remoteHTTPSPort")
    json.removeValue(forKey: "remoteHTTPPort")
    json.removeValue(forKey: "remoteAddressVerification")
    let host = try JSONDecoder().decode(MoonlightMac.Host.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(host.remoteHTTPSPort == nil)
    #expect(host.effectiveHTTPSPort == 47984)
}
