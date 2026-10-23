import Foundation

/// Both app termination and stream stop use the same cancellable deadline.
enum HostAppShutdown {
    static func run(timeout: Duration = .seconds(2), operation: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    static func quit(host: Host, expectedAppID: Int? = nil) async {
        await run {
            if let expectedAppID {
                guard let (current, _) = try? await SunshineHTTPClient.shared.fetchServerInfo(host: host),
                      current.currentAppId == expectedAppID, !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            try? await SunshineHTTPClient.shared.quitApp(host: host)
        }
    }
}
