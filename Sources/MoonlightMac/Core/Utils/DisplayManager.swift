import AppKit
import CoreGraphics

@MainActor
public enum DisplayManager {
    /// Returns the native physical resolution of the display the app is currently on when streaming starts.
    public static func getNativeResolution(for window: NSWindow? = nil) -> (width: Int, height: Int) {
        let win = window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? WindowManager.shared.currentWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        let screen = win?.screen ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = screen else {
            return (1920, 1080)
        }

        return getNativeResolution(for: screen)
    }

    /// Queries CoreGraphics for the native physical display mode of the specified screen.
    public static func getNativeResolution(for screen: NSScreen) -> (width: Int, height: Int) {
        if let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            if let currentMode = CGDisplayCopyDisplayMode(screenNum) {
                let pixelWidth = currentMode.pixelWidth
                let pixelHeight = currentMode.pixelHeight
                if pixelWidth > 0 && pixelHeight > 0 {
                    // Ensure even dimensions required by video decoders and encoders
                    let w = pixelWidth - (pixelWidth % 2)
                    let h = pixelHeight - (pixelHeight % 2)
                    return (w, h)
                }
            }
        }

        // Fallback to points * backingScaleFactor
        let scale = screen.backingScaleFactor
        let rawW = Int(screen.frame.width * scale)
        let rawH = Int(screen.frame.height * scale)
        let w = rawW - (rawW % 2)
        let h = rawH - (rawH % 2)
        return (w > 0 ? w : 1920, h > 0 ? h : 1080)
    }
}
