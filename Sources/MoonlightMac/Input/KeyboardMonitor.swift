import Foundation
import AppKit
import MoonlightCommonC

public final class KeyboardMonitor: @unchecked Sendable {
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

        let vkCode = KeycodeMappings.macToWindowsVirtualKey(macKeyCode: event.keyCode, swapCommandControl: swapCommandControl)
        if vkCode == 0 { return event }

        switch event.type {
        case .keyDown:
            LiSendKeyboardEvent(vkCode, KEY_ACTION_DOWN, 0)
            return nil // consume event
        case .keyUp:
            LiSendKeyboardEvent(vkCode, KEY_ACTION_UP, 0)
            return nil
        case .flagsChanged:
            // Flags changed event: determine if key was pressed or released
            let isDown = isModifierKeyDown(event: event)
            LiSendKeyboardEvent(vkCode, isDown ? KEY_ACTION_DOWN : KEY_ACTION_UP, 0)
            return nil
        default:
            return event
        }
    }

    /// Releases modifier keys on the host to avoid sticky keys when special combos are consumed
    private func raiseModifierKeys() {
        LiSendKeyboardEvent(KeycodeMappings.VK_CONTROL, KEY_ACTION_UP, 0)
        LiSendKeyboardEvent(KeycodeMappings.VK_MENU, KEY_ACTION_UP, 0)
        LiSendKeyboardEvent(KeycodeMappings.VK_SHIFT, KEY_ACTION_UP, 0)
        LiSendKeyboardEvent(KeycodeMappings.VK_LWIN, KEY_ACTION_UP, 0)
    }

    private func isModifierKeyDown(event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x38, 0x3C: // Shift
            return event.modifierFlags.contains(.shift)
        case 0x3B, 0x3E: // Control
            return event.modifierFlags.contains(.control)
        case 0x3A, 0x3D: // Option
            return event.modifierFlags.contains(.option)
        case 0x37, 0x36: // Command
            return event.modifierFlags.contains(.command)
        case 0x39: // Caps Lock
            return event.modifierFlags.contains(.capsLock)
        default:
            return false
        }
    }
}
