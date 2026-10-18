import Foundation
import AppKit
import MoonlightCommonC

public final class MouseMonitor: @unchecked Sendable {
    public var isCaptured: Bool = false {
        didSet {
            updateCursorAssociation()
        }
    }

    private var localMonitor: Any?
    private var isMonitoring = false

    public init() {}

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return event }
            return self.handleMouseEvent(event)
        }
    }

    public func stop() {
        if isCaptured {
            isCaptured = false
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isMonitoring = false
    }

    private func updateCursorAssociation() {
        if isCaptured {
            // Unpin hardware cursor position to bypass macOS acceleration curves
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()

            // Center virtual cursor within key window on main actor
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    let centerPoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
                    CGWarpMouseCursorPosition(centerPoint)
                }
            }
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard isCaptured else { return event }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let deltaX = Int16(clamping: Int(event.deltaX))
            let deltaY = Int16(clamping: Int(event.deltaY))
            if deltaX != 0 || deltaY != 0 {
                LiSendMouseMoveEvent(deltaX, deltaY)
            }
            return nil

        case .leftMouseDown:
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(BUTTON_LEFT))
            return nil
        case .leftMouseUp:
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(BUTTON_LEFT))
            return nil

        case .rightMouseDown:
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(BUTTON_RIGHT))
            return nil
        case .rightMouseUp:
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(BUTTON_RIGHT))
            return nil

        case .otherMouseDown:
            let btn = event.buttonNumber == 2 ? BUTTON_MIDDLE : (event.buttonNumber == 3 ? BUTTON_X1 : BUTTON_X2)
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(btn))
            return nil
        case .otherMouseUp:
            let btn = event.buttonNumber == 2 ? BUTTON_MIDDLE : (event.buttonNumber == 3 ? BUTTON_X1 : BUTTON_X2)
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(btn))
            return nil

        case .scrollWheel:
            let scrollY = Int16(clamping: Int(event.scrollingDeltaY * 120))
            let scrollX = Int16(clamping: Int(event.scrollingDeltaX * 120))
            if scrollY != 0 {
                LiSendHighResScrollEvent(scrollY)
            }
            if scrollX != 0 {
                LiSendHighResHScrollEvent(scrollX)
            }
            return nil

        default:
            return event
        }
    }
}
