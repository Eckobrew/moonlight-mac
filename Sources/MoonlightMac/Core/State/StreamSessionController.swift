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
    #if DEBUG
    @Published public var showPerformanceOverlay: Bool = true
    #else
    @Published public var showPerformanceOverlay: Bool = false
    #endif

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

    public private(set) var activeHost: Host?
    public var isShortcutMode: Bool = false
    private var activeApp: StreamApp?
    public private(set) var activeSettings: StreamSettings?
    private var latencyActivityToken: NSObjectProtocol?

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

        // Request real-time scheduler priority from Darwin kernel and disable App Nap / system sleep throttling
        self.latencyActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Moonlight Low-Latency Game Streaming"
        )

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

        #if DEBUG
        self.showPerformanceOverlay = true
        #else
        self.showPerformanceOverlay = false
        #endif

        DisplaySleepManager.shared.start(keepScreenActive: effectiveSettings.keepScreenActive)

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

            MetalStreamRenderer.shared.enableVsync = effectiveSettings.enableVsync
            MetalStreamRenderer.shared.isHdrActive = effectiveSettings.enableHdr

            let displayID = (WindowManager.shared.currentWindow?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let useNativeRenderer = effectiveSettings.videoRenderer == .native

            FramePacer.shared.configure(
                enabled: effectiveSettings.enableFramePacing,
                displayID: displayID
            ) { pixelBuffer in
                if useNativeRenderer {
                    NativeStreamPresenter.shared.enqueue(pixelBuffer: pixelBuffer)
                } else {
                    MetalStreamRenderer.shared.render(pixelBuffer: pixelBuffer)
                }
            }

            let isRemote = await NetworkReachability.isRemoteSession(host: host)
            self.streamConfigRemotely = isRemote ? Int32(STREAM_CFG_REMOTE) : Int32(STREAM_CFG_LOCAL)

            startLimelightConnection(
                host: host,
                sessionUrl: sessionUrl,
                settings: effectiveSettings,
                rikey: rikey,
                rikeyId: rikeyId,
                isRemote: isRemote
            )

            // Start input capture
            inputCoordinator.startCapturing(
                captureMouse: settings.mouseCaptureMode,
                mouseSensitivity: settings.mouseSensitivity,
                swapWinAltKeys: settings.swapWinAltKeys,
                systemKeyCaptureMode: settings.captureSystemKeys,
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
                        InputCaptureCoordinator.shared.updateKeyboardGrabState()
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
            if let host = activeHost, activeSettings?.enableClipboardSync == true {
                ClipboardSyncManager.shared.start(host: host)
            }

        } catch {
            self.sessionError = error.localizedDescription
            self.stopSession()
        }
    }

    private var streamConfigRemotely: Int32 = STREAM_CFG_LOCAL

    private func startLimelightConnection(
        host: Host,
        sessionUrl: String?,
        settings: StreamSettings,
        rikey: Data,
        rikeyId: UInt32,
        isRemote: Bool
    ) {
        streamTask = Task.detached(priority: .high) {
            var streamConfig = STREAM_CONFIGURATION()
            LiInitializeStreamConfiguration(&streamConfig)

            let remotelyFlag = isRemote ? Int32(STREAM_CFG_REMOTE) : Int32(STREAM_CFG_LOCAL)
            streamConfig.streamingRemotely = remotelyFlag

            let chosenBitrateMbps: Int
            if isRemote && settings.enableRemoteBitrate {
                chosenBitrateMbps = settings.remoteBitrateMbps
                AppLogger.shared.info("Using custom remote bitrate: \(chosenBitrateMbps) Mbps (connection evaluated as remote)", category: "SESSION")
            } else {
                chosenBitrateMbps = settings.bitrateMbps
                AppLogger.shared.info("Using standard bitrate: \(chosenBitrateMbps) Mbps (connection evaluated as local)", category: "SESSION")
            }

            streamConfig.width = Int32(settings.width)
            streamConfig.height = Int32(settings.height)
            streamConfig.fps = Int32(settings.fps)
            streamConfig.bitrate = Int32(chosenBitrateMbps * 1000)
            streamConfig.packetSize = Int32(settings.packetSize)
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

            let addressCString = strdup(host.effectiveAddress)!
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
            arCallbacks.capabilities = CAPABILITY_DIRECT_SUBMIT | CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION

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

        let hostToQuit = activeHost
        let isShortcut = isShortcutMode
        let shouldQuitHostApp = isShortcut || (activeSettings?.quitAppOnStop == true)
        let hadError = sessionError != nil

        guard isStreaming else {
            if isShortcut && !hadError {
                exit(0)
            }
            return
        }
        isStreaming = false
        stopMetricsPolling()
        ClipboardSyncManager.shared.stop()
        DisplaySleepManager.shared.stop()

        if let token = latencyActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            latencyActivityToken = nil
        }

        // 1. Mark video decoder as stopped under submitLock so any in-flight frame completes and future frames are safely dropped
        videoDecoder.teardownSession()

        // 2. Stop FramePacer and flush video presenters
        FramePacer.shared.stop()
        NativeStreamPresenter.shared.flush()
        MetalStreamRenderer.shared.reset()

        // 3. Stop input capture on next main runloop tick to prevent reentrant NSEvent callback crashes
        DispatchQueue.main.async { [weak self] in
            self?.inputCoordinator.stopCapturing()
        }

        // 4. Stop Limelight C connection on background thread (waits for and joins worker threads)
        Task.detached(priority: .userInitiated) {
            LiStopConnection()
        }

        streamTask?.cancel()
        streamTask = nil

        // 5. Request host to terminate app if in shortcut mode or quitAppOnStop is enabled
        if let host = hostToQuit, shouldQuitHostApp {
            Task {
                AppLogger.shared.info("Quitting game on host (shortcutMode: \(isShortcut))", category: "SESSION")
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try? await SunshineHTTPClient.shared.quitApp(host: host)
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                    }
                    _ = await group.next()
                }

                if isShortcut && !hadError {
                    await MainActor.run {
                        exit(0)
                    }
                }
            }
        } else if isShortcut && !hadError {
            Task { @MainActor in
                exit(0)
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
                    let isRemote = (self.streamConfigRemotely == STREAM_CFG_REMOTE)
                    let activeBitrate = (isRemote && settings.enableRemoteBitrate) ? settings.remoteBitrateMbps : settings.bitrateMbps
                    self.metrics.bitrateMbps = Double(activeBitrate)
                    self.metrics.resolution = "\(settings.width)x\(settings.height)"
                    self.metrics.vsyncEnabled = settings.enableVsync
                    self.metrics.pacingEnabled = settings.enableFramePacing
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
        FramePacer.shared.submit(pixelBuffer: pixelBuffer)
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
    guard let config = opusConfig?.pointee else {
        return StreamSessionEngine.shared.audioEngine.setup(
            sampleRate: 48000,
            channelCount: 2,
            streams: 1,
            coupledStreams: 1,
            samplesPerFrame: 240,
            mapping: [0, 1]
        )
    }

    let sampleRate = Double(config.sampleRate)
    let channels = UInt32(config.channelCount)
    let streams = Int(config.streams)
    let coupledStreams = Int(config.coupledStreams)
    let samplesPerFrame = Int(config.samplesPerFrame)

    var mappingBytes = [UInt8](repeating: 0, count: Int(channels))
    withUnsafePointer(to: config.mapping) { tuplePtr in
        tuplePtr.withMemoryRebound(to: UInt8.self, capacity: Int(channels)) { bytePtr in
            for i in 0..<Int(channels) {
                mappingBytes[i] = bytePtr[i]
            }
        }
    }

    return StreamSessionEngine.shared.audioEngine.setup(
        sampleRate: sampleRate,
        channelCount: channels,
        streams: streams,
        coupledStreams: coupledStreams,
        samplesPerFrame: samplesPerFrame,
        mapping: mappingBytes
    )
}

private func sessionAudioStart() {
    AppLogger.shared.info("sessionAudioStart: starting AudioPlaybackEngine", category: "AUDIO")
    StreamSessionEngine.shared.audioEngine.start()
}

private func sessionAudioStop() {
    AppLogger.shared.info("sessionAudioStop: stopping AudioPlaybackEngine", category: "AUDIO")
    StreamSessionEngine.shared.audioEngine.stop()
}

private func sessionAudioCleanup() {
    AppLogger.shared.info("sessionAudioCleanup: cleaning up AudioPlaybackEngine", category: "AUDIO")
    StreamSessionEngine.shared.audioEngine.cleanup()
}

private func sessionAudioDecodeAndPlaySample(sampleData: UnsafeMutablePointer<CChar>?, sampleLength: Int32) {
    StreamSessionEngine.shared.audioEngine.decodeAndPlaySample(sampleData: sampleData, sampleLength: Int(sampleLength))
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

