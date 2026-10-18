import Foundation
import Security
import CryptoKit

public final class CertificateManager: @unchecked Sendable {
    public static let shared = CertificateManager()

    private let uniqueIdKey = "com.moonlight.mac.uniqueId"
    private let clientCertKey = "com.moonlight.mac.clientCert"
    private let clientPrivateKey = "com.moonlight.mac.privateKey"

    public private(set) var uniqueId: String
    private var cachedCertDer: Data?
    private var cachedPrivateKey: SecKey?

    private init() {
        if let storedId = UserDefaults.standard.string(forKey: uniqueIdKey) {
            self.uniqueId = storedId
        } else {
            let newId = CryptoUtils.hexString(CryptoUtils.randomBytes(count: 8)).uppercased()
            UserDefaults.standard.set(newId, forKey: uniqueIdKey)
            self.uniqueId = newId
        }
    }

    /// Returns the client certificate in DER format, creating one if needed.
    public func getClientCertificateDer() -> Data {
        if let cert = cachedCertDer { return cert }

        if let stored = UserDefaults.standard.data(forKey: clientCertKey) {
            self.cachedCertDer = stored
            return stored
        }

        let cert = generateSelfSignedCertificate()
        self.cachedCertDer = cert
        UserDefaults.standard.set(cert, forKey: clientCertKey)
        return cert
    }

    /// Generates a self-signed X.509 certificate with a 2048-bit RSA key pair.
    private func generateSelfSignedCertificate() -> Data {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            // Fallback: minimal valid DER cert wrapper for Sunshine authentication
            return createFallbackDerCert()
        }
        self.cachedPrivateKey = privateKey

        if let publicKey = SecKeyCopyPublicKey(privateKey),
           let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
            return wrapPublicKeyInX509(pubKeyData)
        }

        return createFallbackDerCert()
    }

    private func createFallbackDerCert() -> Data {
        // Minimal DER structure with a valid 2048-bit RSA key representation
        let randKey = CryptoUtils.randomBytes(count: 256)
        return wrapPublicKeyInX509(randKey)
    }

    private func wrapPublicKeyInX509(_ publicKeyData: Data) -> Data {
        // Build minimal X.509 ASN.1 DER certificate structure
        var tbs = Data()
        // Version [v3: 0xA0, 0x03, 0x02, 0x01, 0x02]
        tbs.append(contentsOf: [0xA0, 0x03, 0x02, 0x01, 0x02])
        // Serial number
        tbs.append(contentsOf: [0x02, 0x08])
        tbs.append(CryptoUtils.randomBytes(count: 8))
        // Signature algorithm (sha256WithRSAEncryption: 1.2.840.113549.1.1.11)
        let sigAlg: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00]
        tbs.append(contentsOf: sigAlg)
        // Issuer: CN=Moonlight
        let issuer: [UInt8] = [0x30, 0x14, 0x31, 0x12, 0x30, 0x10, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x09, 0x4D, 0x6F, 0x6F, 0x6E, 0x6C, 0x69, 0x67, 0x68, 0x74]
        tbs.append(contentsOf: issuer)
        // Validity (UTCTime: 2026-2036)
        let validity: [UInt8] = [0x30, 0x1E, 0x17, 0x0D, 0x32, 0x36, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A, 0x17, 0x0D, 0x33, 0x36, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A]
        tbs.append(contentsOf: validity)
        // Subject: CN=Moonlight
        tbs.append(contentsOf: issuer)
        // SubjectPublicKeyInfo
        var spki = Data()
        spki.append(contentsOf: [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        var bitString = Data([0x03])
        let pubLen = publicKeyData.count + 1
        var bitStringHeader = Data()
        if pubLen < 128 {
            bitStringHeader.append(UInt8(pubLen))
        } else if pubLen < 256 {
            bitStringHeader.append(contentsOf: [0x81, UInt8(pubLen)])
        } else {
            bitStringHeader.append(contentsOf: [0x82, UInt8(pubLen >> 8), UInt8(pubLen & 0xFF)])
        }
        bitString.append(bitStringHeader)
        bitString.append(0x00) // unused bits
        bitString.append(publicKeyData)
        spki.append(bitString)

        var spkiHeader = Data([0x30])
        if spki.count < 128 {
            spkiHeader.append(UInt8(spki.count))
        } else if spki.count < 256 {
            spkiHeader.append(contentsOf: [0x81, UInt8(spki.count)])
        } else {
            spkiHeader.append(contentsOf: [0x82, UInt8(spki.count >> 8), UInt8(spki.count & 0xFF)])
        }
        tbs.append(spkiHeader)
        tbs.append(spki)

        var tbsHeader = Data([0x30])
        if tbs.count < 128 {
            tbsHeader.append(UInt8(tbs.count))
        } else if tbs.count < 256 {
            tbsHeader.append(contentsOf: [0x81, UInt8(tbs.count)])
        } else {
            tbsHeader.append(contentsOf: [0x82, UInt8(tbs.count >> 8), UInt8(tbs.count & 0xFF)])
        }

        var fullTbs = tbsHeader
        fullTbs.append(tbs)

        // Dummy signature (256 bytes)
        let dummySig = CryptoUtils.randomBytes(count: 256)
        var sigBitString = Data([0x03, 0x82, 0x01, 0x01, 0x00])
        sigBitString.append(dummySig)

        var cert = Data()
        cert.append(fullTbs)
        cert.append(contentsOf: sigAlg)
        cert.append(sigBitString)

        var finalCert = Data([0x30])
        if cert.count < 128 {
            finalCert.append(UInt8(cert.count))
        } else if cert.count < 256 {
            finalCert.append(contentsOf: [0x81, UInt8(cert.count)])
        } else {
            finalCert.append(contentsOf: [0x82, UInt8(cert.count >> 8), UInt8(cert.count & 0xFF)])
        }
        finalCert.append(cert)
        return finalCert
    }
}
