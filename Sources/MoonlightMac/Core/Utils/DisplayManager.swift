import AppKit
import CoreGraphics

@MainActor
public enum DisplayManager {
    /// Returns the native physical/safe-area resolution of the display the app or window is currently on,
    /// matching moonlight-qt commit 3c2d163981ef3b97d856c724421ff4b6bcb9724d (StreamUtils::getNativeDesktopMode).
    public static func getNativeResolution(for window: NSWindow? = nil) -> (width: Int, height: Int) {
        let win = window ?? NSApp?.keyWindow ?? NSApp?.mainWindow ?? WindowManager.shared.currentWindow ?? NSApp?.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        let screen = win?.screen ?? NSScreen.main ?? NSScreen.screens.first

        return getNativeResolution(for: screen)
    }

    /// Queries CoreGraphics for the native physical display mode and safe area (notch-aware) of the specified screen,
    /// matching moonlight-qt (StreamUtils::getNativeDesktopMode).
    public static func getNativeResolution(for screen: NSScreen?) -> (width: Int, height: Int) {
        let maxDisplays: UInt32 = 16
        var displayCount: UInt32 = 0
        var displayIds = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        CGGetActiveDisplayList(maxDisplays, &displayIds, &displayCount)

        guard displayCount > 0 else {
            return (1920, 1080)
        }

        var displayIndex = 0
        if let targetScreen = screen,
           let screenNum = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            for i in 0..<Int(displayCount) {
                if displayIds[i] == screenNum {
                    displayIndex = i
                    break
                }
            }
        }

        guard displayIndex < Int(displayCount) else {
            return (1920, 1080)
        }

        let displayID = displayIds[displayIndex]

        // Retina displays have non-native resolutions both below and above their
        // native resolution. CoreGraphics flags the true native mode with kDisplayModeNativeFlag.
        guard let modeList = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return fallbackResolution(for: screen)
        }

        let kDisplayModeNativeFlag: UInt32 = 0x02000000
        var nativeW = 0
        var nativeH = 0

        for mode in modeList {
            if (mode.ioFlags & kDisplayModeNativeFlag) != 0 {
                nativeW = mode.width
                nativeH = mode.height
                break
            }
        }

        var safeAreaW = nativeW
        var safeAreaH = nativeH

        #if arch(arm64)
        // On Apple Silicon built-in displays with a camera notch, look for a mode
        // that matches along the width but not the height to avoid rendering under the notch.
        if CGDisplayIsBuiltin(displayID) != 0 {
            for mode in modeList {
                let cgModeWidth = mode.width
                let cgModeHeight = mode.height

                // If the modes differ by more than 100, we'll assume it's not a notch mode
                if nativeW == cgModeWidth && nativeH != cgModeHeight && nativeH <= cgModeHeight + 100 {
                    safeAreaW = cgModeWidth
                    safeAreaH = cgModeHeight
                }
            }
        }
        #endif

        if safeAreaW > 0 && safeAreaH > 0 {
            let w = safeAreaW - (safeAreaW % 2)
            let h = safeAreaH - (safeAreaH % 2)
            return (w, h)
        }

        return fallbackResolution(for: screen)
    }

    private static func fallbackResolution(for screen: NSScreen?) -> (width: Int, height: Int) {
        if let screen = screen {
            let scale = screen.backingScaleFactor
            let rawW = Int(screen.frame.width * scale)
            let rawH = Int(screen.frame.height * scale)
            let w = rawW - (rawW % 2)
            let h = rawH - (rawH % 2)
            if w > 0 && h > 0 {
                return (w, h)
            }
        }
        return (1920, 1080)
    }
}
