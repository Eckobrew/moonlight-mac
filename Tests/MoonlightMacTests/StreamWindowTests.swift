import AppKit
import SwiftUI
import Testing
@testable import MoonlightMac

@MainActor
@Test func streamWindowDoesNotPersistGeometryOrRestorationState() throws {
    _ = NSApplication.shared
    let browser = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let frame = browser.frame
    let style = browser.styleMask
    let stream = StreamWindowController(screen: nil, title: "Test stream", onClose: {})
    defer { stream.close() }
    let window = try #require(stream.window)
    #expect(window !== browser)
    #expect(!window.isRestorable)
    #expect(window.frameAutosaveName.isEmpty)
    #expect(window.acceptsMouseMovedEvents)
    // Borderless fullscreen must remain eligible for keyboard and mouse focus.
    window.styleMask = [.borderless, .resizable]
    #expect(window.canBecomeKey)
    #expect(window.canBecomeMain)
    #expect(browser.frame == frame)
    #expect(browser.styleMask == style)
}

@MainActor
@Test func closingStreamRequestsTeardownBeforeReleasingItsContent() throws {
    _ = NSApplication.shared
    var stopRequests = 0
    let stream = StreamWindowController(screen: nil, title: "Test stream") { stopRequests += 1 }
    let window = try #require(stream.window)
    stream.setContent(Text("Stream"))
    window.performClose(nil)
    #expect(stopRequests == 1)
    #expect(window.contentViewController != nil)
    stream.close()
    #expect(stopRequests == 1)
    #expect(window.contentViewController == nil)
}

@MainActor
@Test func streamFullscreenRequestsCannotChangeTheBrowserWindow() {
    _ = NSApplication.shared
    let browser = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let frame = browser.frame
    let style = browser.styleMask
    let manager = WindowManager.shared
    manager.setBrowserWindow(browser)
    manager.applyWindowMode(.fullscreen, for: browser)
    manager.toggleFullscreen()
    #expect(browser.frame == frame)
    #expect(browser.styleMask == style)
    #expect(manager.currentStreamWindow == nil)
    #expect(manager.currentMode == nil)
}
