//
//  MagicChordTests.swift
//  MoonlightMacTests
//

import Testing
import Foundation
import MoonlightCommonC
@testable import MoonlightMac

@Suite struct MagicChordTests {

    @Test func touchZoneThresholds() {
        let leftTouch = SurfaceTouch(id: 1, x: 0.30, y: 0.70, state: 4, timestamp: 1.0)
        let rightTouch = SurfaceTouch(id: 2, x: 0.70, y: 0.70, state: 4, timestamp: 1.0)
        let centerTouch = SurfaceTouch(id: 3, x: 0.50, y: 0.70, state: 4, timestamp: 1.0)
        let palmTouch = SurfaceTouch(id: 4, x: 0.30, y: 0.10, state: 4, timestamp: 1.0)

        #expect(leftTouch.zone(leftThreshold: 0.46, rightThreshold: 0.54, palmThreshold: 0.20) == .left)
        #expect(rightTouch.zone(leftThreshold: 0.46, rightThreshold: 0.54, palmThreshold: 0.20) == .right)
        #expect(centerTouch.zone(leftThreshold: 0.46, rightThreshold: 0.54, palmThreshold: 0.20) == .deadzone)
        #expect(palmTouch.zone(leftThreshold: 0.46, rightThreshold: 0.54, palmThreshold: 0.20) == .palmRejection)
    }

    @Test func simultaneousClickEmitsBothButtons() {
        let engine = MagicChordEngine()
        var emittedEvents: [(button: Int32, pressed: Bool)] = []
        engine.onButtonEvent = { btn, prs in
            emittedEvents.append((btn, prs))
        }

        // Fingers resting on left and right surface
        let touches = [
            SurfaceTouch(id: 1, x: 0.30, y: 0.80, state: 4, timestamp: 1.0),
            SurfaceTouch(id: 2, x: 0.70, y: 0.80, state: 4, timestamp: 1.0)
        ]
        engine.multitouchDeviceDidUpdateTouches(touches, timestamp: 1.0)

        // Physical switch clicked down (macOS reports leftMouseDown for 2-finger click)
        engine.handleMouseDown(button: BUTTON_LEFT)

        #expect(emittedEvents.contains(where: { $0.button == BUTTON_LEFT && $0.pressed == true }))
        #expect(emittedEvents.contains(where: { $0.button == BUTTON_RIGHT && $0.pressed == true }))

        let snap = engine.getSnapshot()
        #expect(snap.isBothButtonsActive == true)

        // Physical switch unclicked
        emittedEvents.removeAll()
        engine.handleMouseUp(button: BUTTON_LEFT)

        #expect(emittedEvents.contains(where: { $0.button == BUTTON_LEFT && $0.pressed == false }))
        #expect(emittedEvents.contains(where: { $0.button == BUTTON_RIGHT && $0.pressed == false }))
        #expect(engine.getSnapshot().isBothButtonsActive == false)
    }

    @Test func rightClickIntoBothDownViaSecondaryTouch() {
        let engine = MagicChordEngine()
        var emittedEvents: [(button: Int32, pressed: Bool)] = []
        engine.onButtonEvent = { btn, prs in
            emittedEvents.append((btn, prs))
        }

        // Right finger resting on right side
        engine.multitouchDeviceDidUpdateTouches([
            SurfaceTouch(id: 1, x: 0.75, y: 0.80, state: 4, timestamp: 1.0)
        ], timestamp: 1.0)

        // Physically right-click down
        engine.handleMouseDown(button: BUTTON_RIGHT)
        #expect(emittedEvents.count == 1)
        #expect(emittedEvents.first?.button == BUTTON_RIGHT && emittedEvents.first?.pressed == true)

        // While holding right-click, index finger touches left side (steering camera / both down)
        emittedEvents.removeAll()
        engine.multitouchDeviceDidUpdateTouches([
            SurfaceTouch(id: 1, x: 0.75, y: 0.80, state: 4, timestamp: 2.0),
            SurfaceTouch(id: 2, x: 0.25, y: 0.80, state: 4, timestamp: 2.0)
        ], timestamp: 2.0)

        #expect(emittedEvents.count == 1)
        #expect(emittedEvents.first?.button == BUTTON_LEFT && emittedEvents.first?.pressed == true)
        #expect(engine.getSnapshot().isBothButtonsActive == true)

        // Lift index finger while still holding physical switch
        emittedEvents.removeAll()
        engine.multitouchDeviceDidUpdateTouches([
            SurfaceTouch(id: 1, x: 0.75, y: 0.80, state: 4, timestamp: 3.0)
        ], timestamp: 3.0)

        #expect(emittedEvents.count == 1)
        #expect(emittedEvents.first?.button == BUTTON_LEFT && emittedEvents.first?.pressed == false)
        #expect(engine.getSnapshot().isRightButtonActive == true)
        #expect(engine.getSnapshot().isLeftButtonActive == false)

        // Finally release the physical switch
        emittedEvents.removeAll()
        engine.handleMouseUp(button: BUTTON_RIGHT)

        #expect(emittedEvents.count == 1)
        #expect(emittedEvents.first?.button == BUTTON_RIGHT && emittedEvents.first?.pressed == false)
    }

    @Test func resetReleasesAllActiveButtons() {
        let engine = MagicChordEngine()
        var released: [Int32] = []
        engine.onButtonEvent = { btn, prs in
            if !prs { released.append(btn) }
        }

        engine.multitouchDeviceDidUpdateTouches([
            SurfaceTouch(id: 1, x: 0.30, y: 0.80, state: 4, timestamp: 1.0),
            SurfaceTouch(id: 2, x: 0.70, y: 0.80, state: 4, timestamp: 1.0)
        ], timestamp: 1.0)
        engine.handleMouseDown(button: BUTTON_LEFT)

        #expect(engine.getSnapshot().isBothButtonsActive == true)

        // Stream focus lost (tabbed out) or stream disconnect
        engine.reset()

        #expect(released.contains(BUTTON_LEFT))
        #expect(released.contains(BUTTON_RIGHT))
        #expect(engine.getSnapshot().isBothButtonsActive == false)
    }
}
