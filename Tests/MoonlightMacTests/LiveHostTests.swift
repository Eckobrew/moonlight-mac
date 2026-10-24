import AppKit
import Foundation
import Testing

@testable import MoonlightMac

/// Opt in with MOONLIGHT_LIVE_HOST=<saved host name>. Uses the existing pairing
/// credentials, may wake that PC, and reads its app list without launching a game.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_HOST"] != nil))
@MainActor func liveHostWakeAndAuthenticatedFallback() async throws {
    let name = try #require(ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_HOST"])
    let data = try #require(UserDefaults.sharedApp.data(forKey: "com.moonlight.mac.savedHosts"))
    let hosts = try JSONDecoder().decode([MoonlightMac.Host].self, from: data)
    let saved = try #require(hosts.first { $0.name == name }, "No saved host named \(name)")
    try #require(saved.isSecurelyPaired, "Pair this host in the main app first")
    let host = try await HostWakeConnection.resolve(host: saved) {
        print("LIVE HOST: waking \(name)")
    }
    #expect(host.isOnline)
    let apps = try await SunshineHTTPClient.shared.fetchAppList(host: host)
    #expect(!apps.isEmpty)
    print("LIVE HOST: authenticated and fetched \(apps.count) apps")

    // Force an unreachable primary while preserving the real PC's pin and ID.
    // This verifies address fallback over the live connection; Internet routing
    // and router forwarding still need an actual off-site client.
    var fallback = host
    fallback.address = "127.0.0.2"
    fallback.activeAddress = nil
    fallback.remoteAddress = host.effectiveAddress
    let (resolved, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: fallback)
    #expect(resolved.effectiveAddress == host.effectiveAddress)
    #expect(resolved.serverId == host.serverId)
    let fallbackApps = try await SunshineHTTPClient.shared.fetchAppList(host: resolved)
    #expect(Set(fallbackApps.map(\.id)) == Set(apps.map(\.id)))
    print("LIVE HOST: forced fallback authenticated and fetched the same apps")
}

/// Optional hardware smoke test. Opens the host's Desktop app, receives video,
/// disconnects, and closes that app only if this test launched it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_STREAM"] == "1"))
@MainActor func liveDesktopStreamDeliversFrames() async throws {
    let name = try #require(ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_HOST"])
    let data = try #require(UserDefaults.sharedApp.data(forKey: "com.moonlight.mac.savedHosts"))
    let hosts = try JSONDecoder().decode([MoonlightMac.Host].self, from: data)
    let saved = try #require(hosts.first { $0.name == name })
    let host = try await HostWakeConnection.resolve(host: saved, onWaking: {})
    let apps = try await SunshineHTTPClient.shared.fetchAppList(host: host)
    let desktop = try #require(apps.first { $0.title.caseInsensitiveCompare("Desktop") == .orderedSame })
    try #require(host.currentAppId == nil || host.currentAppId == desktop.id, "Another host app is running")
    _ = NSApplication.shared
    let controller = StreamSessionController.shared
    defer { controller.stopSession() }
    for targetBitrate in [40, 20] {
        var settings = StreamSettings()
        settings.width = 1920
        settings.height = 1080
        settings.fps = 60
        settings.bitrateMbps = targetBitrate
        settings.enableRemoteBitrate = true
        settings.remoteBitrateMbps = 0
        settings.quitAppOnStop = false
        await controller.startSession(host: host, app: desktop, settings: settings)
        controller.showPerformanceOverlay = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while controller.sessionError == nil && ContinuousClock.now < deadline
            && (controller.currentStageName != "Connected" || controller.metrics.totalFramesReceived < 60
                || controller.metrics.bitrateMbps != Double(targetBitrate))
        {
            try await Task.sleep(for: .milliseconds(250))
        }
        let error = controller.sessionError
        let frames = controller.metrics.totalFramesReceived
        let bitrate = controller.metrics.bitrateMbps
        let rtt = controller.metrics.roundTripTimeMs
        controller.stopSession()
        // Allow common-c's asynchronous teardown to release its host connection.
        try await Task.sleep(for: .seconds(2))
        #expect(error == nil, "Stream failed: \(error ?? "")")
        #expect(frames >= 60, "No sustained decoded video: \(frames) frames")
        #expect(bitrate == Double(targetBitrate))
        print("LIVE STREAM: received \(frames) frames; configured \(bitrate) Mbps; RTT \(rtt) ms")
    }
    if host.currentAppId == nil {
        let (current, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
        if current.currentAppId == desktop.id { try await SunshineHTTPClient.shared.quitApp(host: current) }
    }
}
