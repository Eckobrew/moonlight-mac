import Foundation
import Testing
import MoonlightCommonC
@testable import MoonlightMac

private func extensionHost() -> MoonlightMac.Host {
    MoonlightMac.Host(name: "Fixture", address: "127.0.0.1", serverId: "fixture",
                      isPaired: true, serverCertificateDER: Data([1, 2, 3]))
}
private actor ExtensionRequests {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
private func reply(_ request: URLRequest, status: Int = 200, _ body: String) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

@Test func otpMatchesHostGoldenVectorWithoutSendingPassphrase() {
    let otp = OTPPairing(code: "0412", passphrase: "correct horse")
    #expect(otp.isValid)
    #expect(otp.authentication(saltHex: "00112233445566778899aabbccddeeff") == "ECC2CAF1B739532ACF7EB1DCA1E8FF11338530A65F3CD16CCF639CFB53BF547A")
    #expect(!OTPPairing(code: "４１２０", passphrase: "correct horse").isValid)
    #expect(!OTPPairing(code: "0412", passphrase: "").isValid)
}

@Test func sleepUsesOneUseTokenAndNoLaunchOrExtraArguments() async throws {
    let calls = ExtensionRequests()
    let client = SunshineHTTPClient(uniqueID: { "fixture" }, extensionTransport: { request, _ in
        await calls.record(request)
        if request.url?.path == "/power-actions/v1" {
            #expect(request.httpMethod == "GET")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty != false)
            return reply(request, "<root status_code=\"200\"><PowerActionVersion>1</PowerActionVersion><SleepSupported>1</SleepSupported><SleepAllowed>1</SleepAllowed><SleepAvailable>1</SleepAvailable><SleepToken>a+b/?&amp;</SleepToken></root>")
        }
        #expect(request.url?.path == "/power-actions/v1/sleep")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody?.isEmpty == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.count == 1)
        #expect(query?.first?.name == "token")
        #expect(query?.first?.value == "a+b/?&")
        return reply(request, status: 202, "<root status_code=\"202\"><SleepAccepted>1</SleepAccepted></root>")
    })
    try await client.sleepHost(host: extensionHost())
    #expect(await calls.requests.count == 2)
}

@Test func busySleepNeverPostsAndLostAcknowledgementNeverRetries() async {
    let calls = ExtensionRequests()
    let busy = SunshineHTTPClient(extensionTransport: { request, _ in
        await calls.record(request)
        return reply(request, "<root status_code=\"200\"><PowerActionVersion>1</PowerActionVersion><SleepSupported>1</SleepSupported><SleepAllowed>1</SleepAllowed><SleepAvailable>0</SleepAvailable></root>")
    })
    await #expect(throws: HostControlError.self) { try await busy.sleepHost(host: extensionHost()) }
    #expect(await calls.requests.count == 1)
    let lostCalls = ExtensionRequests()
    let lost = SunshineHTTPClient(extensionTransport: { request, _ in
        await lostCalls.record(request)
        if request.httpMethod == "POST" { throw URLError(.timedOut) }
        return reply(request, "<root status_code=\"200\"><PowerActionVersion>1</PowerActionVersion><SleepSupported>1</SleepSupported><SleepAllowed>1</SleepAllowed><SleepAvailable>1</SleepAvailable><SleepToken>once</SleepToken></root>")
    })
    await #expect(throws: HostControlError.self) { try await lost.sleepHost(host: extensionHost()) }
    #expect(await lostCalls.requests.count == 2)
}

@Test func runtimeBitrateUsesHostAppliedValueAndSeparateABRCapability() async throws {
    let client = SunshineHTTPClient(uniqueID: { "fixture" }, extensionTransport: { request, _ in
        if request.url?.path == "/api/abr/capabilities" {
            return reply(request, #"{"supported":false,"version":1,"features":["runtime_bitrate"]}"#)
        }
        #expect(request.url?.path == "/bitrate")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "bitrate", value: "40000")) == true)
        return reply(request, "<root status_code=\"200\"><bitrate>25000</bitrate></root>")
    })
    #expect(await client.supportsRuntimeBitrate(host: extensionHost()))
    #expect(try await client.setRuntimeBitrate(host: extensionHost(), kbps: 40000) == 25000)
    await #expect(throws: HostControlError.self) { try await client.setRuntimeBitrate(host: extensionHost(), kbps: 0) }
}

@Test func repeatedCommandsPermissionsAndVirtualDisplayRequests() {
    let xml = Data("<root><ServerCommand>First &amp; second</ServerCommand><ServerCommand><![CDATA[Display <toggle>]]></ServerCommand></root>".utf8)
    let names = HostXMLValues.elements("ServerCommand", data: xml)
    #expect(names == ["First & second", "Display <toggle>"])
    let caps = HostCapabilities.parse(["Permission": String((1 << 25) | (1 << 20)), "VirtualDisplayCapable": "true", "VirtualDisplayDriverReady": "0"], commands: names)
    #expect(caps.canView && caps.canRunCommands && !caps.canLaunch)
    #expect(!caps.virtualDisplayReady)
    #expect(HostCapabilities.parse([:], commands: []).canLaunch) // Legacy unknown, not denial.
    var host = extensionHost(); host.capabilities = caps
    var settings = StreamSettings(); settings.features.virtualDisplayMode = .physical
    #expect(HostLaunchOptions.query(settings: settings, host: host).contains("virtualDisplay=0"))
    #expect(!HostLaunchOptions.query(settings: settings).contains("virtualDisplay"))
}

@Test func appCatalogueRetainsUUIDOrderAndRevisionAcrossNumericIDChanges() {
    let host = extensionHost()
    let uuid = "ed713cab-1c4c-4f08-8cb3-961da3210001"
    let xml = Data("<root><App><ID>8</ID><UUID>\(uuid)</UUID><AppTitle>Z game</AppTitle><IDX>0</IDX><ArtVersion>2</ArtVersion></App><App><ID>2</ID><AppTitle>A game</AppTitle><IDX>1</IDX></App></root>".utf8)
    let apps = SunshineHTTPClient(uniqueID: { "fixture" }).parseAppListXML(data: xml, host: host)
    #expect(apps.map(\.title) == ["Z game", "A game"])
    #expect(apps.first?.uuid == uuid)
    #expect(apps.first?.artVersion == "2")
    var changed = apps[0]; changed.id = 21
    #expect(changed.stableIdentity == apps[0].stableIdentity)
    #expect(ShortcutBundleStore.identifier(host: host, app: changed) == ShortcutBundleStore.identifier(host: host, app: apps[0]))
}

@Test @MainActor func stableSettingsMigrateOnceThenFollowUUID() throws {
    let domain = "moonlight-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = PerAppSettingsStore(defaults: defaults, fallback: nil)
    let host = extensionHost()
    var overrides = AppStreamOverrides(); overrides.bitrateMbps = 17
    store.setOverrides(overrides, for: host, appId: 5)
    var app = StreamApp(id: 5, title: "Before"); app.uuid = UUID().uuidString
    #expect(store.overrides(for: host, app: app).bitrateMbps == 17)
    app.id = 50; app.title = "After"
    #expect(store.overrides(for: host, app: app).bitrateMbps == 17)
    var other = StreamApp(id: 5, title: "Different game"); other.uuid = UUID().uuidString
    #expect(store.overrides(for: host, app: other).isEmpty)
}

@Test func telemetryDistinguishesMissingReadingsFromZero() throws {
    let sample = try JSONDecoder().decode(HostHardwareMetrics.self, from: Data(#"{"version":1,"sampled_at_unix_ms":1,"interval_ms":1000,"cpu":{},"gpus":[{"id":-3,"name":"GPU","metrics":{"gpu_usage_percent":0}}]}"#.utf8))
    #expect(sample.cpu.cpu_usage_percent == nil)
    #expect(sample.gpus[0].metrics["gpu_usage_percent"] == 0)
    #expect(sample.gpus[0].metrics["gpu_temperature_c"] == nil)
}

@Test func monitorActionsDoNotCreateVideoOrTreatConfirmationAsSuccess() async throws {
    var action = StreamApp(id: 2147483502, title: "Disconnect Monitor")
    action.uuid = "9a1c5a25-58fe-40e0-b9aa-7d3f00000002"
    #expect(action.isHostAction && action.control == .disconnectMonitor)
    let calls = ExtensionRequests()
    let client = SunshineHTTPClient(uniqueID: { "fixture" }, extensionTransport: { request, _ in
        await calls.record(request)
        #expect(request.url?.path == "/launch")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(where: { $0.name == "appuuid" }))
        #expect(query.contains(where: { $0.name == "rikey" && $0.value?.count == 32 }))
        return reply(request, "<root status_code=\"410\" status_message=\"Remote Monitor disconnected successfully.\"/>")
    })
    #expect(try await client.performHostAction(host: extensionHost(), app: action) == "Remote Monitor disconnected successfully.")
    #expect(await calls.requests.count == 1)
    let confirmation = SunshineHTTPClient(extensionTransport: { request, _ in
        reply(request, "<root status_code=\"410\" status_message=\"Confirm termination before trying again\"/>")
    })
    await #expect(throws: HostControlError.self) { try await confirmation.performHostAction(host: extensionHost(), app: action) }
    #expect(LiSendHostCommand(0) == -2) // No packet can be sent outside the input lifetime.
}

@Test func reservedControlIDWinsOverConflictingUUIDAndRunningIdentityUsesUUID() {
    var conflict = StreamApp(id: 2147483504, title: "Stale label")
    conflict.uuid = "9a1c5a25-58fe-40e0-b9aa-7d3f00000005"
    #expect(conflict.control == .terminate)
    #expect(conflict.isHostAction)
    var host = extensionHost()
    host.currentAppId = 1
    host.currentAppUUID = "ED713CAB-1C4C-4F08-8CB3-961DA3210001"
    var app = StreamApp(id: 99, title: "Renumbered")
    app.uuid = host.currentAppUUID?.lowercased()
    #expect(app.matchesRunning(on: host))
    app.uuid = UUID().uuidString
    app.id = 1
    #expect(!app.matchesRunning(on: host))
}
