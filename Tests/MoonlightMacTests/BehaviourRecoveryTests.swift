import Foundation
import Testing
@testable import MoonlightMac

@Test func shortcutIdentitiesSeparateHostsAndSurviveRediscovery() {
    var host = Host(name: "PC", address: "192.168.1.2", serverId: "stable-id")
    let first = ShortcutBundleStore.identifier(host: host, appID: 7)
    host.address = "192.168.1.9"
    host.id = UUID()
    #expect(ShortcutBundleStore.identifier(host: host, appID: 7) == first)
    #expect(ShortcutBundleStore.identifier(host: host, appID: 8) != first)
    host.serverId = "other-pc"
    #expect(ShortcutBundleStore.identifier(host: host, appID: 7) != first)
    let filename = ShortcutBundleStore.filename(title: "../../Game/Bad", hostName: "PC", identifier: first)
    #expect(!filename.contains("/"))
}

@Test func shortcutInstallPreservesUnrelatedAppsAndReplacesOwnedBundleAtomically() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let destination = root.appendingPathComponent("Game.app")
    let staged = root.appendingPathComponent("Staged.app")
    func bundle(_ url: URL, id: String, content: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(content.utf8).write(to: url.appendingPathComponent("payload"))
    }
    try bundle(destination, id: "unrelated", content: "original")
    try bundle(staged, id: "owned", content: "new")
    #expect(throws: (any Error).self) {
        try ShortcutBundleStore.install(staged: staged, destination: destination, identifier: "owned")
    }
    #expect(try String(contentsOf: destination.appendingPathComponent("payload"), encoding: .utf8) == "original")
    try fm.removeItem(at: destination)
    try ShortcutBundleStore.install(staged: staged, destination: destination, identifier: "owned")
    try bundle(staged, id: "owned", content: "replacement")
    try ShortcutBundleStore.install(staged: staged, destination: destination, identifier: "owned")
    #expect(try String(contentsOf: destination.appendingPathComponent("payload"), encoding: .utf8) == "replacement")
    // Missing/incomplete staging must not remove the existing working shortcut.
    #expect(throws: (any Error).self) {
        try ShortcutBundleStore.install(staged: staged, destination: destination, identifier: "owned")
    }
    #expect(try String(contentsOf: destination.appendingPathComponent("payload"), encoding: .utf8) == "replacement")
}

@Test func shortcutInstallDoesNotFollowDestinationSymlinks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent("Original.app")
    let staged = root.appendingPathComponent("Staged.app")
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "owned"], format: .xml, options: 0)
    for url in [target, staged] {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    let link = root.appendingPathComponent("Game.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) {
        try ShortcutBundleStore.install(staged: staged, destination: link, identifier: "owned")
    }
    #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(fm.fileExists(atPath: target.path))
}

@Test func motionRequestsRespectControllerSensorRateAndDisable() {
    var state = ControllerMotionRequests()
    state.update(slot: 0, category: 1, hz: 10)
    state.update(slot: 0, category: 2, hz: 100)
    state.update(slot: 1, category: 2, hz: 20)
    #expect({ state.shouldSend(slot: 0, category: 1, now: 0, value: SIMD3(1, 0, 0)) }())
    #expect({ state.shouldSend(slot: 0, category: 2, now: 0, value: SIMD3(1, 0, 0)) }())
    #expect(!{ state.shouldSend(slot: 0, category: 1, now: 0.02, value: SIMD3(2, 0, 0)) }())
    #expect({ state.shouldSend(slot: 0, category: 2, now: 0.02, value: SIMD3(2, 0, 0)) }())
    #expect(!{ state.shouldSend(slot: 1, category: 1, now: 0, value: SIMD3(1, 0, 0)) }())
    state.update(slot: 0, category: 2, hz: 0)
    #expect(!{ state.shouldSend(slot: 0, category: 2, now: 1, value: SIMD3(3, 0, 0)) }())
    #expect({ state.shouldSend(slot: 1, category: 2, now: 1, value: SIMD3(3, 0, 0)) }())
    state.reset()
    #expect(!{ state.shouldSend(slot: 1, category: 2, now: 2, value: SIMD3(4, 0, 0)) }())
}

@Test func clipboardRecoversAfterTransientFailuresAndOnlyDisablesUnsupportedEndpoints() {
    var retry = ClipboardRetryState()
    for attempt in 0..<10 {
        let now = Double(attempt) * 100
        retry.failed(URLError(.timedOut), at: now)
        #expect(!retry.canAttempt(at: now))
        #expect(retry.canAttempt(at: now + 30))
    }
    retry.succeeded()
    #expect(retry.canAttempt(at: 0))
    retry.failed(NSError(domain: "SunshineHTTPClient", code: 404), at: 0)
    #expect(!retry.canAttempt(at: 1000))
    retry.succeeded()
    retry.failed(NSError(domain: "Other", code: 404), at: 0)
    #expect(retry.canAttempt(at: 30))
}

private actor ShutdownProbe {
    var cancelled = false
    func markCancelled() { cancelled = true }
}

@Test func shutdownDeadlineCancelsOutstandingWork() async {
    let probe = ShutdownProbe()
    let start = ContinuousClock.now
    await HostAppShutdown.run(timeout: .milliseconds(20)) {
        do { try await Task.sleep(for: .seconds(60)) }
        catch { await probe.markCancelled() }
    }
    #expect(await probe.cancelled)
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test func shutdownDoesNotWaitForDeadlineWhenRequestCompletes() async {
    let start = ContinuousClock.now
    await HostAppShutdown.run(timeout: .seconds(60)) {}
    #expect(start.duration(to: .now) < .seconds(1))
}
