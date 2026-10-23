import AppKit
import SwiftUI

@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    private struct SavedWindow {
        let frame: NSRect
        let style: NSWindow.StyleMask
        let level: NSWindow.Level
        let collectionBehavior: NSWindow.CollectionBehavior
        let presentationOptions: NSApplication.PresentationOptions
    }

    /// Preserve SwiftUI's window delegate while receiving AppKit's failure-only
    /// delegate callbacks (there are no corresponding failure notifications).
    private final class TransitionDelegate: NSObject, NSWindowDelegate {
        weak var original: (any NSWindowDelegate)?
        var onFailure: (() -> Void)?

        init(original: (any NSWindowDelegate)?) { self.original = original }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }

        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            original?.windowDidFailToEnterFullScreen?(window)
            onFailure?()
        }

        func windowDidFailToExitFullScreen(_ window: NSWindow) {
            original?.windowDidFailToExitFullScreen?(window)
            onFailure?()
        }
    }

    private var transitionDelegate: TransitionDelegate?
    private weak var contentWindow: NSWindow?
    private weak var streamWindow: NSWindow?
    private var savedWindow: SavedWindow?
    private var transition: WindowModeTransition?
    private var observers: [NSObjectProtocol] = []
    private var changedPresentationOptions = false
    public private(set) var currentMode: WindowMode?

    private init() {}

    public var currentWindow: NSWindow? { targetWindow() }

    public func setContentWindow(_ window: NSWindow) { contentWindow = window }

    private func targetWindow(provided: NSWindow? = nil) -> NSWindow? {
        provided ?? streamWindow ?? contentWindow ?? NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow ?? NSApp.keyWindow
    }

    /// Called once when the stream view attaches. Layout, connection callbacks
    /// and HUD updates must not issue another fullscreen request.
    public func applyStartupWindowMode(_ mode: WindowMode, for window: NSWindow? = nil) {
        guard savedWindow == nil else { return }
        applyWindowMode(mode, for: window)
    }

    public func applyWindowMode(_ mode: WindowMode, for window: NSWindow? = nil) {
        guard let window = targetWindow(provided: window) else { return }
        if savedWindow == nil {
            streamWindow = window
            savedWindow = SavedWindow(frame: window.frame, style: window.styleMask,
                                      level: window.level, collectionBehavior: window.collectionBehavior,
                                      presentationOptions: NSApp.presentationOptions)
            transition = WindowModeTransition(requested: mode,
                                              originalWasNativeFullscreen: window.styleMask.contains(.fullScreen))
            observeTransitions(of: window)
        } else {
            guard window === streamWindow else { return }
            transition?.requested = mode
        }
        currentMode = mode
        processTransition()
    }

    public func toggleFullscreen(for window: NSWindow? = nil) {
        guard let window = targetWindow(provided: window) else { return }
        let fullscreenRequested = currentMode == .fullscreen || currentMode == .fullscreenDesktop
        let preferred = StreamSessionController.shared.activeSettings?.windowMode ?? .fullscreenDesktop
        applyWindowMode(fullscreenRequested ? .windowed : (preferred == .windowed ? .fullscreenDesktop : preferred),
                        for: window)
    }

    public func restoreWindowAfterStream(for window: NSWindow? = nil) {
        guard savedWindow != nil else { return }
        transition?.requested = nil
        currentMode = nil
        processTransition()
    }

    public func hideStreamWindow() {
        // A shortcut process is about to exit. Hiding its one window is enough;
        // AppKit removes its fullscreen Space when the process terminates.
        targetWindow()?.orderOut(nil)
        restorePresentationOptions()
    }

    public func showCurrentWindow() {
        guard let window = targetWindow() else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func observeTransitions(of window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification
        ]
        let delegate = TransitionDelegate(original: window.delegate)
        delegate.onFailure = { [weak self] in self?.handleTransitionFailure() }
        transitionDelegate = delegate
        window.delegate = delegate
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: window,
                                                                 queue: OperationQueue.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleTransitionNotification(name)
                }
            }
            observers.append(observer)
        }
    }

    private func handleTransitionNotification(_ name: Notification.Name) {
        guard streamWindow != nil, transition != nil else { return }
        if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
            if transition?.inFlight == false {
                // A green-window-button action is a user request too.
                let mode: WindowMode = name == NSWindow.willEnterFullScreenNotification ? .fullscreenDesktop : .windowed
                transition?.requested = mode
                currentMode = mode
            }
            transition?.inFlight = true
            return
        }
        transition?.inFlight = false
        processTransition()
    }

    private func handleTransitionFailure() {
        guard let window = streamWindow else { return }
        transition?.inFlight = false
        AppLogger.shared.error("Native fullscreen transition failed; keeping the window usable", category: "Window")
        restorePresentationOptions()
        if transition?.requested == nil {
            finishRestoration()
        } else {
            let mode: WindowMode = window.styleMask.contains(.fullScreen) ? .fullscreenDesktop : .windowed
            transition?.requested = mode
            currentMode = mode
        }
        InputCaptureCoordinator.shared.mouseMonitor.refreshCapture()
    }

    private func processTransition() {
        guard let window = streamWindow, let saved = savedWindow, let transition else { return }
        switch transition.action(isNativeFullscreen: window.styleMask.contains(.fullScreen)) {
        case .wait:
            return
        case .enterNative:
            restorePresentationOptions()
            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
            window.level = .normal
            window.collectionBehavior.subtract([.fullScreenNone, .fullScreenAuxiliary])
            window.collectionBehavior.insert([.fullScreenPrimary, .managed])
            self.transition?.inFlight = true
            window.toggleFullScreen(nil)
            return
        case .exitNative:
            self.transition?.inFlight = true
            window.toggleFullScreen(nil)
            return
        case .nativeReady:
            break
        case .windowed:
            restorePresentationOptions()
            window.styleMask = saved.style.subtracting(.fullScreen).union([.titled, .closable, .miniaturizable, .resizable])
            window.level = .normal
            window.collectionBehavior = saved.collectionBehavior
            if !transition.originalWasNativeFullscreen { window.setFrame(saved.frame, display: true) }
        case .borderless:
            // Resizable borderless windows remain eligible to become key. Keep
            // normal level so banners, Notification Center and Cmd+Tab work.
            let screen = window.screen ?? NSScreen.main
            window.styleMask = [.borderless, .resizable]
            window.level = .normal
            window.collectionBehavior = saved.collectionBehavior
            if let screen { window.setFrame(screen.frame, display: true) }
            NSApp.presentationOptions = saved.presentationOptions.subtracting([.hideDock, .hideMenuBar])
                .union([.autoHideDock, .autoHideMenuBar])
            changedPresentationOptions = true
        case .restore:
            restorePresentationOptions()
            if !window.styleMask.contains(.fullScreen) {
                window.styleMask = saved.style.subtracting(.fullScreen)
                if !transition.originalWasNativeFullscreen { window.setFrame(saved.frame, display: true) }
            }
            window.level = saved.level
            window.collectionBehavior = saved.collectionBehavior
            finishRestoration()
            return
        }
        // Focus is recovered by the input coordinator only while this app and
        // this Space are active. Never activate/raise the app during transitions.
        InputCaptureCoordinator.shared.mouseMonitor.refreshCapture()
        FramePacer.shared.updateWindow(window)
    }

    private func restorePresentationOptions() {
        guard changedPresentationOptions, let saved = savedWindow else { return }
        NSApp.presentationOptions = saved.presentationOptions
        changedPresentationOptions = false
    }

    private func finishRestoration() {
        if let delegate = transitionDelegate, streamWindow?.delegate === delegate {
            streamWindow?.delegate = delegate.original
        }
        transitionDelegate = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        savedWindow = nil
        transition = nil
        streamWindow = nil
        currentMode = nil
    }
}
