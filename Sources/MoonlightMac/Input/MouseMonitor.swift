import Foundation
import AppKit
import MoonlightCommonC

@MainActor
public final class MouseMonitor: @unchecked Sendable {
    public var isCaptured: Bool = false {
        didSet {
            guard isCaptured != oldValue else { return }
            updateCursorAssociation()
            onCaptureStateChanged?()
        }
    }

    /// Notified whenever capture state changes (used to update the keyboard grab, like moonlight-qt setCaptureActive)
    public var onCaptureStateChanged: (() -> Void)?

    public var sensitivity: Double = 1.0
    /// Independent horizontal multiplier. Applied on top of `sensitivity`, matching
    /// moonlight-qt's per-axis scaling (useful for aspect ratio and preference corrections).
    public var sensitivityX: Double = 1.0
    /// Independent vertical multiplier, applied on top of `sensitivity`.
    public var sensitivityY: Double = 1.0

    /// When true, non-integer deltas accumulate across events (no movement is dropped).
    /// When false, each event is rounded independently, which matches moonlight-qt's default
    /// behavior for mice that already report whole-pixel deltas.
    public var useSubPixelAccumulation: Bool = true

    private var localMonitor: Any?
    private var isMonitoring = false
    private var seenWarp = false
    private var fractionalX: Double = 0.0
    private var fractionalY: Double = 0.0
    private var isCursorHidden: Bool = false
    /// Process-global coalescing flag we changed in `start()`, restored in `stop()`.
    private var previousCoalescingState: Bool?

    private var appResignObserver: NSObjectProtocol?
    private var appBecomeActiveObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var streamWindow: NSWindow?

    /// Dedicated high-priority serial queue for Limelight network socket I/O (matches moonlight-macos-enhanced).
    /// Shared with `KeyboardMonitor` so all `LiSend*` calls are serialized on one queue.
    private let inputQueue: DispatchQueue

    public init(inputQueue: DispatchQueue = DispatchQueue(label: "com.moonlight.input", qos: .userInteractive)) {
        self.inputQueue = inputQueue
    }

    public func setStreamWindow(_ window: NSWindow) {
        guard streamWindow !== window else { return }
        streamWindow = window
        if isMonitoring { applyCursorAssociation() }
    }

    public func refreshCapture() {
        guard isMonitoring else { return }
        applyCursorAssociation()
    }

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        if streamWindow == nil { streamWindow = WindowManager.shared.currentWindow }
        previousCoalescingState = NSEvent.isMouseCoalescingEnabled

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
            queue: OperationQueue.main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isCaptured else { return }
                CGAssociateMouseAndMouseCursorPosition(1)
                self.restoreMouseCoalescing()
                self.unhideCursorIfNeeded()
            }
        }

        // Re-arm capture when app regains focus
        appBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: OperationQueue.main
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
            queue: OperationQueue.main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isCaptured else { return }
                let isKey = (NSApp.keyWindow ?? NSApp.mainWindow)?.isKeyWindow ?? false
                if !isKey || !NSApp.isActive {
                    CGAssociateMouseAndMouseCursorPosition(1)
                    self.restoreMouseCoalescing()
                    self.unhideCursorIfNeeded()
                } else {
                    self.applyCursorAssociation()
                }
            }
        }

        // Initial capture may precede the asynchronous fullscreen transition.
        // Re-arm when it completes, just as we do after switching back to the app.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didEndSheetNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: OperationQueue.main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, window === self.streamWindow else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isMonitoring else { return }
                        self.applyCursorAssociation()
                    }
                }
            }
            windowObservers.append(observer)
        }
    }

    public func stop() {
        if isCaptured {
            isCaptured = false
        }
        // Only restore the global flag if this monitor is the one that changed it.
        if let previous = previousCoalescingState {
            NSEvent.isMouseCoalescingEnabled = previous
            previousCoalescingState = nil
        }
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
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        streamWindow = nil
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
        if isCaptured, NSApp.isActive, let window = streamWindow,
           window.isKeyWindow, window.attachedSheet == nil {
            // Forward motion promptly. Limelight already batches high-rate relative
            // input at 1 ms intervals; AppKit grouping adds another source of bursts.
            NSEvent.isMouseCoalescingEnabled = false

            // Ensure the streaming window receives continuous mouseMoved events
            window.acceptsMouseMovedEvents = true

            // In CoreGraphics screen coordinates, Y starts at top of the primary screen
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080.0
            let centerScreenX = window.frame.midX
            let centerScreenY = primaryScreenHeight - window.frame.midY
            let centerPoint = CGPoint(x: centerScreenX, y: centerScreenY)

            // Discard the first motion event after entering relative mode (as SDL does).
            seenWarp = true
            CGWarpMouseCursorPosition(centerPoint)

            // Disassociate cursor position to allow infinite relative mouse travel
            CGAssociateMouseAndMouseCursorPosition(0)
            hideCursorIfNeeded()
            fractionalX = 0.0
            fractionalY = 0.0
        } else {
            restoreMouseCoalescing()
            seenWarp = false
            fractionalX = 0.0
            fractionalY = 0.0
            CGAssociateMouseAndMouseCursorPosition(1)
            unhideCursorIfNeeded()
        }
    }

    // MARK: - Event Dispatching

    private func restoreMouseCoalescing() {
        if let previous = previousCoalescingState {
            NSEvent.isMouseCoalescingEnabled = previous
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        if !isCaptured {
            // Moonlight-Qt behavior: recapture on left click release inside the *stream* window.
            // The monitors are app-wide, so checking only `event.window != nil` also recaptured on
            // clicks in other Moonlight windows (e.g. the host grid) and trapped the cursor.
            if event.type == .leftMouseUp, isStreamWindow(event.window) {
                isCaptured = true
                return nil
            }
            return event
        }

        // Capture intent survives focus changes, but input must not leak into the
        // host while a settings window, sheet, or another app has focus.
        guard NSApp.isActive, isStreamWindow(event.window), event.window?.isKeyWindow == true else {
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

            // Apply per-axis scaling on top of the global sensitivity.
            let scaleX = sensitivity * sensitivityX
            let scaleY = sensitivity * sensitivityY
            if scaleX != 1.0 { deltaX *= scaleX }
            if scaleY != 1.0 { deltaY *= scaleY }

            if !useSubPixelAccumulation {
                let stepX = Int16(clamping: Int(deltaX.rounded()))
                let stepY = Int16(clamping: Int(deltaY.rounded()))
                if stepX != 0 || stepY != 0 {
                    inputQueue.async {
                        LiSendMouseMoveEvent(stepX, stepY)
                    }
                }
                return nil
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

    /// True only for the window that is currently presenting the stream.
    ///
    private func isStreamWindow(_ window: NSWindow?) -> Bool {
        guard let window = window else { return false }
        guard let streamWindow else { return false }
        guard window === streamWindow else { return false }

        // Sheets and panels presented over the stream window are not the stream itself.
        return !(window is NSPanel) && window.parent == nil
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
