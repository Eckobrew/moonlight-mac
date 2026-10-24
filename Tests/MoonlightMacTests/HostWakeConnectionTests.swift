import Foundation
import Testing

@testable import MoonlightMac

@Test @MainActor func awakeHostOpensWithoutWake() async throws {
    let host = Host(name: "PC", address: "192.168.1.2", status: .online)
    var wakes = 0
    let result = try await HostWakeConnection.resolve(
        host: host, probe: { $0 }, wake: { _ in wakes += 1 }, onWaking: { wakes += 1 })
    #expect(result.id == host.id)
    #expect(wakes == 0)
}

@Test @MainActor func sleepingHostWaitsForLiveServerInfo() async throws {
    let host = Host(name: "PC", address: "192.168.1.2", status: .offline, macAddress: "aa:bb:cc:dd:ee:ff")
    var events: [String] = []
    var probes = 0
    let result = try await HostWakeConnection.resolve(
        host: host,
        probe: { current in
            events.append("probe")
            probes += 1
            // Even a successful probe returning offline metadata is not ready.
            if probes < 3 { return current }
            var ready = current
            ready.status = .online
            return ready
        },
        wake: { mac in
            #expect(mac == host.macAddress)
            events.append("wake")
        }, pause: { events.append("wait") }, onWaking: { events.append("waking") })
    #expect(result.isOnline)
    #expect(events == ["probe", "waking", "wake", "wait", "probe", "wait", "probe"])
}

@Test @MainActor func wakeNeedsSavedMAC() async {
    let host = Host(name: "PC", address: "192.168.1.2")
    var wakes = 0
    await #expect(throws: HostWakeConnection.Failure.self) {
        try await HostWakeConnection.resolve(
            host: host, probe: { _ in throw URLError(.cannotConnectToHost) }, wake: { _ in wakes += 1 }, onWaking: {})
    }
    #expect(wakes == 0)
}

@Test @MainActor func cancelledWakeDoesNotPublishReadyHost() async {
    let host = Host(name: "PC", address: "192.168.1.2", macAddress: "aa:bb:cc:dd:ee:ff")
    var probes = 0
    await #expect(throws: CancellationError.self) {
        try await HostWakeConnection.resolve(
            host: host,
            probe: { _ in
                probes += 1
                throw URLError(.cannotConnectToHost)
            }, wake: { _ in }, pause: { throw CancellationError() }, onWaking: {})
    }
    #expect(probes == 1)
}

@Test @MainActor func wakeStopsAfterTimeoutAndPreservesTrustErrors() async {
    let host = Host(name: "PC", address: "192.168.1.2", macAddress: "aa:bb:cc:dd:ee:ff")
    var probes = 0
    await #expect(throws: HostWakeConnection.Failure.self) {
        try await HostWakeConnection.resolve(
            host: host, attempts: 2,
            probe: { _ in
                probes += 1
                throw URLError(.cannotConnectToHost)
            }, wake: { _ in }, pause: {}, onWaking: {})
    }
    #expect(probes == 3)
    var wakes = 0
    await #expect(throws: HostTrustError.self) {
        try await HostWakeConnection.resolve(
            host: host, probe: { _ in throw HostTrustError.unexpectedHost }, wake: { _ in wakes += 1 }, onWaking: {})
    }
    #expect(wakes == 0)
}

@Test func wakeDatagramSendsWithoutConnectionHandshake() throws {
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
        }
    }
    try #require(bound)
    let payload = Data(repeating: 0xff, count: 102)
    try WakeOnLAN.send(payload, to: "127.0.0.1", port: UInt16(bigEndian: address.sin_port))
    var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    try #require(poll(&ready, 1, 1000) > 0)
    var bytes = [UInt8](repeating: 0, count: 128)
    let count = recv(descriptor, &bytes, bytes.count, 0)
    #expect(count == payload.count)
    #expect(Data(bytes.prefix(Int(max(0, count)))) == payload)
}
