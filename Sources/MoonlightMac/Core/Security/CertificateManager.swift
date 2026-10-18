import Foundation
import Security

public final class CertificateManager: @unchecked Sendable {
    public static let shared = CertificateManager()

    private let uniqueIdKey = "com.moonlight.mac.uniqueId"
    public private(set) var uniqueId: String

    private var cachedIdentity: SecIdentity?
    private var cachedPrivateKey: SecKey?
    private var cachedPemCert: Data?
    private var cachedDerCert: Data?

    private init() {
        if let storedId = UserDefaults.standard.string(forKey: uniqueIdKey), !storedId.isEmpty {
            self.uniqueId = storedId
        } else {
            // Moonlight uses 16-character hex unique ID
            var bytes = [UInt8](repeating: 0, count: 8)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let newId = bytes.map { String(format: "%02x", $0) }.joined().uppercased()
            UserDefaults.standard.set(newId, forKey: uniqueIdKey)
            self.uniqueId = newId
        }

        ensureCredentialsExist()
    }

    private var appSupportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MoonlightMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var certPath: URL { appSupportDir.appendingPathComponent("client.crt") }
    public var keyPath: URL { appSupportDir.appendingPathComponent("client.key") }
    public var p12Path: URL { appSupportDir.appendingPathComponent("client.p12") }

    private func ensureCredentialsExist() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: certPath.path) || !fm.fileExists(atPath: p12Path.path) {
            generateCredentials()
        }
        loadCredentials()
    }

    private func generateCredentials() {
        let opensslPath = FileManager.default.fileExists(atPath: "/opt/local/bin/openssl") ? "/opt/local/bin/openssl" : "/usr/bin/openssl"

        // 1. Generate RSA 2048 private key and self-signed certificate matching Moonlight-Qt
        let genCertProcess = Process()
        genCertProcess.executableURL = URL(fileURLWithPath: opensslPath)
        genCertProcess.arguments = [
            "req", "-x509",
            "-newkey", "rsa:2048",
            "-keyout", keyPath.path,
            "-out", certPath.path,
            "-days", "7300",
            "-nodes",
            "-subj", "/CN=NVIDIA GameStream Client"
        ]
        try? genCertProcess.run()
        genCertProcess.waitUntilExit()

        // 2. Export to PKCS#12 for macOS SecIdentity
        let genP12Process = Process()
        genP12Process.executableURL = URL(fileURLWithPath: opensslPath)
        genP12Process.arguments = [
            "pkcs12", "-export",
            "-out", p12Path.path,
            "-inkey", keyPath.path,
            "-in", certPath.path,
            "-passout", "pass:moonlight"
        ]
        try? genP12Process.run()
        genP12Process.waitUntilExit()
    }

    private func loadCredentials() {
        if let certData = try? Data(contentsOf: certPath) {
            self.cachedPemCert = certData

            // Convert PEM to DER
            if let pemString = String(data: certData, encoding: .utf8) {
                let lines = pemString.components(separatedBy: "\n").filter { !$0.contains("---") && !$0.isEmpty }
                let base64 = lines.joined()
                self.cachedDerCert = Data(base64Encoded: base64)
            }
        }

        if let p12Data = try? Data(contentsOf: p12Path) {
            // Use kSecImportToMemoryOnly matching modern macOS and Qt 6.8+
            // This prevents ANY interaction with user or system keychains, completely eliminating password prompts.
            let options: [String: Any] = [
                kSecImportExportPassphrase as String: "moonlight",
                "kSecImportToMemoryOnly": true
            ]
            var items: CFArray?
            let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
            if status == errSecSuccess,
               let array = items as? [[String: Any]],
               let first = array.first,
               let identity = first[kSecImportItemIdentity as String] {
                let secIdentity = (identity as! SecIdentity)
                self.cachedIdentity = secIdentity
                var privKey: SecKey?
                SecIdentityCopyPrivateKey(secIdentity, &privKey)
                self.cachedPrivateKey = privKey
                AppLogger.shared.info("Loaded client identity into memory without keychain prompts", category: "SECURITY")
            } else {
                AppLogger.shared.error("SecPKCS12Import failed with status: \(status)", category: "SECURITY")
            }
        }
    }

    /// Returns the client certificate in PEM format data
    public func getClientCertificatePem() -> Data {
        if let cached = cachedPemCert { return cached }
        ensureCredentialsExist()
        return cachedPemCert ?? Data()
    }

    /// Returns the client certificate in DER format
    public func getClientCertificateDer() -> Data {
        if let cached = cachedDerCert { return cached }
        ensureCredentialsExist()
        return cachedDerCert ?? getClientCertificatePem()
    }

    /// Returns the certificate signature bytes (last 256 bytes of DER)
    public func getCertificateSignature() -> Data {
        let der = getClientCertificateDer()
        if der.count >= 256 {
            return der.suffix(256)
        }
        return Data(repeating: 0, count: 256)
    }

    /// Extracts the RSA-2048 signature bytes (last 256 bytes of DER) from a PEM certificate string
    public func getCertificateSignature(fromPem pemString: String) -> Data? {
        let clean = pemString
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: clean), der.count >= 256 else { return nil }
        return der.suffix(256)
    }

    /// Returns SecIdentity for mutual TLS authentication
    public func getClientIdentity() -> SecIdentity? {
        if let cached = cachedIdentity { return cached }
        ensureCredentialsExist()
        return cachedIdentity
    }

    /// Signs data with RSA-SHA256 using the client private key
    public func signData(data: Data) -> Data? {
        if let privateKey = cachedPrivateKey {
            var error: Unmanaged<CFError>?
            if let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) {
                return signature as Data
            }
        }

        // Fallback using openssl process
        let opensslPath = FileManager.default.fileExists(atPath: "/opt/local/bin/openssl") ? "/opt/local/bin/openssl" : "/usr/bin/openssl"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = ["dgst", "-sha256", "-sign", keyPath.path]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(data)
            try? inputPipe.fileHandleForWriting.close()
            let sigData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 && !sigData.isEmpty {
                return sigData
            }
        } catch {
            print("OpenSSL signing error: \(error)")
        }

        return nil
    }
}
