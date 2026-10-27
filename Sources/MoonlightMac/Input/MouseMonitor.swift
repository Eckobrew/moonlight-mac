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

    public var desktopMode = false {
        didSet { if desktopMode != oldValue { releaseRelativeCapture(); refreshCapture() } }
    }
    public var swapButtons = false
    public var reverseScroll = false
    public var videoSize = CGSize(width: 1920, height: 1080)
    public func toggleMode() { desktopMode.toggle() }

    public var sensitivity: Double = 1.0
    /// Independent horizontal multiplier. Applied on top of `sensitivity`, matching
    /// moonlight-qt's per-axis scaling (useful for aspect ratio and preference corrections).
    public var sensitivityX: Double = 1.0
    /// Independent vertical multiplier, applied on top of `sensitivity`.
    public var sensitivityY: Double = 1.0

    /// Preserve fractional sensitivity adjustments after SDL-compatible Cocoa delta conversion.
    public var useSubPixelAccumulation: Bool = true

    private var localMonitor: Any?
    private var isMonitoring = false
    private var seenWarp = false
    private var motion = RelativeMouseMotion()
    public private(set) var isRelativeCaptureActive = false
    private var recoveryWorkItems: [DispatchWorkItem] = []
    private var isCursorHidden: Bool = false
    private var pressedButtons = Set<Int32>()

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
        if isMonitoring { scheduleCaptureRecovery() }
    }

    public func refreshCapture() {
        guard isMonitoring else { return }
        scheduleCaptureRecovery()
    }

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        if streamWindow == nil { streamWindow = WindowManager.shared.currentStreamWindow }

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
                self.cancelCaptureRecovery()
                self.releaseRelativeCapture()
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
                self.scheduleCaptureRecovery()
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
                self.scheduleCaptureRecovery()
            }
        }

        // Initial capture may precede the asynchronous fullscreen transition.
        // Re-arm when it completes, just as we do after switching back to the app.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didEndSheetNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: OperationQueue.main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, window === self.streamWindow else { return }
                    self.scheduleCaptureRecovery()
                }
            }
            windowObservers.append(observer)
        }
    }

    public func stop() {
        if isCaptured {
            isCaptured = false
        }
        cancelCaptureRecovery()
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
        releaseRelativeCapture()
    }

    // MARK: - Relative Mouse Capture (Matches Moonlight-Qt SDL Cocoa Backend)

    private func updateCursorAssociation() {
        if isCaptured { scheduleCaptureRecovery() }
        else { cancelCaptureRecovery(); releaseRelativeCapture() }
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

    private var focusState: StreamMouseFocus {
        guard let window = streamWindow else { return StreamMouseFocus(requested: false) }
        return StreamMouseFocus(requested: isMonitoring && isCaptured,
                                appActive: NSApp.isActive, windowKey: window.isKeyWindow,
                                otherKeyWindow: NSApp.keyWindow != nil && NSApp.keyWindow !== window,
                                visible: window.isVisible && window.occlusionState.contains(.visible),
                                onActiveSpace: window.isOnActiveSpace,
                                blockedByDialog: window.attachedSheet != nil || NSApp.modalWindow != nil,
                                minimized: window.isMiniaturized)
    }

    private func cancelCaptureRecovery() {
        recoveryWorkItems.forEach { $0.cancel() }
        recoveryWorkItems.removeAll()
    }

    private func scheduleCaptureRecovery() {
        cancelCaptureRecovery()
        guard isMonitoring else { return }
        // Release immediately when focus genuinely moves away. Retry only after
        // AppKit has settled its key-window and fullscreen/Space notifications.
        if focusState.action == .release { releaseRelativeCapture() }
        for delay in [0.0, 0.1, 0.35, 1.0] {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isMonitoring else { return }
                self.applyCursorAssociation()
            }
            recoveryWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func releaseRelativeCapture() {
        for button in pressedButtons {
            inputQueue.async { LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), button) }
        }
        pressedButtons.removeAll()
        if isRelativeCaptureActive {
            CGAssociateMouseAndMouseCursorPosition(1)
            isRelativeCaptureActive = false
            onCaptureStateChanged?()
        }
        seenWarp = false
        motion.reset()
        unhideCursorIfNeeded()
    }

    private func applyCursorAssociation() {
        if desktopMode { releaseRelativeCapture(); return }
        if focusState.action == .restoreKeyWindow {
            // makeKey does not activate an app or raise us above banners.
            streamWindow?.makeKey()
        }
        guard focusState.action == .capture, let window = streamWindow else {
            releaseRelativeCapture()
            return
        }
        window.acceptsMouseMovedEvents = true
        if !isRelativeCaptureActive {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
            let point = CGPoint(x: window.frame.midX, y: primaryHeight - window.frame.midY)
            seenWarp = true
            CGWarpMouseCursorPosition(point)
            motion.reset()
        }
        // Reassert association after a temporary system interruption, but do not
        // recenter/drop real motion on every focus/visibility notification.
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
            releaseRelativeCapture()
            return
        }
        if !isRelativeCaptureActive {
            isRelativeCaptureActive = true
            onCaptureStateChanged?()
        }
        hideCursorIfNeeded()
    }

    // MARK: - Event Dispatching

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
        guard (desktopMode ? (NSApp.isActive && streamWindow?.isKeyWindow == true && streamWindow?.attachedSheet == nil) : focusState.action == .capture),
              event.window == nil || isStreamWindow(event.window) else {
            return event
        }

        if !desktopMode {
            if !isRelativeCaptureActive { applyCursorAssociation() }
            guard isRelativeCaptureActive else { return event }
        }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if desktopMode {
                _ = sendDesktopPosition(event)
                return event // Preserve the native cursor while desktop control is active.
            }
            // Discard the single synthetic delta generated when centering cursor during capture
            // (Matches SDL2 / Moonlight-Qt justEnabledRelative behavior)
            if seenWarp {
                seenWarp = false
                return nil
            }

            let step = motion.consume(x: Double(event.deltaX), y: Double(event.deltaY),
                                      scaleX: sensitivity * sensitivityX,
                                      scaleY: sensitivity * sensitivityY,
                                      accumulateSensitivity: useSubPixelAccumulation)
            if step.x != 0 || step.y != 0 {
                inputQueue.async { LiSendMouseMoveEvent(step.x, step.y) }
            }
            return nil

        case .leftMouseDown:
            guard !desktopMode || sendDesktopPosition(event) else { return event }
            sendButton(BUTTON_LEFT, pressed: true)
            return nil
        case .leftMouseUp:
            sendButton(BUTTON_LEFT, pressed: false)
            return nil
        case .rightMouseDown:
            guard !desktopMode || sendDesktopPosition(event) else { return event }
            sendButton(BUTTON_RIGHT, pressed: true)
            return nil
        case .rightMouseUp:
            sendButton(BUTTON_RIGHT, pressed: false)
            return nil
        case .otherMouseDown, .otherMouseUp:
            guard !desktopMode || event.type == .otherMouseUp || sendDesktopPosition(event) else { return event }
            if let button = buttonForNumber(event.buttonNumber) {
                sendButton(button, pressed: event.type == .otherMouseDown)
            }
            return nil
        case .scrollWheel:
            guard !desktopMode || sendDesktopPosition(event) else { return event }
            let scroll = MouseWheelMotion.consume(x: Double(event.deltaX) * (reverseScroll ? -1 : 1), y: Double(event.deltaY) * (reverseScroll ? -1 : 1),
                                                  precise: event.hasPreciseScrollingDeltas)
            if scroll.x != 0 || scroll.y != 0 {
                inputQueue.async {
                    if scroll.y != 0 { LiSendHighResScrollEvent(scroll.y) }
                    if scroll.x != 0 { LiSendHighResHScrollEvent(scroll.x) }
                }
            }
            return nil

        default:
            return event
        }
    }

    /// True only for the window that is currently presenting the stream.
    private func isStreamWindow(_ window: NSWindow?) -> Bool {
        guard let window = window else { return false }
        guard let streamWindow else { return false }
        guard window === streamWindow else { return false }

        // Sheets and panels presented over the stream window are not the stream itself.
        return !(window is NSPanel) && window.parent == nil
    }

    private func sendDesktopPosition(_ event: NSEvent) -> Bool {
        guard let window = streamWindow, let view = window.contentView else { return false }
        let location = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        guard let position = DesktopMousePosition.map(point: view.convert(location, from: nil),
            bounds: view.bounds, video: videoSize, flipped: view.isFlipped) else { return false }
        inputQueue.async { LiSendMousePositionEvent(position.x, position.y, position.width, position.height) }
        return true
    }

    private func sendButton(_ button: Int32, pressed: Bool) {
        let button = swapButtons ? (button == BUTTON_LEFT ? BUTTON_RIGHT : button == BUTTON_RIGHT ? BUTTON_LEFT : button) : button
        if pressed { pressedButtons.insert(button) }
        else { pressedButtons.remove(button) }
        inputQueue.async {
            LiSendMouseButtonEvent(CChar(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), button)
        }
    }

    private func buttonForNumber(_ number: Int) -> Int32? {
        switch number {
        case 2:
            return BUTTON_MIDDLE
        case 3:
            return BUTTON_X1
        case 4:
            return BUTTON_X2
        default:
            return nil
        }
    }
}
