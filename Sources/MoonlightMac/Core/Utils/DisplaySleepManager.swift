import Foundation
import AppKit
import IOKit.pwr_mgt

/// Manages system display sleep assertions to keep the screen awake during active streaming sessions.
/// Specifically configured so sleep prevention is only active while Moonlight is the focused application.
@MainActor
public final class DisplaySleepManager {
    public static let shared = DisplaySleepManager()

    private var assertionID: IOPMAssertionID = 0
    public private(set) var isStreaming: Bool = false
    public private(set) var keepScreenActive: Bool = true
    private var observers: [any NSObjectProtocol] = []

    private init() {
        setupObservers()
    }

    /// Called when a streaming session begins.
    public func start(keepScreenActive: Bool) {
        self.isStreaming = true
        self.keepScreenActive = keepScreenActive
        evaluateAssertion()
    }

    /// Called when a streaming session ends.
    public func stop() {
        self.isStreaming = false
        releaseAssertion()
    }

    /// Dynamically updates the user preference (e.g. if toggled while streaming).
    public func update(keepScreenActive: Bool) {
        self.keepScreenActive = keepScreenActive
        evaluateAssertion()
    }

    /// Whether the macOS display sleep prevention assertion is currently active.
    public var isHoldingAssertion: Bool {
        return assertionID != 0
    }

    /// Determines if Moonlight's stream window currently has focus.
    public var isStreamFocused: Bool {
        guard let app = NSApp, app.isActive else { return false }
        if let window = WindowManager.shared.currentWindow {
            if window.isMiniaturized || !window.isVisible {
                return false
            }
            return window.isKeyWindow || window.isMainWindow
        }
        return true
    }

    /// Re-evaluates whether display sleep should currently be prevented.
    public func evaluateAssertion() {
        let shouldAssert = isStreaming && keepScreenActive && isStreamFocused
        if shouldAssert {
            acquireAssertion()
        } else {
            releaseAssertion()
        }
    }

    private func acquireAssertion() {
        guard assertionID == 0 else { return }
        let reason = "Moonlight Game Stream (Display Active)" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            AppLogger.shared.info("Display sleep prevention assertion acquired (ID: \(assertionID))", category: "Power")
        } else {
            AppLogger.shared.warning("Failed to acquire display sleep assertion (code: \(result))", category: "Power")
            assertionID = 0
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        let currentID = assertionID
        let result = IOPMAssertionRelease(currentID)
        assertionID = 0
        if result == kIOReturnSuccess {
            AppLogger.shared.info("Display sleep prevention assertion released (ID: \(currentID))", category: "Power")
        } else {
            AppLogger.shared.warning("Failed to release display sleep assertion (code: \(result))", category: "Power")
        }
    }

    private func setupObservers() {
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            let obs = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: OperationQueue.main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleNotification(name: name)
                }
            }
            observers.append(obs)
        }
    }

    private func handleNotification(name: Notification.Name) {
        if name == NSApplication.didResignActiveNotification ||
           name == NSApplication.didHideNotification {
            releaseAssertion()
            return
        }

        // Defer slightly to ensure AppKit has finished updating key / main window states
        DispatchQueue.main.async { [weak self] in
            self?.evaluateAssertion()
        }
    }
}
