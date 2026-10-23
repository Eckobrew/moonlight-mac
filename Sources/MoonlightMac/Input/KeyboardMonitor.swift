import Foundation
import AppKit
import MoonlightCommonC

public final class KeyboardMonitor: @unchecked Sendable {
    public var swapWinAltKeys: Bool = true
    public var onQuitRequested: (@Sendable () -> Void)?
    public var onToggleMouseCaptureRequested: (@Sendable () -> Void)?
    public var onToggleFullscreenRequested: (@Sendable () -> Void)?
    public var onToggleStatsOverlayRequested: (@Sendable () -> Void)?
    public var onToggleMouseModeRequested: (@Sendable () -> Void)?
    public var onMinimizeRequested: (@Sendable () -> Void)?
    public var onPasteRequested: (@Sendable () -> Void)?

    /// Serial queue shared with `MouseMonitor` for Limelight input writes. All `LiSend*` calls take
    /// the same control-stream mutex inside moonlight-common-c, so they must be sent from one queue:
    /// sending them on the main thread made AppKit event dispatch block behind mouse packets.
    private let inputQueue: DispatchQueue

    /// Legacy saved preference; both values now use normalized position-based virtual keys.
    public var keyboardLayout: KeyboardLayout = .us

    private var localMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var isMonitoring = false
    private var keysDown = Set<HostKey>()
    private let KEY_ACTION_DOWN: CChar = 0x03
    private let KEY_ACTION_UP: CChar = 0x04

    public init(inputQueue: DispatchQueue = DispatchQueue(label: "com.moonlight.input", qos: .userInteractive)) {
        self.inputQueue = inputQueue
    }

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
            queue: OperationQueue.main
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
        raiseAllKeys()
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
                case 0x0C, 0x0E, 0x35: // Q, E, or Esc: Quit / Disconnect stream
                    raiseModifierKeys()
                    DispatchQueue.main.async { [weak self] in
                        if StreamSessionController.shared.isShortcutMode {
                            for window in NSApp.windows {
                                window.orderOut(nil)
                                window.setIsVisible(false)
                            }
                        }
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

        guard let key = KeycodeMappings.hostKey(macKeyCode: event.keyCode,
                                               swapWinAltKeys: swapWinAltKeys) else { return event }
        let modifiers = modifierByte(for: event.modifierFlags)
        // Caps Lock flags represent a toggle, not a held switch. Send a complete
        // press on each transition so the host never retains a held Caps Lock key.
        if event.type == .flagsChanged && event.keyCode == 0x39 {
            sendKey(key, KEY_ACTION_DOWN, modifiers)
            sendKey(key, KEY_ACTION_UP, modifiers)
            return nil
        }

        switch event.type {
        case .keyDown:
            keysDown.insert(key)
            sendKey(key, KEY_ACTION_DOWN, modifiers)
            return nil // consume event
        case .keyUp:
            keysDown.remove(key)
            sendKey(key, KEY_ACTION_UP, modifiers)
            return nil
        case .flagsChanged:
            // Determine press/release of this specific (left or right) modifier key
            let isDown = isModifierKeyDown(event: event)
            if isDown {
                keysDown.insert(key)
            } else {
                keysDown.remove(key)
            }
            sendKey(key, isDown ? KEY_ACTION_DOWN : KEY_ACTION_UP, modifiers)
            return nil
        default:
            return event
        }
    }

    private func sendKey(_ key: HostKey, _ action: CChar, _ modifiers: CChar) {
        inputQueue.async {
            Self.sendKeyNow(key, action, modifiers)
        }
    }

    private static func sendKeyNow(_ key: HostKey, _ action: CChar, _ modifiers: CChar) {
        LiSendKeyboardEvent2(key.wireCode, action, modifiers | key.extendedModifier, key.flags)
    }

    /// Builds the Limelight modifier byte (MODIFIER_SHIFT/CTRL/ALT/META) like moonlight-qt keyboard.cpp
    private func modifierByte(for flags: NSEvent.ModifierFlags) -> CChar {
        var mods: Int32 = 0
        if flags.contains(.shift) { mods |= MODIFIER_SHIFT }
        if flags.contains(.control) { mods |= MODIFIER_CTRL }

        if swapWinAltKeys {
            if flags.contains(.option) { mods |= MODIFIER_META } // Option is Windows
            if flags.contains(.command) { mods |= MODIFIER_ALT }  // Command is Alt
        } else {
            if flags.contains(.option) { mods |= MODIFIER_ALT }
            if flags.contains(.command) { mods |= MODIFIER_META }
        }
        return CChar(truncatingIfNeeded: mods)
    }

    /// Releases every key we've pressed on the host (matches moonlight-qt raiseAllKeys).
    /// Synchronous so the releases are ordered after any queued keyDown.
    public func raiseAllKeys() {
        let keys = keysDown
        keysDown.removeAll()
        guard !keys.isEmpty else { return }
        inputQueue.sync {
            for key in keys {
                Self.sendKeyNow(key, self.KEY_ACTION_UP, 0)
            }
        }
    }

    /// Releases modifier keys on the host to avoid sticky keys when special combos are consumed
    private func raiseModifierKeys() {
        raiseAllKeys()
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
