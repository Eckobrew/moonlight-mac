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

    private let mouseQueue = DispatchQueue(label: "com.moonlight-stream.input.mouse", qos: .userInteractive)
    private var suppressMotionUntil: DispatchTime = .now()

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
        // Use a dedicated high-priority serial queue for low-latency input (matching SDL / moonlight-qt)
        mouse.handlerQueue = mouseQueue
        mouse.mouseInput?.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self = self, self.isCaptured else { return }
            // GCMouse reports raw unaccelerated sensor counts (mickeys).
            // Normalizing by HIDGCMouseRelativeSpeedDivisor (2.5) matches desktop point scale
            // (as in moonlight-macos-enhanced and moonlight-qt) preventing excessive twitchy sensitivity.
            let normalizedX = Double(deltaX) / 2.5
            let normalizedY = Double(-deltaY) / 2.5
            self.handleRelativeMotion(deltaX: normalizedX, deltaY: normalizedY)
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

    // Direct, zero-latency scaled delta calculation (matching moonlight-macos-enhanced's HIDScaledRelativeDelta)
    private func scaledRelativeDelta(_ delta: Double, sensitivity: Double) -> Int16 {
        guard delta != 0.0 else { return 0 }
        var scaled = delta * sensitivity
        if scaled > Double(Int16.max) {
            scaled = Double(Int16.max)
        } else if scaled < Double(Int16.min) {
            scaled = Double(Int16.min)
        } else if abs(scaled) < 1.0 {
            // Keep micro-adjustments crisp and responsive immediately without accumulator buffering
            scaled = scaled > 0.0 ? 1.0 : -1.0
        }
        return Int16(lrint(scaled))
    }

    private func handleRelativeMotion(deltaX: Double, deltaY: Double) {
        guard isCaptured, DispatchTime.now() >= suppressMotionUntil else { return }

        let stepX = scaledRelativeDelta(deltaX, sensitivity: sensitivity)
        let stepY = scaledRelativeDelta(deltaY, sensitivity: sensitivity)

        if stepX != 0 || stepY != 0 {
            LiSendMouseMoveEvent(stepX, stepY)
        }
    }

    private func updateCursorAssociation() {
        if isCaptured {
            // Suppress synthetic warp motion for 120ms to prevent center-warp jumps
            suppressMotionUntil = .now() + .milliseconds(120)
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()

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
            // If GCMouse is active, it handles raw motion directly at hardware polling rate on mouseQueue
            if hasActiveGCMouse {
                return nil
            }

            // Fallback for trackpad or when GCMouse is not attached: query unscaled CGEvent delta values
            var rawDeltaX = Double(event.deltaX)
            var rawDeltaY = Double(event.deltaY)
            if let cg = event.cgEvent {
                let cgX = cg.getDoubleValueField(.mouseEventDeltaX)
                let cgY = cg.getDoubleValueField(.mouseEventDeltaY)
                if cgX != 0 || cgY != 0 {
                    rawDeltaX = cgX
                    rawDeltaY = cgY
                }
            }

            if rawDeltaX != 0 || rawDeltaY != 0 {
                handleRelativeMotion(deltaX: rawDeltaX, deltaY: rawDeltaY)
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
