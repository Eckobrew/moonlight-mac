import AppKit
import CoreGraphics

@MainActor
public enum DisplayManager {
    /// Returns the native physical resolution of the display the app is currently on when streaming starts.
    public static func getNativeResolution(for window: NSWindow? = nil) -> (width: Int, height: Int) {
        let win = window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        let screen = win?.screen ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = screen else {
            return (1920, 1080)
        }

        return getNativeResolution(for: screen)
    }

    /// Queries CoreGraphics for the native physical display mode of the specified screen.
    public static func getNativeResolution(for screen: NSScreen) -> (width: Int, height: Int) {
        let kDisplayModeNativeFlag: UInt32 = 0x02000000

        if let screenNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            if let modeList = CGDisplayCopyAllDisplayModes(screenNum, nil) as? [CGDisplayMode] {
                for mode in modeList {
                    if (mode.ioFlags & kDisplayModeNativeFlag) != 0 {
                        return (mode.pixelWidth, mode.pixelHeight)
                    }
                }
            }
        }

        // Fallback to points * backingScaleFactor
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale)
        let h = Int(screen.frame.height * scale)
        return (w > 0 ? w : 1920, h > 0 ? h : 1080)
    }
}
