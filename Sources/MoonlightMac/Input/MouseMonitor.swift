import Foundation
import AppKit
import MoonlightCommonC

/// Native mouse monitor replicating the exact mouse motion and capture pipeline from Moonlight-Qt.
public final class MouseMonitor: @unchecked Sendable {
    public var isCaptured: Bool = false {
        didSet {
            updateCursorAssociation()
        }
    }

    public var sensitivity: Double = 1.0

    private var localMonitor: Any?
    private var isMonitoring = false
    private var seenWarp = false
    private var suppressWarpUntil: DispatchTime = .now()
    private var fractionalX: Double = 0.0
    private var fractionalY: Double = 0.0

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
        NSEvent.isMouseCoalescingEnabled = true
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isMonitoring = false
        fractionalX = 0.0
        fractionalY = 0.0
    }

    // MARK: - Relative Mouse Capture (Matches Moonlight-Qt SDL Cocoa Backend)

    private func updateCursorAssociation() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.applyCursorAssociation()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyCursorAssociation()
            }
        }
    }

    @MainActor
    private func applyCursorAssociation() {
        if isCaptured {
            // Disable mouse coalescing so high-polling-rate mice deliver every single movement immediately without OS lag
            NSEvent.isMouseCoalescingEnabled = false

            // Ensure the streaming window receives continuous uncoalesced mouseMoved events
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                window.acceptsMouseMovedEvents = true

                // In CoreGraphics screen coordinates, Y starts at top of the primary screen
                let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080.0
                let centerScreenX = window.frame.midX
                let centerScreenY = primaryScreenHeight - window.frame.midY
                let centerPoint = CGPoint(x: centerScreenX, y: centerScreenY)

                // Mark seenWarp and brief suppression to discard the synthetic delta from CGWarpMouseCursorPosition
                seenWarp = true
                suppressWarpUntil = .now() + .milliseconds(80)
                CGWarpMouseCursorPosition(centerPoint)
            }

            // Disassociate cursor position to allow infinite relative mouse travel
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            fractionalX = 0.0
            fractionalY = 0.0
        } else {
            NSEvent.isMouseCoalescingEnabled = true
            seenWarp = false
            fractionalX = 0.0
            fractionalY = 0.0
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    // MARK: - Event Dispatching

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        if !isCaptured {
            // Moonlight-Qt behavior: recapture mouse on left click release inside window
            if event.type == .leftMouseUp && event.window != nil {
                isCaptured = true
                return nil
            }
            return event
        }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Discard the synthetic delta generated when centering cursor during capture
            if seenWarp || DispatchTime.now() < suppressWarpUntil {
                seenWarp = false
                return nil
            }

            // Extract native Cocoa deltas directly (matches SDL2 / moonlight-qt Cocoa_HandleMouseEvent)
            var deltaX = Double(event.deltaX)
            var deltaY = Double(event.deltaY)

            // Apply sensitivity scaling if configured
            if sensitivity != 1.0 {
                deltaX *= sensitivity
                deltaY *= sensitivity
            }

            // Sub-pixel fractional accumulator: accumulates micro-movements across uncoalesced events
            // and emits exact integer steps without dropping movement or artificially accelerating slow aim
            fractionalX += deltaX
            fractionalY += deltaY

            let stepX = Int16(clamping: Int(fractionalX))
            let stepY = Int16(clamping: Int(fractionalY))

            fractionalX -= Double(stepX)
            fractionalY -= Double(stepY)

            if stepX != 0 || stepY != 0 {
                LiSendMouseMoveEvent(stepX, stepY)
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
            let btn = buttonForNumber(event.buttonNumber)
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(btn))
            return nil
        case .otherMouseUp:
            let btn = buttonForNumber(event.buttonNumber)
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(btn))
            return nil

        case .scrollWheel:
            // Match SDL2 / moonlight-qt scroll handling with macOS acceleration clamp
            var preciseY = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.1 : event.deltaY)
            var preciseX = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaX * 0.1 : event.deltaX)

            // Clamp on macOS to prevent wild OS scroll acceleration deltas (matching moonlight-qt mouse.cpp)
            preciseY = max(-1.0, min(1.0, preciseY))
            preciseX = max(-1.0, min(1.0, preciseX))

            let scrollY = Int16(clamping: Int(lrint(Double(preciseY * 120.0))))
            let scrollX = Int16(clamping: Int(lrint(Double(preciseX * 120.0))))

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

    private func buttonForNumber(_ number: Int) -> Int32 {
        switch number {
        case 2:
            return BUTTON_MIDDLE
        case 3:
            return BUTTON_X1
        case 4:
            return BUTTON_X2
        default:
            return BUTTON_MIDDLE
        }
    }
}
