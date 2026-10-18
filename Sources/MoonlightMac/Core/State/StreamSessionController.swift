import Foundation
import CoreVideo
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

    public var videoDecoder: VideoToolboxDecoder { StreamSessionEngine.shared.videoDecoder }
    public var audioEngine: AudioPlaybackEngine { StreamSessionEngine.shared.audioEngine }
    public let renderer = MetalStreamRenderer.shared
    public let inputCoordinator = InputCaptureCoordinator.shared

    private var streamTask: Task<Void, Never>?
    private var metricsTimer: Timer?

    private var activeHost: Host?
    private var activeApp: StreamApp?
    private var activeSettings: StreamSettings?

    private init() {
        StreamSessionEngine.shared.videoDecoder.delegate = self
    }

    public func updateStage(stage: Int, name: String) {
        self.currentStage = stage
        self.currentStageName = name
    }

    public func markConnected() {
        self.currentStageName = "Connected"
    }

    public func handleStageFailed(stage: Int, code: Int) {
        self.sessionError = "Stage \(stage) failed (code \(code))"
        self.stopSession()
    }

    public func handleTerminated(code: Int) {
        self.sessionError = code == 0 ? "Session ended gracefully" : "Connection terminated (Error \(code))"
        self.stopSession()
    }

    public func startSession(host: Host, app: StreamApp, settings: StreamSettings) async {
        guard !isStreaming else { return }

        self.activeHost = host
        self.activeApp = app
        self.activeSettings = settings
        self.isStreaming = true
        self.sessionError = nil
        self.currentStageName = "Requesting session from host..."

        // Generate 16-byte random keys for remote input encryption
        let rikey = CryptoUtils.randomBytes(count: 16)
        let rikeyId = CryptoUtils.randomBytes(count: 16)
        let rikeyHex = CryptoUtils.hexString(rikey)
        let rikeyIdHex = CryptoUtils.hexString(rikeyId)

        do {
            let sessionUrl = try await SunshineHTTPClient.shared.launchApp(
                host: host,
                appId: app.id,
                settings: settings,
                rikey: rikeyHex,
                rikeyId: rikeyIdHex
            )

            startLimelightConnection(
                host: host,
                sessionUrl: sessionUrl,
                settings: settings,
                rikey: rikey,
                rikeyId: rikeyId
            )

            // Start input capture
            inputCoordinator.startCapturing(
                captureMouse: settings.mouseCaptureMode,
                swapCommandControl: settings.swapCommandControl,
                onEscape: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.stopSession()
                    }
                }
            )

            startMetricsPolling()

        } catch {
            self.sessionError = error.localizedDescription
            self.isStreaming = false
        }
    }

    private func startLimelightConnection(
        host: Host,
        sessionUrl: String,
        settings: StreamSettings,
        rikey: Data,
        rikeyId: Data
    ) {
        streamTask = Task.detached(priority: .high) { [weak self] in
            var streamConfig = STREAM_CONFIGURATION()
            LiInitializeStreamConfiguration(&streamConfig)

            streamConfig.width = Int32(settings.width)
            streamConfig.height = Int32(settings.height)
            streamConfig.fps = Int32(settings.fps)
            streamConfig.bitrate = Int32(settings.bitrateMbps * 1000)
            streamConfig.packetSize = Int32(settings.packetSize)
            streamConfig.streamingRemotely = STREAM_CFG_AUTO
            streamConfig.supportedVideoFormats = settings.codec.limelightMask
            streamConfig.audioConfiguration = settings.audioMode.limelightValue
            streamConfig.colorSpace = Int32(COLORSPACE_REC_709)
            streamConfig.colorRange = Int32(settings.fullRangeColor ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED)
            streamConfig.encryptionFlags = Int32(bitPattern: UInt32(ENCFLG_ALL))

            _ = rikey.withUnsafeBytes { raw in
                memcpy(&streamConfig.remoteInputAesKey, raw.baseAddress!, 16)
            }
            _ = rikeyId.withUnsafeBytes { raw in
                memcpy(&streamConfig.remoteInputAesIv, raw.baseAddress!, 16)
            }

            var serverInfo = SERVER_INFORMATION()
            LiInitializeServerInformation(&serverInfo)

            let addressCString = strdup(host.address)!
            let appVersionCString = strdup(host.appVersion)!
            let gfeVersionCString = strdup(host.gfeVersion)!
            let sessionUrlCString = strdup(sessionUrl)!

            serverInfo.address = UnsafePointer(addressCString)
            serverInfo.serverInfoAppVersion = UnsafePointer(appVersionCString)
            serverInfo.serverInfoGfeVersion = UnsafePointer(gfeVersionCString)
            serverInfo.rtspSessionUrl = UnsafePointer(sessionUrlCString)
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
            free(UnsafeMutableRawPointer(mutating: sessionUrlCString))

            Task { @MainActor [weak self] in
                if result != 0 {
                    self?.sessionError = "Connection failed with code \(result)"
                    self?.stopSession()
                }
            }
        }
    }

    public func stopSession() {
        guard isStreaming else { return }
        isStreaming = false
        stopMetricsPolling()
        inputCoordinator.stopCapturing()

        Task.detached(priority: .utility) {
            LiStopConnection()
        }

        streamTask?.cancel()
        streamTask = nil

        videoDecoder.teardownSession()
        audioEngine.stop()

        if let host = activeHost {
            Task {
                try? await SunshineHTTPClient.shared.quitApp(host: host)
            }
        }
    }

    private func startMetricsPolling() {
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                var estimatedRtt: UInt32 = 0
                var estimatedRttVar: UInt32 = 0
                if LiGetEstimatedRttInfo(&estimatedRtt, &estimatedRttVar) {
                    self.metrics.roundTripTimeMs = Double(estimatedRtt)
                }
                self.metrics.currentFps = self.renderer.currentRenderFps
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
        MetalStreamRenderer.shared.setPixelBuffer(pixelBuffer)
        Task { @MainActor in
            StreamSessionController.shared.metrics.decodeTimeMs = decodeTimeMs
            StreamSessionController.shared.metrics.totalFramesRendered += 1
        }
    }

    public nonisolated func decoderDidDropFrame(frameNumber: Int) {
        Task { @MainActor in
            StreamSessionController.shared.metrics.networkDroppedFrames += 1
            StreamSessionController.shared.metrics.totalFramesDropped += 1
        }
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
