//
//  TouchState.swift
//  MoonlightMac
//

import Foundation
import CoreGraphics

public enum MouseZone: Sendable {
    case left
    case right
    case deadzone
    case palmRejection
}

public struct SurfaceTouch: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let x: Double        // 0.0 (left) to 1.0 (right)
    public let y: Double        // 0.0 (palm/bottom) to 1.0 (top tip)
    public let state: Int32     // 3=make, 4=touching
    public let timestamp: Double

    public var isTouching: Bool {
        return state == 3 || state == 4
    }

    public func zone(leftThreshold: Double, rightThreshold: Double, palmThreshold: Double) -> MouseZone {
        if y < palmThreshold {
            return .palmRejection
        }
        if x <= leftThreshold {
            return .left
        }
        if x >= rightThreshold {
            return .right
        }
        return .deadzone
    }
}

/// Snapshot of engine state for thread-safe UI rendering in settings
public struct ChordEngineSnapshot: Equatable, Sendable {
    public var isLeftButtonActive: Bool = false
    public var isRightButtonActive: Bool = false
    public var isBothButtonsActive: Bool = false
    public var isLeftEmulated: Bool = false
    public var isRightEmulated: Bool = false
    public var hasLeftTouch: Bool = false
    public var hasRightTouch: Bool = false

    public init(
        isLeftButtonActive: Bool = false,
        isRightButtonActive: Bool = false,
        isBothButtonsActive: Bool = false,
        isLeftEmulated: Bool = false,
        isRightEmulated: Bool = false,
        hasLeftTouch: Bool = false,
        hasRightTouch: Bool = false
    ) {
        self.isLeftButtonActive = isLeftButtonActive
        self.isRightButtonActive = isRightButtonActive
        self.isBothButtonsActive = isBothButtonsActive
        self.isLeftEmulated = isLeftEmulated
        self.isRightEmulated = isRightEmulated
        self.hasLeftTouch = hasLeftTouch
        self.hasRightTouch = hasRightTouch
    }
}
