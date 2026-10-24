import Foundation
import Security
import MoonlightCommonC

public final class SunshineHTTPClient: NSObject, @unchecked Sendable {
    public static let shared = SunshineHTTPClient()
    private let uniqueID: @Sendable () -> String
    typealias ExtensionTransport = @Sendable (URLRequest, Host) async throws -> (Data, HTTPURLResponse)
    private let extensionTransport: ExtensionTransport?

    init(uniqueID: @escaping @Sendable () -> String = { CertificateManager.shared.uniqueId }, extensionTransport: ExtensionTransport? = nil) {
        self.uniqueID = uniqueID
        self.extensionTransport = extensionTransport
        super.init()
    }

    private let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6.0
        config.timeoutIntervalForResource = 10.0
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 16
        config.httpAdditionalHeaders = ["Connection": "close"]
        return URLSession(configuration: config, delegate: PinnedHostDelegate(certificateDER: nil), delegateQueue: nil)
    }()

    private let pairingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180.0
        config.timeoutIntervalForResource = 180.0
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 8
        config.httpAdditionalHeaders = ["Connection": "close"]
        return URLSession(configuration: config, delegate: PinnedHostDelegate(certificateDER: nil), delegateQueue: nil)
    }()

    private let sessionsLock = NSLock()
    private var authenticatedSessions: [Data: URLSession] = [:]

    private func session(certificateDER: Data?) throws -> URLSession {
        guard let certificateDER else { throw HostTrustError.pairingRequired }
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else {
            throw HostTrustError.invalidCertificate
        }
        return sessionsLock.withLock {
            if let existing = authenticatedSessions[certificateDER] { return existing }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 10
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.httpAdditionalHeaders = ["Connection": "close"]
            let session = URLSession(configuration: config,
                                     delegate: PinnedHostDelegate(certificateDER: certificateDER), delegateQueue: nil)
            authenticatedSessions[certificateDER] = session
            return session
        }
    }

    private func data(for request: URLRequest, host: Host) async throws -> (Data, URLResponse) {
        guard request.url?.scheme == "https" else { throw URLError(.secureConnectionFailed) }
        return try await session(certificateDER: host.serverCertificateDER).data(for: request)
    }

    public static func isValidMacAddress(_ mac: String) -> Bool {
        let clean = mac.filter { $0.isHexDigit }
        guard clean.count == 12 else { return false }
        if clean.allSatisfy({ $0 == "0" }) { return false }
        if clean.allSatisfy({ $0 == "f" || $0 == "F" }) { return false }
        return true
    }

    private func queryServerInfo(address: String, httpsPort: Int, httpPort: Int, uniqueId: String, certificateDER: Data?, timeout: TimeInterval = 2.0) async -> (Data, Bool)? {
        var responseData: Data?
        var isHttps = false

        // Skip protocols whose port is definitively closed. A sleeping or unreachable host used to cost
        // a full HTTPS timeout followed by a full HTTP timeout on every refresh tick.
        // Only probe HTTP if HTTPS is unreachable or fails, avoiding an extra aborted TCP handshake
        // on port 47989 for every normal HTTPS poll.
        let httpsReachable = certificateDER != nil && httpsPort > 0 && TCPProbe.canConnect(address: address, port: UInt16(clamping: httpsPort))

        if httpsReachable,
           let httpsUrl = URL(string: "https://\(Host.urlHost(address)):\(httpsPort)/serverinfo?uniqueid=\(uniqueId)") {
            do {
                var request = URLRequest(url: httpsUrl)
                request.timeoutInterval = timeout
                let (data, response) = try await session(certificateDER: certificateDER).data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    let xmlDict = parseSimpleXML(data: data)
                    let xmlCode = xmlDict["status_code"]
                    if xmlCode == "200" || xmlCode == nil {
                        responseData = data
                        isHttps = true
                        AppLogger.shared.info("serverinfo returned 200 over HTTPS for \(address) (mTLS authenticated)", category: "HTTP")
                    } else {
                        AppLogger.shared.debug("HTTPS serverinfo for \(address) returned XML status \(xmlCode ?? "nil") (\(xmlDict["status_message"] ?? "")); host is not paired. Falling back to HTTP.", category: "HTTP")
                    }
                }
            } catch {
                AppLogger.shared.debug("HTTPS serverinfo failed for \(address): \(error.localizedDescription)", category: "HTTP")
            }
        }

        if responseData == nil, certificateDER == nil,
           TCPProbe.canConnect(address: address, port: UInt16(clamping: httpPort)),
           let httpUrl = URL(string: "http://\(Host.urlHost(address)):\(httpPort)/serverinfo?uniqueid=\(uniqueId)") {
            do {
                var request = URLRequest(url: httpUrl)
                request.timeoutInterval = timeout
                let (data, response) = try await defaultSession.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    responseData = data
                    AppLogger.shared.info("serverinfo returned 200 over HTTP for \(address)", category: "HTTP")
                }
            } catch {
                AppLogger.shared.debug("HTTP serverinfo failed for \(address): \(error.localizedDescription)", category: "HTTP")
            }
        }

        if let data = responseData {
            return (data, isHttps)
        }
        return nil
    }

    public func fetchServerInfo(host: Host, forceRemoteVerification: Bool = false) async throws -> (Host, [String: String]) {
        let uniqueId = uniqueID()

        AppLogger.shared.info("Fetching serverinfo for \(host.address)...", category: "HTTP")

        var candidates = [host.address]
        if host.isSecurelyPaired, host.serverId?.isEmpty == false,
           let remote = host.remoteAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remote.isEmpty, remote != host.address {
            candidates.append(remote)
        }
        var result: (String, [String: String], Bool, Data)?
        var lastError: Error = URLError(.cannotConnectToHost)
        for address in candidates {
            try Task.checkCancellation()
            guard let (data, isHTTPS) = await queryServerInfo(
                address: address,
                httpsPort: address == host.remoteAddress ? (host.remoteHTTPSPort ?? host.httpsPort) : host.httpsPort,
                httpPort: address == host.remoteAddress ? (host.remoteHTTPPort ?? host.httpPort) : host.httpPort,
                uniqueId: uniqueId, certificateDER: host.serverCertificateDER
            ) else { continue }
            let metadata = parseSimpleXML(data: data)
            guard (metadata["status_code"] == nil || metadata["status_code"] == "200"),
                  metadata["appversion"] != nil || metadata["uniqueid"] != nil || metadata["hostname"] != nil else {
                lastError = URLError(.badServerResponse)
                continue
            }
            if let expected = host.serverId, !expected.isEmpty,
               metadata["uniqueid"].map({ expected.caseInsensitiveCompare($0) != .orderedSame }) ?? true {
                lastError = HostTrustError.unexpectedHost
                continue
            }
            result = (address, metadata, isHTTPS, data)
            break
        }
        guard let (activeAddr, dict, isHttps, serverInfoData) = result else { throw lastError }
        if host.isSecurelyPaired && !isHttps {
            // HTTP can tell us a listener is alive, but cannot authenticate metadata
            // or refresh the saved certificate's host identity.
            var unverified = host
            unverified.status = .offline
            return (unverified, [:])
        }
        var updatedHost = host
        updatedHost.activeAddress = activeAddr
        if isHttps {
            updatedHost.capabilities = HostCapabilities.parse(dict, commands: HostXMLValues.elements("ServerCommand", data: serverInfoData))
            updatedHost.currentAppUUID = dict["currentgameuuid"].flatMap { $0.isEmpty ? nil : $0 }
        }
        updatedHost.lastSeen = Date()
        if let hostname = dict["hostname"], !hostname.isEmpty { updatedHost.name = hostname }
        if let appVersion = dict["appversion"], !appVersion.isEmpty { updatedHost.appVersion = appVersion }
        if let gfeVersion = dict["GfeVersion"], !gfeVersion.isEmpty { updatedHost.gfeVersion = gfeVersion }
        if let uid = dict["uniqueid"], !uid.isEmpty { updatedHost.serverId = uid }
        if let mac = dict["mac"], !mac.isEmpty, SunshineHTTPClient.isValidMacAddress(mac) {
            updatedHost.macAddress = mac
        }
        if activeAddr == host.address, let httpsPortStr = dict["HttpsPort"], let port = Int(httpsPortStr), (1...65535).contains(port) {
            updatedHost.httpsPort = port
        }
        // ExternalPort is a WAN HTTP mapping, not the host's LAN HTTP port.
        // Do not overwrite the configured listener port during every refresh.
        if let codec = dict["ServerCodecModeSupport"], let codecVal = Int32(codec) {
            updatedHost.serverCodecModeSupport = codecVal
        }

        // Determine pairing and reachability:
        // 1. If this host was already paired, it MUST remain paired!
        //    (Only explicit unpairHost or HTTP 401 on an authenticated endpoint can unpair a host).
        // 2. Over plain HTTP fallback, Sunshine/GameStream cannot authenticate client certificates and
        //    always returns PairStatus 0. Therefore, HTTP fallback must never clear isPaired.
        // 3. For new/unpaired hosts, an HTTPS response with PairStatus == 1 confirms pairing.
        let isConfirmedPaired: Bool
        if host.isSecurelyPaired {
            isConfirmedPaired = true
        } else if isHttps && dict["PairStatus"] == "1" {
            isConfirmedPaired = true
        } else {
            isConfirmedPaired = false
        }

        updatedHost.isPaired = isConfirmedPaired || host.needsCertificatePairing
        updatedHost.status = isConfirmedPaired ? .online : .pairingRequired

        if isConfirmedPaired, let curGame = dict["currentgame"], let curGameId = Int(curGame), curGameId != 0 {
            updatedHost.currentAppId = curGameId
            updatedHost.status = .streaming
        } else {
            updatedHost.currentAppId = nil
            if updatedHost.status == .streaming {
                updatedHost.status = isConfirmedPaired ? .online : .pairingRequired
            }
        }

        if activeAddr == host.address {
            updatedHost = await RemoteAddressDiscovery.shared.update(
                host: updatedHost, reportedAddress: dict["ExternalIP"],
                reportedHTTPPort: dict["ExternalPort"].flatMap(Int.init), force: forceRemoteVerification
            ) { [self] address, port, httpPort, expectedHost in
                await verifyRemoteEndpoint(address: address, httpsPort: port, httpPort: httpPort, host: expectedHost)
            }
        }

        AppLogger.shared.info("Parsed host [\(updatedHost.name)] (Active: \(activeAddr), Remote: \(updatedHost.remoteAddress ?? "none")) - Paired: \(updatedHost.isPaired), Status: \(updatedHost.status)", category: "HTTP")
        return (updatedHost, dict)
    }

    /// A reachable socket or an HTTP UUID alone cannot authenticate a remote PC.
    func verifyRemoteEndpoint(address: String, httpsPort: Int, httpPort: Int? = nil, host: Host) async -> Bool {
        guard host.isSecurelyPaired, let expectedID = host.serverId, !expectedID.isEmpty,
              (1...65535).contains(httpsPort),
              let url = URL(string: "https://\(Host.urlHost(address)):\(httpsPort)/serverinfo?uniqueid=\(uniqueID())") else {
            return false
        }
        var verificationStage = "HTTPS certificate and server ID"
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await self.data(for: request, host: host)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let metadata = parseSimpleXML(data: data)
            guard (metadata["status_code"] == nil || metadata["status_code"] == "200"),
                  metadata["uniqueid"].map({ expectedID.caseInsensitiveCompare($0) == .orderedSame }) == true else {
                return false
            }
            // ExternalPort describes HTTP. Check that listener too, after the
            // HTTPS endpoint has authenticated the PC. HTTP alone is never proof.
            if let httpPort {
                verificationStage = "HTTP server ID"
                guard (1...65535).contains(httpPort),
                      let httpURL = URL(string: "http://\(Host.urlHost(address)):\(httpPort)/serverinfo?uniqueid=\(uniqueID())") else { return false }
                var httpRequest = URLRequest(url: httpURL)
                httpRequest.timeoutInterval = 3
                let (httpData, httpResponse) = try await defaultSession.data(for: httpRequest)
                let httpMetadata = parseSimpleXML(data: httpData)
                guard (httpResponse as? HTTPURLResponse)?.statusCode == 200,
                      httpMetadata["status_code"] == nil || httpMetadata["status_code"] == "200",
                      httpMetadata["uniqueid"].map({ expectedID.caseInsensitiveCompare($0) == .orderedSame }) == true else { return false }
            }
            return true
        } catch {
            let failure = error as NSError
            AppLogger.shared.warning("Remote verification for \(address) failed during \(verificationStage): \(failure.domain) \(failure.code): \(failure.localizedDescription)", category: "NETWORK")
            return false
        }
    }

    public func fetchAppList(host: Host) async throws -> [StreamApp] {
        let uniqueId = uniqueID()
        guard let url = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/applist?uniqueid=\(uniqueId)") else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Fetching applist from \(url.absoluteString)...", category: "HTTP")
        let (data, response) = try await data(for: URLRequest(url: url), host: host)
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            AppLogger.shared.error("applist returned HTTP status \(httpResp.statusCode)", category: "HTTP")
            throw URLError(.badServerResponse)
        }

        let dict = parseSimpleXML(data: data)
        if dict["status_code"] == "401" {
            AppLogger.shared.error("applist failed: Host reported client not authorized (401). Host must be paired.", category: "HTTP")
            throw NSError(domain: "SunshineHTTPClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Client is not authorized. Please pair with this host first."])
        }

        let apps = parseAppListXML(data: data, host: host)
        AppLogger.shared.info("Fetched \(apps.count) apps from host \(host.name)", category: "HTTP")
        return apps
    }

    public func fetchBoxArt(host: Host, appId: Int, appUUID: String? = nil) async throws -> Data {
        let uniqueId = uniqueID()
        guard let url = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/appasset?uniqueid=\(uniqueId)&appid=\(appId)&AssetType=2&AssetIdx=0" + (appUUID.flatMap { UUID(uuidString: $0) != nil ? "&appuuid=\($0)" : nil } ?? "")) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await data(for: URLRequest(url: url), host: host)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func launchApp(
        host: Host,
        appId: Int,
        appUUID: String? = nil,
        settings: StreamSettings,
        rikey: String,
        rikeyId: UInt32
    ) async throws -> String? {
        let uniqueId = uniqueID()
        let mode = "\(settings.width)x\(settings.height)x\(settings.fps)"
        let surroundAudioInfo = settings.audioMode.surroundAudioInfo
        let localAudioPlayMode = settings.muteHostAudio ? 0 : 1
        let sops = settings.optimizeGameSettings ? "1" : "0"
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/launch?uniqueid=\(uniqueId)&appid=\(appId)&mode=\(mode)&additionalStates=1&sops=\(sops)&rikey=\(rikey)&rikeyid=\(rikeyId)&localAudioPlayMode=\(localAudioPlayMode)&surroundAudioInfo=\(surroundAudioInfo)"
        if let appUUID, UUID(uuidString: appUUID) != nil { urlString += "&appuuid=\(appUUID)" }
        urlString.append(HostLaunchOptions.query(settings: settings, host: host))
        if !extraParams.isEmpty { urlString.append(extraParams) }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Launching app \(appId) on \(host.effectiveAddress), requested mode=\(mode)", category: "HTTP")
        let (data, response) = try await data(for: URLRequest(url: url), host: host)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.shared.error("Launch app returned HTTP \(code)", category: "HTTP")
            throw URLError(.badServerResponse)
        }

        let dict = parseSimpleXML(data: data)
        let statusCode = dict["status_code"] ?? "200"
        if statusCode != "200" {
            let statusMsg = dict["status_message"] ?? "Server Error"
            AppLogger.shared.error("Launch app failed: \(statusMsg) (code \(statusCode))", category: "HTTP")
            throw NSError(domain: "SunshineHTTPClient", code: Int(statusCode) ?? -1, userInfo: [NSLocalizedDescriptionKey: statusMsg])
        }

        if let gameSession = dict["gamesession"], gameSession == "0" {
            AppLogger.shared.error("Host failed to create game session", category: "HTTP")
            throw NSError(domain: "SunshineHTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Host failed to launch game session"])
        }

        let sessionUrl = dict["sessionUrl0"]
        if let sUrl = sessionUrl, !sUrl.isEmpty {
            AppLogger.shared.info("Launch succeeded with RTSP sessionUrl0: \(sUrl)", category: "HTTP")
            return sUrl
        } else {
            AppLogger.shared.info("Launch succeeded with direct RTSP connection", category: "HTTP")
            return nil
        }
    }

    public func resumeApp(
        host: Host,
        settings: StreamSettings,
        rikey: String,
        rikeyId: UInt32
    ) async throws -> String? {
        let uniqueId = uniqueID()
        let mode = "\(settings.width)x\(settings.height)x\(settings.fps)"
        let surroundAudioInfo = settings.audioMode.surroundAudioInfo
        let localAudioPlayMode = settings.muteHostAudio ? 0 : 1
        let sops = settings.optimizeGameSettings ? "1" : "0"
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/resume?uniqueid=\(uniqueId)&mode=\(mode)&additionalStates=1&sops=\(sops)&rikey=\(rikey)&rikeyid=\(rikeyId)&localAudioPlayMode=\(localAudioPlayMode)&surroundAudioInfo=\(surroundAudioInfo)"
        urlString.append(HostLaunchOptions.query(settings: settings, host: host))
        if !extraParams.isEmpty { urlString.append(extraParams) }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Resuming stream on \(host.effectiveAddress), requested mode=\(mode)", category: "HTTP")
        let (data, response) = try await data(for: URLRequest(url: url), host: host)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let dict = parseSimpleXML(data: data)
        let statusCode = dict["status_code"] ?? "200"
        if statusCode != "200" {
            let statusMsg = dict["status_message"] ?? "Server Error"
            AppLogger.shared.error("Resume app failed: \(statusMsg) (code \(statusCode))", category: "HTTP")
            throw NSError(domain: "SunshineHTTPClient", code: Int(statusCode) ?? -1, userInfo: [NSLocalizedDescriptionKey: statusMsg])
        }

        if let resumeStatus = dict["resume"], resumeStatus == "0" {
            AppLogger.shared.error("Host failed to resume session", category: "HTTP")
            throw NSError(domain: "SunshineHTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Host failed to resume session"])
        }

        let sessionUrl = dict["sessionUrl0"]
        if let sUrl = sessionUrl, !sUrl.isEmpty {
            AppLogger.shared.info("Resume succeeded with RTSP sessionUrl0: \(sUrl)", category: "HTTP")
            return sUrl
        } else {
            AppLogger.shared.info("Resume succeeded with direct RTSP connection", category: "HTTP")
            return nil
        }
    }

    public func quitApp(host: Host) async throws {
        let uniqueId = uniqueID()
        guard let url = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/cancel?uniqueid=\(uniqueId)") else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Canceling stream: \(url.absoluteString)", category: "HTTP")
        _ = try await data(for: URLRequest(url: url), host: host)
    }

    public func unpair(host: Host) async {
        let uniqueId = uniqueID()

        AppLogger.shared.info("Sending unpair request to \(host.effectiveAddress)...", category: "HTTP")

        // Send unpair to HTTP port (47989)
        if let httpUrl = URL(string: "http://\(host.urlAddress):\(host.effectiveHTTPPort)/unpair?uniqueid=\(uniqueId)") {
            _ = try? await defaultSession.data(from: httpUrl)
        }

        // Also send unpair to HTTPS port (47984)
        if host.httpsPort > 0,
           let httpsUrl = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/unpair?uniqueid=\(uniqueId)") {
            _ = try? await data(for: URLRequest(url: httpsUrl), host: host)
        }
    }

    public func getClipboardContent(host: Host) async throws -> String {
        let uniqueId = uniqueID()
        guard let url = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/actions/clipboard?type=text&uniqueid=\(uniqueId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        let (data, response) = try await data(for: request, host: host)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SunshineHTTPClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(code)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func sendClipboardContent(host: Host, text: String) async throws {
        let uniqueId = uniqueID()
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/actions/clipboard?uniqueid=\(uniqueId)&uuid=\(uuid)&type=text") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = text.data(using: .utf8)
        request.timeoutInterval = 2.0

        let (_, response) = try await data(for: request, host: host)
        guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SunshineHTTPClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(code)"])
        }
    }

    func extensionRequest(host: Host, path: String, query: [URLQueryItem] = [], method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        guard host.isSecurelyPaired, let baseURL = host.baseUrlHttps, var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw HostTrustError.pairingRequired }
        parts.path = path
        parts.queryItems = (path.hasPrefix("/power-actions/") ? [] : [URLQueryItem(name: "uniqueid", value: uniqueID())]) + query
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if method == "POST" { request.httpBody = Data() }
        if let extensionTransport { return try await extensionTransport(request, host) }
        let (bytes, response) = try await data(for: request, host: host)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }

    public func fetchRaw(urlString: String, timeout: TimeInterval = 10.0, usePairingSession: Bool = false, certificateDER: Data? = nil) async throws -> (Data, [String: String]) {
        guard let url = URL(string: urlString) else {
            AppLogger.shared.error("Invalid HTTP request URL", category: "HTTP")
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        AppLogger.shared.debug("HTTP GET \(url.host ?? "host")\(url.path) (timeout: \(Int(timeout))s)", category: "HTTP")

        let sessionToUse = url.scheme == "https" ? try session(certificateDER: certificateDER) : (usePairingSession ? pairingSession : defaultSession)
        do {
            let (data, response) = try await sessionToUse.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = parseSimpleXML(data: data)
            AppLogger.shared.debug("HTTP \(statusCode) response (XML status: \(parsed["status_code"] ?? "unknown"))", category: "HTTP")
            return (data, parsed)
        } catch {
            AppLogger.shared.error("HTTP GET failed for \(url.host ?? "host")\(url.path): \(error.localizedDescription)", category: "HTTP")
            throw error
        }
    }

    // Compiled once. The old code built two NSRegularExpressions for every parsed response, and
    // parseAppListXML calls the parser once per <app> block.
    private static let innerTagRegex = try? NSRegularExpression(pattern: "<([a-zA-Z0-9_-]+)>([^<]*)</\\1>", options: [])
    private static let attributeRegex = try? NSRegularExpression(pattern: "([a-zA-Z0-9_-]+)=[\"']([^\"']*)[\"']", options: [])
    private static let appBlockRegex = try? NSRegularExpression(pattern: "(?si)<app>(.*?)</app>", options: [])

    public func parseSimpleXML(data: Data) -> [String: String] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [:] }
        return parseSimpleXML(xmlString: xmlString)
    }

    public func parseSimpleXML(xmlString: String) -> [String: String] {
        var result: [String: String] = [:]
        let nsString = xmlString as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // 1. Match inner tags: <tag>val</tag>
        if let regex = Self.innerTagRegex {
            for match in regex.matches(in: xmlString, options: [], range: fullRange) {
                let key = nsString.substring(with: match.range(at: 1))
                let val = nsString.substring(with: match.range(at: 2))
                result[key] = val.replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&apos;", with: "'")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&amp;", with: "&")
            }
        }

        // 2. Match XML attributes: attr="val" or attr='val' (e.g. status_code="200", paired="1")
        if let regex = Self.attributeRegex {
            for match in regex.matches(in: xmlString, options: [], range: fullRange) {
                let key = nsString.substring(with: match.range(at: 1))
                let val = nsString.substring(with: match.range(at: 2))
                if result[key] == nil {
                    result[key] = val.replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&apos;", with: "'")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&amp;", with: "&")
                }
            }
        }

        return result
    }

    func parseAppListXML(data: Data, host: Host) -> [StreamApp] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [] }
        var apps: [StreamApp] = []

        // Match <App>...</App> or <app>...</app> case-insensitively
        guard let appBlockRegex = Self.appBlockRegex else { return [] }

        let nsString = xmlString as NSString
        let matches = appBlockRegex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            // Parse the substring directly; the previous version round-tripped it through Data.
            let appContent = nsString.substring(with: match.range(at: 1))
            let appDict = parseSimpleXML(xmlString: appContent)

            let rawTitle = appDict["AppTitle"] ?? appDict["apptitle"]
            let rawId = appDict["ID"] ?? appDict["id"]

            if let idStr = rawId, let appId = Int(idStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let unescapedTitle = (rawTitle ?? "Unknown App").trimmingCharacters(in: .whitespacesAndNewlines)

                let isCollector = (appDict["IsAppCollectorGame"] ?? appDict["isappcollectorgame"]) == "1"
                let boxArtUrl = URL(string: "https://\(host.urlAddress):\(host.effectiveHTTPSPort)/appasset?uniqueid=\(uniqueID())&appid=\(appId)&AssetType=2&AssetIdx=0")
                var app = StreamApp(id: appId, title: unescapedTitle, isAppCollectorGame: isCollector, boxArtUrl: boxArtUrl)
                app.uuid = appDict["UUID"].flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
                app.hostOrder = appDict["IDX"].flatMap(Int.init)
                app.artVersion = appDict["ArtVersion"]
                apps.append(app)
            }
        }

        return apps
    }
}
