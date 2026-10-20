import Foundation
import AppKit
import MoonlightCommonC

public final class KeyboardMonitor: @unchecked Sendable {
    public var swapWinAltKeys: Bool = true
    public var swapCommandControl: Bool = false
    public var onQuitRequested: (@Sendable () -> Void)?
    public var onToggleMouseCaptureRequested: (@Sendable () -> Void)?
    public var onToggleFullscreenRequested: (@Sendable () -> Void)?
    public var onToggleStatsOverlayRequested: (@Sendable () -> Void)?
    public var onToggleMouseModeRequested: (@Sendable () -> Void)?
    public var onMinimizeRequested: (@Sendable () -> Void)?
    public var onPasteRequested: (@Sendable () -> Void)?

    private var localMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var isMonitoring = false
    private var keysDown = Set<Int16>()
    private let KEY_ACTION_DOWN: CChar = 0x03
    private let KEY_ACTION_UP: CChar = 0x04

    public init() {}

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyEvent(event)
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.raiseModifierKeys()
        }
    }

    public func stop() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let obs = appResignObserver {
            NotificationCenter.default.removeObserver(obs)
            appResignObserver = nil
        }
        isMonitoring = false
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Only trigger special key combos on keyDown events
        if event.type == .keyDown {
            let isMoonlightCombo = event.modifierFlags.contains([.control, .option, .shift])
            let isCmdCtrl = event.modifierFlags.contains([.command, .control])

            // Moonlight-Qt Key Combos on macOS: Control + Option + Shift + <Key>
            if isMoonlightCombo {
                switch event.keyCode {
                case 0x0C: // Q: Quit / Disconnect stream
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onQuitRequested?()
                    }
                    return nil

                case 0x06: // Z: Toggle mouse capture (release or recapture cursor)
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleMouseCaptureRequested?()
                    }
                    return nil

                case 0x07: // X: Toggle Fullscreen / Windowed
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleFullscreenRequested?()
                    }
                    return nil

                case 0x01: // S: Toggle Stats Overlay (Performance HUD)
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleStatsOverlayRequested?()
                    }
                    return nil

                case 0x2E: // M: Toggle Mouse Mode
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleMouseModeRequested?()
                    }
                    return nil

                case 0x02: // D: Minimize Window
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onMinimizeRequested?()
                    }
                    return nil

                case 0x09: // V: Type Clipboard Text to Host
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onPasteRequested?()
                    }
                    return nil

                default:
                    break
                }
            }

            // Fallback shortcuts: Cmd + Ctrl + Q (Quit) and Cmd + Ctrl + B (Toggle Window Mode)
            if isCmdCtrl {
                if event.keyCode == 0x0C { // Q
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onQuitRequested?()
                    }
                    return nil
                } else if event.keyCode == 0x0B { // B
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleFullscreenRequested?()
                    }
                    return nil
                }
            }
        }

        let vkCode = KeycodeMappings.macToWindowsVirtualKey(
            macKeyCode: event.keyCode,
            swapWinAltKeys: swapWinAltKeys,
            swapCommandControl: swapCommandControl
        )
        if vkCode == 0 { return event }

        let modifiers = modifierByte(for: event.modifierFlags)

        switch event.type {
        case .keyDown:
            keysDown.insert(vkCode)
            LiSendKeyboardEvent(vkCode, KEY_ACTION_DOWN, modifiers)
            return nil // consume event
        case .keyUp:
            keysDown.remove(vkCode)
            LiSendKeyboardEvent(vkCode, KEY_ACTION_UP, modifiers)
            return nil
        case .flagsChanged:
            // Determine press/release of this specific (left or right) modifier key
            let isDown = isModifierKeyDown(event: event)
            if isDown {
                keysDown.insert(vkCode)
            } else {
                keysDown.remove(vkCode)
            }
            LiSendKeyboardEvent(vkCode, isDown ? KEY_ACTION_DOWN : KEY_ACTION_UP, modifiers)
            return nil
        default:
            return event
        }
    }

    /// Builds the Limelight modifier byte (MODIFIER_SHIFT/CTRL/ALT/META) like moonlight-qt keyboard.cpp
    private func modifierByte(for flags: NSEvent.ModifierFlags) -> CChar {
        var mods: Int32 = 0
        if flags.contains(.shift) { mods |= MODIFIER_SHIFT }

        if swapCommandControl {
            if flags.contains(.control) { mods |= MODIFIER_META }
            if flags.contains(.command) { mods |= MODIFIER_CTRL }
            if flags.contains(.option) { mods |= MODIFIER_ALT }
        } else if swapWinAltKeys {
            if flags.contains(.control) { mods |= MODIFIER_CTRL }
            if flags.contains(.option) { mods |= MODIFIER_META } // Option is Windows
            if flags.contains(.command) { mods |= MODIFIER_ALT }  // Command is Alt
        } else {
            if flags.contains(.control) { mods |= MODIFIER_CTRL }
            if flags.contains(.option) { mods |= MODIFIER_ALT }
            if flags.contains(.command) { mods |= MODIFIER_META }
        }
        return CChar(truncatingIfNeeded: mods)
    }

    /// Releases every key we've pressed on the host (matches moonlight-qt raiseAllKeys)
    public func raiseAllKeys() {
        for vk in keysDown {
            LiSendKeyboardEvent(vk, KEY_ACTION_UP, 0)
        }
        keysDown.removeAll()
    }

    /// Releases modifier keys on the host to avoid sticky keys when special combos are consumed
    private func raiseModifierKeys() {
        raiseAllKeys()
        for vk in [KeycodeMappings.VK_LCONTROL, KeycodeMappings.VK_RCONTROL,
                   KeycodeMappings.VK_LMENU, KeycodeMappings.VK_RMENU,
                   KeycodeMappings.VK_LSHIFT, KeycodeMappings.VK_RSHIFT,
                   KeycodeMappings.VK_LWIN, KeycodeMappings.VK_RWIN] {
            LiSendKeyboardEvent(vk, KEY_ACTION_UP, 0)
        }
    }

    /// Uses device-dependent flag bits (NX_DEVICE*KEYMASK) so left/right modifiers are tracked independently
    private func isModifierKeyDown(event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch event.keyCode {
        case 0x3B: return raw & 0x0000_0001 != 0 // NX_DEVICELCTLKEYMASK
        case 0x3E: return raw & 0x0000_2000 != 0 // NX_DEVICERCTLKEYMASK
        case 0x38: return raw & 0x0000_0002 != 0 // NX_DEVICELSHIFTKEYMASK
        case 0x3C: return raw & 0x0000_0004 != 0 // NX_DEVICERSHIFTKEYMASK
        case 0x37: return raw & 0x0000_0008 != 0 // NX_DEVICELCMDKEYMASK
        case 0x36: return raw & 0x0000_0010 != 0 // NX_DEVICERCMDKEYMASK
        case 0x3A: return raw & 0x0000_0020 != 0 // NX_DEVICELALTKEYMASK
        case 0x3D: return raw & 0x0000_0040 != 0 // NX_DEVICERALTKEYMASK
        case 0x39: return event.modifierFlags.contains(.capsLock)
        default: return false
        }
    }
}
