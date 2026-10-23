import Foundation

/// AppKit focus recovery never activates the app or moves it to another Space.
struct StreamMouseFocus {
    var requested = true
    var appActive = true
    var windowKey = true
    var otherKeyWindow = false
    var visible = true
    var onActiveSpace = true
    var blockedByDialog = false
    var minimized = false

    enum Action: Equatable { case release, capture, restoreKeyWindow }

    var action: Action {
        guard requested, appActive, visible, onActiveSpace,
              !blockedByDialog, !minimized, !otherKeyWindow else { return .release }
        return windowKey ? .capture : .restoreKeyWindow
    }
}

/// Matches SDL2's Cocoa delta conversion before optional user sensitivity scaling.
/// No extra acceleration, smoothing or native-delta fractional accumulation.
struct RelativeMouseMotion {
    private var remainderX = 0.0
    private var remainderY = 0.0

    mutating func reset() { remainderX = 0; remainderY = 0 }

    mutating func consume(x: Double, y: Double, scaleX: Double, scaleY: Double,
                          accumulateSensitivity: Bool) -> (x: Int16, y: Int16) {
        guard x.isFinite, y.isFinite, scaleX.isFinite, scaleY.isFinite else { return (0, 0) }
        let dx = x.rounded(.towardZero) * scaleX + (accumulateSensitivity ? remainderX : 0)
        let dy = y.rounded(.towardZero) * scaleY + (accumulateSensitivity ? remainderY : 0)
        guard dx.isFinite, dy.isFinite else { reset(); return (0, 0) }
        let integralX = dx.rounded(.towardZero)
        let integralY = dy.rounded(.towardZero)
        remainderX = accumulateSensitivity ? dx - integralX : 0
        remainderY = accumulateSensitivity ? dy - integralY : 0
        return (Int16(max(Double(Int16.min), min(Double(Int16.max), integralX))),
                Int16(max(Double(Int16.min), min(Double(Int16.max), integralY))))
    }
}

enum MouseWheelMotion {
    static func consume(x: Double, y: Double, precise: Bool) -> (x: Int16, y: Int16) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        // SDL's Cocoa backend flips X, preserves Y, and expands discrete wheel
        // movement to full ticks before moonlight-qt's acceleration clamp.
        func wheel(_ delta: Double) -> Int16 {
            let value = precise ? delta : delta.rounded(.awayFromZero)
            return Int16(max(-1, min(1, value)) * 120)
        }
        return (wheel(-x), wheel(y))
    }
}
