import Foundation
import Testing
@testable import MoonlightMac

@Test func externalStreamWindowDoesNotSelectBuiltInDisplay() {
    let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let window = CGRect(x: 1600, y: 100, width: 1000, height: 700)
    #expect(DisplayManager.screenIndex(for: window, screens: [builtIn, external]) == 1)
    #expect(DisplayManager.screenIndex(for: window, screens: [external, builtIn]) == 0)
}

@Test func displaySelectionHandlesNegativeOriginsAndSpanningWindows() {
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let window = CGRect(x: -800, y: 100, width: 1000, height: 700)
    #expect(DisplayManager.screenIndex(for: window, screens: [right, left]) == 1)
    #expect(DisplayManager.screenIndex(for: CGRect(x: 5000, y: 0, width: 800, height: 600),
                                       screens: [left, right]) == nil)
    #expect(DisplayManager.screenIndex(for: window, screens: []) == nil)
}
