import Foundation
import Security
import Testing
@testable import MoonlightMac

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func pairingVerifiesSignatureAndRejectsTampering() throws {
    let certificate = try fixture("host.der")
    let secret = try fixture("secret.bin")
    let signature = try fixture("signature.bin")
    #expect(HostTrust.verify(secret: secret, signature: signature, certificateDER: certificate))
    #expect(!HostTrust.verify(secret: Data("tampered".utf8), signature: signature, certificateDER: certificate))
    var damaged = signature
    damaged[0] ^= 1
    #expect(!HostTrust.verify(secret: secret, signature: damaged, certificateDER: certificate))
    #expect(!HostTrust.verify(secret: secret, signature: signature, certificateDER: Data()))
}

@Test func certificatePinRequiresExactLeafCertificate() throws {
    let certificate = try fixture("host.der")
    let leaf = try #require(SecCertificateCreateWithData(nil, certificate as CFData))
    var result: SecTrust?
    #expect(SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, nil), &result) == errSecSuccess)
    let trust = try #require(result)
    #expect(HostTrust.matches(trust, certificateDER: certificate))
    var different = certificate
    different[different.count - 1] ^= 1
    #expect(!HostTrust.matches(trust, certificateDER: different))
    #expect(!HostTrust.matches(trust, certificateDER: Data()))
}

@Test func certificateParsingHandlesMalformedDER() throws {
    let pem = try String(data: fixture("host.pem"), encoding: .utf8)!
    let der = try fixture("host.der")
    #expect(HostTrust.certificateDER(pem: pem) == der)
    #expect(HostTrust.certificateSignature(der: der)?.count == 256)
    #expect(HostTrust.certificateDER(pem: "not a certificate") == nil)
    for length in 0..<der.count {
        #expect(HostTrust.certificateSignature(der: der.prefix(length)) == nil)
    }
    #expect(HostTrust.certificateSignature(der: Data([0x30, 0xFF])) == nil)
}

@Test func legacyHostsRequirePairingWithoutLosingSavedIdentity() throws {
    let host = Host(name: "Saved PC", address: "pc.local", serverId: "stable-id", isPaired: true)
    let encoded = try JSONEncoder().encode(host)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "serverCertificateDER")
    let restored = try JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.id == host.id)
    #expect(restored.serverId == "stable-id")
    #expect(restored.needsCertificatePairing)
    #expect(!restored.isSecurelyPaired)
    var paired = restored
    paired.serverCertificateDER = try fixture("host.der")
    let roundTrip = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(paired))
    #expect(roundTrip.isSecurelyPaired)
    #expect(roundTrip.serverCertificateDER == paired.serverCertificateDER)
}

@Test func authenticatedRequestsDoNotFollowRedirects() throws {
    let source = try #require(URL(string: "https://pc.local:47984/launch?rikey=test"))
    let destination = try #require(URL(string: "http://other.local/capture"))
    let response = try #require(HTTPURLResponse(url: source, statusCode: 302,
                                               httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: source)
    let delegate = PinnedHostDelegate(certificateDER: try fixture("host.der"))
    var called = false
    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                        newRequest: URLRequest(url: destination)) { redirected in
        called = true
        #expect(redirected == nil)
    }
    #expect(called)
}
