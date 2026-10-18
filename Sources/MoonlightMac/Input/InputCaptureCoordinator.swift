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
        swapCommandControl: Bool = false,
        onEscape: @escaping @Sendable () -> Void
    ) {
        keyboardMonitor.swapCommandControl = swapCommandControl
        keyboardMonitor.onEscapeRequested = onEscape
        keyboardMonitor.start()

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
