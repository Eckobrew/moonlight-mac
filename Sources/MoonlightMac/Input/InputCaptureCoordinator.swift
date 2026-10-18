import Foundation
import AppKit

public final class InputCaptureCoordinator: @unchecked Sendable {
    public static let shared = InputCaptureCoordinator()

    public let keyboardMonitor = KeyboardMonitor()
    public let mouseMonitor = MouseMonitor()
    public let gameControllerManager = GameControllerManager.shared

    private init() {}

    public func startCapturing(
        captureMouse: Bool = true,
        mouseSensitivity: Double = 1.0,
        swapCommandControl: Bool = false,
        onQuit: @escaping @Sendable () -> Void,
        onToggleMouseCapture: (@Sendable () -> Void)? = nil,
        onToggleFullscreen: (@Sendable () -> Void)? = nil,
        onToggleStatsOverlay: (@Sendable () -> Void)? = nil,
        onToggleMouseMode: (@Sendable () -> Void)? = nil,
        onMinimize: (@Sendable () -> Void)? = nil,
        onPaste: (@Sendable () -> Void)? = nil
    ) {
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
        mouseMonitor.start()
        mouseMonitor.isCaptured = captureMouse

        gameControllerManager.start()
    }

    public func stopCapturing() {
        mouseMonitor.isCaptured = false
        mouseMonitor.stop()
        keyboardMonitor.stop()
        gameControllerManager.stop()
    }

    public func toggleMouseCapture() {
        mouseMonitor.isCaptured.toggle()
    }
}
