import Foundation
import GameController
import MoonlightCommonC

public final class GameControllerManager: @unchecked Sendable {
    public static let shared = GameControllerManager()

    private let queue = DispatchQueue(label: "com.moonlight-stream.input.gamecontroller", qos: .userInteractive)
    private var pollTimer: DispatchSourceTimer?
    private var isRunning = false
    private let lock = NSLock()
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
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        connectedControllers = GCController.controllers()
        let hasControllers = !connectedControllers.isEmpty
        lock.unlock()

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

        if hasControllers {
            startPolling()
        }
    }

    public func stop() {
        NotificationCenter.default.removeObserver(self)
        lock.lock()
        isRunning = false
        connectedControllers.removeAll()
        lock.unlock()
        stopPolling()
    }

    private func startPolling() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pollTimer != nil { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                self?.pollConnectedControllers()
            }
            timer.resume()
            self.pollTimer = timer
        }
    }

    private func stopPolling() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pollTimer?.cancel()
            self.pollTimer = nil
        }
    }

    @objc private func handleControllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            lock.lock()
            if !connectedControllers.contains(controller) {
                connectedControllers.append(controller)
            }
            let shouldStart = isRunning
            lock.unlock()

            if shouldStart {
                startPolling()
            }
        }
    }

    @objc private func handleControllerDidDisconnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            lock.lock()
            connectedControllers.removeAll(where: { $0 == controller })
            let isEmpty = connectedControllers.isEmpty
            lock.unlock()

            if isEmpty {
                stopPolling()
            }
        }
    }

    private func pollConnectedControllers() {
        lock.lock()
        let controllers = connectedControllers
        lock.unlock()

        for (index, controller) in controllers.prefix(4).enumerated() {
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
        lock.lock()
        let controllers = connectedControllers
        lock.unlock()

        guard Int(controllerNumber) < controllers.count else { return }
        let controller = controllers[Int(controllerNumber)]

        if let haptics = controller.haptics {
            // Optional Apple haptics feedback if supported on controller
            _ = haptics
        }
    }
}
