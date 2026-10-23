import Testing
@testable import MoonlightMac

@Test func fullscreenStartupAndBannerFocusCanRecover() {
    var state = StreamMouseFocus(windowKey: false)
    #expect(state.action == .restoreKeyWindow)
    state.windowKey = true
    #expect(state.action == .capture)
    state.windowKey = false // Temporary system interruption, app still active.
    #expect(state.action == .restoreKeyWindow)
    state.windowKey = true
    #expect(state.action == .capture)
}

@Test func recoveryDoesNotOverrideUserFocusOrReleasedCapture() {
    let base = StreamMouseFocus(windowKey: false)
    var states = [StreamMouseFocus]()
    var state = base; state.appActive = false; states.append(state)
    state = base; state.otherKeyWindow = true; states.append(state)
    state = base; state.onActiveSpace = false; states.append(state)
    state = base; state.blockedByDialog = true; states.append(state)
    state = base; state.minimized = true; states.append(state)
    state = base; state.visible = false; states.append(state)
    state = base; state.requested = false; states.append(state)
    for state in states { #expect(state.action == .release) }
}

@Test func unitMouseSensitivityMatchesSDLCocoaTruncation() {
    var motion = RelativeMouseMotion()
    for _ in 0..<10 {
        let delta = motion.consume(x: 1.9, y: -1.9, scaleX: 1, scaleY: 1, accumulateSensitivity: true)
        #expect(delta.x == 1)
        #expect(delta.y == -1)
    }
    let micro = motion.consume(x: 0.9, y: -0.9, scaleX: 1, scaleY: 1, accumulateSensitivity: true)
    #expect(micro.x == 0 && micro.y == 0)
}

@Test func customSensitivityKeepsFractionsAndResetClearsThem() {
    var motion = RelativeMouseMotion()
    let first = motion.consume(x: 1, y: -1, scaleX: 0.5, scaleY: 0.5, accumulateSensitivity: true)
    #expect(first.x == 0 && first.y == 0)
    let second = motion.consume(x: 1, y: -1, scaleX: 0.5, scaleY: 0.5, accumulateSensitivity: true)
    #expect(second.x == 1 && second.y == -1)
    _ = motion.consume(x: 1, y: 1, scaleX: 0.5, scaleY: 0.5, accumulateSensitivity: true)
    motion.reset()
    let reset = motion.consume(x: 1, y: 1, scaleX: 0.5, scaleY: 0.5, accumulateSensitivity: true)
    #expect(reset.x == 0 && reset.y == 0)
    let unaccumulated = motion.consume(x: -1.9, y: 1.9, scaleX: 0.5, scaleY: 0.5, accumulateSensitivity: false)
    #expect(unaccumulated.x == 0 && unaccumulated.y == 0)
}

@Test func scrollingMatchesSDLCocoaAxesTicksAndClamp() {
    let precise = MouseWheelMotion.consume(x: 0.125, y: -0.125, precise: true)
    #expect(precise.x == -15 && precise.y == -15)
    let discrete = MouseWheelMotion.consume(x: -0.125, y: 0.125, precise: false)
    #expect(discrete.x == 120 && discrete.y == 120)
    let accelerated = MouseWheelMotion.consume(x: 10, y: -10, precise: true)
    #expect(accelerated.x == -120 && accelerated.y == -120)
}
