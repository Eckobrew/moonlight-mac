import Foundation
import MoonlightCommonC

public final class SunshineHTTPClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let shared = SunshineHTTPClient()

    private lazy var defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 15.0
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var pairingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180.0
        config.timeoutIntervalForResource = 180.0
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Handle server trust and mutual TLS client certificate authentication
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            AppLogger.shared.debug("Accepting server trust for host: \(challenge.protectionSpace.host)", category: "HTTP")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            if let identity = CertificateManager.shared.getClientIdentity() {
                AppLogger.shared.debug("Providing client mTLS certificate identity to: \(challenge.protectionSpace.host)", category: "HTTP")
                let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                AppLogger.shared.warning("Client certificate challenge received but no identity found", category: "HTTP")
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func fetchServerInfo(host: Host) async throws -> (Host, [String: String]) {
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        AppLogger.shared.info("Fetching serverinfo for \(host.address)...", category: "HTTP")

        // 1. Try HTTPS first matching Moonlight-Qt (properly reports pairing status)
        var responseData: Data?
        var isHttps = false

        if host.httpsPort > 0,
           let httpsUrl = URL(string: "https://\(host.address):\(host.httpsPort)/serverinfo?uniqueid=\(uniqueId)&uuid=\(uuid)") {
            do {
                let (data, response) = try await defaultSession.data(from: httpsUrl)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    responseData = data
                    isHttps = true
                    AppLogger.shared.info("serverinfo returned 200 over HTTPS (mTLS authenticated)", category: "HTTP")
                }
            } catch {
                AppLogger.shared.debug("HTTPS serverinfo failed: \(error.localizedDescription); falling back to HTTP", category: "HTTP")
            }
        }

        // 2. Fall back to HTTP if HTTPS fails or host is not yet paired
        if responseData == nil,
           let httpUrl = URL(string: "http://\(host.address):\(host.httpPort)/serverinfo?uniqueid=\(uniqueId)&uuid=\(uuid)") {
            do {
                let (data, response) = try await defaultSession.data(from: httpUrl)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    responseData = data
                    AppLogger.shared.info("serverinfo returned 200 over HTTP", category: "HTTP")
                }
            } catch {
                AppLogger.shared.error("HTTP serverinfo failed for \(host.address): \(error.localizedDescription)", category: "HTTP")
            }
        }

        guard let data = responseData else {
            throw URLError(.cannotConnectToHost)
        }

        let dict = parseSimpleXML(data: data)
        var updatedHost = host
        if let hostname = dict["hostname"], !hostname.isEmpty { updatedHost.name = hostname }
        if let appVersion = dict["appversion"] { updatedHost.appVersion = appVersion }
        if let gfeVersion = dict["GfeVersion"] { updatedHost.gfeVersion = gfeVersion }
        if let mac = dict["mac"] { updatedHost.macAddress = mac }
        if let httpsPortStr = dict["HttpsPort"], let port = Int(httpsPortStr), port > 0 {
            updatedHost.httpsPort = port
        }
        if let extPortStr = dict["ExternalPort"], let port = Int(extPortStr), port > 0 {
            updatedHost.httpPort = port
        }
        if let codec = dict["ServerCodecModeSupport"], let codecVal = Int32(codec) {
            updatedHost.serverCodecModeSupport = codecVal
        }

        // PairStatus is 1 if verified via HTTPS or if XML PairStatus == 1
        let pairStatus = isHttps || (dict["PairStatus"] == "1")
        updatedHost.isPaired = pairStatus
        updatedHost.status = pairStatus ? .online : .pairingRequired

        if let curGame = dict["currentgame"], let curGameId = Int(curGame), curGameId != 0 {
            updatedHost.currentAppId = curGameId
            updatedHost.status = .streaming
        }

        AppLogger.shared.info("Parsed host [\(updatedHost.name)] - Paired: \(updatedHost.isPaired), Status: \(updatedHost.status)", category: "HTTP")
        return (updatedHost, dict)
    }

    public func fetchAppList(host: Host) async throws -> [StreamApp] {
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "https://\(host.address):\(host.httpsPort)/applist?uniqueid=\(uniqueId)&uuid=\(uuid)") else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Fetching applist from \(url.absoluteString)...", category: "HTTP")
        let (data, response) = try await defaultSession.data(from: url)
        if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
            AppLogger.shared.error("applist returned status \(httpResp.statusCode)", category: "HTTP")
            throw URLError(.badServerResponse)
        }

        let apps = parseAppListXML(data: data, host: host)
        AppLogger.shared.info("Fetched \(apps.count) apps from host \(host.name)", category: "HTTP")
        return apps
    }

    public func launchApp(
        host: Host,
        appId: Int,
        settings: StreamSettings,
        rikey: String,
        rikeyId: String
    ) async throws -> String {
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let mode = "\(settings.width)x\(settings.height)x\(settings.fps)"
        let surroundAudioInfo = settings.audioMode.limelightValue
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.address):\(host.httpsPort)/launch?uniqueid=\(uniqueId)&uuid=\(uuid)&appid=\(appId)&mode=\(mode)&additionalflags=0&rikey=\(rikey)&rikeyid=\(rikeyId)&surroundAudioInfo=\(surroundAudioInfo)"
        if !extraParams.isEmpty {
            urlString.append(extraParams)
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Launching app \(appId): \(url.absoluteString)", category: "HTTP")
        let (data, response) = try await defaultSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.shared.error("Launch app returned HTTP \(code)", category: "HTTP")
            throw URLError(.badServerResponse)
        }

        let dict = parseSimpleXML(data: data)
        guard let sessionUrl = dict["sessionUrl0"], !sessionUrl.isEmpty else {
            AppLogger.shared.error("Launch response missing sessionUrl0", category: "HTTP")
            throw NSError(domain: "SunshineHTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to obtain sessionUrl0 from host launch response"])
        }

        AppLogger.shared.info("Launch succeeded with sessionUrl0: \(sessionUrl)", category: "HTTP")
        return sessionUrl
    }

    public func resumeApp(
        host: Host,
        settings: StreamSettings,
        rikey: String,
        rikeyId: String
    ) async throws -> String {
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let surroundAudioInfo = settings.audioMode.limelightValue
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.address):\(host.httpsPort)/resume?uniqueid=\(uniqueId)&uuid=\(uuid)&rikey=\(rikey)&rikeyid=\(rikeyId)&surroundAudioInfo=\(surroundAudioInfo)"
        if !extraParams.isEmpty {
            urlString.append(extraParams)
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Resuming stream: \(url.absoluteString)", category: "HTTP")
        let (data, response) = try await defaultSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let dict = parseSimpleXML(data: data)
        guard let sessionUrl = dict["sessionUrl0"], !sessionUrl.isEmpty else {
            throw NSError(domain: "SunshineHTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to obtain sessionUrl0 from host resume response"])
        }

        return sessionUrl
    }

    public func quitApp(host: Host) async throws {
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "https://\(host.address):\(host.httpsPort)/cancel?uniqueid=\(uniqueId)&uuid=\(uuid)") else {
            throw URLError(.badURL)
        }

        AppLogger.shared.info("Canceling stream: \(url.absoluteString)", category: "HTTP")
        _ = try await defaultSession.data(from: url)
    }

    public func unpair(host: Host) async {
        let uniqueId = CertificateManager.shared.uniqueId
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        AppLogger.shared.info("Sending unpair request to \(host.address)...", category: "HTTP")

        // Send unpair to HTTP port (47989)
        if let httpUrl = URL(string: "http://\(host.address):\(host.httpPort)/unpair?uniqueid=\(uniqueId)&uuid=\(uuid)") {
            _ = try? await defaultSession.data(from: httpUrl)
        }

        // Also send unpair to HTTPS port (47984)
        if host.httpsPort > 0,
           let httpsUrl = URL(string: "https://\(host.address):\(host.httpsPort)/unpair?uniqueid=\(uniqueId)&uuid=\(uuid)") {
            _ = try? await defaultSession.data(from: httpsUrl)
        }
    }

    public func fetchRaw(urlString: String, timeout: TimeInterval = 10.0, usePairingSession: Bool = false) async throws -> (Data, [String: String]) {
        guard let url = URL(string: urlString) else {
            AppLogger.shared.error("Invalid URL: \(urlString)", category: "HTTP")
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        AppLogger.shared.debug("HTTP GET: \(urlString) (timeout: \(Int(timeout))s)", category: "HTTP")

        let sessionToUse = usePairingSession ? pairingSession : defaultSession
        let (data, response) = try await sessionToUse.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = parseSimpleXML(data: data)

        AppLogger.shared.debug("HTTP \(statusCode) response: \(parsed)", category: "HTTP")
        return (data, parsed)
    }

    public func parseSimpleXML(data: Data) -> [String: String] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]

        // 1. Match inner tags: <tag>val</tag>
        let pattern = "<([a-zA-Z0-9_-]+)>([^<]*)</\\1>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = xmlString as NSString
            let matches = regex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                let key = nsString.substring(with: match.range(at: 1))
                let val = nsString.substring(with: match.range(at: 2))
                result[key] = val
            }
        }

        // 2. Match XML attributes: attr="val" or attr='val' (e.g. status_code="200", paired="1")
        let attrPattern = "([a-zA-Z0-9_-]+)=[\"']([^\"']*)[\"']"
        if let regex = try? NSRegularExpression(pattern: attrPattern, options: []) {
            let nsString = xmlString as NSString
            let matches = regex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
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

        let appBlockPattern = "(?s)<app>(.*?)</app>"
        guard let appBlockRegex = try? NSRegularExpression(pattern: appBlockPattern, options: []) else { return [] }

        let nsString = xmlString as NSString
        let matches = appBlockRegex.matches(in: xmlString, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let appContent = nsString.substring(with: match.range(at: 1))
            let appDict = parseSimpleXML(data: appContent.data(using: .utf8) ?? Data())
            if let title = appDict["AppTitle"], let idStr = appDict["ID"], let appId = Int(idStr) {
                let isCollector = appDict["IsAppCollectorGame"] == "1"
                let boxArtUrl = URL(string: "https://\(host.address):\(host.httpsPort)/appasset?uniqueid=\(CertificateManager.shared.uniqueId)&appid=\(appId)&AssetType=2&AssetIdx=0")
                apps.append(StreamApp(id: appId, title: title, isAppCollectorGame: isCollector, boxArtUrl: boxArtUrl))
            }
        }

        return apps
    }
}
