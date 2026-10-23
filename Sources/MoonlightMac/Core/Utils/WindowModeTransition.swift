/// Serialize native fullscreen transitions. A new request replaces the pending
/// destination; it never toggles a window while AppKit is still animating it.
struct WindowModeTransition {
    var requested: WindowMode?
    var originalWasNativeFullscreen: Bool
    var inFlight = false

    enum Action: Equatable {
        case wait, enterNative, exitNative, nativeReady, windowed, borderless, restore
    }

    func action(isNativeFullscreen: Bool) -> Action {
        guard !inFlight else { return .wait }
        let wantsNative = requested.map { $0 == .fullscreenDesktop } ?? originalWasNativeFullscreen
        if wantsNative != isNativeFullscreen { return wantsNative ? .enterNative : .exitNative }
        switch requested {
        case .fullscreenDesktop: return .nativeReady
        case .fullscreen: return .borderless
        case .windowed: return .windowed
        case nil: return .restore
        }
    }
}
