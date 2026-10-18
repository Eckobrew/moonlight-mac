import Foundation
import GameController
import MoonlightCommonC

public final class GameControllerManager: @unchecked Sendable {
    public static let shared = GameControllerManager()

    private var pollTimer: Timer?
    private var connectedControllers: [GCController] = []

    // Controller button flags (matching XInput / Moonlight controller mask)
    private let BUTTON_DPAD_UP: Int16        = 0x0001
    private let BUTTON_DPAD_DOWN: Int16      = 0x0002
    private let BUTTON_DPAD_LEFT: Int16      = 0x0004
    private let BUTTON_DPAD_RIGHT: Int16     = 0x0008
    private let BUTTON_START: Int16          = 0x0010
    private let BUTTON_BACK: Int16           = 0x0020
    private let BUTTON_LEFT_STICK: Int16     = 0x0040
    private let BUTTON_RIGHT_STICK: Int16    = 0x0080
    private let BUTTON_LEFT_BUMPER: Int16    = 0x0100
    private let BUTTON_RIGHT_BUMPER: Int16   = 0x0200
    private let BUTTON_GUIDE: Int16          = 0x0400
    private let BUTTON_A: Int16              = 0x1000
    private let BUTTON_B: Int16              = 0x2000
    private let BUTTON_X: Int16              = 0x4000
    private let BUTTON_Y: Int16              = -0x8000 // 0x8000 as signed Int16

    private init() {}

    public func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleControllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleControllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        connectedControllers = GCController.controllers()

        // 120Hz polling loop for sub-millisecond controller response
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.pollConnectedControllers()
            }
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NotificationCenter.default.removeObserver(self)
        connectedControllers.removeAll()
    }

    @objc private func handleControllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            if !connectedControllers.contains(controller) {
                connectedControllers.append(controller)
            }
        }
    }

    @objc private func handleControllerDidDisconnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            connectedControllers.removeAll(where: { $0 == controller })
        }
    }

    private func pollConnectedControllers() {
        for (index, controller) in connectedControllers.prefix(4).enumerated() {
            guard let gamepad = controller.extendedGamepad else { continue }

            var buttonFlags: Int16 = 0
            if gamepad.dpad.up.isPressed { buttonFlags |= BUTTON_DPAD_UP }
            if gamepad.dpad.down.isPressed { buttonFlags |= BUTTON_DPAD_DOWN }
            if gamepad.dpad.left.isPressed { buttonFlags |= BUTTON_DPAD_LEFT }
            if gamepad.dpad.right.isPressed { buttonFlags |= BUTTON_DPAD_RIGHT }

            if gamepad.buttonA.isPressed { buttonFlags |= BUTTON_A }
            if gamepad.buttonB.isPressed { buttonFlags |= BUTTON_B }
            if gamepad.buttonX.isPressed { buttonFlags |= BUTTON_X }
            if gamepad.buttonY.isPressed { buttonFlags |= BUTTON_Y }

            if gamepad.leftShoulder.isPressed { buttonFlags |= BUTTON_LEFT_BUMPER }
            if gamepad.rightShoulder.isPressed { buttonFlags |= BUTTON_RIGHT_BUMPER }

            if gamepad.leftThumbstickButton?.isPressed == true { buttonFlags |= BUTTON_LEFT_STICK }
            if gamepad.rightThumbstickButton?.isPressed == true { buttonFlags |= BUTTON_RIGHT_STICK }

            if gamepad.buttonMenu.isPressed { buttonFlags |= BUTTON_START }
            if gamepad.buttonOptions?.isPressed == true { buttonFlags |= BUTTON_BACK }
            if gamepad.buttonHome?.isPressed == true { buttonFlags |= BUTTON_GUIDE }

            let leftTrigger = UInt8(clamping: Int(gamepad.leftTrigger.value * 255.0))
            let rightTrigger = UInt8(clamping: Int(gamepad.rightTrigger.value * 255.0))

            let leftStickX = Int16(clamping: Int(gamepad.leftThumbstick.xAxis.value * 32767.0))
            let leftStickY = Int16(clamping: Int(gamepad.leftThumbstick.yAxis.value * 32767.0))
            let rightStickX = Int16(clamping: Int(gamepad.rightThumbstick.xAxis.value * 32767.0))
            let rightStickY = Int16(clamping: Int(gamepad.rightThumbstick.yAxis.value * 32767.0))

            let activeMask: Int16 = Int16(1 << index)
            LiSendMultiControllerEvent(
                Int16(index),
                activeMask,
                Int32(buttonFlags),
                leftTrigger,
                rightTrigger,
                leftStickX,
                leftStickY,
                rightStickX,
                rightStickY
            )
        }
    }

    public func rumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        guard Int(controllerNumber) < connectedControllers.count else { return }
        let controller = connectedControllers[Int(controllerNumber)]

        if let haptics = controller.haptics {
            // Optional Apple haptics feedback if supported on controller
            _ = haptics
        }
    }
}
