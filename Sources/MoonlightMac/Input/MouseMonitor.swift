import Foundation
import AppKit
import GameController
import MoonlightCommonC

public final class MouseMonitor: @unchecked Sendable {
    public var isCaptured: Bool = false {
        didSet {
            updateCursorAssociation()
        }
    }

    public var sensitivity: Double = 1.0

    private var localMonitor: Any?
    private var mouseConnectObserver: Any?
    private var mouseDisconnectObserver: Any?
    private var isMonitoring = false

    private var subpixelDeltaX: Double = 0.0
    private var subpixelDeltaY: Double = 0.0
    private let deltaLock = NSLock()

    private var hasActiveGCMouse: Bool {
        return !GCMouse.mice().isEmpty
    }

    public init() {}

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        setupGCMouse()

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
        if let obs = mouseConnectObserver {
            NotificationCenter.default.removeObserver(obs)
            mouseConnectObserver = nil
        }
        if let obs = mouseDisconnectObserver {
            NotificationCenter.default.removeObserver(obs)
            mouseDisconnectObserver = nil
        }
        tearDownGCMouse()
        isMonitoring = false
    }

    // MARK: - GameController GCMouse Integration (Matches Moonlight-Qt & Moonlight-macOS-Enhanced)

    private func setupGCMouse() {
        for mouse in GCMouse.mice() {
            registerGCMouse(mouse)
        }

        mouseConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let mouse = note.object as? GCMouse {
                self?.registerGCMouse(mouse)
            }
        }

        mouseDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let mouse = note.object as? GCMouse {
                self?.unregisterGCMouse(mouse)
            }
        }
    }

    private func registerGCMouse(_ mouse: GCMouse) {
        mouse.mouseInput?.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self = self, self.isCaptured else { return }
            // In GameController framework, deltaY is positive upwards; invert to standard downward-positive deltas
            self.handleRawDelta(deltaX: Double(deltaX), deltaY: Double(-deltaY))
        }
    }

    private func unregisterGCMouse(_ mouse: GCMouse) {
        mouse.mouseInput?.mouseMovedHandler = nil
    }

    private func tearDownGCMouse() {
        for mouse in GCMouse.mice() {
            unregisterGCMouse(mouse)
        }
    }

    private func handleRawDelta(deltaX: Double, deltaY: Double) {
        guard isCaptured else { return }

        let scaledX = deltaX * sensitivity
        let scaledY = deltaY * sensitivity

        deltaLock.lock()
        subpixelDeltaX += scaledX
        subpixelDeltaY += scaledY

        let stepX = Int16(clamping: Int(subpixelDeltaX))
        let stepY = Int16(clamping: Int(subpixelDeltaY))

        if stepX != 0 || stepY != 0 {
            subpixelDeltaX -= Double(stepX)
            subpixelDeltaY -= Double(stepY)
            deltaLock.unlock()
            LiSendMouseMoveEvent(stepX, stepY)
        } else {
            deltaLock.unlock()
        }
    }

    private func updateCursorAssociation() {
        if isCaptured {
            // Unpin hardware cursor position to bypass macOS acceleration curves and confines
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
            // If GCMouse is active, it handles raw motion directly at hardware polling rate
            if hasActiveGCMouse {
                return nil
            }

            // Fallback for trackpad or when GCMouse is not attached: query unscaled CGEvent delta values
            var rawDeltaX: Double = 0.0
            var rawDeltaY: Double = 0.0
            if let cg = event.cgEvent {
                rawDeltaX = cg.getDoubleValueField(.mouseEventDeltaX)
                rawDeltaY = cg.getDoubleValueField(.mouseEventDeltaY)
            }
            if rawDeltaX == 0 && rawDeltaY == 0 {
                rawDeltaX = Double(event.deltaX)
                rawDeltaY = Double(event.deltaY)
            }

            if rawDeltaX != 0 || rawDeltaY != 0 {
                handleRawDelta(deltaX: rawDeltaX, deltaY: rawDeltaY)
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
            let hasPrecise = event.hasPreciseScrollingDeltas
            let multiplier: CGFloat = hasPrecise ? 60 : 120
            let scrollY = Int16(clamping: Int(event.scrollingDeltaY * multiplier))
            let scrollX = Int16(clamping: Int(event.scrollingDeltaX * multiplier))
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
