import Foundation
import Testing
@testable import MoonlightMac

@Test func tcpProbeFallsBackToReachableResolvedAddress() throws {
    // localhost commonly resolves to ::1 first. Listen only on IPv4 so the probe
    // must survive a refused IPv6 connection to find the working IPv4 listener.
    let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    #expect(listener >= 0)
    guard listener >= 0 else { return }
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(bindResult == 0)
    #expect(listen(listener, 4) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &length)
        }
    }
    #expect(nameResult == 0)
    #expect(TCPProbe.canConnect(address: "localhost", port: UInt16(bigEndian: address.sin_port)))
    #expect(!TCPProbe.canConnect(address: "localhost", port: 0))
}
