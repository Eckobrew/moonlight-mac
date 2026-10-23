import Foundation
import AppKit

@MainActor
public final class InputCaptureCoordinator: @unchecked Sendable {
    public static let shared = InputCaptureCoordinator()

    private let inputQueue = DispatchQueue(label: "com.moonlight.input", qos: .userInteractive)
    public let keyboardMonitor: KeyboardMonitor
    public let mouseMonitor: MouseMonitor
    public let gameControllerManager = GameControllerManager.shared

    private var systemKeyCaptureMode: SystemKeyCaptureMode = .off
    private var isActive = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        keyboardMonitor = KeyboardMonitor(inputQueue: inputQueue)
        mouseMonitor = MouseMonitor(inputQueue: inputQueue)
    }

    public func startCapturing(
        captureMouse: Bool = true,
        mouseSensitivity: Double = 1.0,
        mouseSensitivityX: Double = 1.0,
        mouseSensitivityY: Double = 1.0,
        mouseSubPixelAccumulation: Bool = true,
        swapWinAltKeys: Bool = true,
        keyboardLayout: KeyboardLayout = .us,
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
        keyboardMonitor.keyboardLayout = keyboardLayout
        keyboardMonitor.onQuitRequested = onQuit
        keyboardMonitor.onToggleMouseCaptureRequested = onToggleMouseCapture
        keyboardMonitor.onToggleFullscreenRequested = onToggleFullscreen
        keyboardMonitor.onToggleStatsOverlayRequested = onToggleStatsOverlay
        keyboardMonitor.onToggleMouseModeRequested = onToggleMouseMode
        keyboardMonitor.onMinimizeRequested = onMinimize
        keyboardMonitor.onPasteRequested = onPaste
        keyboardMonitor.start()

        mouseMonitor.sensitivity = mouseSensitivity
        mouseMonitor.sensitivityX = mouseSensitivityX
        mouseMonitor.sensitivityY = mouseSensitivityY
        mouseMonitor.useSubPixelAccumulation = mouseSubPixelAccumulation
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
            mouseMonitor.isRelativeCaptureActive &&
            NSApp.isActive &&
            (NSApp.keyWindow != nil)

        if shouldGrab && systemKeyCaptureMode == .fullscreenOnly {
            shouldGrab = isStreamWindowFullscreen()
        }

        KeyboardGrab.shared.setGrabbed(shouldGrab)
    }

    /// Whether the *stream* window is currently covering the display.
    ///
    /// Checked against the window itself rather than the configured window mode: the previous
    /// implementation returned true whenever `currentMode` was `.fullscreen`/`.fullscreenDesktop`
    /// (the default), so "In fullscreen" behaved exactly like "Always" even in a windowed stream.
    private func isStreamWindowFullscreen() -> Bool {
        guard let window = WindowManager.shared.currentWindow ?? NSApp.keyWindow else { return false }

        // Native macOS fullscreen Space.
        if window.styleMask.contains(.fullScreen) {
            return true
        }

        // Borderless "Fullscreen" mode covers the display without using a fullscreen Space.
        if window.styleMask == .borderless, let screen = window.screen {
            return window.frame.equalTo(screen.frame)
        }

        return false
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
            // Fullscreen transitions post these notifications before AppKit finishes updating the
            // window's style mask and frame, so evaluating synchronously would read stale state.
            let isFullscreenTransition = (name == NSWindow.didEnterFullScreenNotification ||
                                          name == NSWindow.didExitFullScreenNotification)
            let obs = NotificationCenter.default.addObserver(forName: name, object: nil, queue: OperationQueue.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    if isResign {
                        // Never hold the grab while another app is focused
                        KeyboardGrab.shared.setGrabbed(false)
                        self.keyboardMonitor.raiseAllKeys()
                    }
                    if isFullscreenTransition {
                        DispatchQueue.main.async { self.updateKeyboardGrabState() }
                    } else {
                        self.updateKeyboardGrabState()
                    }
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
