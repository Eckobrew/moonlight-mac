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
        otp: OTPPairing? = nil,
        onPinGenerated: @escaping @Sendable (String) -> Void
    ) async throws -> Host {
        if let otp, !otp.isValid { throw HostControlError(code: 400, message: "Enter the four-digit OTP and the host passphrase (at least four characters).") }
        do {
            return try await performHandshake(host: host, otp: otp, onPinGenerated: onPinGenerated)
        } catch {
            // Complete cleanup before allowing a retry. A detached, unawaited
            // cleanup could otherwise unpair the next successful attempt.
            await Task.detached {
                await self.httpClient.unpair(host: host)
            }.value
            throw error
        }
    }

    private func performHandshake(host: Host, otp: OTPPairing?, onPinGenerated: @escaping @Sendable (String) -> Void) async throws -> Host {
        try Task.checkCancellation()
        // Pairing one PC must not change the identity already registered on other PCs.
        let uniqueId = CertificateManager.shared.uniqueId
        if host.needsCertificatePairing {
            await httpClient.unpair(host: host)
        }
        let clientCertPem = CertificateManager.shared.getClientCertificatePem()
        let clientCertHex = CryptoUtils.hexString(clientCertPem)

        let pin = otp?.code ?? String(format: "%04d", Int.random(in: 1000...9999))
        let clientSalt = CryptoUtils.randomBytes(count: 16)
        let clientSaltHex = CryptoUtils.hexString(clientSalt)

        AppLogger.shared.info("Starting pairing with host \(host.name) (\(host.address))", category: "PAIRING")

        // Display PIN on UI for user to enter in Sunshine/Apollo web UI
        if otp == nil { onPinGenerated(pin) }

        // Derive AES key matching Moonlight-Qt: SHA256(salt + pin.utf8)[0..<16]
        let aesKey = CryptoUtils.deriveKey(salt: clientSalt, pin: pin)

        // ==========================================
        // Stage 1: phrase=getservercert
        // ==========================================
        AppLogger.shared.info("[Stage 1/5] Waiting for user to enter PIN on host (phrase=getservercert)...", category: "PAIRING")
        var getCertUrl = "http://\(host.urlAddress):\(host.effectiveHTTPPort)/pair?uniqueid=\(uniqueId)&devicename=Moonlight%20Mac&updateState=1&phrase=getservercert&salt=\(clientSaltHex)&clientcert=\(clientCertHex)"
        
        if let otp { getCertUrl += "&otpauth=\(otp.authentication(saltHex: clientSaltHex))" }
        let (_, certDict) = try await httpClient.fetchRaw(urlString: getCertUrl, timeout: 180.0, usePairingSession: true)

        guard certDict["paired"] == "1" else {
            let msg = certDict["status_message"] ?? "Stage 1 rejected by host"
            AppLogger.shared.error("Stage 1 failed: \(msg)", category: "PAIRING")
            throw NSError(domain: "PairingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stage 1 failed: \(msg)"])
        }

        guard let plainCertHex = certDict["plaincert"], !plainCertHex.isEmpty,
              let plainCertData = CryptoUtils.dataFromHex(plainCertHex),
              let serverCertPem = String(data: plainCertData, encoding: .utf8) else {
            let msg = certDict["status_message"] ?? "Host did not return certificate. Server likely already pairing."
            AppLogger.shared.error("Stage 1 cert missing: \(msg)", category: "PAIRING")
            throw NSError(domain: "PairingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stage 1 failed: \(msg)"])
        }

        guard let serverCertificateDER = HostTrust.certificateDER(pem: serverCertPem),
              let serverCertSig = HostTrust.certificateSignature(der: serverCertificateDER) else {
            AppLogger.shared.error("Failed to extract 256-byte signature from host server certificate", category: "PAIRING")
            throw NSError(domain: "PairingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse host certificate signature"])
        }
        AppLogger.shared.info("[Stage 1/5] Host accepted PIN! Retrieved server certificate (\(serverCertPem.count) chars, sig: \(serverCertSig.count) bytes)", category: "PAIRING")

        // ==========================================
        // Stage 2: clientchallenge
        // ==========================================
        AppLogger.shared.info("[Stage 2/5] Sending client challenge...", category: "PAIRING")
        let randomChallenge = CryptoUtils.randomBytes(count: 16)
        guard let encryptedChallenge = CryptoUtils.aes128EcbEncrypt(data: randomChallenge, key: aesKey) else {
            throw NSError(domain: "PairingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt client challenge"])
        }
        let challengeHex = CryptoUtils.hexString(encryptedChallenge)

        let clientChallengeUrl = "http://\(host.urlAddress):\(host.effectiveHTTPPort)/pair?uniqueid=\(uniqueId)&devicename=Moonlight%20Mac&updateState=1&clientchallenge=\(challengeHex)"
        let (_, challengeDict) = try await httpClient.fetchRaw(urlString: clientChallengeUrl, timeout: 10.0)

        guard challengeDict["paired"] == "1" else {
            let msg = challengeDict["status_message"] ?? "Stage 2 rejected"
            throw NSError(domain: "PairingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stage 2 failed: \(msg)"])
        }

        guard let challengeResponseHex = challengeDict["challengeresponse"],
              let challengeResponseCipher = CryptoUtils.dataFromHex(challengeResponseHex),
              let challengeResponseData = CryptoUtils.aes128EcbDecrypt(data: challengeResponseCipher, key: aesKey),
              challengeResponseData.count >= 32 + 16 else {
            AppLogger.shared.error("Stage 2: invalid challengeresponse", category: "PAIRING")
            throw NSError(domain: "PairingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Stage 2 failed: Incorrect PIN or invalid challenge response"])
        }

        let serverResponse = challengeResponseData[0..<32]
        let serverChallenge = challengeResponseData[32..<48]
        AppLogger.shared.info("[Stage 2/5] Received server challenge (\(serverChallenge.count) bytes)", category: "PAIRING")

        // ==========================================
        // Stage 3: serverchallengeresp
        // ==========================================
        AppLogger.shared.info("[Stage 3/5] Computing server challenge response and verifying PIN...", category: "PAIRING")
        let clientSecretData = CryptoUtils.randomBytes(count: 16)
        let clientCertSig = CertificateManager.shared.getCertificateSignature()

        var challengeResponse = Data()
        challengeResponse.append(serverChallenge)
        challengeResponse.append(clientCertSig)
        challengeResponse.append(clientSecretData)

        let challengeResponseHash = CryptoUtils.sha256(challengeResponse)
        guard let encryptedChallengeResponseHash = CryptoUtils.aes128EcbEncrypt(data: challengeResponseHash, key: aesKey) else {
            throw NSError(domain: "PairingService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt challenge response hash"])
        }
        let serverChallengeRespHex = CryptoUtils.hexString(encryptedChallengeResponseHash)

        let serverChallengeRespUrl = "http://\(host.urlAddress):\(host.effectiveHTTPPort)/pair?uniqueid=\(uniqueId)&devicename=Moonlight%20Mac&updateState=1&serverchallengeresp=\(serverChallengeRespHex)"
        let (_, serverRespDict) = try await httpClient.fetchRaw(urlString: serverChallengeRespUrl, timeout: 10.0)

        guard serverRespDict["paired"] == "1" else {
            let msg = serverRespDict["status_message"] ?? "Stage 3 rejected"
            throw NSError(domain: "PairingService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Stage 3 failed: \(msg)"])
        }

        guard let pairingSecretHex = serverRespDict["pairingsecret"],
              let pairingSecretData = CryptoUtils.dataFromHex(pairingSecretHex),
              pairingSecretData.count > 16 else {
            AppLogger.shared.error("Stage 3: host did not return valid pairingsecret", category: "PAIRING")
            throw NSError(domain: "PairingService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Stage 3 failed: Host did not return pairing secret"])
        }

        let serverSecret = Data(pairingSecretData.prefix(16))
        guard HostTrust.verify(secret: serverSecret, signature: Data(pairingSecretData.dropFirst(16)),
                               certificateDER: serverCertificateDER) else {
            throw HostTrustError.invalidSignature
        }

        // Verify PIN correctness
        var expectedResponseData = Data()
        expectedResponseData.append(randomChallenge)
        expectedResponseData.append(serverCertSig)
        expectedResponseData.append(serverSecret)
        let expectedHash = CryptoUtils.sha256(expectedResponseData)

        if expectedHash != serverResponse {
            AppLogger.shared.error("Stage 3: PIN verification failed! Incorrect PIN entered on host.", category: "PAIRING")
            throw NSError(domain: "PairingService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Stage 3 failed: Incorrect PIN entered on host"])
        }
        AppLogger.shared.info("[Stage 3/5] Cryptographic PIN verification succeeded!", category: "PAIRING")

        // ==========================================
        // Stage 4: clientpairingsecret
        // ==========================================
        AppLogger.shared.info("[Stage 4/5] Signing client pairing secret...", category: "PAIRING")
        guard let clientSignature = CertificateManager.shared.signData(data: clientSecretData) else {
            throw NSError(domain: "PairingService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Stage 4 failed: Unable to sign client pairing secret"])
        }
        var clientPairingSecret = clientSecretData
        clientPairingSecret.append(clientSignature)
        let clientPairingSecretHex = CryptoUtils.hexString(clientPairingSecret)

        let clientSecretUrl = "http://\(host.urlAddress):\(host.effectiveHTTPPort)/pair?uniqueid=\(uniqueId)&devicename=Moonlight%20Mac&updateState=1&clientpairingsecret=\(clientPairingSecretHex)"
        let (_, clientSecretDict) = try await httpClient.fetchRaw(urlString: clientSecretUrl, timeout: 10.0)

        guard clientSecretDict["paired"] == "1" else {
            let msg = clientSecretDict["status_message"] ?? "Stage 4 rejected"
            throw NSError(domain: "PairingService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Stage 4 failed: \(msg)"])
        }
        AppLogger.shared.info("[Stage 4/5] Client pairing secret accepted by host", category: "PAIRING")

        // ==========================================
        // Stage 5: phrase=pairchallenge over HTTPS
        // ==========================================
        AppLogger.shared.info("[Stage 5/5] Establishing mTLS encrypted verification (phrase=pairchallenge)...", category: "PAIRING")
        let pairChallengeUrl = "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/pair?uniqueid=\(uniqueId)&devicename=Moonlight%20Mac&updateState=1&phrase=pairchallenge"
        let (_, pairChallengeDict) = try await httpClient.fetchRaw(urlString: pairChallengeUrl, timeout: 15.0, certificateDER: serverCertificateDER)

        guard pairChallengeDict["paired"] == "1" else {
            let msg = pairChallengeDict["status_message"] ?? "Stage 5 rejected over HTTPS"
            throw NSError(domain: "PairingService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Stage 5 failed: \(msg)"])
        }

        // Only persist the pin after PIN, signature and pinned mTLS verification succeed.
        var candidate = host
        candidate.isPaired = false
        candidate.serverId = nil
        candidate.serverCertificateDER = serverCertificateDER
        let (verifiedHost, _) = try await httpClient.fetchServerInfo(host: candidate)
        guard verifiedHost.isSecurelyPaired else {
            throw NSError(domain: "PairingService", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Host did not confirm pairing over verified HTTPS."])
        }
        try Task.checkCancellation()
        AppLogger.shared.info("Pairing completed securely with host \(host.name)", category: "PAIRING")
        return verifiedHost
    }
}
