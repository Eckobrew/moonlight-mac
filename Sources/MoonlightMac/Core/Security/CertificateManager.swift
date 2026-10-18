import Foundation
import Security

public final class CertificateManager: @unchecked Sendable {
    public static let shared = CertificateManager()

    private let uniqueIdKey = "com.moonlight.mac.uniqueId"
    public private(set) var uniqueId: String

    private var cachedIdentity: SecIdentity?
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

    private var certPath: URL { appSupportDir.appendingPathComponent("client.crt") }
    private var keyPath: URL { appSupportDir.appendingPathComponent("client.key") }
    private var p12Path: URL { appSupportDir.appendingPathComponent("client.p12") }

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
        }

        if let p12Data = try? Data(contentsOf: p12Path) {
            let options: [String: Any] = [kSecImportExportPassphrase as String: "moonlight"]
            var items: CFArray?
            let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
            if status == errSecSuccess,
               let array = items as? [[String: Any]],
               let first = array.first,
               let identity = first[kSecImportItemIdentity as String] {
                self.cachedIdentity = (identity as! SecIdentity)
            }
        }
    }

    /// Returns the client certificate in PEM format data
    public func getClientCertificatePem() -> Data {
        if let cached = cachedPemCert { return cached }
        ensureCredentialsExist()
        return cachedPemCert ?? Data()
    }

    /// Returns the client certificate in DER format or fallback to PEM
    public func getClientCertificateDer() -> Data {
        return getClientCertificatePem()
    }

    /// Returns SecIdentity for mutual TLS authentication
    public func getClientIdentity() -> SecIdentity? {
        if let cached = cachedIdentity { return cached }
        ensureCredentialsExist()
        return cachedIdentity
    }
}
