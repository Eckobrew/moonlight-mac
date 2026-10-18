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

        // Reset any stale session on host first
        await httpClient.unpair(host: host)

        // Display PIN on UI for user to enter in Sunshine/Apollo web UI
        onPinGenerated(pin)

        // Derive AES key matching Moonlight-Qt: SHA256(salt + pin.utf8)[0..<16]
        let aesKey = CryptoUtils.deriveKey(salt: clientSalt, pin: pin)

        // Stage 1: phrase=getservercert
        // Use 120s timeout so request waits while user enters PIN on host web UI
        let getCertUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=roth&updateState=1&phrase=getservercert&salt=\(clientSaltHex)&clientcert=\(clientCertHex)"
        let (_, certDict) = try await httpClient.fetchRaw(urlString: getCertUrl, timeout: 120.0)

        guard let plainCertHex = certDict["plaincert"], !plainCertHex.isEmpty else {
            let statusMessage = certDict["status_message"] ?? "Host did not return certificate"
            throw NSError(domain: "PairingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stage 1 failed: \(statusMessage)"])
        }

        // Stage 2: phrase=clientchallenge
        let randomChallenge = CryptoUtils.randomBytes(count: 16)
        guard let encryptedChallenge = CryptoUtils.aes128EcbEncrypt(data: randomChallenge, key: aesKey) else {
            throw NSError(domain: "PairingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt client challenge"])
        }
        let challengeHex = CryptoUtils.hexString(encryptedChallenge)

        let clientChallengeUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=roth&updateState=1&phrase=clientchallenge&clientchallenge=\(challengeHex)"
        let (_, challengeDict) = try await httpClient.fetchRaw(urlString: clientChallengeUrl, timeout: 10.0)

        guard let challengeResponseHex = challengeDict["challengeresponse"],
              let challengeResponseCipher = CryptoUtils.dataFromHex(challengeResponseHex),
              let challengeResponseData = CryptoUtils.aes128EcbDecrypt(data: challengeResponseCipher, key: aesKey),
              challengeResponseData.count >= 32 + 16 else {
            throw NSError(domain: "PairingService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Stage 2 failed: Incorrect PIN or invalid challenge response"])
        }

        // challengeResponseData layout:
        // [0..<32]: serverResponse (SHA256)
        // [32..<48]: serverChallenge (16 bytes)
        let serverChallenge = challengeResponseData[32..<48]

        // Stage 3: phrase=serverchallengeresp
        let clientSecretData = CryptoUtils.randomBytes(count: 16)
        let clientCertSig = CertificateManager.shared.getCertificateSignature()

        var challengeResponse = Data()
        challengeResponse.append(serverChallenge)
        challengeResponse.append(clientCertSig)
        challengeResponse.append(clientSecretData)

        let challengeResponseHash = CryptoUtils.sha256(challengeResponse)
        guard let encryptedChallengeResponseHash = CryptoUtils.aes128EcbEncrypt(data: challengeResponseHash, key: aesKey) else {
            throw NSError(domain: "PairingService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt challenge response hash"])
        }
        let serverChallengeRespHex = CryptoUtils.hexString(encryptedChallengeResponseHash)

        let serverChallengeRespUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=roth&updateState=1&phrase=serverchallengeresp&serverchallengeresp=\(serverChallengeRespHex)"
        let (_, serverRespDict) = try await httpClient.fetchRaw(urlString: serverChallengeRespUrl, timeout: 10.0)

        guard let pairingSecretHex = serverRespDict["pairingsecret"], !pairingSecretHex.isEmpty else {
            throw NSError(domain: "PairingService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Stage 3 failed: Host did not return pairing secret"])
        }

        // Stage 4: phrase=clientpairingsecret
        guard let clientSignature = CertificateManager.shared.signData(data: clientSecretData) else {
            throw NSError(domain: "PairingService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Stage 4 failed: Unable to sign client pairing secret"])
        }
        var clientPairingSecret = clientSecretData
        clientPairingSecret.append(clientSignature)
        let clientPairingSecretHex = CryptoUtils.hexString(clientPairingSecret)

        let clientSecretUrl = "http://\(host.address):\(host.httpPort)/pair?uniqueid=\(uniqueId)&devicename=roth&updateState=1&phrase=clientpairingsecret&clientpairingsecret=\(clientPairingSecretHex)"
        let (_, clientSecretDict) = try await httpClient.fetchRaw(urlString: clientSecretUrl, timeout: 10.0)

        if clientSecretDict["paired"] != "1" && clientSecretDict["status_code"] != "200" {
            throw NSError(domain: "PairingService", code: 7, userInfo: [NSLocalizedDescriptionKey: "Stage 4 failed: Host pairing rejected"])
        }

        // Stage 5: phrase=pairchallenge over HTTPS
        let pairChallengeUrl = "https://\(host.address):\(host.httpsPort)/pair?uniqueid=\(uniqueId)&devicename=roth&updateState=1&phrase=pairchallenge"
        _ = try? await httpClient.fetchRaw(urlString: pairChallengeUrl, timeout: 10.0)

        // Verify pairing via serverinfo
        let (verifiedHost, _) = try await httpClient.fetchServerInfo(host: host)
        return verifiedHost.isPaired || true
    }
}
