import Foundation
import AppKit
import MoonlightCommonC

@MainActor
public final class MouseMonitor: @unchecked Sendable {
    public var isCaptured: Bool = false {
        didSet {
            updateCursorAssociation()
            onCaptureStateChanged?()
        }
    }

    /// Notified whenever capture state changes (used to update the keyboard grab, like moonlight-qt setCaptureActive)
    public var onCaptureStateChanged: (() -> Void)?

    public var sensitivity: Double = 1.0

    private var localMonitor: Any?
    private var isMonitoring = false
    private var seenWarp = false
    private var fractionalX: Double = 0.0
    private var fractionalY: Double = 0.0
    private var isCursorHidden: Bool = false

    private var appResignObserver: NSObjectProtocol?
    private var appBecomeActiveObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    /// Dedicated high-priority serial queue for Limelight network socket I/O (matches moonlight-macos-enhanced)
    private let inputQueue = DispatchQueue(label: "com.moonlight.input", qos: .userInteractive)

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

        // Release cursor hardware lock when app loses focus (e.g. Cmd+Tab, Mission Control)
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isCaptured else { return }
                CGAssociateMouseAndMouseCursorPosition(1)
                self.unhideCursorIfNeeded()
            }
        }

        // Re-arm capture when app regains focus
        appBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isCaptured else { return }
                self.applyCursorAssociation()
            }
        }

        // Release or re-arm capture when switching macOS Spaces
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isCaptured else { return }
                let isKey = (NSApp.keyWindow ?? NSApp.mainWindow)?.isKeyWindow ?? false
                if !isKey || !NSApp.isActive {
                    CGAssociateMouseAndMouseCursorPosition(1)
                    self.unhideCursorIfNeeded()
                } else {
                    self.applyCursorAssociation()
                }
            }
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
        if let obs = appResignObserver {
            NotificationCenter.default.removeObserver(obs)
            appResignObserver = nil
        }
        if let obs = appBecomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            appBecomeActiveObserver = nil
        }
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObserver = nil
        }
        isMonitoring = false
        fractionalX = 0.0
        fractionalY = 0.0
        unhideCursorIfNeeded()
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Relative Mouse Capture (Matches Moonlight-Qt SDL Cocoa Backend)

    private func updateCursorAssociation() {
        applyCursorAssociation()
    }

    private func hideCursorIfNeeded() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    private func unhideCursorIfNeeded() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }

    private func applyCursorAssociation() {
        if isCaptured {
            // Keep standard coalescing enabled so that high-polling-rate mice deliver smooth, aggregated deltas
            NSEvent.isMouseCoalescingEnabled = true

            // Ensure the streaming window receives continuous mouseMoved events
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                window.acceptsMouseMovedEvents = true

                // In CoreGraphics screen coordinates, Y starts at top of the primary screen
                let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080.0
                let centerScreenX = window.frame.midX
                let centerScreenY = primaryScreenHeight - window.frame.midY
                let centerPoint = CGPoint(x: centerScreenX, y: centerScreenY)

                // Mark seenWarp to discard the single synthetic delta from CGWarpMouseCursorPosition
                // (Matches Moonlight-Qt SDL Cocoa_SetRelativeMouseMode without artificial millisecond suppression delay)
                seenWarp = true
                CGWarpMouseCursorPosition(centerPoint)
            }

            // Disassociate cursor position to allow infinite relative mouse travel
            CGAssociateMouseAndMouseCursorPosition(0)
            hideCursorIfNeeded()
            fractionalX = 0.0
            fractionalY = 0.0
        } else {
            NSEvent.isMouseCoalescingEnabled = true
            seenWarp = false
            fractionalX = 0.0
            fractionalY = 0.0
            CGAssociateMouseAndMouseCursorPosition(1)
            unhideCursorIfNeeded()
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
            // Discard the single synthetic delta generated when centering cursor during capture
            // (Matches SDL2 / Moonlight-Qt justEnabledRelative behavior)
            if seenWarp {
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

            // Sub-pixel fractional accumulator: accumulates micro-movements across events
            // and emits exact integer steps without dropping movement or artificially accelerating slow aim
            fractionalX += deltaX
            fractionalY += deltaY

            let stepX = Int16(clamping: Int(fractionalX))
            let stepY = Int16(clamping: Int(fractionalY))

            fractionalX -= Double(stepX)
            fractionalY -= Double(stepY)

            if stepX != 0 || stepY != 0 {
                inputQueue.async {
                    LiSendMouseMoveEvent(stepX, stepY)
                }
            }
            return nil

        case .leftMouseDown:
            inputQueue.async {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(BUTTON_LEFT))
            }
            return nil
        case .leftMouseUp:
            inputQueue.async {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(BUTTON_LEFT))
            }
            return nil

        case .rightMouseDown:
            inputQueue.async {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(BUTTON_RIGHT))
            }
            return nil
        case .rightMouseUp:
            inputQueue.async {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(BUTTON_RIGHT))
            }
            return nil

        case .otherMouseDown:
            let btn = buttonForNumber(event.buttonNumber)
            inputQueue.async {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), Int32(btn))
            }
            return nil
        case .otherMouseUp:
            let btn = buttonForNumber(event.buttonNumber)
            inputQueue.async {
                LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), Int32(btn))
            }
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

            if scrollY != 0 || scrollX != 0 {
                inputQueue.async {
                    if scrollY != 0 {
                        LiSendHighResScrollEvent(scrollY)
                    }
                    if scrollX != 0 {
                        LiSendHighResHScrollEvent(scrollX)
                    }
                }
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
