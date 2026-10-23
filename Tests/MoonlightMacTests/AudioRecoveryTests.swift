import AudioToolbox
import Foundation
import Testing
@testable import MoonlightMac

private final class FakeAudioOutput: AudioOutputBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var muted = false
    private var startCount = 0
    private var disposed = false
    private var failures = 0
    private var uid: String?
    private var callback: (@Sendable () -> Void)?
    private var startWasMuted: [Bool] = []
    var startEntered: DispatchSemaphore?
    var allowStart: DispatchSemaphore?

    var isRunning: Bool { lock.withLock { running } }
    var isMuted: Bool { lock.withLock { muted } }
    var starts: Int { lock.withLock { startCount } }
    var startsMuted: [Bool] { lock.withLock { startWasMuted } }
    var isDisposed: Bool { lock.withLock { disposed } }
    func failNextStarts(_ count: Int) { lock.withLock { failures = count } }
    func setCallback(_ change: @escaping @Sendable () -> Void) { lock.withLock { callback = change } }
    func notify() { lock.withLock { callback }?() }
    func selectDevice(uid: String?) throws {
        lock.withLock {
            if self.uid != uid { running = false; self.uid = uid }
        }
    }
    func setMuted(_ muted: Bool) { lock.withLock { self.muted = muted } }
    func start() throws {
        startEntered?.signal()
        allowStart?.wait()
        try lock.withLock {
            startCount += 1
            startWasMuted.append(muted)
            if failures > 0 {
                failures -= 1
                throw NSError(domain: "FakeAudio", code: 1)
            }
            running = true
        }
    }
    func stop() { lock.withLock { running = false } }
    func dispose() { lock.withLock { running = false; disposed = true } }
}

@Test func backgroundMuteSurvivesSetupAndEngineReplacement() {
    let control = AudioPlaybackControl()
    defer { control.cleanup() }
    control.configure(deviceUID: nil, muteOnFocusLoss: true, appFocused: false)
    let first = FakeAudioOutput()
    #expect(control.install { change in first.setCallback(change); return first })
    control.start()
    #expect(first.startsMuted == [true])
    control.cleanup()
    let second = FakeAudioOutput()
    #expect(control.install { change in second.setCallback(change); return second })
    control.start()
    #expect(second.startsMuted == [true])
    control.updateFocus(true)
    control.synchronize()
    #expect(!second.isMuted)
    control.updateFocus(false)
    control.synchronize()
    #expect(second.isMuted)
}

@Test func outputRestartFailureRetriesWithoutStreamReconnect() async throws {
    let control = AudioPlaybackControl()
    defer { control.cleanup() }
    let output = FakeAudioOutput()
    #expect(control.install { change in output.setCallback(change); return output })
    control.start()
    output.failNextStarts(1)
    control.configure(deviceUID: "new-device", muteOnFocusLoss: true, appFocused: false)
    control.applyOutputDevice()
    control.synchronize()
    #expect(!output.isRunning)
    for _ in 0..<100 {
        if output.isRunning { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(output.isRunning)
    #expect(output.starts == 3)
    #expect(output.startsMuted.suffix(2) == [true, true])
}

@Test func stoppedAudioCancelsPendingRecovery() async throws {
    let control = AudioPlaybackControl()
    defer { control.cleanup() }
    let output = FakeAudioOutput()
    output.failNextStarts(1)
    #expect(control.install { change in output.setCallback(change); return output })
    control.start()
    control.stop()
    output.notify()
    try await Task.sleep(for: .milliseconds(250))
    control.synchronize()
    #expect(output.starts == 1)
    #expect(!output.isRunning)
}

@Test func oldConfigurationCallbacksCannotRestartReplacedOutput() {
    let control = AudioPlaybackControl()
    defer { control.cleanup() }
    let old = FakeAudioOutput()
    #expect(control.install { change in old.setCallback(change); return old })
    control.start()
    let replacement = FakeAudioOutput()
    #expect(control.install { change in replacement.setCallback(change); return replacement })
    control.start()
    old.notify()
    control.synchronize()
    #expect(old.isDisposed)
    #expect(!old.isRunning)
    #expect(old.starts == 1)
    #expect(replacement.starts == 1)
}

@Test func teardownWaitsForInFlightDeviceOperationThenDisposesOutput() throws {
    let control = AudioPlaybackControl()
    let output = FakeAudioOutput()
    #expect(control.install { change in output.setCallback(change); return output })
    control.start()
    let entered = DispatchSemaphore(value: 0)
    let allow = DispatchSemaphore(value: 0)
    output.startEntered = entered
    output.allowStart = allow
    control.configure(deviceUID: "new-device", muteOnFocusLoss: false, appFocused: true)
    control.applyOutputDevice()
    #expect(entered.wait(timeout: .now() + 2) == .success)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { control.cleanup(); done.signal() }
    #expect(done.wait(timeout: .now() + 0.02) == .timedOut)
    allow.signal()
    #expect(done.wait(timeout: .now() + 2) == .success)
    output.notify()
    control.synchronize()
    #expect(output.isDisposed)
    #expect(!output.isRunning)
    #expect(output.starts == 2)
}

@Test func streamChannelLayoutsMatchCanonicalSamples() throws {
    #expect(StreamAudioLayout.tag(channels: 2) == kAudioChannelLayoutTag_Stereo)
    #expect(StreamAudioLayout.tag(channels: 6) == kAudioChannelLayoutTag_MPEG_5_1_A)
    // Ask CoreAudio to expand the tag and check actual speaker labels, rather
    // than testing only that the implementation returns a chosen constant.
    var tag = try #require(StreamAudioLayout.tag(channels: 8))
    var size: UInt32 = 0
    #expect(AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                     UInt32(MemoryLayout.size(ofValue: tag)), &tag, &size) == noErr)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { memory.deallocate() }
    #expect(AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                 UInt32(MemoryLayout.size(ofValue: tag)), &tag, &size, memory) == noErr)
    let layout = memory.assumingMemoryBound(to: AudioChannelLayout.self)
    #expect(layout.pointee.mNumberChannelDescriptions == 8)
    let labels = withUnsafePointer(to: &layout.pointee.mChannelDescriptions) {
        $0.withMemoryRebound(to: AudioChannelDescription.self, capacity: 8) { ptr in
            (0..<8).map { ptr[$0].mChannelLabel }
        }
    }
    #expect(labels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                       kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
                       kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftSurround,
                       kAudioChannelLabel_RightSurround])
}
