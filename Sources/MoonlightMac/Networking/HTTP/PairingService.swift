import Foundation

public enum PairingState: Equatable, Sendable {
    case idle
    case displayingPin(pin: String)
    case verifying
    case succeeded
    case failed(reason: String)
}

public final class PairingService: @unchecked Sendable {
    public static let shared = PairingService()

    private let httpClient = SunshineHTTPClient.shared

    public func pair(
        host: Host,
        onPinGenerated: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        let uniqueId = CertificateManager.shared.uniqueId
        let clientCertPem = CertificateManager.shared.getClientCertificatePem()
        let clientCertHex = CryptoUtils.hexString(clientCertPem)

        let pin = String(format: "%04d", Int.random(in: 1000...9999))
        let clientSalt = CryptoUtils.randomBytes(count: 16)
        let clientSaltHex = CryptoUtils.hexString(clientSalt)

        onPinGenerated(pin)

        // Step 1: phrase=getservercert
        let getCertUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=MoonlightMac&updateState=1&phrase=getservercert&salt=\(clientSaltHex)&clientcert=\(clientCertHex)"
        let (_, certDict) = try await httpClient.fetchRaw(urlString: getCertUrl)

        guard let plainCertHex = certDict["plaincert"], !plainCertHex.isEmpty else {
            throw NSError(domain: "PairingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server did not return certificate"])
        }

        let aesKey = CryptoUtils.deriveKey(salt: clientSalt, pin: pin)

        // Step 2: phrase=clientchallenge
        let randomChallenge = CryptoUtils.randomBytes(count: 16)
        guard let encryptedChallenge = CryptoUtils.aes128EcbEncrypt(data: randomChallenge, key: aesKey) else {
            throw NSError(domain: "PairingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt challenge"])
        }
        let challengeHex = CryptoUtils.hexString(encryptedChallenge)

        let clientChallengeUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=MoonlightMac&updateState=1&phrase=clientchallenge&clientchallenge=\(challengeHex)"

        // Wait / poll until host accepts PIN (user types PIN on Sunshine web UI)
        var paired = false
        var attempts = 0
        let maxAttempts = 30 // 30 x 1s = 30 seconds

        while attempts < maxAttempts && !paired {
            do {
                let (_, challengeDict) = try await httpClient.fetchRaw(urlString: clientChallengeUrl)
                if let resp = challengeDict["challengeresponse"], !resp.isEmpty {
                    // Step 3: phrase=serverchallengeresp
                    let serverChallengeRespUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=MoonlightMac&updateState=1&phrase=serverchallengeresp"
                    let (_, serverRespDict) = try await httpClient.fetchRaw(urlString: serverChallengeRespUrl)

                    if serverRespDict["paired"] == "1" || serverRespDict["paired"] == nil {
                        // Step 4: pairchallenge finalization
                        let pairFinalUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=MoonlightMac&updateState=1&phrase=pairchallenge"
                        let (_, finalDict) = try await httpClient.fetchRaw(urlString: pairFinalUrl)
                        if finalDict["paired"] == "1" {
                            paired = true
                            break
                        }
                    }
                }
            } catch {
                // Keep polling until user confirms PIN
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
            attempts += 1
        }

        // Verify pairing status via serverinfo
        let (verifiedHost, _) = try await httpClient.fetchServerInfo(host: host)
        return verifiedHost.isPaired || paired
    }
}
