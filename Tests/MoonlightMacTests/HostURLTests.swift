import Foundation
import Testing
@testable import MoonlightMac

@Test func hostURLsSupportIPv6AndActiveAddress() throws {
    let host = Host(name: "PC", address: "192.168.1.2", activeAddress: "2001:db8::1")
    #expect(host.baseUrlHttps?.absoluteString == "https://[2001:db8::1]:47984")
    #expect(host.baseUrlHttp?.absoluteString == "http://[2001:db8::1]:47989")
    #expect(Host.urlHost("[::1]") == "[::1]")
    #expect(Host.urlHost("pc.local") == "pc.local")
}
