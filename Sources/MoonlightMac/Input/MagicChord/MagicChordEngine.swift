//
//  MagicChordEngine.swift
//  MoonlightMac
//

import Foundation
import MoonlightCommonC

public final class MagicChordEngine: MultitouchDeviceManagerDelegate, @unchecked Sendable {
    public static let shared = MagicChordEngine()

    public var onButtonEvent: ((_ button: Int32, _ pressed: Bool) -> Void)?

    public var leftThreshold: Double = 0.46
    public var rightThreshold: Double = 0.54
    public var palmThreshold: Double = 0.20

    private var isLeftDownInStream: Bool = false
    private var isRightDownInStream: Bool = false
    private var isPhysicalSwitchDown: Bool = false
    private var initialPhysicalButton: Int32? = nil

    private var hasLeftTouch: Bool = false
    private var hasRightTouch: Bool = false

    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    public init() {
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deallocate()
    }

    // MARK: - Snapshot for Settings Visualizer

    public func getSnapshot() -> ChordEngineSnapshot {
        os_unfair_lock_lock(lock)
        let leftDown = isLeftDownInStream
        let rightDown = isRightDownInStream
        let initial = initialPhysicalButton
        let leftTouch = hasLeftTouch
        let rightTouch = hasRightTouch

        let isLeftEmu = leftDown && initial != BUTTON_LEFT
        let isRightEmu = rightDown && initial != BUTTON_RIGHT

        let snapshot = ChordEngineSnapshot(
            isLeftButtonActive: leftDown,
            isRightButtonActive: rightDown,
            isBothButtonsActive: leftDown && rightDown,
            isLeftEmulated: isLeftEmu,
            isRightEmulated: isRightEmu,
            hasLeftTouch: leftTouch,
            hasRightTouch: rightTouch
        )
        os_unfair_lock_unlock(lock)
        return snapshot
    }

    // MARK: - Multitouch Device Updates

    public func multitouchDeviceDidUpdateTouches(_ touches: [SurfaceTouch], timestamp: Double) {
        let leftThresh = leftThreshold
        let rightThresh = rightThreshold
        let palmThresh = palmThreshold

        var currentLeftTouch = false
        var currentRightTouch = false

        for t in touches where t.isTouching {
            switch t.zone(leftThreshold: leftThresh, rightThreshold: rightThresh, palmThreshold: palmThresh) {
            case .left:
                currentLeftTouch = true
            case .right:
                currentRightTouch = true
            case .deadzone, .palmRejection:
                break
            }
        }

        var shouldPressLeft = false
        var shouldReleaseLeft = false
        var shouldPressRight = false
        var shouldReleaseRight = false

        os_unfair_lock_lock(lock)
        self.hasLeftTouch = currentLeftTouch
        self.hasRightTouch = currentRightTouch

        if isPhysicalSwitchDown {
            // Secondary touch brought down while clicking
            if currentLeftTouch && !isLeftDownInStream {
                isLeftDownInStream = true
                shouldPressLeft = true
            } else if !currentLeftTouch && isLeftDownInStream {
                // Left finger lifted: release left button
                isLeftDownInStream = false
                shouldReleaseLeft = true
            }

            if currentRightTouch && !isRightDownInStream {
                isRightDownInStream = true
                shouldPressRight = true
            } else if !currentRightTouch && isRightDownInStream {
                // Right finger lifted: release right button
                isRightDownInStream = false
                shouldReleaseRight = true
            }
        }
        os_unfair_lock_unlock(lock)

        if shouldPressLeft { onButtonEvent?(BUTTON_LEFT, true) }
        if shouldReleaseLeft { onButtonEvent?(BUTTON_LEFT, false) }
        if shouldPressRight { onButtonEvent?(BUTTON_RIGHT, true) }
        if shouldReleaseRight { onButtonEvent?(BUTTON_RIGHT, false) }
    }

    public var isAnyButtonActive: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return isLeftDownInStream || isRightDownInStream || isPhysicalSwitchDown
    }

    // MARK: - Physical Click Events from Magic Mouse

    public func handleMouseDown(button: Int32) {
        var pressButtons: [Int32] = []

        os_unfair_lock_lock(lock)
        isPhysicalSwitchDown = true

        let leftTouch = hasLeftTouch
        let rightTouch = hasRightTouch

        if leftTouch && rightTouch {
            // Both fingers touching: chord both down!
            isLeftDownInStream = true
            isRightDownInStream = true
            initialPhysicalButton = button
            pressButtons.append(BUTTON_LEFT)
            pressButtons.append(BUTTON_RIGHT)
        } else if rightTouch && !leftTouch {
            // Only right finger touching: right click!
            isRightDownInStream = true
            initialPhysicalButton = BUTTON_RIGHT
            pressButtons.append(BUTTON_RIGHT)
        } else if leftTouch && !rightTouch {
            // Only left finger touching: left click!
            isLeftDownInStream = true
            initialPhysicalButton = BUTTON_LEFT
            pressButtons.append(BUTTON_LEFT)
        } else {
            // Fallback to the reported OS button (e.g. click in deadzone)
            initialPhysicalButton = button
            if button == BUTTON_LEFT {
                isLeftDownInStream = true
                pressButtons.append(BUTTON_LEFT)
            } else if button == BUTTON_RIGHT {
                isRightDownInStream = true
                pressButtons.append(BUTTON_RIGHT)
            } else {
                pressButtons.append(button)
            }
        }
        os_unfair_lock_unlock(lock)

        for btn in pressButtons {
            onButtonEvent?(btn, true)
        }
    }

    public func handleMouseUp(button: Int32) {
        var releaseButtons: [Int32] = []

        os_unfair_lock_lock(lock)
        isPhysicalSwitchDown = false
        initialPhysicalButton = nil

        if isLeftDownInStream {
            isLeftDownInStream = false
            releaseButtons.append(BUTTON_LEFT)
        }
        if isRightDownInStream {
            isRightDownInStream = false
            releaseButtons.append(BUTTON_RIGHT)
        }

        if button != BUTTON_LEFT && button != BUTTON_RIGHT {
            releaseButtons.append(button)
        }
        os_unfair_lock_unlock(lock)

        for btn in releaseButtons {
            onButtonEvent?(btn, false)
        }
    }

    public func reset() {
        var releaseButtons: [Int32] = []

        os_unfair_lock_lock(lock)
        if isLeftDownInStream {
            isLeftDownInStream = false
            releaseButtons.append(BUTTON_LEFT)
        }
        if isRightDownInStream {
            isRightDownInStream = false
            releaseButtons.append(BUTTON_RIGHT)
        }
        isPhysicalSwitchDown = false
        initialPhysicalButton = nil
        hasLeftTouch = false
        hasRightTouch = false
        os_unfair_lock_unlock(lock)

        for btn in releaseButtons {
            onButtonEvent?(btn, false)
        }
    }
}
