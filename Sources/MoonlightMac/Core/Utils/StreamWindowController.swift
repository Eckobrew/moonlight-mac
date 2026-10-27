import AppKit
import SwiftUI

/// Owns one session's window. It has no frame autosave or restoration identity,
/// so native fullscreen and borderless geometry cannot affect the host browser.
@MainActor
final class StreamWindowController: NSWindowController, NSWindowDelegate {
    private final class StreamWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private let onClose: () -> Void

    init(screen: NSScreen?, title: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, visibleFrame.width * 0.9, visibleFrame.height * 0.9 * 16 / 9)
        let size = NSSize(width: width, height: width * 9 / 16)
        let frame = NSRect(x: visibleFrame.midX - size.width / 2,
                           y: visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let window = StreamWindow(contentRect: frame,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.backgroundColor = .black
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentMinSize = NSSize(width: 640, height: 360)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("Use init(screen:title:onClose:)") }

    func setContent(_ content: some View) {
        window?.contentViewController = NSHostingController(rootView: content)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        // Session teardown releases input and video before closing this window.
        return false
    }

    override func close() {
        window?.delegate = nil
        super.close()
        window?.contentViewController = nil
    }
}
