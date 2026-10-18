import AppKit
import SwiftUI

@MainActor
public final class WindowManager: ObservableObject {
    public static let shared = WindowManager()

    private var previousStyleMask: NSWindow.StyleMask?
    private var previousFrame: NSRect?
    private var previousLevel: NSWindow.Level?
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var startupWorkItem: DispatchWorkItem?
    public private(set) var currentMode: WindowMode?

    private init() {}

    private func targetWindow(provided: NSWindow? = nil) -> NSWindow? {
        return provided ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
    }

    /// Applies the window mode with a slight delay (0.12s) to allow view transition layout to complete
    public func applyStartupWindowMode(_ mode: WindowMode, for window: NSWindow? = nil) {
        startupWorkItem?.cancel()
        startupWorkItem = nil

        guard let window = targetWindow(provided: window) else {
            AppLogger.shared.warning("applyStartupWindowMode: No visible window found!", category: "Window")
            return
        }

        // Save pre-stream frame if currently a standard window
        if self.previousFrame == nil && !window.styleMask.contains(.fullScreen) && window.styleMask != .borderless {
            self.previousFrame = window.frame
        }

        AppLogger.shared.info("applyStartupWindowMode: targetMode=\(mode.rawValue), window=\(window.description), isFullScreen=\(window.styleMask.contains(.fullScreen))", category: "Window")

        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self = self, let window = window else { return }
            self.applyWindowMode(mode, for: window)
        }
        self.startupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    public func applyWindowMode(_ mode: WindowMode, for window: NSWindow? = nil) {
        guard let window = targetWindow(provided: window) else {
            AppLogger.shared.warning("applyWindowMode: No visible window found!", category: "Window")
            return
        }

        AppLogger.shared.info("applyWindowMode: applying \(mode.rawValue)", category: "Window")
        self.currentMode = mode

        switch mode {
        case .windowed:
            applyWindowed(to: window)
        case .fullscreen:
            applyFullscreenCurrentSpace(to: window)
        case .fullscreenDesktop:
            applyFullscreenSpace(to: window)
        }
    }

    public func toggleFullscreen(for window: NSWindow? = nil) {
        guard let window = targetWindow(provided: window) else { return }
        if window.styleMask.contains(.fullScreen) || window.styleMask == .borderless {
            applyWindowMode(.windowed, for: window)
        } else {
            let target = StreamSessionController.shared.activeSettings?.windowMode ?? .fullscreenDesktop
            applyWindowMode(target == .windowed ? .fullscreenDesktop : target, for: window)
        }
    }

    public func cycleWindowMode(for window: NSWindow? = nil) {
        guard let current = currentMode else {
            applyWindowMode(.fullscreenDesktop, for: window)
            return
        }
        let next: WindowMode
        switch current {
        case .fullscreenDesktop:
            next = .fullscreen
        case .fullscreen:
            next = .windowed
        case .windowed:
            next = .fullscreenDesktop
        }
        applyWindowMode(next, for: window)
    }

    public func restoreWindowAfterStream(for window: NSWindow? = nil) {
        startupWorkItem?.cancel()
        startupWorkItem = nil

        guard let window = targetWindow(provided: window) else { return }

        AppLogger.shared.info("restoreWindowAfterStream: restoring standard window, isFullScreen=\(window.styleMask.contains(.fullScreen))", category: "Window")
        restorePresentationOptions()

        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            // macOS Space exit transition takes ~0.5s; verify and enforce normal window after transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak window] in
                guard let self = self, let window = window else { return }
                self.restoreStandardWindowFrame(for: window)
            }
        } else {
            restoreStandardWindowFrame(for: window)
        }

        currentMode = nil
    }

    private func restoreStandardWindowFrame(for window: NSWindow) {
        if window.styleMask.contains(.fullScreen) {
            // Still in transition, try once more
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
                guard let window = window else { return }
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
                self?.restoreStandardWindowFrame(for: window)
            }
            return
        }

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.level = .normal

        if let prevFrame = previousFrame {
            window.setFrame(prevFrame, display: true, animate: true)
            previousFrame = nil
        } else {
            let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let targetW = min(1100.0, visible.width * 0.8)
            let targetH = min(700.0, visible.height * 0.8)
            let targetFrame = NSRect(
                x: visible.midX - targetW / 2.0,
                y: visible.midY - targetH / 2.0,
                width: targetW,
                height: targetH
            )
            window.setFrame(targetFrame, display: true, animate: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// "Windowed": Extends to fill all available space (excluding dock and menu bar)
    private func applyWindowed(to window: NSWindow) {
        AppLogger.shared.info("applyWindowed: entering windowed mode extending to fill available space", category: "Window")
        restorePresentationOptions()

        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        if previousFrame == nil && !window.styleMask.contains(.fullScreen) && window.styleMask != .borderless {
            previousFrame = window.frame
        }

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.level = .normal

        // Windowed mode extends to fill all available space (not the dock or menu bar)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(screen.visibleFrame, display: true, animate: true)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// "Fullscreen (Windowed)": Moves the app to its own macOS Space via native fullscreen spaces
    private func applyFullscreenSpace(to window: NSWindow) {
        AppLogger.shared.info("applyFullscreenSpace: window=\(window.description), isFullScreen=\(window.styleMask.contains(.fullScreen))", category: "Window")
        restorePresentationOptions()

        if previousFrame == nil && !window.styleMask.contains(.fullScreen) && window.styleMask != .borderless {
            previousFrame = window.frame
        }

        // If currently in borderless mode on current space, restore resizable titled style first
        if window.styleMask == .borderless || !window.styleMask.contains(.titled) {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.level = .normal
        }

        // Ensure window has resizable style mask so macOS allows native fullscreen space
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }

        // Ensure window collection behavior supports native fullscreen Space
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if !window.styleMask.contains(.fullScreen) {
            AppLogger.shared.info("applyFullscreenSpace: invoking window.toggleFullScreen(nil)", category: "Window")
            window.toggleFullScreen(nil)
        } else {
            AppLogger.shared.info("applyFullscreenSpace: window is already in fullscreen Space", category: "Window")
        }
    }

    /// "Fullscreen": Covers the entire display on the current Space (borderless window)
    private func applyFullscreenCurrentSpace(to window: NSWindow) {
        AppLogger.shared.info("applyFullscreenCurrentSpace: entering borderless on current Space", category: "Window")

        // Exit native macOS Spaces fullscreen first if active
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        if previousPresentationOptions == nil {
            previousPresentationOptions = NSApp.presentationOptions
        }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        if previousFrame == nil {
            previousFrame = window.frame
        }

        window.styleMask = [.borderless]
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(screen.frame, display: true)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func restorePresentationOptions() {
        if let prev = previousPresentationOptions {
            NSApp.presentationOptions = prev
            previousPresentationOptions = nil
        } else {
            NSApp.presentationOptions = []
        }
    }
}
