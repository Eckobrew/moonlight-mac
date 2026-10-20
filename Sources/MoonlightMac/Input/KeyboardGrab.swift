import Foundation
import AppKit
import Darwin

/// System keyboard shortcut capture, implemented the same way moonlight-qt does it.
///
/// moonlight-qt calls `SDL_SetWindowKeyboardGrab()`, which on macOS (SDL `Cocoa_SetWindowKeyboardGrab`)
/// calls the CoreGraphics Services function `CGSSetGlobalHotKeyOperatingMode` to disable global
/// hotkeys (⌘Tab, ⌘Space, Mission Control, Spaces, etc). The key presses are then delivered to the app
/// as ordinary NSEvents, where `KeyboardMonitor` forwards them to the host.
///
/// No event tap and no Accessibility permission are required.
@MainActor
public final class KeyboardGrab {
    public static let shared = KeyboardGrab()

    private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
    private typealias CGSSetGlobalHotKeyOperatingModeFn = @convention(c) (Int32, Int32) -> Int32

    // CGSGlobalHotKeyOperatingMode values
    private let kCGSGlobalHotKeyEnable: Int32 = 0
    private let kCGSGlobalHotKeyDisable: Int32 = 1

    private let mainConnectionID: CGSMainConnectionIDFn?
    private let setOperatingMode: CGSSetGlobalHotKeyOperatingModeFn?

    public private(set) var isGrabbed = false

    private init() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        if let sym = dlsym(handle, "CGSMainConnectionID") {
            mainConnectionID = unsafeBitCast(sym, to: CGSMainConnectionIDFn.self)
        } else {
            mainConnectionID = nil
        }
        if let sym = dlsym(handle, "CGSSetGlobalHotKeyOperatingMode") {
            setOperatingMode = unsafeBitCast(sym, to: CGSSetGlobalHotKeyOperatingModeFn.self)
        } else {
            setOperatingMode = nil
        }
        if mainConnectionID == nil || setOperatingMode == nil {
            AppLogger.shared.warning("[keyboard] CGSSetGlobalHotKeyOperatingMode unavailable; system shortcuts cannot be captured", category: "Input")
        }
    }

    public func setGrabbed(_ grabbed: Bool) {
        guard grabbed != isGrabbed else { return }
        guard let connID = mainConnectionID?(), let setMode = setOperatingMode else { return }

        let result = setMode(connID, grabbed ? kCGSGlobalHotKeyDisable : kCGSGlobalHotKeyEnable)
        isGrabbed = grabbed
        AppLogger.shared.info("[keyboard] global hotkeys \(grabbed ? "disabled (grabbed)" : "restored") result=\(result)", category: "Input")
    }
}
