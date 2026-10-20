import Foundation
import AppKit

@MainActor
public final class InputCaptureCoordinator: @unchecked Sendable {
    public static let shared = InputCaptureCoordinator()

    public let keyboardMonitor = KeyboardMonitor()
    public let mouseMonitor = MouseMonitor()
    public let gameControllerManager = GameControllerManager.shared

    private var systemKeyCaptureMode: SystemKeyCaptureMode = .off
    private var isActive = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    public func startCapturing(
        captureMouse: Bool = true,
        mouseSensitivity: Double = 1.0,
        swapWinAltKeys: Bool = true,
        swapCommandControl: Bool = false,
        systemKeyCaptureMode: SystemKeyCaptureMode = .off,
        onQuit: @escaping @Sendable () -> Void,
        onToggleMouseCapture: (@Sendable () -> Void)? = nil,
        onToggleFullscreen: (@Sendable () -> Void)? = nil,
        onToggleStatsOverlay: (@Sendable () -> Void)? = nil,
        onToggleMouseMode: (@Sendable () -> Void)? = nil,
        onMinimize: (@Sendable () -> Void)? = nil,
        onPaste: (@Sendable () -> Void)? = nil
    ) {
        isActive = true
        self.systemKeyCaptureMode = systemKeyCaptureMode

        keyboardMonitor.swapWinAltKeys = swapWinAltKeys
        keyboardMonitor.swapCommandControl = swapCommandControl
        keyboardMonitor.onQuitRequested = onQuit
        keyboardMonitor.onToggleMouseCaptureRequested = onToggleMouseCapture
        keyboardMonitor.onToggleFullscreenRequested = onToggleFullscreen
        keyboardMonitor.onToggleStatsOverlayRequested = onToggleStatsOverlay
        keyboardMonitor.onToggleMouseModeRequested = onToggleMouseMode
        keyboardMonitor.onMinimizeRequested = onMinimize
        keyboardMonitor.onPasteRequested = onPaste
        keyboardMonitor.start()

        mouseMonitor.sensitivity = mouseSensitivity
        mouseMonitor.onCaptureStateChanged = { [weak self] in
            self?.updateKeyboardGrabState()
        }
        mouseMonitor.start()
        mouseMonitor.isCaptured = captureMouse

        gameControllerManager.start()

        installObservers()
        updateKeyboardGrabState()
    }

    public func stopCapturing() {
        isActive = false
        removeObservers()
        KeyboardGrab.shared.setGrabbed(false)
        keyboardMonitor.raiseAllKeys()

        mouseMonitor.onCaptureStateChanged = nil
        mouseMonitor.isCaptured = false
        mouseMonitor.stop()
        keyboardMonitor.stop()
        gameControllerManager.stop()
    }

    public func toggleMouseCapture() {
        mouseMonitor.isCaptured.toggle()
    }

    /// Mirrors moonlight-qt SdlInputHandler::updateKeyboardGrabState():
    /// grab only while capture is active, the app is focused, and (in fullscreen-only mode) the window is fullscreen.
    public func updateKeyboardGrabState() {
        var shouldGrab = isActive &&
            systemKeyCaptureMode != .off &&
            mouseMonitor.isCaptured &&
            NSApp.isActive &&
            (NSApp.keyWindow != nil)

        if shouldGrab && systemKeyCaptureMode == .fullscreenOnly {
            shouldGrab = isStreamWindowFullscreen()
        }

        KeyboardGrab.shared.setGrabbed(shouldGrab)
    }

    private func isStreamWindowFullscreen() -> Bool {
        if let window = WindowManager.shared.currentWindow ?? NSApp.keyWindow,
           window.styleMask.contains(.fullScreen) {
            return true
        }
        switch WindowManager.shared.currentMode {
        case .fullscreen, .fullscreenDesktop:
            return true
        default:
            return false
        }
    }

    private func installObservers() {
        removeObservers()
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            let isResign = (name == NSApplication.didResignActiveNotification)
            let obs = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    if isResign {
                        // Never hold the grab while another app is focused
                        KeyboardGrab.shared.setGrabbed(false)
                        self.keyboardMonitor.raiseAllKeys()
                    }
                    self.updateKeyboardGrabState()
                }
            }
            observers.append(obs)
        }
    }

    private func removeObservers() {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
    }
}
