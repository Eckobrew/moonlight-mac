import Foundation

struct HostControlError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

extension SunshineHTTPClient {
    func checkExtension(_ data: Data, _ response: HTTPURLResponse) throws -> [String: String] {
        let xml = parseSimpleXML(data: data)
        let status = Int(xml["status_code"] ?? "") ?? response.statusCode
        guard (200...299).contains(response.statusCode), (200...299).contains(status) else {
            throw HostControlError(code: status, message: xml["status_message"] ?? "Host request failed (\(status)).")
        }
        return xml
    }

    func supportsRuntimeBitrate(host: Host) async -> Bool {
        guard let (data, response) = try? await extensionRequest(host: host, path: "/api/abr/capabilities"),
              response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["features"] as? [String])?.contains("runtime_bitrate") == true
    }

    func setRuntimeBitrate(host: Host, kbps: Int) async throws -> Int {
        guard (1...500_000).contains(kbps) else { throw HostControlError(code: 400, message: "Bitrate must be between 1 and 500000 Kbps.") }
        let (data, response) = try await extensionRequest(host: host, path: "/bitrate", query: [.init(name: "bitrate", value: String(kbps))])
        let xml = try checkExtension(data, response)
        guard let applied = xml["bitrate"].flatMap(Int.init), (1...500_000).contains(applied) else { throw URLError(.badServerResponse) }
        return applied
    }

    func fetchHardwareMetrics(host: Host) async throws -> HostHardwareMetrics {
        let (data, response) = try await extensionRequest(host: host, path: "/api/hardware-metrics")
        guard response.statusCode == 200 else {
            throw HostControlError(code: response.statusCode, message: "Host statistics unavailable (\(response.statusCode)).")
        }
        let metrics = try JSONDecoder().decode(HostHardwareMetrics.self, from: data)
        guard metrics.version == 1, metrics.interval_ms > 0 else { throw URLError(.badServerResponse) }
        return metrics
    }

    /// Called once per explicit user confirmation. Neither request is retried.
    func sleepHost(host: Host) async throws {
        let (data, response) = try await extensionRequest(host: host, path: "/power-actions/v1")
        let xml = try checkExtension(data, response)
        guard xml["PowerActionVersion"] == "1", xml["SleepSupported"] == "1", xml["SleepAllowed"] == "1", xml["SleepAvailable"] == "1",
              let token = xml["SleepToken"], !token.isEmpty else {
            throw HostControlError(code: 409, message: "The PC cannot sleep now. End all host sessions and check this device's sleep permission, then confirm again.")
        }
        try Task.checkCancellation()
        let accepted: Data
        let result: HTTPURLResponse
        do {
            (accepted, result) = try await extensionRequest(host: host, path: "/power-actions/v1/sleep", query: [.init(name: "token", value: token)], method: "POST")
        } catch {
            throw HostControlError(code: -1, message: "The sleep request's outcome is unknown because its acknowledgement was not received. Confirm again before retrying.")
        }
        let confirmation = try checkExtension(accepted, result)
        guard result.statusCode == 202, confirmation["status_code"] == "202", confirmation["SleepAccepted"] == "1" else {
            throw HostControlError(code: result.statusCode, message: "Sleep outcome is unknown. Confirm again before retrying.")
        }
    }

    /// Host actions deliberately complete with XML 410 instead of an RTSP URL.
    func performHostAction(host: Host, app: StreamApp) async throws -> String {
        guard app.isHostAction else { throw URLError(.unsupportedURL) }
        var query = [URLQueryItem(name: "appid", value: String(app.id)),
                     .init(name: "rikey", value: CryptoUtils.hexString(CryptoUtils.randomBytes(count: 16))),
                     .init(name: "rikeyid", value: String(UInt32.random(in: 1...UInt32.max))),
                     .init(name: "localAudioPlayMode", value: "0")]
        if let uuid = app.uuid { query.append(.init(name: "appuuid", value: uuid)) }
        let (data, response) = try await extensionRequest(host: host, path: "/launch", query: query)
        let xml = parseSimpleXML(data: data)
        // A 410 also requests termination confirmation. Only the specific,
        // documented completion message for this action is successful.
        let expected: String
        switch app.control {
        case .disconnectMonitor: expected = "Remote Monitor disconnected successfully."
        case .disconnectInput: expected = "Remote Input disconnected successfully."
        case .terminate: expected = "Active stream terminated. Remote Monitor and Remote Input remain connected."
        default: throw URLError(.unsupportedURL)
        }
        guard response.statusCode == 200, xml["status_code"] == "410", xml["status_message"] == expected else {
            throw HostControlError(code: Int(xml["status_code"] ?? "") ?? response.statusCode,
                                   message: xml["status_message"] ?? "Host action was not confirmed.")
        }
        return expected
    }
}
