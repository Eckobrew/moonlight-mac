import Testing
@testable import MoonlightMac

@Test func fullscreenRequestsWaitForAppKitCompletion() {
    var state = WindowModeTransition(requested: .fullscreenDesktop, originalWasNativeFullscreen: false)
    #expect(state.action(isNativeFullscreen: false) == .enterNative)
    state.inFlight = true
    #expect(state.action(isNativeFullscreen: false) == .wait)
    // A user exits while entry is animating: wait, then exit exactly once.
    state.requested = .windowed
    #expect(state.action(isNativeFullscreen: true) == .wait)
    state.inFlight = false
    #expect(state.action(isNativeFullscreen: true) == .exitNative)
    #expect(state.action(isNativeFullscreen: false) == .windowed)
}

@Test func disconnectDuringFullscreenEntryRestoresOriginalWindow() {
    var state = WindowModeTransition(requested: .fullscreenDesktop, originalWasNativeFullscreen: false, inFlight: true)
    state.requested = nil
    #expect(state.action(isNativeFullscreen: false) == .wait)
    state.inFlight = false
    #expect(state.action(isNativeFullscreen: true) == .exitNative)
    #expect(state.action(isNativeFullscreen: false) == .restore)
}

@Test func borderlessWaitsForNativeFullscreenExitAndPreexistingFullscreenIsPreserved() {
    var state = WindowModeTransition(requested: .fullscreen, originalWasNativeFullscreen: false)
    #expect(state.action(isNativeFullscreen: true) == .exitNative)
    #expect(state.action(isNativeFullscreen: false) == .borderless)
    state = WindowModeTransition(requested: nil, originalWasNativeFullscreen: true)
    #expect(state.action(isNativeFullscreen: false) == .enterNative)
    #expect(state.action(isNativeFullscreen: true) == .restore)
}
