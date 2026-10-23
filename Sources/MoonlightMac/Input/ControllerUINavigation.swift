import AppKit
import GameController

/// UI-only navigation; streaming controller packets are handled separately.
@MainActor final class ControllerUINavigation {
    static let shared = ControllerUINavigation()
    private var timer: Timer?
    private weak var state: AppState?
    private var previous = Set<String>()
    private var needsBaseline = true
    private weak var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    private var lastMove: TimeInterval = 0
    func start(state: AppState) {
        self.state = state
        if observers.isEmpty {
            for name in [
                Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect,
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    })
            }
        }
        refresh()
    }

    func refresh() {
        controller = GCController.controllers().first { $0.extendedGamepad != nil }
        guard let state, NSApp.isActive, !state.isStreaming, !state.isShortcutLaunch, controller != nil
        else {
            timer?.invalidate()
            timer = nil
            previous.removeAll()
            needsBaseline = true
            return
        }
        guard timer == nil else { return }
        needsBaseline = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }
    private func poll() {
        guard let state, NSApp.isActive, !state.isStreaming, !state.isShortcutLaunch,
            let pad = controller?.extendedGamepad
        else {
            previous.removeAll()
            return
        }
        var pressed = Set<String>()
        if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.6 { pressed.insert("up") }
        if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.6 { pressed.insert("down") }
        if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.6 { pressed.insert("left") }
        if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.6 { pressed.insert("right") }
        if pad.buttonA.isPressed { pressed.insert("accept") }
        if pad.buttonB.isPressed { pressed.insert("back") }
        if pad.buttonY.isPressed { pressed.insert("settings") }
        if needsBaseline {
            previous = pressed
            needsBaseline = false
            return
        }
        let fresh = pressed.subtracting(previous)
        previous = pressed
        let now = ProcessInfo.processInfo.systemUptime
        let direction = pressed.first { ["up", "left", "down", "right"].contains($0) }
        let move = direction != nil && (fresh.contains(direction!) || now - lastMove > 0.3)
        let modal =
            NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil || state.isShowingSettings
            || state.isShowingAddHost || state.isShowingPairing
        if modal {
            if move {
                postKey(48, characters: "\t", modifiers: ["up", "left"].contains(direction!) ? .shift : [])
                lastMove = now
            }
            if fresh.contains("accept") { postKey(36, characters: "\r") }
            if fresh.contains("back") { postKey(53, characters: "\u{1b}") }
            return
        }
        if fresh.contains("settings") {
            state.isShowingSettings = true
            return
        }
        if fresh.contains("back") {
            state.selectedHost = nil
            return
        }
        if let host = state.selectedHost, host.isSecurelyPaired {
            let apps = state.appsForSelectedHost
            guard !apps.isEmpty else { return }
            var index = apps.firstIndex { $0.id == state.controllerAppFocus } ?? 0
            if move {
                index = (index + (["up", "left"].contains(direction!) ? -1 : 1) + apps.count) % apps.count
                lastMove = now
            }
            if state.controllerAppFocus != apps[index].id { state.controllerAppFocus = apps[index].id }
            if fresh.contains("accept") { state.launchStream(host: host, app: apps[index]) }
        } else {
            let hosts = state.hosts.filter { !state.settings.hideUnpairedHosts || $0.isPaired }
            guard !hosts.isEmpty else { return }
            var index = hosts.firstIndex { $0.id == state.controllerHostFocus } ?? 0
            if move {
                index =
                    (index + (["up", "left"].contains(direction!) ? -1 : 1) + hosts.count) % hosts.count
                lastMove = now
            }
            if state.controllerHostFocus != hosts[index].id {
                state.controllerHostFocus = hosts[index].id
            }
            if fresh.contains("accept") {
                let host = hosts[index]
                state.selectedHost = host
                Task {
                    if host.isSecurelyPaired {
                        await state.loadApps(for: host)
                    } else {
                        await state.startPairing(for: host)
                    }
                }
            }
        }
    }
    private func postKey(_ key: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = NSApp.keyWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: key)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
}
