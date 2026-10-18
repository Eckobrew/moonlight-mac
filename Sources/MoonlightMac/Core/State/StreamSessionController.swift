import Foundation
import CoreVideo
import AppKit
import MoonlightCommonC

// Nonisolated engine holder for high-throughput C callbacks
public final class StreamSessionEngine: @unchecked Sendable {
    public static let shared = StreamSessionEngine()

    public let videoDecoder = VideoToolboxDecoder()
    public let audioEngine = AudioPlaybackEngine.shared

    private init() {}
}

@MainActor
public final class StreamSessionController: ObservableObject, VideoDecoderDelegate {
    public static let shared = StreamSessionController()

    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var currentStageName: String = ""
    @Published public private(set) var currentStage: Int = 0
    @Published public private(set) var metrics = PerformanceMetrics()
    @Published public private(set) var sessionError: String?
    @Published public var showPerformanceOverlay: Bool = true

    public func togglePerformanceOverlay() {
        showPerformanceOverlay.toggle()
    }

    public var videoDecoder: VideoToolboxDecoder { StreamSessionEngine.shared.videoDecoder }
    public var audioEngine: AudioPlaybackEngine { StreamSessionEngine.shared.audioEngine }
    public let renderer = MetalStreamRenderer.shared
    public let inputCoordinator = InputCaptureCoordinator.shared

    private var streamTask: Task<Void, Never>?
    private var metricsTimer: Timer?

    private let metricsAccumulator = StreamMetricsAccumulator()

    private var activeHost: Host?
    private var activeApp: StreamApp?
    public private(set) var activeSettings: StreamSettings?

    private init() {
        StreamSessionEngine.shared.videoDecoder.delegate = self
    }

    public func updateStage(stage: Int, name: String) {
        self.currentStage = stage
        self.currentStageName = name
    }

    public func markConnected() {
        self.currentStageName = "Connected"
        if let settings = activeSettings {
            WindowManager.shared.applyStartupWindowMode(settings.windowMode)
        }
    }

    public func handleStageFailed(stage: Int, code: Int) {
        self.sessionError = "Stage \(stage) failed (code \(code))"
        self.stopSession()
    }

    public func handleTerminated(code: Int) {
        self.sessionError = code == 0 ? nil : "Connection terminated (Error \(code))"
        self.stopSession()
    }

    public func clearError() {
        self.sessionError = nil
    }

    public func startSession(host: Host, app: StreamApp, settings: StreamSettings) async {
        guard !isStreaming else { return }

        // If Native resolution is requested, resolve the native physical resolution of the display the app is running on
        var effectiveSettings = settings
        if effectiveSettings.width == 0 || effectiveSettings.height == 0 {
            let (nativeW, nativeH) = DisplayManager.getNativeResolution()
            effectiveSettings.width = nativeW
            effectiveSettings.height = nativeH
            AppLogger.shared.info("Resolved Native display resolution: \(nativeW)x\(nativeH)", category: "Session")
        }

        self.activeHost = host
        self.activeApp = app
        self.activeSettings = effectiveSettings
        self.isStreaming = true
        self.sessionError = nil
        self.currentStageName = "Requesting session from host..."

        WindowManager.shared.applyStartupWindowMode(effectiveSettings.windowMode)

        // Generate 16-byte random key for remote input AES encryption
        let rikey = CryptoUtils.randomBytes(count: 16)
        let rikeyId = UInt32.random(in: 1...UInt32.max)
        let rikeyHex = CryptoUtils.hexString(rikey)

        do {
            let sessionUrl: String?
            if host.currentAppId == app.id {
                sessionUrl = try await SunshineHTTPClient.shared.resumeApp(
                    host: host,
                    settings: effectiveSettings,
                    rikey: rikeyHex,
                    rikeyId: rikeyId
                )
            } else {
                sessionUrl = try await SunshineHTTPClient.shared.launchApp(
                    host: host,
                    appId: app.id,
                    settings: effectiveSettings,
                    rikey: rikeyHex,
                    rikeyId: rikeyId
                )
            }

            startLimelightConnection(
                host: host,
                sessionUrl: sessionUrl,
                settings: effectiveSettings,
                rikey: rikey,
                rikeyId: rikeyId
            )

            // Start input capture
            inputCoordinator.startCapturing(
                captureMouse: settings.mouseCaptureMode,
                swapCommandControl: settings.swapCommandControl,
                onQuit: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.stopSession()
                    }
                },
                onToggleMouseCapture: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.inputCoordinator.toggleMouseCapture()
                    }
                },
                onToggleFullscreen: {
                    Task { @MainActor in
                        WindowManager.shared.toggleFullscreen()
                    }
                },
                onToggleStatsOverlay: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.togglePerformanceOverlay()
                    }
                },
                onToggleMouseMode: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.inputCoordinator.toggleMouseCapture()
                    }
                },
                onMinimize: {
                    Task { @MainActor in
                        NSApp.keyWindow?.miniaturize(nil)
                    }
                },
                onPaste: {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
                        _ = clean.withCString { cStr in
                            LiSendUtf8TextEvent(cStr, UInt32(strlen(cStr)))
                        }
                    }
                }
            )

            startMetricsPolling()

        } catch {
            self.sessionError = error.localizedDescription
            self.stopSession()
        }
    }

    private func startLimelightConnection(
        host: Host,
        sessionUrl: String?,
        settings: StreamSettings,
        rikey: Data,
        rikeyId: UInt32
    ) {
        streamTask = Task.detached(priority: .high) { [weak self] in
            var streamConfig = STREAM_CONFIGURATION()
            LiInitializeStreamConfiguration(&streamConfig)

            streamConfig.width = Int32(settings.width)
            streamConfig.height = Int32(settings.height)
            streamConfig.fps = Int32(settings.fps)
            streamConfig.bitrate = Int32(settings.bitrateMbps * 1000)
            streamConfig.packetSize = Int32(settings.packetSize)
            streamConfig.streamingRemotely = STREAM_CFG_LOCAL
            streamConfig.supportedVideoFormats = settings.codec.limelightMask
            streamConfig.audioConfiguration = settings.audioMode.limelightValue
            streamConfig.colorSpace = Int32(COLORSPACE_REC_709)
            streamConfig.colorRange = Int32(settings.fullRangeColor ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED)
            streamConfig.encryptionFlags = Int32(bitPattern: UInt32(ENCFLG_ALL))

            _ = rikey.withUnsafeBytes { raw in
                memcpy(&streamConfig.remoteInputAesKey, raw.baseAddress!, 16)
            }
            var riKeyIdNetworkOrder = rikeyId.bigEndian
            _ = withUnsafeBytes(of: &riKeyIdNetworkOrder) { raw in
                memcpy(&streamConfig.remoteInputAesIv, raw.baseAddress!, 4)
            }

            var serverInfo = SERVER_INFORMATION()
            LiInitializeServerInformation(&serverInfo)

            let addressCString = strdup(host.address)!
            let appVersionCString = strdup(host.appVersion)!
            let gfeVersionCString = strdup(host.gfeVersion)!
            let sessionUrlCString = (sessionUrl != nil && !sessionUrl!.isEmpty) ? strdup(sessionUrl!) : nil

            serverInfo.address = UnsafePointer(addressCString)
            serverInfo.serverInfoAppVersion = UnsafePointer(appVersionCString)
            serverInfo.serverInfoGfeVersion = UnsafePointer(gfeVersionCString)
            if let sessionUrlCString = sessionUrlCString {
                serverInfo.rtspSessionUrl = UnsafePointer(sessionUrlCString)
            }
            serverInfo.serverCodecModeSupport = host.serverCodecModeSupport

            var clCallbacks = CONNECTION_LISTENER_CALLBACKS()
            LiInitializeConnectionCallbacks(&clCallbacks)
            clCallbacks.stageStarting = sessionStageStarting
            clCallbacks.stageComplete = sessionStageComplete
            clCallbacks.stageFailed = sessionStageFailed
            clCallbacks.connectionStarted = sessionConnectionStarted
            clCallbacks.connectionTerminated = sessionConnectionTerminated
            clCallbacks.rumble = sessionRumble

            var drCallbacks = DECODER_RENDERER_CALLBACKS()
            LiInitializeVideoCallbacks(&drCallbacks)
            drCallbacks.setup = sessionVideoSetup
            drCallbacks.start = sessionVideoStart
            drCallbacks.stop = sessionVideoStop
            drCallbacks.cleanup = sessionVideoCleanup
            drCallbacks.submitDecodeUnit = sessionVideoSubmitDecodeUnit
            drCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT

            var arCallbacks = AUDIO_RENDERER_CALLBACKS()
            LiInitializeAudioCallbacks(&arCallbacks)
            arCallbacks.`init` = sessionAudioInit
            arCallbacks.start = sessionAudioStart
            arCallbacks.stop = sessionAudioStop
            arCallbacks.cleanup = sessionAudioCleanup
            arCallbacks.decodeAndPlaySample = sessionAudioDecodeAndPlaySample
            arCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT

            let result = LiStartConnection(
                &serverInfo,
                &streamConfig,
                &clCallbacks,
                &drCallbacks,
                &arCallbacks,
                nil, 0,
                nil, 0
            )

            free(UnsafeMutableRawPointer(mutating: addressCString))
            free(UnsafeMutableRawPointer(mutating: appVersionCString))
            free(UnsafeMutableRawPointer(mutating: gfeVersionCString))
            if let sessionUrlCString = sessionUrlCString {
                free(UnsafeMutableRawPointer(mutating: sessionUrlCString))
            }

            Task { @MainActor [weak self] in
                if result != 0 {
                    self?.sessionError = "Connection failed with code \(result)"
                    self?.stopSession()
                }
            }
        }
    }

    public func stopSession() {
        WindowManager.shared.restoreWindowAfterStream()

        guard isStreaming else { return }
        isStreaming = false
        stopMetricsPolling()

        // 1. Mark video decoder as stopped under submitLock so any in-flight frame completes and future frames are safely dropped
        videoDecoder.teardownSession()

        // 2. Stop input capture on next main runloop tick to prevent reentrant NSEvent callback crashes
        DispatchQueue.main.async { [weak self] in
            self?.inputCoordinator.stopCapturing()
        }

        // 3. Stop Limelight C connection on background thread (waits for and joins worker threads)
        Task.detached(priority: .userInitiated) {
            LiStopConnection()
        }

        streamTask?.cancel()
        streamTask = nil

        // 4. Request host to terminate app if activeHost is set
        if let host = activeHost {
            Task {
                try? await SunshineHTTPClient.shared.quitApp(host: host)
            }
        }
    }

    private func startMetricsPolling() {
        metricsTimer?.invalidate()
        metricsAccumulator.reset()

        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let snap = self.metricsAccumulator.snapshot(currentFps: self.metrics.currentFps)

                var estimatedRtt: UInt32 = 0
                var estimatedRttVar: UInt32 = 0
                if LiGetEstimatedRttInfo(&estimatedRtt, &estimatedRttVar) {
                    self.metrics.roundTripTimeMs = Double(estimatedRtt)
                }

                self.metrics.currentFps = snap.fps
                self.metrics.decodeTimeMs = snap.decodeTime
                self.metrics.totalFramesRendered = snap.rendered
                self.metrics.totalFramesReceived = snap.received
                self.metrics.totalFramesDropped = snap.dropped
                self.metrics.networkDroppedFrames = snap.netDropped

                if let settings = self.activeSettings {
                    self.metrics.targetFps = settings.fps
                    self.metrics.bitrateMbps = Double(settings.bitrateMbps)
                    self.metrics.resolution = "\(settings.width)x\(settings.height)"
                }
            }
        }
    }

    private func stopMetricsPolling() {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    // MARK: - VideoDecoderDelegate
    public nonisolated func decoderDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTimeUs: UInt64, decodeTimeMs: Double) {
        NativeStreamPresenter.shared.enqueue(pixelBuffer: pixelBuffer)
        metricsAccumulator.recordRender(decodeTimeMs: decodeTimeMs)
    }

    public nonisolated func decoderDidDropFrame(frameNumber: Int) {
        metricsAccumulator.recordDrop()
    }

    public nonisolated func decoderDidDetectNetworkFrameDrop(count: Int) {
        metricsAccumulator.recordNetworkDrop(count: count)
    }
}

// Global C Callbacks for Limelight
private func sessionStageStarting(stage: Int32) {
    let stageName = LiGetStageName(stage).map { String(cString: $0) } ?? "Stage \(stage)"
    Task { @MainActor in
        StreamSessionController.shared.updateStage(stage: Int(stage), name: stageName)
    }
}

private func sessionStageComplete(stage: Int32) {
    let stageName = LiGetStageName(stage).map { String(cString: $0) } ?? "Stage \(stage)"
    Task { @MainActor in
        StreamSessionController.shared.updateStage(stage: Int(stage), name: stageName)
    }
}

private func sessionStageFailed(stage: Int32, errorCode: Int32) {
    Task { @MainActor in
        StreamSessionController.shared.handleStageFailed(stage: Int(stage), code: Int(errorCode))
    }
}

private func sessionConnectionStarted() {
    Task { @MainActor in
        StreamSessionController.shared.markConnected()
    }
}

private func sessionConnectionTerminated(errorCode: Int32) {
    Task { @MainActor in
        StreamSessionController.shared.handleTerminated(code: Int(errorCode))
    }
}

private func sessionRumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
    GameControllerManager.shared.rumble(controllerNumber: controllerNumber, lowFreqMotor: lowFreqMotor, highFreqMotor: highFreqMotor)
}

private func sessionVideoSetup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32, context: UnsafeMutableRawPointer?, drFlags: Int32) -> Int32 {
    return StreamSessionEngine.shared.videoDecoder.setup(videoFormat: videoFormat, width: width, height: height)
}

private func sessionVideoStart() {}
private func sessionVideoStop() {
    StreamSessionEngine.shared.videoDecoder.teardownSession()
}
private func sessionVideoCleanup() {
    StreamSessionEngine.shared.videoDecoder.teardownSession()
}

private func sessionVideoSubmitDecodeUnit(decodeUnit: PDECODE_UNIT?) -> Int32 {
    guard let du = decodeUnit else { return DR_NEED_IDR }
    return StreamSessionEngine.shared.videoDecoder.submitDecodeUnit(du)
}

private func sessionAudioInit(audioConfiguration: Int32, opusConfig: POPUS_MULTISTREAM_CONFIGURATION?, context: UnsafeMutableRawPointer?, arFlags: Int32) -> Int32 {
    let sampleRate = opusConfig?.pointee.sampleRate ?? 48000
    let channels = opusConfig?.pointee.channelCount ?? 2
    return StreamSessionEngine.shared.audioEngine.setup(sampleRate: Double(sampleRate), channelCount: UInt32(channels))
}

private func sessionAudioStart() {
    StreamSessionEngine.shared.audioEngine.start()
}

private func sessionAudioStop() {
    StreamSessionEngine.shared.audioEngine.stop()
}

private func sessionAudioCleanup() {
    StreamSessionEngine.shared.audioEngine.cleanup()
}

private func sessionAudioDecodeAndPlaySample(sampleData: UnsafeMutablePointer<CChar>?, sampleLength: Int32) {
    guard let data = sampleData else { return }
    StreamSessionEngine.shared.audioEngine.decodeAndPlaySample(sampleData: data, sampleLength: Int(sampleLength))
}

private final class StreamMetricsAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDecodeTimeMs: Double = 0.0
    private var framesRendered: UInt64 = 0
    private var framesReceived: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var networkDropped: Int = 0
    private var lastFpsSampleTime: TimeInterval = CACurrentMediaTime()
    private var lastFpsFrameCount: UInt64 = 0

    func recordRender(decodeTimeMs: Double) {
        lock.lock()
        self.lastDecodeTimeMs = decodeTimeMs
        self.framesRendered &+= 1
        self.framesReceived &+= 1
        lock.unlock()
    }

    func recordDrop() {
        lock.lock()
        self.framesDropped &+= 1
        self.framesReceived &+= 1
        lock.unlock()
    }

    func recordNetworkDrop(count: Int) {
        lock.lock()
        self.networkDropped &+= count
        lock.unlock()
    }

    func snapshot(currentFps: Double) -> (rendered: UInt64, received: UInt64, dropped: UInt64, netDropped: Int, decodeTime: Double, fps: Double) {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsSampleTime
        var computedFps = currentFps
        if elapsed >= 0.45 {
            let delta = framesRendered >= lastFpsFrameCount ? (framesRendered - lastFpsFrameCount) : 0
            computedFps = Double(delta) / elapsed
            lastFpsSampleTime = now
            lastFpsFrameCount = framesRendered
        }

        return (framesRendered, framesReceived, framesDropped, networkDropped, lastDecodeTimeMs, computedFps)
    }

    func reset() {
        lock.lock()
        lastDecodeTimeMs = 0.0
        framesRendered = 0
        framesReceived = 0
        framesDropped = 0
        networkDropped = 0
        lastFpsSampleTime = CACurrentMediaTime()
        lastFpsFrameCount = 0
        lock.unlock()
    }
}

