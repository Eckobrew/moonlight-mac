import Foundation
import AppKit
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
    private var lastSentStates = [ControllerState?](repeating: nil, count: 16)

    // Rumble state per controller slot, independent of the input polling queue.
    private let hapticsQueue = DispatchQueue(label: "com.moonlight-stream.input.haptics", qos: .userInitiated)
    private var hapticEngines: [Int: RumbleDriver] = [:]

    /// Drives one game controller's haptics from Limelight's two-motor rumble model.
    ///
    /// Limelight reports a low-frequency (left, "big") and high-frequency (right, "small") motor,
    /// each 0...65535. Core Haptics has no dual-motor API, so both are folded into one continuous
    /// event: intensity follows the stronger motor, sharpness follows the high-frequency motor.
    /// Confined to `hapticsQueue`.
    private final class RumbleDriver: @unchecked Sendable {
        private let engine: CHHapticEngine
        private var lastApplied: UInt32?
        private var requested: (low: UInt16, high: UInt16) = (0, 0)
        private let queue: DispatchQueue
        private var activePlayer: CHHapticAdvancedPatternPlayer?

        /// Loop the continuous event until the host changes or stops its request.
        private static let continuousDuration: TimeInterval = 0.25

        init?(controller: GCController, queue: DispatchQueue, locality: GCHapticsLocality = .default) {
            guard let engine = controller.haptics?.createEngine(withLocality: locality) else { return nil }
            self.engine = engine
            self.queue = queue

            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.lastApplied = nil
                    self?.activePlayer = nil
                }
            }
            engine.resetHandler = { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.lastApplied = nil
                    self.activePlayer = nil
                    do {
                        try self.engine.start()
                        self.apply(low: self.requested.low, high: self.requested.high)
                    } catch {
                        AppLogger.shared.warning("[Rumble] Engine recovery failed: \(error.localizedDescription)", category: "Input")
                    }
                }
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
            requested = (low, high)
            let packed = (UInt32(low) << 16) | UInt32(high)
            guard packed != lastApplied else { return }

            guard low > 0 || high > 0 else {
                try? activePlayer?.stop(atTime: CHHapticTimeImmediate)
                activePlayer = nil
                lastApplied = packed
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
                try engine.start()
                try activePlayer?.stop(atTime: CHHapticTimeImmediate)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makeAdvancedPlayer(with: pattern)
                player.loopEnabled = true
                player.loopEnd = Self.continuousDuration
                try player.start(atTime: CHHapticTimeImmediate)
                activePlayer = player
                lastApplied = packed
            } catch {
                lastApplied = nil
                AppLogger.shared.debug("[Rumble] Failed to play haptic pattern: \(error.localizedDescription)", category: "Input")
            }
        }
    }

    private struct NativeProfile {
        let buttons: [(GCControllerButtonInput, Int32)]
        let touchpads: [GCControllerTouchpad]
    }
    private var supportsControllerTouch = false
    private var nativeProfiles: [ObjectIdentifier: NativeProfile] = [:]
    private static let extraButtons: [(String, Int32)] = [
        (GCInputButtonShare, MISC_FLAG), (GCInputXboxPaddleOne, PADDLE1_FLAG),
        (GCInputXboxPaddleTwo, PADDLE2_FLAG), (GCInputXboxPaddleThree, PADDLE3_FLAG),
        (GCInputXboxPaddleFour, PADDLE4_FLAG), (GCInputDualShockTouchpadButton, TOUCHPAD_FLAG)
    ]

    /// Native profile layout is stable until disconnect. Resolve aliases and sort
    /// touchpads once, rather than rebuilding dictionaries at 125 Hz.
    private func nativeProfile(for controller: GCController) -> NativeProfile {
        let id = ObjectIdentifier(controller)
        if let cached = nativeProfiles[id] { return cached }
        let profile = controller.physicalInputProfile
        let buttons = Self.extraButtons.compactMap { name, flag -> (GCControllerButtonInput, Int32)? in
            profile.buttons[name].map { ($0, flag) }
        }
        var seen = Set<ObjectIdentifier>()
        let touchpads = profile.touchpads.keys.sorted().compactMap { name -> GCControllerTouchpad? in
            guard let touchpad = profile.touchpads[name], seen.insert(ObjectIdentifier(touchpad)).inserted else { return nil }
            return touchpad
        }
        let resolved = NativeProfile(buttons: buttons, touchpads: Array(touchpads.prefix(2)))
        nativeProfiles[id] = resolved
        return resolved
    }

    private var preferences = ClientFeatures()
    private var slotLimit = 4
    private var appFocused = true
    private var announced = Set<Int>()
    private var focusObservers: [NSObjectProtocol] = []
    private var touchStates: [Int: [Int: SIMD2<Float>]] = [:]
    private var lastBattery: [Int: String] = [:]
    private var lastBatteryPoll: TimeInterval = 0
    private var menuPressedAt: [Int: TimeInterval] = [:]
    private var mouseEmulation = Set<Int>()
    private var mouseButtons: [Int: (Bool, Bool)] = [:]

    @MainActor public func configure(_ preferences: ClientFeatures, extendedSlots: Bool = true) {
        lock.withLock { self.preferences = preferences; slotLimit = extendedSlots ? 16 : 4; appFocused = NSApp.isActive }
    }

    /// The same bitmap is sent during launch and controller arrival.
    @MainActor public static func launchMask(persistent: Bool, extendedSlots: Bool = true) -> UInt16 {
        let count = min(extendedSlots ? 16 : 4, GCController.controllers().filter { $0.extendedGamepad != nil }.count)
        return persistent ? 1 : count == 16 ? .max : UInt16((1 << count) - 1)
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

    private var motionRequests = ControllerMotionRequests()

    /// Called on the connection listener thread; polling reads under the same lock.
    public func setMotionRequest(controllerNumber: UInt16, category: UInt8, reportRateHz: UInt16) {
        lock.lock()
        guard isRunning, Int(controllerNumber) < min(slotLimit, connectedControllers.count),
              category == UInt8(LI_MOTION_TYPE_ACCEL) || category == UInt8(LI_MOTION_TYPE_GYRO) else { lock.unlock(); return }
        if category == UInt8(LI_MOTION_TYPE_GYRO), connectedControllers[Int(controllerNumber)].motion?.hasRotationRate != true { lock.unlock(); return }
        motionRequests.update(slot: Int(controllerNumber), category: category, hz: reportRateHz)
        if Int(controllerNumber) < connectedControllers.count {
            connectedControllers[Int(controllerNumber)].motion?.sensorsActive = motionRequests.isEnabled(slot: Int(controllerNumber))
        }
        lock.unlock()
    }

    private init() {}

    public func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        supportsControllerTouch = LiGetHostFeatureFlags() & UInt32(LI_FF_CONTROLLER_TOUCH_EVENTS) != 0
        nativeProfiles.removeAll()
        connectedControllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        let hasControllers = !connectedControllers.isEmpty || preferences.persistentGamepad
        announced.removeAll()
        lastBattery.removeAll()
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

        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: OperationQueue.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppFocused(NSApp.isActive) }
            })
        }
        if hasControllers { startPolling() }
    }

    private func setAppFocused(_ focused: Bool) {
        lock.withLock {
            appFocused = focused
            if !focused && !preferences.backgroundGamepad { releaseInputState() }
        }
    }

    private func releaseInputState() {
        for slot in 0..<16 where announced.contains(slot) {
            LiSendMultiControllerEvent(Int16(slot), Int16(bitPattern: activeMask), 0, 0, 0, 0, 0, 0, 0)
            cancelTouches(slot: slot)
        }
        for (_, buttons) in mouseButtons {
            if buttons.0 { LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_LEFT) }
            if buttons.1 { LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), BUTTON_RIGHT) }
        }
        mouseButtons.removeAll()
        lastSentStates = [ControllerState?](repeating: nil, count: 16)
    }

    private var activeMask: UInt16 {
        let count = min(slotLimit, connectedControllers.count)
        return preferences.persistentGamepad ? 1 : count == 16 ? .max : UInt16((1 << count) - 1)
    }

    public func stop() {
        NotificationCenter.default.removeObserver(self)
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.removeAll()
        lock.lock()
        releaseInputState()
        for controller in connectedControllers {
            controller.motion?.sensorsActive = false
            if let sony = controller.extendedGamepad as? GCDualSenseGamepad {
                sony.leftTrigger.setModeOff(); sony.rightTrigger.setModeOff()
            }
        }
        isRunning = false
        announced.removeAll()
        mouseEmulation.removeAll()
        menuPressedAt.removeAll()
        connectedControllers.removeAll()
        nativeProfiles.removeAll()
        lastSentStates = [ControllerState?](repeating: nil, count: 16)
        // These are also written by the poll queue; reset them under the same lock it uses.
        motionRequests.reset()
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
            if controller.extendedGamepad != nil && !connectedControllers.contains(controller) {
                connectedControllers.append(controller)
                announced.removeAll()
                lastSentStates = [ControllerState?](repeating: nil, count: 16)
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
            releaseInputState()
            controller.motion?.sensorsActive = false
            connectedControllers.removeAll(where: { $0 == controller })
            nativeProfiles[ObjectIdentifier(controller)] = nil
            mouseEmulation.removeAll()
            menuPressedAt.removeAll()
            if let sony = controller.extendedGamepad as? GCDualSenseGamepad { sony.leftTrigger.setModeOff(); sony.rightTrigger.setModeOff() }
            announced.removeAll()
            lastSentStates = [ControllerState?](repeating: nil, count: 16)
            motionRequests.reset()
            // Array removal shifts later controllers into lower slots. Release the old
            // slots immediately, even when the last controller disappears and polling stops.
            if isRunning, removedIndex != nil {
                let mask = Int16(bitPattern: activeMask)
                for slot in 0..<16 {
                    LiSendMultiControllerEvent(Int16(slot), mask, 0, 0, 0, 0, 0, 0, 0)
                }
            }
            let isEmpty = connectedControllers.isEmpty && !preferences.persistentGamepad
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
        guard isRunning, appFocused || preferences.backgroundGamepad else { return }
        let controllers = connectedControllers

        // Slots that no longer have a controller must be forgotten so a reconnect re-sends state.
        for slot in min(controllers.count, lastSentStates.count)..<lastSentStates.count {
            lastSentStates[slot] = nil
        }

        let mask = activeMask
        if controllers.isEmpty && preferences.persistentGamepad {
            if !announced.contains(0), LiSendControllerArrivalEvent(0, 1, UInt8(LI_CTYPE_UNKNOWN), 0xFFFF, 0) == 0 { announced.insert(0) }
            if announced.contains(0) { send(ControllerState(), slot: 0, mask: 1) }
        }
        var merged = ControllerState()
        for (index, controller) in controllers.prefix(slotLimit).enumerated() {
            guard let gamepad = controller.extendedGamepad else { continue }
            let slot = preferences.persistentGamepad ? 0 : index
            announce(controller, slot: slot, mask: mask)
            guard announced.contains(slot) else { continue }

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

            var state = ControllerState(
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

            for (button, flag) in nativeProfile(for: controller).buttons where button.isPressed { state.buttons |= flag }
            if preferences.swapFaceButtons {
                let original = state.buttons
                state.buttons &= ~(Int32(A_FLAG | B_FLAG | X_FLAG | Y_FLAG))
                if original & A_FLAG != 0 { state.buttons |= B_FLAG }
                if original & B_FLAG != 0 { state.buttons |= A_FLAG }
                if original & X_FLAG != 0 { state.buttons |= Y_FLAG }
                if original & Y_FLAG != 0 { state.buttons |= X_FLAG }
            }
            if preferences.gamepadMouse && emulateMouse(controller: controller, slot: index) { state = ControllerState() }
            if preferences.persistentGamepad {
                merged.buttons |= state.buttons
                merged.leftTrigger = max(merged.leftTrigger, state.leftTrigger)
                merged.rightTrigger = max(merged.rightTrigger, state.rightTrigger)
                func larger(_ a: Int16, _ b: Int16) -> Int16 { abs(Int(a)) > abs(Int(b)) ? a : b }
                merged.leftStickX = larger(merged.leftStickX, state.leftStickX); merged.leftStickY = larger(merged.leftStickY, state.leftStickY)
                merged.rightStickX = larger(merged.rightStickX, state.rightStickX); merged.rightStickY = larger(merged.rightStickY, state.rightStickY)
            } else { send(state, slot: slot, mask: mask) }
            if !preferences.persistentGamepad || index == 0 { sendTouchState(for: controller, slot: slot) }
        }
        if preferences.persistentGamepad && !controllers.isEmpty { send(merged, slot: 0, mask: mask) }
        reportBattery(controllers)

        sendPendingMotion(controllers: controllers)
    }

    /// Sends motion at most once per host-requested interval, and only when the sample changed.
    private func sendPendingMotion(controllers: [GCController]) {
        // Called with the manager lock held by the poll loop.
        let now = CACurrentMediaTime()

        for (index, controller) in controllers.prefix(preferences.persistentGamepad ? 1 : slotLimit).enumerated() {
            guard announced.contains(index), motionRequests.isEnabled(slot: index),
                  let motion = controller.motion else { continue }

            let gravity = 9.80665
            let radiansToDegrees = 180.0 / Double.pi

            let accel = motion.acceleration
            let gyro = motion.rotationRate
            let ax = Float(-accel.x * gravity), ay = Float(-accel.y * gravity), az = Float(-accel.z * gravity)
            let gx = Float(gyro.x * radiansToDegrees), gy = Float(gyro.z * radiansToDegrees), gz = Float(-gyro.y * radiansToDegrees)

            if motionRequests.shouldSend(slot: index, category: UInt8(LI_MOTION_TYPE_ACCEL), now: now,
                                         value: SIMD3(ax, ay, az)) {
                LiSendControllerMotionEvent(UInt8(index), UInt8(LI_MOTION_TYPE_ACCEL), ax, ay, az)
            }
            if motionRequests.shouldSend(slot: index, category: UInt8(LI_MOTION_TYPE_GYRO), now: now,
                                         value: SIMD3(gx, gy, gz)) {
                LiSendControllerMotionEvent(UInt8(index), UInt8(LI_MOTION_TYPE_GYRO), gx, gy, gz)
            }
        }
    }

    public func rumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        // Runs on the Limelight video/control callback thread: never do haptics work inline.
        hapticsQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let controllers = self.connectedControllers
            let running = self.isRunning
            self.lock.unlock()
            guard running else { return }

            let slot = Int(controllerNumber)
            guard slot < controllers.count else { return }

            let driver: RumbleDriver
            if let existing = self.hapticEngines[slot * 3] {
                driver = existing
            } else {
                guard let created = RumbleDriver(controller: controllers[slot], queue: self.hapticsQueue) else { return }
                self.hapticEngines[slot * 3] = created
                driver = created
            }

            driver.apply(low: lowFreqMotor, high: highFreqMotor)
        }
    }

    private func send(_ state: ControllerState, slot: Int, mask: UInt16) {
        guard lastSentStates[slot] != state else { return }
        if LiSendMultiControllerEvent(Int16(slot), Int16(bitPattern: mask), state.buttons, state.leftTrigger,
            state.rightTrigger, state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY) == 0 {
            lastSentStates[slot] = state
        }
    }

    private func announce(_ controller: GCController, slot: Int, mask: UInt16) {
        guard !announced.contains(slot) else { return }
        let profile = nativeProfile(for: controller)
        let sony = controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad
        var caps = UInt16(LI_CCAP_ANALOG_TRIGGERS)
        if controller.haptics != nil { caps |= UInt16(LI_CCAP_RUMBLE) }
        if controller.haptics?.supportedLocalities.contains(.leftTrigger) == true { caps |= UInt16(LI_CCAP_TRIGGER_RUMBLE) }
        if let motion = controller.motion {
            caps |= UInt16(LI_CCAP_ACCEL)
            if motion.hasRotationRate { caps |= UInt16(LI_CCAP_GYRO) }
        }
        if controller.battery != nil { caps |= UInt16(LI_CCAP_BATTERY_STATE) }
        if controller.light != nil { caps |= UInt16(LI_CCAP_RGB_LED) }
        if !profile.touchpads.isEmpty { caps |= UInt16(LI_CCAP_TOUCHPAD) }
        if profile.touchpads.count > 1 { caps |= UInt16(LI_CCAP_DUAL_TOUCHPAD) }
        var buttons: UInt32 = 0xF31F
        if let pad = controller.extendedGamepad {
            if pad.buttonOptions != nil { buttons |= 0x20 }
            if pad.leftThumbstickButton != nil { buttons |= 0x40 }
            if pad.rightThumbstickButton != nil { buttons |= 0x80 }
            if pad.buttonHome != nil { buttons |= 0x400 }
        }
        for (_, flag) in profile.buttons { buttons |= UInt32(bitPattern: flag) }
        if LiSendControllerArrivalEvent(UInt8(slot), mask, UInt8(sony ? LI_CTYPE_PS : LI_CTYPE_UNKNOWN), buttons, caps) == 0 {
            announced.insert(slot)
        }
    }

    private func cancelTouches(slot: Int) {
        for (touchpad, _) in touchStates[slot] ?? [:] {
            _ = LiSendControllerTouchEvent2(UInt8(slot), UInt8(LI_TOUCH_EVENT_CANCEL), UInt8(touchpad), 0, 0, 0, 0)
        }
        touchStates[slot] = nil
    }

    private func sendTouchState(for controller: GCController, slot: Int) {
        guard supportsControllerTouch else { return }
        // Position-only legacy Sony dpads provide no contact state. Do not invent touches.
        for (index, touch) in nativeProfile(for: controller).touchpads.enumerated() {
            let touching = touch.touchState != .up
            let previous = touchStates[slot]?[index]
            let value = SIMD2((touch.touchSurface.xAxis.value + 1) / 2, (1 - touch.touchSurface.yAxis.value) / 2)
            let event: UInt8
            if touching { event = UInt8(previous == nil ? LI_TOUCH_EVENT_DOWN : LI_TOUCH_EVENT_MOVE) }
            else if previous != nil { event = UInt8(LI_TOUCH_EVENT_UP) }
            else { continue }
            if touching && previous == value { continue }
            let position = touching ? value : previous ?? value
            if LiSendControllerTouchEvent2(UInt8(slot), event, UInt8(index), 0, position.x, position.y, touching ? 1 : 0) == 0 {
                touchStates[slot, default: [:]][index] = touching ? value : nil
            }
        }
    }

    private func reportBattery(_ controllers: [GCController]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBatteryPoll > 5 else { return }
        lastBatteryPoll = now
        for (slot, controller) in controllers.prefix(preferences.persistentGamepad ? 1 : slotLimit).enumerated() {
            guard let battery = controller.battery else { continue }
            let state: UInt8
            switch battery.batteryState {
            case .charging: state = UInt8(LI_BATTERY_STATE_CHARGING)
            case .full: state = UInt8(LI_BATTERY_STATE_FULL)
            case .discharging: state = UInt8(LI_BATTERY_STATE_DISCHARGING)
            default: state = UInt8(LI_BATTERY_STATE_UNKNOWN)
            }
            let percent = battery.batteryLevel < 0 ? UInt8(LI_BATTERY_PERCENTAGE_UNKNOWN) : UInt8(min(100, max(0, battery.batteryLevel * 100)))
            let value = "\(state):\(percent)"
            if lastBattery[slot] != value, LiSendControllerBatteryEvent(UInt8(slot), state, percent) == 0 { lastBattery[slot] = value }
        }
    }

    private func emulateMouse(controller: GCController, slot: Int) -> Bool {
        guard let pad = controller.extendedGamepad else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if pad.buttonMenu.isPressed {
            if menuPressedAt[slot] == nil { menuPressedAt[slot] = now }
            if let began = menuPressedAt[slot], now - began > 0.75 {
                if mouseEmulation.contains(slot) { mouseEmulation.remove(slot) } else { mouseEmulation.insert(slot) }
                menuPressedAt[slot] = .infinity
            }
        } else { menuPressedAt[slot] = nil }
        let active = mouseEmulation.contains(slot)
        let left = active && (pad.buttonA.isPressed || pad.rightTrigger.isPressed)
        let right = active && pad.buttonB.isPressed
        let old = mouseButtons[slot] ?? (false, false)
        if old.0 != left { _ = LiSendMouseButtonEvent(CChar(left ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), BUTTON_LEFT) }
        if old.1 != right { _ = LiSendMouseButtonEvent(CChar(right ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), BUTTON_RIGHT) }
        mouseButtons[slot] = (left, right)
        if active {
            func delta(_ v: Float) -> Int16 { abs(v) < 0.15 ? 0 : Int16(v * 8) }
            _ = LiSendMouseMoveEvent(delta(pad.leftThumbstick.xAxis.value), -delta(pad.leftThumbstick.yAxis.value))
            let scroll = delta(pad.rightThumbstick.yAxis.value)
            if scroll != 0 { _ = LiSendHighResScrollEvent(scroll * 4) }
        }
        return active
    }

    public func setLED(slot: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        lock.withLock {
            guard isRunning, Int(slot) < connectedControllers.count else { return }
            connectedControllers[Int(slot)].light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
        }
    }

    public func rumbleTriggers(slot: UInt16, left: UInt16, right: UInt16) {
        hapticsQueue.async { [weak self] in
            guard let self else { return }
            let controller = self.lock.withLock { self.isRunning && Int(slot) < self.connectedControllers.count ? self.connectedControllers[Int(slot)] : nil }
            guard let controller else { return }
            for (offset, value, locality) in [(1, left, GCHapticsLocality.leftTrigger), (2, right, GCHapticsLocality.rightTrigger)] {
                guard controller.haptics?.supportedLocalities.contains(locality) == true else { continue }
                let key = Int(slot) * 3 + offset
                if self.hapticEngines[key] == nil { self.hapticEngines[key] = RumbleDriver(controller: controller, queue: self.hapticsQueue, locality: locality) }
                self.hapticEngines[key]?.apply(low: value, high: 0)
            }
        }
    }
    public func setAdaptiveTriggers(slot: UInt16, flags: UInt8, leftType: UInt8, rightType: UInt8, left: [UInt8], right: [UInt8]) {
        lock.withLock {
            guard isRunning, Int(slot) < connectedControllers.count,
                  let pad = connectedControllers[Int(slot)].extendedGamepad as? GCDualSenseGamepad else { return }
            if flags & UInt8(DS_EFFECT_LEFT_TRIGGER) != 0 { AdaptiveTriggerEffect.decode(type: leftType, bytes: left).apply(to: pad.leftTrigger) }
            if flags & UInt8(DS_EFFECT_RIGHT_TRIGGER) != 0 { AdaptiveTriggerEffect.decode(type: rightType, bytes: right).apply(to: pad.rightTrigger) }
        }
    }

}
