import Foundation
import AppKit
import MoonlightCommonC

public final class KeyboardMonitor: @unchecked Sendable {
    public var swapCommandControl: Bool = false
    public var onEscapeRequested: (@Sendable () -> Void)?

    private var localMonitor: Any?
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
    }

    public func stop() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isMonitoring = false
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Hotkey: Cmd + Ctrl + Q releases mouse or exits stream
        if event.modifierFlags.contains([.command, .control]) && event.keyCode == 0x0C { // Q
            onEscapeRequested?()
            return nil
        }

        let vkCode = KeycodeMappings.macToWindowsVirtualKey(macKeyCode: event.keyCode, swapCommandControl: swapCommandControl)
        if vkCode == 0 { return event }

        switch event.type {
        case .keyDown:
            if !event.isARepeat {
                LiSendKeyboardEvent(vkCode, KEY_ACTION_DOWN, 0)
            }
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
