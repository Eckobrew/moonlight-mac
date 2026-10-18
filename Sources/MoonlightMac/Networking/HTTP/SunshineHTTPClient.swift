import Foundation
import MoonlightCommonC

public final class SunshineHTTPClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let shared = SunshineHTTPClient()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 15.0
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
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            if let identity = CertificateManager.shared.getClientIdentity() {
                let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func fetchServerInfo(host: Host) async throws -> (Host, [String: String]) {
        let uniqueId = CertificateManager.shared.uniqueId

        // 1. Prioritize HTTP on host.httpPort (default 47989) matching Moonlight-Qt
        var responseData: Data?
        if let httpUrl = URL(string: "http://\(host.address):\(host.httpPort)/serverinfo?uniqueid=\(uniqueId)"),
           let (httpData, response) = try? await session.data(from: httpUrl),
           let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
            responseData = httpData
        } else if let httpsUrl = URL(string: "https://\(host.address):\(host.httpsPort)/serverinfo?uniqueid=\(uniqueId)"),
                  let (httpsData, response) = try? await session.data(from: httpsUrl),
                  let httpsResp = response as? HTTPURLResponse, httpsResp.statusCode == 200 {
            responseData = httpsData
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
        let pairStatus = dict["PairStatus"] == "1"
        updatedHost.isPaired = pairStatus
        updatedHost.status = pairStatus ? .online : .pairingRequired
        if let curGame = dict["currentgame"], let curGameId = Int(curGame), curGameId != 0 {
            updatedHost.currentAppId = curGameId
            updatedHost.status = .streaming
        }

        return (updatedHost, dict)
    }

    public func fetchAppList(host: Host) async throws -> [StreamApp] {
        let uniqueId = CertificateManager.shared.uniqueId
        guard let url = URL(string: "https://\(host.address):\(host.httpsPort)/applist?uniqueid=\(uniqueId)") else {
            throw URLError(.badURL)
        }

        let (data, _) = try await session.data(from: url)
        return parseAppListXML(data: data, host: host)
    }

    public func launchApp(
        host: Host,
        appId: Int,
        settings: StreamSettings,
        rikey: String,
        rikeyId: String
    ) async throws -> String {
        let uniqueId = CertificateManager.shared.uniqueId
        let mode = "\(settings.width)x\(settings.height)x\(settings.fps)"
        let surroundAudioInfo = settings.audioMode.limelightValue
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.address):\(host.httpsPort)/launch?uniqueid=\(uniqueId)&appid=\(appId)&mode=\(mode)&additionalflags=0&rikey=\(rikey)&rikeyid=\(rikeyId)&surroundAudioInfo=\(surroundAudioInfo)"
        if !extraParams.isEmpty {
            urlString.append(extraParams)
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let dict = parseSimpleXML(data: data)
        guard let sessionUrl = dict["sessionUrl0"], !sessionUrl.isEmpty else {
            throw NSError(domain: "SunshineHTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to obtain sessionUrl0 from host launch response"])
        }

        return sessionUrl
    }

    public func resumeApp(
        host: Host,
        settings: StreamSettings,
        rikey: String,
        rikeyId: String
    ) async throws -> String {
        let uniqueId = CertificateManager.shared.uniqueId
        let surroundAudioInfo = settings.audioMode.limelightValue
        let extraParams = LiGetLaunchUrlQueryParameters().map { String(cString: $0) } ?? ""

        var urlString = "https://\(host.address):\(host.httpsPort)/resume?uniqueid=\(uniqueId)&rikey=\(rikey)&rikeyid=\(rikeyId)&surroundAudioInfo=\(surroundAudioInfo)"
        if !extraParams.isEmpty {
            urlString.append(extraParams)
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
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
        guard let url = URL(string: "https://\(host.address):\(host.httpsPort)/cancel?uniqueid=\(uniqueId)") else {
            throw URLError(.badURL)
        }

        _ = try await session.data(from: url)
    }

    public func fetchRaw(urlString: String) async throws -> (Data, [String: String]) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        return (data, parseSimpleXML(data: data))
    }

    private func parseSimpleXML(data: Data) -> [String: String] {
        guard let xmlString = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]

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
