import Foundation
import GameController
import CoreHaptics
import MoonlightCommonC

public final class GameControllerManager: @unchecked Sendable {
    public static let shared = GameControllerManager()

    private let queue = DispatchQueue(label: "com.moonlight-stream.input.gamecontroller", qos: .userInteractive)
    private var pollTimer: DispatchSourceTimer?
    private var isRunning = false
    private let lock = NSLock()
    private var connectedControllers: [GCController] = []

    // Last state sent per controller slot. Polling runs at 125 Hz; without this, an idle controller
    // still produces a full input packet every tick (31 KB/s of pure noise on the network).
    private struct ControllerState: Equatable {
        var buttons: Int32 = 0
        var leftTrigger: UInt8 = 0
        var rightTrigger: UInt8 = 0
        var leftStickX: Int16 = 0
        var leftStickY: Int16 = 0
        var rightStickX: Int16 = 0
        var rightStickY: Int16 = 0
    }
    private var lastSentStates = [ControllerState?](repeating: nil, count: 4)

    // Rumble state per controller slot, independent of the input polling queue.
    private let hapticsQueue = DispatchQueue(label: "com.moonlight-stream.input.haptics", qos: .userInitiated)
    private var hapticEngines: [Int: RumbleDriver] = [:]

    /// Drives one game controller's haptics from Limelight's two-motor rumble model.
    ///
    /// Limelight reports a low-frequency (left, "big") and high-frequency (right, "small") motor,
    /// each 0...65535. Core Haptics has no dual-motor API, so both are folded into one continuous
    /// event: intensity follows the stronger motor, sharpness follows the high-frequency motor.
    /// Confined to `hapticsQueue`.
    private final class RumbleDriver {
        private let engine: CHHapticEngine
        private var lastApplied: UInt32 = 0
        private var activePlayer: CHHapticPatternPlayer?

        /// Rumble is re-sent while active; a short continuous event refreshed on each update keeps
        /// the motor running without retriggering at the packet rate.
        private static let continuousDuration: TimeInterval = 0.25

        init?(controller: GCController) {
            guard let engine = controller.haptics?.createEngine(withLocality: .default) else { return nil }
            self.engine = engine

            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { _ in }
            engine.resetHandler = { [weak engine] in
                try? engine?.start()
            }

            do {
                try engine.start()
            } catch {
                AppLogger.shared.warning("[Rumble] Failed to start haptics engine: \(error.localizedDescription)", category: "Input")
                return nil
            }
        }

        deinit {
            engine.stop()
        }

        func apply(low: UInt16, high: UInt16) {
            // Skip redundant updates: games often resend the same rumble value every frame.
            let packed = (UInt32(low) << 16) | UInt32(high)
            guard packed != lastApplied else { return }
            lastApplied = packed

            guard low > 0 || high > 0 else {
                try? activePlayer?.stop(atTime: CHHapticTimeImmediate)
                activePlayer = nil
                return
            }

            let lowNorm = Float(low) / 65535.0
            let highNorm = Float(high) / 65535.0

            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: max(lowNorm, highNorm))
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: highNorm)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: Self.continuousDuration
            )

            do {
                // Restart the previous event rather than stacking players, so long rumble does not
                // accumulate one active player per update.
                try activePlayer?.stop(atTime: CHHapticTimeImmediate)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
                activePlayer = player
            } catch {
                AppLogger.shared.debug("[Rumble] Failed to play haptic pattern: \(error.localizedDescription)", category: "Input")
            }
        }
    }

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
        lastSentStates = [ControllerState?](repeating: nil, count: 4)
        lock.unlock()
        stopPolling()

        hapticsQueue.async { [weak self] in
            self?.hapticEngines.removeAll()
        }
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
            let removedIndex = connectedControllers.firstIndex(of: controller)
            connectedControllers.removeAll(where: { $0 == controller })
            let isEmpty = connectedControllers.isEmpty
            lock.unlock()

            // Release the haptics engine for the slot that disappeared.
            if let removedIndex = removedIndex {
                hapticsQueue.async { [weak self] in
                    self?.hapticEngines[removedIndex] = nil
                }
            }

            if isEmpty {
                stopPolling()
            }
        }
    }

    private func pollConnectedControllers() {
        lock.lock()
        let controllers = connectedControllers
        lock.unlock()

        // Slots that no longer have a controller must be forgotten so a reconnect re-sends state.
        for slot in controllers.count..<lastSentStates.count {
            lastSentStates[slot] = nil
        }

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

            let state = ControllerState(
                buttons: Int32(buttonFlags),
                leftTrigger: leftTrigger,
                rightTrigger: rightTrigger,
                leftStickX: leftStickX,
                leftStickY: leftStickY,
                rightStickX: rightStickX,
                rightStickY: rightStickY
            )

            guard lastSentStates[index] != state else { continue }
            lastSentStates[index] = state

            let activeMask: Int16 = Int16(1 << index)
            LiSendMultiControllerEvent(
                Int16(index),
                activeMask,
                state.buttons,
                state.leftTrigger,
                state.rightTrigger,
                state.leftStickX,
                state.leftStickY,
                state.rightStickX,
                state.rightStickY
            )
        }
    }

    public func rumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        // Runs on the Limelight video/control callback thread: never do haptics work inline.
        hapticsQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let controllers = self.connectedControllers
            self.lock.unlock()

            let slot = Int(controllerNumber)
            guard slot < controllers.count else { return }

            let driver: RumbleDriver
            if let existing = self.hapticEngines[slot] {
                driver = existing
            } else {
                guard let created = RumbleDriver(controller: controllers[slot]) else { return }
                self.hapticEngines[slot] = created
                driver = created
            }

            driver.apply(low: lowFreqMotor, high: highFreqMotor)
        }
    }
}
