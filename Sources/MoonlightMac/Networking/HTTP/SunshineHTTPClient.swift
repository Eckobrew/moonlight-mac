import Foundation
import Security
import MoonlightCommonC

public final class SunshineHTTPClient: NSObject, @unchecked Sendable {
    public static let shared = SunshineHTTPClient()

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
                AppLogger.shared.debug("HTTPS serverinfo failed for \(address): \(error.localizedDescription); falling back to HTTP", category: "HTTP")
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

    public func fetchServerInfo(host: Host) async throws -> (Host, [String: String]) {
        let uniqueId = CertificateManager.shared.uniqueId

        AppLogger.shared.info("Fetching serverinfo for \(host.address)...", category: "HTTP")

        // 1. Try primary address first
        var successInfo = await queryServerInfo(address: host.address, httpsPort: host.httpsPort, httpPort: host.httpPort, uniqueId: uniqueId, certificateDER: host.serverCertificateDER)
        var activeAddr = host.address

        // 2. If primary address failed, attempt fallback to remoteAddress
        if successInfo == nil,
           let remote = host.remoteAddress,
           !remote.isEmpty,
           remote != host.address {
            AppLogger.shared.info("Primary address \(host.address) unreachable for host \(host.name). Attempting fallback to remote address \(remote)...", category: "HTTP")
            if let remoteSuccess = await queryServerInfo(address: remote, httpsPort: host.httpsPort, httpPort: host.httpPort, uniqueId: uniqueId, certificateDER: host.serverCertificateDER) {
                successInfo = remoteSuccess
                activeAddr = remote
                AppLogger.shared.info("Successfully connected to \(host.name) via remote IP backup: \(remote)", category: "HTTP")
            }
        }

        guard let (data, isHttps) = successInfo else {
            throw URLError(.cannotConnectToHost)
        }

        let dict = parseSimpleXML(data: data)
        guard dict["appversion"] != nil || dict["uniqueid"] != nil || dict["mac"] != nil || dict["hostname"] != nil else {
            AppLogger.shared.error("Invalid serverinfo response from \(activeAddr): missing GameStream/Sunshine metadata", category: "HTTP")
            throw URLError(.badServerResponse)
        }

        if let expected = host.serverId, !expected.isEmpty,
           let actual = dict["uniqueid"], expected.caseInsensitiveCompare(actual) != .orderedSame {
            throw HostTrustError.unexpectedHost
        }
        if host.isSecurelyPaired && !isHttps {
            // HTTP can tell us a listener is alive, but cannot authenticate metadata
            // or refresh the saved certificate's host identity.
            var unverified = host
            unverified.status = .offline
            return (unverified, [:])
        }
        var updatedHost = host
        updatedHost.activeAddress = activeAddr
        if let hostname = dict["hostname"], !hostname.isEmpty { updatedHost.name = hostname }
        if let appVersion = dict["appversion"], !appVersion.isEmpty { updatedHost.appVersion = appVersion }
        if let gfeVersion = dict["GfeVersion"], !gfeVersion.isEmpty { updatedHost.gfeVersion = gfeVersion }
        if let uid = dict["uniqueid"], !uid.isEmpty { updatedHost.serverId = uid }
        if let mac = dict["mac"], !mac.isEmpty, SunshineHTTPClient.isValidMacAddress(mac) {
            updatedHost.macAddress = mac
        }
        if let httpsPortStr = dict["HttpsPort"], let port = Int(httpsPortStr), port > 0 {
            updatedHost.httpsPort = port
        }
        if let extPortStr = dict["ExternalPort"], let port = Int(extPortStr), port > 0 {
            updatedHost.httpPort = port
        }
        if let extIp = dict["ExternalIP"], !extIp.isEmpty {
            updatedHost.remoteAddress = extIp
        }
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

        AppLogger.shared.info("Parsed host [\(updatedHost.name)] (Active: \(activeAddr), Remote: \(updatedHost.remoteAddress ?? "none")) - Paired: \(updatedHost.isPaired), Status: \(updatedHost.status)", category: "HTTP")
        return (updatedHost, dict)
    }

    public func fetchAppList(host: Host) async throws -> [StreamApp] {
        let uniqueId = CertificateManager.shared.uniqueId
        guard let url = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/applist?uniqueid=\(uniqueId)") else {
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

    public func fetchBoxArt(host: Host, appId: Int) async throws -> Data {
        let uniqueId = CertificateManager.shared.uniqueId
        guard let url = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/appasset?uniqueid=\(uniqueId)&appid=\(appId)&AssetType=2&AssetIdx=0") else {
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
        settings: StreamSettings,
        rikey: String,
        rikeyId: UInt32
    ) async throws -> String? {
        let uniqueId = CertificateManager.shared.uniqueId
        let mode = "\(settings.width)x\(settings.height)x\(settings.fps)"
        let surroundAudioInfo = settings.audioMode.surroundAudioInfo
        let localAudioPlayMode = settings.muteHostAudio ? 0 : 1
        let sops = settings.optimizeGameSettings ? "1" : "0"
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.urlAddress):\(host.httpsPort)/launch?uniqueid=\(uniqueId)&appid=\(appId)&mode=\(mode)&additionalStates=1&sops=\(sops)&rikey=\(rikey)&rikeyid=\(rikeyId)&localAudioPlayMode=\(localAudioPlayMode)&surroundAudioInfo=\(surroundAudioInfo)"
        if !extraParams.isEmpty {
            urlString.append(extraParams)
        }

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
        let uniqueId = CertificateManager.shared.uniqueId
        let mode = "\(settings.width)x\(settings.height)x\(settings.fps)"
        let surroundAudioInfo = settings.audioMode.surroundAudioInfo
        let localAudioPlayMode = settings.muteHostAudio ? 0 : 1
        let sops = settings.optimizeGameSettings ? "1" : "0"
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.urlAddress):\(host.httpsPort)/resume?uniqueid=\(uniqueId)&mode=\(mode)&additionalStates=1&sops=\(sops)&rikey=\(rikey)&rikeyid=\(rikeyId)&localAudioPlayMode=\(localAudioPlayMode)&surroundAudioInfo=\(surroundAudioInfo)"
        if !extraParams.isEmpty {
            urlString.append(extraParams)
        }

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
        let uniqueId = CertificateManager.shared.uniqueId
        guard let url = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/cancel?uniqueid=\(uniqueId)") else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Canceling stream: \(url.absoluteString)", category: "HTTP")
        _ = try await data(for: URLRequest(url: url), host: host)
    }

    public func unpair(host: Host) async {
        let uniqueId = CertificateManager.shared.uniqueId

        AppLogger.shared.info("Sending unpair request to \(host.effectiveAddress)...", category: "HTTP")

        // Send unpair to HTTP port (47989)
        if let httpUrl = URL(string: "http://\(host.urlAddress):\(host.httpPort)/unpair?uniqueid=\(uniqueId)") {
            _ = try? await defaultSession.data(from: httpUrl)
        }

        // Also send unpair to HTTPS port (47984)
        if host.httpsPort > 0,
           let httpsUrl = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/unpair?uniqueid=\(uniqueId)") {
            _ = try? await data(for: URLRequest(url: httpsUrl), host: host)
        }
    }

    public func getClipboardContent(host: Host) async throws -> String {
        let uniqueId = CertificateManager.shared.uniqueId
        guard let url = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/actions/clipboard?type=text&uniqueid=\(uniqueId)") else {
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
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/actions/clipboard?uniqueid=\(uniqueId)&uuid=\(uuid)&type=text") else {
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
                result[key] = val
            }
        }

        // 2. Match XML attributes: attr="val" or attr='val' (e.g. status_code="200", paired="1")
        if let regex = Self.attributeRegex {
            for match in regex.matches(in: xmlString, options: [], range: fullRange) {
                let key = nsString.substring(with: match.range(at: 1))
                let val = nsString.substring(with: match.range(at: 2))
                if result[key] == nil {
                    result[key] = val
                }
            }
        }

        return result
    }

    private func parseAppListXML(data: Data, host: Host) -> [StreamApp] {
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
                let unescapedTitle = (rawTitle ?? "Unknown App")
                    .replacingOccurrences(of: "&apos;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let isCollector = (appDict["IsAppCollectorGame"] ?? appDict["isappcollectorgame"]) == "1"
                let boxArtUrl = URL(string: "https://\(host.urlAddress):\(host.httpsPort)/appasset?uniqueid=\(CertificateManager.shared.uniqueId)&appid=\(appId)&AssetType=2&AssetIdx=0")
                apps.append(StreamApp(id: appId, title: unescapedTitle, isAppCollectorGame: isCollector, boxArtUrl: boxArtUrl))
            }
        }

        return apps
    }
}
