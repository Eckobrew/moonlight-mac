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
    /// Sign bit of the XInput button mask. Held as Int32 (`0x8000`, not `-0x8000`) so that
    /// combining it with other buttons does not sign-extend into 0xFFFF8000: the host parses this
    /// field as an unsigned 32-bit mask, and a sign-extended value does not match the Y bit.
    private let BUTTON_Y: Int32              = 0x8000

    /// Whether the host accepts touch events, queried lazily once the RTSP handshake completes.
    private var touchReportingChecked = false
    private var touchReportingEnabled = false

    /// Cached answer to "can this controller produce touch/motion data", so the poll loop does not
    /// re-run the protocol casts and capability query for every controller on every tick.
    private enum ControllerCapabilities {
        case basic            // no touchpad, no motion
        case touchOnly        // touchpad, no motion data
        case touchAndMotion
    }
    private var controllerCapabilities = [ControllerCapabilities?](repeating: nil, count: 4)

    /// Motion is sent no faster than the host asked for, and only when the sample changed.
    private var motionInterval: TimeInterval = 0
    private var lastMotionSendTime: TimeInterval = 0
    private var lastMotionValues: [(accel: (Float, Float, Float), gyro: (Float, Float, Float))?] =
        [nil, nil, nil, nil]


    /// Tracks which motion categories the host currently wants, so a per-category disable does not
    /// stop reporting for the other one.
    private let motionRequested = MotionRequestState()

    // Touch tracking per controller slot (edge detection for DOWN/MOVE/UP).
    private var primaryWasTouching = [Bool](repeating: false, count: 4)
    private var lastTouchX = [Float](repeating: 0, count: 4)
    private var lastTouchY = [Float](repeating: 0, count: 4)

    private final class MotionRequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var accelHz: UInt16 = 0
        private var gyroHz: UInt16 = 0

        func update(category: UInt8, hz: UInt16) {
            lock.lock()
            if category == UInt8(LI_MOTION_TYPE_ACCEL) { accelHz = hz } else { gyroHz = hz }
            lock.unlock()
        }

        /// Largest rate the host asked for; 0 when it disabled reporting entirely.
        var requestedHz: UInt16 {
            lock.lock(); defer { lock.unlock() }
            return max(accelHz, gyroHz)
        }
    }

    /// Applies a host motion-state change. Called from the connection listener thread.
    public func setMotionRequest(category: UInt8, reportRateHz: UInt16) {
        motionRequested.update(category: category, hz: reportRateHz)
        let hz = motionRequested.requestedHz
        lock.lock()
        motionReportingEnabledStorage = hz > 0
        // Honour the requested rate instead of always sending at the poll frequency.
        motionInterval = hz > 0 ? 1.0 / Double(hz) : 0
        if hz == 0 { lastMotionValues = [nil, nil, nil, nil] }
        lock.unlock()
    }

    /// Set when the host enables motion reporting via `ConnListenerSetMotionEventState`.
    /// Guarded by `lock` because the listener runs on the network thread and the poll loop reads it.
    private var motionReportingEnabledStorage = false
    var motionReportingEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return motionReportingEnabledStorage
    }

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
        touchReportingChecked = false
        touchReportingEnabled = false
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
        // These are also written by the poll queue; reset them under the same lock it uses.
        controllerCapabilities = [ControllerCapabilities?](repeating: nil, count: 4)
        lastMotionValues = [nil, nil, nil, nil]
        primaryWasTouching = [Bool](repeating: false, count: 4)
        lastTouchX = [Float](repeating: 0, count: 4)
        lastTouchY = [Float](repeating: 0, count: 4)
        touchReportingChecked = false
        touchReportingEnabled = false
        motionReportingEnabledStorage = false
        motionInterval = 0
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
                lastSentStates = [ControllerState?](repeating: nil, count: 4)
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
            controllerCapabilities = [ControllerCapabilities?](repeating: nil, count: 4)
            lastSentStates = [ControllerState?](repeating: nil, count: 4)
            lastMotionValues = [nil, nil, nil, nil]
            primaryWasTouching = [Bool](repeating: false, count: 4)
            lastTouchX = [Float](repeating: 0.5, count: 4)
            lastTouchY = [Float](repeating: 0.5, count: 4)
            // Array removal shifts later controllers into lower slots. Release the old
            // slots immediately, even when the last controller disappears and polling stops.
            if isRunning, removedIndex != nil {
                let count = min(connectedControllers.count, 4)
                let mask = Int16((1 << count) - 1)
                for slot in 0..<4 {
                    LiSendMultiControllerEvent(Int16(slot), mask, 0, 0, 0, 0, 0, 0, 0)
                }
            }
            let isEmpty = connectedControllers.isEmpty
            lock.unlock()

            // Release the haptics engine for the slot that disappeared.
            if removedIndex != nil {
                hapticsQueue.async { [weak self] in
                    self?.hapticEngines.removeAll()
                }
            }

            if isEmpty {
                stopPolling()
            }
        }
    }

    private func pollConnectedControllers() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        let controllers = connectedControllers

        // Slots that no longer have a controller must be forgotten so a reconnect re-sends state.
        for slot in min(controllers.count, lastSentStates.count)..<lastSentStates.count {
            lastSentStates[slot] = nil
            controllerCapabilities[slot] = nil
        }

        let activeCount = min(controllers.count, 4)
        let activeMask: Int16 = activeCount > 0 ? Int16((1 << activeCount) - 1) : 0

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
                // BUTTON_Y is the 0x8000 bit; combine in the unsigned 32-bit domain, then feed the
                // low 16 bits as the limelight mask (which is an int32 on the wire).
                buttons: Int32(UInt16(bitPattern: buttonFlags)) | (gamepad.buttonY.isPressed ? BUTTON_Y : 0),
                leftTrigger: leftTrigger,
                rightTrigger: rightTrigger,
                leftStickX: leftStickX,
                leftStickY: leftStickY,
                rightStickX: rightStickX,
                rightStickY: rightStickY
            )

            if lastSentStates[index] != state {
                lastSentStates[index] = state

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

            // Touchpad is sampled every tick (not change-gated by button/stick state) because the
            // library needs DOWN/MOVE/UP edges, which the helper derives from its own per-slot state.
            if capabilities(of: controller, slot: index) != .basic {
                sendTouchState(for: gamepad, controllerSlot: index, activeMask: activeMask)
            }
        }

        sendPendingMotion(controllers: controllers)
    }

    /// Sends motion at most once per host-requested interval, and only when the sample changed.
    private func sendPendingMotion(controllers: [GCController]) {
        // Called with the manager lock held by the poll loop.
        guard motionReportingEnabledStorage else { return }

        let now = CACurrentMediaTime()
        guard now - lastMotionSendTime >= motionInterval else { return }
        lastMotionSendTime = now

        for (index, controller) in controllers.prefix(4).enumerated() {
            guard capabilities(of: controller, slot: index) == .touchAndMotion,
                  let motion = controller.motion else { continue }

            let gravity = 9.80665
            let radiansToDegrees = 180.0 / Double.pi

            let accel = motion.acceleration
            let gyro = motion.rotationRate
            let ax = Float(accel.x * gravity), ay = Float(accel.y * gravity), az = Float(accel.z * gravity)
            let gx = Float(gyro.x * radiansToDegrees), gy = Float(gyro.y * radiansToDegrees), gz = Float(gyro.z * radiansToDegrees)

            // Suppress redundant samples: an idle controller reports the same gravity vector forever.
            if let previous = lastMotionValues[index],
               previous.accel == (ax, ay, az), previous.gyro == (gx, gy, gz) {
                continue
            }
            lastMotionValues[index] = (accel: (ax, ay, az), gyro: (gx, gy, gz))

            LiSendControllerMotionEvent(UInt8(index), UInt8(LI_MOTION_TYPE_ACCEL), ax, ay, az)
            LiSendControllerMotionEvent(UInt8(index), UInt8(LI_MOTION_TYPE_GYRO), gx, gy, gz)
        }
    }

    /// Cached protocol classification, so the poll loop avoids repeated casts every frame.
    private func capabilities(of controller: GCController, slot: Int) -> ControllerCapabilities {
        if let cached = controllerCapabilities[slot] { return cached }

        let resolved: ControllerCapabilities
        if let gamepad = controller.extendedGamepad,
           gamepad is GCDualShockGamepad || gamepad is GCDualSenseGamepad {
            resolved = controller.motion != nil ? .touchAndMotion : .touchOnly
        } else {
            resolved = .basic
        }
        controllerCapabilities[slot] = resolved
        return resolved
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

    // MARK: - Touchpad (DS4 / DualSense)

    /// Whether the host asked for touch events (`LiGetHostFeatureFlags()`). Sampled once per
    /// session in `start()`; calling into the library per frame took its control lock.
    private var hostSupportsTouch: Bool { touchReportingEnabled }

    /// Pushes a DualShock/DualSense touchpad sample to the host.
    ///
    /// macOS reports the touchpad as a single `GCControllerTouchpad` whose `fingerPosition` is
    /// normalized to -1...1 with the origin at the center; Limelight expects 0...1 with the origin
    /// at the top-left. Only controllers in `GCDualShockGamepad`/`GCDualSenseGamepad` expose it.
    func sendTouchState(for gamepad: GCExtendedGamepad, controllerSlot: Int, activeMask: Int16) {
        if !touchReportingChecked {
            let flags = LiGetHostFeatureFlags()
            if flags != 0 {
                touchReportingChecked = true
                touchReportingEnabled = (flags & UInt32(bitPattern: LI_FF_CONTROLLER_TOUCH_EVENTS)) != 0
            } else {
                touchReportingEnabled = (flags & UInt32(bitPattern: LI_FF_CONTROLLER_TOUCH_EVENTS)) != 0
            }
        }
        guard touchReportingEnabled else { return }

        // DS4/DualSense expose the touchpad as a direction pad plus a click button. macOS does NOT
        // report a per-finger touch-down state (GCControllerDirectionPad has no `isTouched`), so a
        // finger-down is inferred: the position leaving its resting value, or the pad being clicked.
        let primary: GCControllerDirectionPad
        let clicked: Bool
        if let dualSense = gamepad as? GCDualSenseGamepad {
            primary = dualSense.touchpadPrimary
            clicked = dualSense.touchpadButton.isPressed
        } else if let dualShock = gamepad as? GCDualShockGamepad {
            primary = dualShock.touchpadPrimary
            clicked = dualShock.touchpadButton.isPressed
        } else {
            return
        }

        let pointerId: UInt32 = 0

        // GCController normalizes to -1...1 from the center; Limelight wants 0...1 from top-left.
        let x = Float((Double(primary.xAxis.value) + 1.0) / 2.0)
        let y = Float((Double(primary.yAxis.value) + 1.0) / 2.0)
        let moved = x != lastTouchX[controllerSlot] || y != lastTouchY[controllerSlot]

        // Treat a click as an explicit touch, and any movement far from the resting point as one.
        let awayFromRest = abs(x - 0.5) > 0.02 || abs(y - 0.5) > 0.02
        let touched = clicked || moved || awayFromRest

        let eventType: UInt8
        if touched && !primaryWasTouching[controllerSlot] {
            eventType = UInt8(LI_TOUCH_EVENT_DOWN)
        } else if touched && moved {
            eventType = UInt8(LI_TOUCH_EVENT_MOVE)
        } else if !touched && primaryWasTouching[controllerSlot] {
            eventType = UInt8(LI_TOUCH_EVENT_UP)
        } else {
            return
        }
        primaryWasTouching[controllerSlot] = touched

        let pressure: Float = touched ? 1.0 : 0.0
        var mutableX = x
        var mutableY = y
        if eventType == UInt8(LI_TOUCH_EVENT_UP) {
            // Release at the last known position.
            mutableX = lastTouchX[controllerSlot]
            mutableY = lastTouchY[controllerSlot]
        } else {
            lastTouchX[controllerSlot] = x
            lastTouchY[controllerSlot] = y
        }

        _ = activeMask
        LiSendControllerTouchEvent2(
            UInt8(controllerSlot),
            eventType,
            0,
            pointerId,
            mutableX,
            mutableY,
            pressure
        )
    }

    // MARK: - Motion (DUALSHOCK 4 / DualSense)

    /// Motion is NOT gated by a feature flag: the library only reports whether the host supports
    /// touch (LI_FF_CONTROLLER_TOUCH_EVENTS). Motion is enabled solely by the host asking for it
    /// through `ConnListenerSetMotionEventState`, which feeds `motionInterval` and
    /// `motionReportingEnabled`. Samples are packed by `sendPendingMotion`.
}
