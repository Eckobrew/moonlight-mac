import Foundation
import Security

public enum HostTrustError: LocalizedError {
    case pairingRequired
    case invalidCertificate
    case invalidSignature
    case unexpectedHost

    public var errorDescription: String? {
        switch self {
        case .pairingRequired:
            return "Pair this PC again to securely verify its certificate. Older versions did not save host certificates."
        case .invalidCertificate:
            return "The PC supplied an invalid certificate."
        case .invalidSignature:
            return "The PC's pairing signature could not be verified. Pairing was stopped."
        case .unexpectedHost:
            return "The responding PC does not match the saved host. Check its address and pair again if the PC was reinstalled."
        }
    }
}

/// Certificate utilities do not access credentials or persistent storage.
enum HostTrust {
    static func certificateDER(pem: String) -> Data? {
        let base64 = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              SecCertificateCreateWithData(nil, der as CFData) != nil else { return nil }
        return der
    }

    static func matches(_ trust: SecTrust, certificateDER: Data) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        // Pairing authenticates this exact self-signed certificate. Public PKI name
        // and expiry checks cannot replace the pairing pin for a GameStream host.
        return SecCertificateCopyData(leaf) as Data == certificateDER
    }

    static func verify(secret: Data, signature: Data, certificateDER: Data) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let key = SecCertificateCopyKey(cert),
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                     secret as CFData, signature as CFData, nil)
    }

    /// X.509 is SEQUENCE { tbsCertificate, signatureAlgorithm, signature BIT STRING }.
    /// Parse lengths instead of assuming every server uses an RSA-2048 certificate.
    static func certificateSignature(der: Data) -> Data? {
        let bytes = [UInt8](der)
        var offset = 0
        func read(_ expectedTag: UInt8, limit: Int) -> Range<Int>? {
            guard offset + 2 <= limit, bytes[offset] == expectedTag else { return nil }
            offset += 1
            let first = Int(bytes[offset])
            offset += 1
            var length = first
            if first & 0x80 != 0 {
                let count = first & 0x7F
                guard count > 0, count <= 4, offset + count <= limit else { return nil }
                length = 0
                for _ in 0..<count {
                    length = length * 256 + Int(bytes[offset])
                    offset += 1
                }
            }
            guard length <= limit - offset else { return nil }
            let range = offset..<(offset + length)
            offset += length
            return range
        }
        guard let outer = read(0x30, limit: bytes.count), outer.upperBound == bytes.count else { return nil }
        offset = outer.lowerBound
        guard read(0x30, limit: outer.upperBound) != nil,
              read(0x30, limit: outer.upperBound) != nil,
              let signature = read(0x03, limit: outer.upperBound),
              offset == outer.upperBound, signature.count > 1,
              bytes[signature.lowerBound] == 0 else { return nil }
        return Data(bytes[(signature.lowerBound + 1)..<signature.upperBound])
    }
}

/// Each authenticated session is bound to a certificate, never to an unauthenticated
/// server ID or an address learned from Bonjour/HTTP.
final class PinnedHostDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let certificateDER: Data?
    init(certificateDER: Data?) { self.certificateDER = certificateDER }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let certificateDER, let trust = challenge.protectionSpace.serverTrust,
                  HostTrust.matches(trust, certificateDER: certificateDER) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            guard certificateDER != nil, let identity = CertificateManager.shared.getClientIdentity() else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // These endpoints do not redirect. Never follow a redirect carrying rikey,
        // pairing material or clipboard text to a different endpoint or plain HTTP.
        completionHandler(nil)
    }
}
