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
    var host = try await HostWakeConnection.resolve(host: saved, onWaking: {})
    if ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_WAN"] == "1" {
        let discovered = await Task.detached { NetworkReachability.queryClientExternalAddress() }.value
        let address = try #require(
            ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_WAN_ADDRESS"] ?? discovered,
            "Could not discover the gateway WAN address; set MOONLIGHT_LIVE_WAN_ADDRESS explicitly")
        try #require(NetworkReachability.isUsableRemoteAddress(address))
        try #require(!NetworkReachability.isLocalNetworkAddress(address))
        // Deliberately make the primary unreachable. All authenticated traffic,
        // including stream startup, must use the public address as its fallback.
        var fallback = host
        fallback.address = "127.0.0.2"
        fallback.activeAddress = nil
        fallback.remoteAddress = address
        host = try await SunshineHTTPClient.shared.fetchServerInfo(host: fallback).0
        try #require(host.effectiveAddress == address)
        let isRemote = await NetworkReachability.isRemoteSession(host: host)
        try #require(!isRemote, "A shared-gateway hairpin connection must remain local")
        print("LIVE WAN: public-address fallback authenticated; hairpin correctly classified local")
    }
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

/// Read-only remote endpoint diagnostic; never wakes, sleeps or launches an app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOONLIGHT_REMOTE_DIAGNOSTIC"] != nil))
func liveRemoteAddressDiscoveryDiagnostic() async throws {
    let name = try #require(ProcessInfo.processInfo.environment["MOONLIGHT_REMOTE_DIAGNOSTIC"])
    let data = try #require(UserDefaults.sharedApp.data(forKey: "com.moonlight.mac.savedHosts"))
    let saved = try #require(JSONDecoder().decode([MoonlightMac.Host].self, from: data).first { $0.name == name })
    let client = SunshineHTTPClient.shared
    let reachable = try await HostWakeConnection.resolve(host: saved) { print("REMOTE DIAGNOSTIC: waking \(name)") }
    let (updated, metadata) = try await client.fetchServerInfo(host: reachable, forceRemoteVerification: true)
    print("REMOTE DIAGNOSTIC: \(updated.remoteAddressVerification ?? "no check")")
    print("REMOTE DIAGNOSTIC: reported IP=\(metadata["ExternalIP"] ?? "none"), HTTP=\(metadata["ExternalPort"] ?? "none"), HTTPS=\(metadata["HttpsPort"] ?? "none")")
    let apps = try await client.fetchAppList(host: updated)
    print("HOST EXTENSIONS: virtual display=\(updated.capabilities?.virtualDisplayCapable == true), metrics version=\(updated.capabilities?.hardwareMetricsVersion ?? 0), sleep allowed=\(updated.capabilities?.sleepAvailable == true), commands=\(updated.capabilities?.commands.count ?? 0), monitor tile=\(apps.contains { $0.isRemoteMonitor })")
    let discovered = await Task.detached { NetworkReachability.queryClientExternalAddress() }.value
    if let address = discovered {
        let tls = await client.verifyRemoteEndpoint(address: address, httpsPort: saved.httpsPort, host: saved)
        let both = await client.verifyRemoteEndpoint(address: address, httpsPort: saved.httpsPort, httpPort: saved.httpPort, host: saved)
        print("REMOTE DIAGNOSTIC: STUN IP=\(address), pinned HTTPS verified=\(tls), HTTPS + HTTP verified=\(both)")
    }
}

/// Creates only a temporary monitor owned by this client. Never launches/quits
/// a game, executes a server command, sleeps the host or changes pairing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_MONITOR"] == "1"))
@MainActor func liveRemoteMonitorDeliversFramesAndChangesBitrate() async throws {
    let name = ProcessInfo.processInfo.environment["MOONLIGHT_LIVE_HOST"] ?? "Nathan-PC"
    let data = try #require(UserDefaults.sharedApp.data(forKey: "com.moonlight.mac.savedHosts"))
    let saved = try #require(JSONDecoder().decode([MoonlightMac.Host].self, from: data).first { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    let client = SunshineHTTPClient.shared
    let host = try await HostWakeConnection.resolve(host: saved) { print("LIVE MONITOR: waking \(name)") }
    let catalogue = try await client.fetchAppList(host: host)
    try #require(!catalogue.contains { $0.control == .disconnectMonitor || $0.control == .disconnectInput }, "This client already owns a remote role; preserve it")
    let monitor = try #require(catalogue.first { $0.isRemoteMonitor }, "Host does not advertise Remote Monitor")
    _ = NSApplication.shared
    let controller = StreamSessionController.shared
    controller.isShortcutMode = false
    func cleanup() async {
        controller.stopSession()
        await controller.waitForConnectionStop()
        if let apps = try? await client.fetchAppList(host: host), let release = apps.first(where: { $0.control == .disconnectMonitor }) {
            _ = try? await client.performHostAction(host: host, app: release)
        }
    }
    do {
        var settings = StreamSettings()
        settings.width = 1920; settings.height = 1080; settings.fps = 60; settings.bitrateMbps = 20
        settings.windowMode = .windowed
        settings.quitAppOnStop = true // This must never make a monitor send /cancel.
        await controller.startSession(host: host, app: monitor, settings: settings)
        controller.showPerformanceOverlay = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while controller.sessionError == nil && ContinuousClock.now < deadline && controller.metrics.totalFramesReceived < 60 {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(controller.sessionError == nil, "\(controller.sessionError ?? "")")
        try #require(controller.metrics.totalFramesReceived >= 60, "Monitor did not deliver decoded frames")
        #expect(controller.isRemoteMonitorSession)
        #expect(!controller.shouldQuitHostAppOnStop)
        print("LIVE MONITOR: decoded \(controller.metrics.totalFramesReceived) frames")
        let probeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !controller.runtimeBitrateSupported && ContinuousClock.now < probeDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(controller.runtimeBitrateSupported, "Host did not advertise runtime bitrate")
        await controller.applyRuntimeBitrate(mbps: 15)
        try #require(controller.runtimeBitrateKbps > 0 && controller.runtimeBitrateKbps <= 15000)
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.metrics.bitrateMbps == Double(controller.runtimeBitrateKbps) / 1000)
        print("LIVE MONITOR: host applied bitrate \(controller.runtimeBitrateKbps) Kbps; statistics show \(controller.metrics.bitrateMbps) Mbps")
        await controller.disconnectRemoteMonitor()
        #expect(!controller.isStreaming)
        let after = try await client.fetchAppList(host: host)
        #expect(!after.contains { $0.control == .disconnectMonitor })
        print("LIVE MONITOR: released the temporary monitor without /cancel")
    } catch {
        await cleanup()
        throw error
    }
    await cleanup()
}
