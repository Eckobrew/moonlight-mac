import Foundation

/// Engine graph and device operations run on one queue. The decoder and real-time
/// source callback never start/stop an engine or wait for device recovery.
protocol AudioOutputBackend: AnyObject, Sendable {
    var isRunning: Bool { get }
    var statusMessage: String? { get }
    func selectDevice(uid: String?) throws
    func setMuted(_ muted: Bool)
    func start() throws
    func stop()
    func dispose()
}

extension AudioOutputBackend { var statusMessage: String? { nil } }

final class AudioPlaybackControl: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.moonlight.audio.control", qos: .userInitiated)
    private var backend: (any AudioOutputBackend)?
    private var generation: UInt64 = 0
    private var wantsPlayback = false
    private var deviceUID: String?
    private var muteOnFocusLoss = false
    private var appFocused = false
    private var retry: DispatchWorkItem?
    private var retryDelay = 0.1

    @discardableResult
    func install(_ makeBackend: @Sendable (@escaping @Sendable () -> Void) throws -> any AudioOutputBackend) -> Bool {
        queue.sync {
            invalidate()
            let installedGeneration = generation
            do {
                backend = try makeBackend { [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, self.generation == installedGeneration else { return }
                        self.recover()
                    }
                }
                backend?.setMuted(muteOnFocusLoss && !appFocused)
                return true
            } catch {
                RuntimeServiceStatus.reportAudio("Audio setup failed. Reconnect the stream or select another output device.")
                AppLogger.shared.error("Audio setup failed: \(error.localizedDescription)", category: "AUDIO")
                return false
            }
        }
    }

    func configure(deviceUID: String?, muteOnFocusLoss: Bool, appFocused: Bool) {
        queue.sync {
            self.deviceUID = deviceUID
            self.muteOnFocusLoss = muteOnFocusLoss
            self.appFocused = appFocused
            backend?.setMuted(muteOnFocusLoss && !appFocused)
        }
    }

    func updateFocus(_ focused: Bool) {
        queue.async {
            self.appFocused = focused
            self.backend?.setMuted(self.muteOnFocusLoss && !focused)
        }
    }

    func start() {
        queue.sync {
            guard backend != nil else { return }
            wantsPlayback = true
            recover()
        }
    }

    func applyOutputDevice() {
        queue.async { self.recover() }
    }

    func stop() {
        queue.sync {
            wantsPlayback = false
            retry?.cancel()
            retry = nil
            backend?.stop()
        }
    }

    func cleanup() { queue.sync { invalidate() } }

    /// A barrier useful to callers/tests needing completed queued control work.
    func synchronize() { queue.sync {} }

    private func invalidate() {
        generation &+= 1
        wantsPlayback = false
        retry?.cancel()
        retry = nil
        retryDelay = 0.1
        backend?.dispose()
        backend = nil
        RuntimeServiceStatus.reportAudio(nil)
    }

    private func recover() {
        guard wantsPlayback, let backend else { return }
        do {
            try backend.selectDevice(uid: deviceUID)
            // Apply mute before starting, including after device changes.
            backend.setMuted(muteOnFocusLoss && !appFocused)
            if !backend.isRunning { try backend.start() }
            retry?.cancel()
            retry = nil
            retryDelay = 0.1
            RuntimeServiceStatus.reportAudio(backend.statusMessage)
        } catch {
            RuntimeServiceStatus.reportAudio("Audio output is unavailable. Reconnecting automatically; check the output device in Settings.")
            AppLogger.shared.warning("Audio recovery will retry: \(error.localizedDescription)", category: "AUDIO")
            guard retry == nil else { return }
            let expectedGeneration = generation
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.generation == expectedGeneration, self.wantsPlayback else { return }
                self.retry = nil
                self.recover()
            }
            retry = item
            queue.asyncAfter(deadline: .now() + retryDelay, execute: item)
            retryDelay = min(2, retryDelay * 2)
        }
    }
}
