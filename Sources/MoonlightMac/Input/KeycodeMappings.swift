import Foundation
import AppKit

public enum KeycodeMappings {
    // Windows Virtual Key codes
    public static let VK_BACK: Int16       = 0x08
    public static let VK_TAB: Int16        = 0x09
    public static let VK_RETURN: Int16     = 0x0D
    // Left/right-specific modifier codes (matches moonlight-qt keyboard.cpp)
    public static let VK_LSHIFT: Int16     = 0xA0
    public static let VK_RSHIFT: Int16     = 0xA1
    public static let VK_LCONTROL: Int16   = 0xA2
    public static let VK_RCONTROL: Int16   = 0xA3
    public static let VK_LMENU: Int16      = 0xA4 // Left Alt
    public static let VK_RMENU: Int16      = 0xA5 // Right Alt
    public static let VK_PAUSE: Int16      = 0x13
    public static let VK_CAPITAL: Int16    = 0x14 // Caps Lock
    public static let VK_ESCAPE: Int16     = 0x1B
    public static let VK_SPACE: Int16      = 0x20
    public static let VK_PRIOR: Int16      = 0x21 // Page Up
    public static let VK_NEXT: Int16       = 0x22 // Page Down
    public static let VK_END: Int16        = 0x23
    public static let VK_HOME: Int16       = 0x24
    public static let VK_LEFT: Int16       = 0x25
    public static let VK_UP: Int16         = 0x26
    public static let VK_RIGHT: Int16      = 0x27
    public static let VK_DOWN: Int16       = 0x28
    public static let VK_INSERT: Int16     = 0x2D
    public static let VK_DELETE: Int16     = 0x2E
    public static let VK_LWIN: Int16       = 0x5B // Left Windows Key (Command)
    public static let VK_RWIN: Int16       = 0x5C // Right Windows Key

    // Standard letters (0x41 = 'A' ... 0x5A = 'Z')
    // Standard digits (0x30 = '0' ... 0x39 = '9')
    // Function keys (0x70 = F1 ... 0x7B = F12)

    public static func macToWindowsVirtualKey(
        macKeyCode: UInt16,
        swapWinAltKeys: Bool = false,
        swapCommandControl: Bool = false
    ) -> Int16 {
        switch macKeyCode {
        case 0x00: return 0x41 // A
        case 0x01: return 0x53 // S
        case 0x02: return 0x44 // D
        case 0x03: return 0x46 // F
        case 0x04: return 0x48 // H
        case 0x05: return 0x47 // G
        case 0x06: return 0x5A // Z
        case 0x07: return 0x58 // X
        case 0x08: return 0x43 // C
        case 0x09: return 0x56 // V
        case 0x0B: return 0x42 // B
        case 0x0C: return 0x51 // Q
        case 0x0D: return 0x57 // W
        case 0x0E: return 0x45 // E
        case 0x0F: return 0x52 // R
        case 0x10: return 0x59 // Y
        case 0x11: return 0x54 // T
        case 0x12: return 0x31 // 1
        case 0x13: return 0x32 // 2
        case 0x14: return 0x33 // 3
        case 0x15: return 0x34 // 4
        case 0x16: return 0x36 // 6
        case 0x17: return 0x35 // 5
        case 0x18: return 0xBB // =
        case 0x19: return 0x39 // 9
        case 0x1A: return 0x37 // 7
        case 0x1B: return 0xBD // -
        case 0x1C: return 0x38 // 8
        case 0x1D: return 0x30 // 0
        case 0x1E: return 0xDD // ]
        case 0x1F: return 0x4F // O
        case 0x20: return 0x55 // U
        case 0x21: return 0xDB // [
        case 0x22: return 0x49 // I
        case 0x23: return 0x50 // P
        case 0x24: return VK_RETURN
        case 0x25: return 0x4C // L
        case 0x26: return 0x4A // J
        case 0x27: return 0xDE // '
        case 0x28: return 0x4B // K
        case 0x29: return 0xBA // ;
        case 0x2A: return 0xDC // \
        case 0x2B: return 0xBC // ,
        case 0x2C: return 0xBF // /
        case 0x2D: return 0x4E // N
        case 0x2E: return 0x4D // M
        case 0x2F: return 0xBE // .
        case 0x30: return VK_TAB
        case 0x31: return VK_SPACE
        case 0x32: return 0xC0 // `
        case 0x33: return VK_BACK
        case 0x35: return VK_ESCAPE

        // Modifiers
        case 0x37: // Left Command
            if swapCommandControl {
                return VK_LCONTROL
            } else if swapWinAltKeys {
                return VK_LMENU // Left Alt (matches physical PC position next to space)
            } else {
                return VK_LWIN  // Left Win
            }
        case 0x36: // Right Command
            if swapCommandControl {
                return VK_RCONTROL
            } else if swapWinAltKeys {
                return VK_RMENU // Right Alt
            } else {
                return VK_RWIN  // Right Win
            }
        case 0x38: // Left Shift
            return VK_LSHIFT
        case 0x3C: // Right Shift
            return VK_RSHIFT
        case 0x39: // Caps lock
            return VK_CAPITAL
        case 0x3A: // Left Option
            if swapWinAltKeys {
                return VK_LWIN  // Left Win (matches physical PC position between Ctrl and Alt)
            } else {
                return VK_LMENU // Left Alt
            }
        case 0x3D: // Right Option
            if swapWinAltKeys {
                return VK_RWIN  // Right Win
            } else {
                return VK_RMENU // Right Alt
            }
        case 0x3B: // Left Control
            if swapCommandControl {
                return VK_LWIN
            } else {
                return VK_LCONTROL // Left Control (stays Control!)
            }
        case 0x3E: // Right Control
            if swapCommandControl {
                return VK_RWIN
            } else {
                return VK_RCONTROL // Right Control (stays Control!)
            }

        // Arrow keys
        case 0x7B: return VK_LEFT
        case 0x7C: return VK_RIGHT
        case 0x7D: return VK_DOWN
        case 0x7E: return VK_UP

        // Function keys
        case 0x7A: return 0x70 // F1
        case 0x78: return 0x71 // F2
        case 0x63: return 0x72 // F3
        case 0x76: return 0x73 // F4
        case 0x60: return 0x74 // F5
        case 0x61: return 0x75 // F6
        case 0x62: return 0x76 // F7
        case 0x64: return 0x77 // F8
        case 0x65: return 0x78 // F9
        case 0x6D: return 0x79 // F10
        case 0x67: return 0x7A // F11
        case 0x6F: return 0x7B // F12

        default:
            return 0
        }
    }
}
