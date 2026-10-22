import Foundation
import CoreVideo
import AppKit
import MoonlightCommonC

// Nonisolated engine holder for high-throughput C callbacks
public final class StreamSessionEngine: @unchecked Sendable {
    public static let shared = StreamSessionEngine()

    public let videoDecoder = VideoToolboxDecoder()
    public let audioEngine = AudioPlaybackEngine.shared

    private let callbackLock = NSLock()
    private var callbackGenerationStorage: UInt64 = 0
    fileprivate var callbackGeneration: UInt64 {
        get { callbackLock.withLock { callbackGenerationStorage } }
        set { callbackLock.withLock { callbackGenerationStorage = newValue } }
    }

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
    private var stoppingTask: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var metricsTimer: Timer?

    private let metricsAccumulator = StreamMetricsAccumulator()

    public private(set) var activeHost: Host?
    public var isShortcutMode: Bool = false
    public var onSessionStopped: (@MainActor () -> Void)?
    private var activeApp: StreamApp?
    public private(set) var activeSettings: StreamSettings?
    private var latencyActivityToken: NSObjectProtocol?
    private let streamDiagnosticsEnabled = ProcessInfo.processInfo.environment["MOONLIGHT_STREAM_DIAGNOSTICS"] == "1"

    private init() {
        StreamSessionEngine.shared.videoDecoder.delegate = self
    }

    fileprivate func acceptsCallback(generation: UInt64) -> Bool {
        isStreaming && sessionGeneration == generation
    }

    public func updateStage(stage: Int, name: String) {
        guard isStreaming else { return }
        self.currentStage = stage
        self.currentStageName = name
    }

    public func markConnected() {
        guard isStreaming else { return }
        self.currentStageName = "Connected"
        if let settings = activeSettings {
            WindowManager.shared.applyStartupWindowMode(settings.windowMode)
        }
    }

    public func handleStageFailed(stage: Int, code: Int) {
        guard isStreaming else { return }
        self.sessionError = "Stage \(stage) failed (code \(code))"
        self.stopSession()
    }

    public func handleTerminated(code: Int) {
        guard isStreaming else { return }
        self.sessionError = code == 0 ? nil : "Connection terminated (Error \(code))"
        self.stopSession()
    }

    public func clearError() {
        self.sessionError = nil
    }

    public func startSession(host: Host, app: StreamApp, settings: StreamSettings) async {
        guard !isStreaming else { return }
        // Snapshot the launching window/display before awaiting teardown or
        // replacing views. AppKit's key window can change during those operations.
        var effectiveSettings = settings
        if effectiveSettings.width == 0 || effectiveSettings.height == 0 {
            let window = WindowManager.shared.currentWindow
            let (nativeW, nativeH) = DisplayManager.getNativeResolution(for: window)
            effectiveSettings.width = nativeW
            effectiveSettings.height = nativeH
            AppLogger.shared.info("Resolved Native display resolution: \(nativeW)x\(nativeH) on \(window?.screen?.localizedName ?? "default display")", category: "Session")
        }
        // moonlight-common-c has process-global connection state. Finish the previous
        // teardown before another startup can touch it.
        let requestGeneration = sessionGeneration
        await stoppingTask?.value
        guard !isStreaming, sessionGeneration == requestGeneration, !Task.isCancelled else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration

        // Request real-time scheduler priority from Darwin kernel and disable App Nap / system sleep throttling
        self.latencyActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Moonlight Low-Latency Game Streaming"
        )

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

            guard isStreaming, sessionGeneration == generation else { return }
            try Task.checkCancellation()

            MetalStreamRenderer.shared.enableVsync = effectiveSettings.enableVsync
            MetalStreamRenderer.shared.isHdrActive = effectiveSettings.enableHdr

            let displayID = (WindowManager.shared.currentWindow?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let useNativeRenderer = effectiveSettings.videoRenderer == .native

            // Route audio to the selected output device and honour focus-loss muting.
            audioEngine.configureOutput(
                deviceUID: effectiveSettings.audioOutputDeviceUID,
                muteOnFocusLoss: effectiveSettings.muteAudioOnFocusLoss
            )

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
            guard isStreaming, sessionGeneration == generation else { return }
            try Task.checkCancellation()
            self.streamConfigRemotely = isRemote ? Int32(STREAM_CFG_REMOTE) : Int32(STREAM_CFG_LOCAL)

            // Probe and wait up to 3s for host RTSP port to accept connections before starting Limelight
            await waitForRtspPortReady(host: host, sessionUrl: sessionUrl)

            guard isStreaming, sessionGeneration == generation else { return }
            try Task.checkCancellation()
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
                mouseSensitivityX: settings.mouseSensitivityX,
                mouseSensitivityY: settings.mouseSensitivityY,
                mouseSubPixelAccumulation: settings.mouseSubPixelAccumulation,
                swapWinAltKeys: settings.swapWinAltKeys,
                keyboardLayout: settings.keyboardLayout,
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
                    guard let text = NSPasteboard.general.string(forType: .string) else { return }
                    let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
                    // LiSendUtf8TextEvent packs the whole string into a single reliable control
                    // packet and takes its length as UInt32, so truncate oversized pastes instead
                    // of overflowing the length or the allocator.
                    let utf8 = Array(clean.utf8.prefix(Self.maxPasteBytes))
                    guard !utf8.isEmpty else { return }
                    if utf8.count < clean.utf8.count {
                        AppLogger.shared.warning("Pasted text truncated to \(Self.maxPasteBytes) bytes", category: "CLIPBOARD")
                    }
                    utf8.withUnsafeBufferPointer { buffer in
                        buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { cStr in
                            _ = LiSendUtf8TextEvent(cStr, UInt32(buffer.count))
                        }
                    }
                }
            )

            startMetricsPolling()
            if let host = activeHost, activeSettings?.enableClipboardSync == true {
                ClipboardSyncManager.shared.start(host: host)
            }

        } catch {
            guard sessionGeneration == generation, isStreaming else { return }
            self.sessionError = error.localizedDescription
            self.stopSession()
        }
    }

    private var streamConfigRemotely: Int32 = STREAM_CFG_LOCAL

    /// Upper bound for the in-stream paste shortcut. The control packet holds the text inline, so
    /// this keeps one paste from allocating a multi-megabyte enet packet.
    private nonisolated static let maxPasteBytes = 64 * 1024

    private func waitForRtspPortReady(host: Host, sessionUrl: String?, timeoutSeconds: Double = 3.0) async {
        var port: UInt16 = 48010
        if let sUrl = sessionUrl, let url = URL(string: sUrl), let p = url.port, let validPort = UInt16(exactly: p), validPort > 0 {
            port = validPort
        }

        let address = host.effectiveAddress
        let generation = sessionGeneration
        let probePort = port
        let start = Date()
        let deadline = start.addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            guard isStreaming, sessionGeneration == generation, !Task.isCancelled else { return }
            let reachable = await Task.detached(priority: .utility) {
                TCPProbe.canConnect(address: address, port: probePort)
            }.value
            if reachable {
                let elapsed = String(format: "%.0f", Date().timeIntervalSince(start) * 1000)
                AppLogger.shared.info("RTSP port \(port) is ready on \(address) (waited \(elapsed)ms)", category: "SESSION")
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        AppLogger.shared.info("Proceeding to RTSP handshake for \(address):\(port)", category: "SESSION")
    }

    private func canConnectToTcpPort(address: String, port: UInt16) -> Bool {
        TCPProbe.canConnect(address: address, port: port)
    }

    private func startLimelightConnection(
        host: Host,
        sessionUrl: String?,
        settings: StreamSettings,
        rikey: Data,
        rikeyId: UInt32,
        isRemote: Bool
    ) {
        let generation = sessionGeneration
        StreamSessionEngine.shared.callbackGeneration = generation
        streamTask = Task.detached(priority: .high) {
            guard !Task.isCancelled else { return }
            var streamConfig = STREAM_CONFIGURATION()
            LiInitializeStreamConfiguration(&streamConfig)

            // Let the library classify the connection itself by resolving the address and testing
            // it against private/NAT64 ranges. That classification is what enables its remote
            // packet-size cap (1024 bytes IPv4, 1184 IPv6) and the 500 Kbps bitrate headroom
            // subtraction in the SDP. Passing STREAM_CFG_LOCAL/.REMOTE skipped both.
            streamConfig.streamingRemotely = Int32(STREAM_CFG_AUTO)

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
            streamConfig.supportedVideoFormats = settings.codec.limelightMask(enableHdr: settings.enableHdr)
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
            clCallbacks.setMotionEventState = sessionSetMotionEventState

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
            // Match moonlight-qt: omit CAPABILITY_DIRECT_SUBMIT so moonlight-common-c decouples
            // UDP socket reception/FEC (AudioRecv) from AES decryption and Opus decoding (AudioDec)
            // via its packet queue, and enables LiGetPendingAudioDuration() backpressure.
            arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION

            let result: Int32
            if Task.isCancelled {
                result = -1
            } else {
                result = LiStartConnection(
                    &serverInfo,
                    &streamConfig,
                    &clCallbacks,
                    &drCallbacks,
                    &arCallbacks,
                    nil, 0,
                    nil, 0
                )
            }

            free(UnsafeMutableRawPointer(mutating: addressCString))
            free(UnsafeMutableRawPointer(mutating: appVersionCString))
            free(UnsafeMutableRawPointer(mutating: gfeVersionCString))
            if let sessionUrlCString = sessionUrlCString {
                free(UnsafeMutableRawPointer(mutating: sessionUrlCString))
            }

            Task { @MainActor [weak self] in
                guard let self = self, self.isStreaming, self.sessionGeneration == generation else { return }
                if result != 0 && self.sessionError == nil {
                    self.sessionError = "Connection failed with code \(result)"
                    self.stopSession()
                }
            }
        }
    }

    public func stopSession() {
        // Also invalidate a reconnect that is still waiting for old cleanup.
        sessionGeneration &+= 1
        let isShortcut = isShortcutMode
        let hostToQuit = activeHost
        let shouldQuitHostApp = isShortcut || (activeSettings?.quitAppOnStop == true)

        if isShortcut {
            for window in NSApp.windows {
                window.alphaValue = 0
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
                window.orderOut(nil)
                window.setIsVisible(false)
            }
            NSApp.hide(nil)
        } else {
            WindowManager.shared.restoreWindowAfterStream()
        }

        guard isStreaming else {
            if isShortcut {
                exit(0)
            }
            return
        }
        isStreaming = false
        onSessionStopped?()
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
            guard let self, !self.isStreaming else { return }
            self.inputCoordinator.stopCapturing()
        }

        // 4. Stop Limelight C connection on background thread (waits for and joins worker threads)
        let connectionTask = streamTask
        connectionTask?.cancel()
        LiInterruptConnection()
        stoppingTask = Task.detached(priority: .userInitiated) {
            // LiStartConnection performs its own cleanup on failure. Never run
            // LiStopConnection concurrently with that cleanup.
            await connectionTask?.value
            LiStopConnection()
        }
        streamTask = nil

        // 5. Request host to terminate app if in shortcut mode or quitAppOnStop is enabled
        if let host = hostToQuit, shouldQuitHostApp {
            let connectionStop = stoppingTask
            stoppingTask = Task.detached(priority: .userInitiated) {
                await connectionStop?.value
                AppLogger.shared.info("Quitting game on host in background (shortcutMode: \(isShortcut))", category: "SESSION")
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try? await SunshineHTTPClient.shared.quitApp(host: host)
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(2))
                    }
                    _ = await group.next()
                    group.cancelAll()
                }

                if isShortcut {
                    exit(0)
                }
            }
        } else if isShortcut {
            exit(0)
        }
    }

    private func startMetricsPolling() {
        metricsTimer?.invalidate()
        metricsAccumulator.reset()

        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMetricsIfNeeded()
            }
        }
    }

    /// Samples the accumulator and publishes a single `metrics` update.
    ///
    /// Assigning a whole struct once means SwiftUI sees one change per tick instead of the eight
    /// separate `@Published` sends the previous per-field assignment produced.
    private func updateMetricsIfNeeded() {
        // With the HUD hidden nothing reads these numbers, so avoid invalidating the view tree.
        guard showPerformanceOverlay || streamDiagnosticsEnabled else {
            metricsAccumulator.resetFpsWindow()
            return
        }

        let snap = metricsAccumulator.snapshot(currentFps: metrics.currentFps)

        var estimatedRtt: UInt32 = 0
        var estimatedRttVar: UInt32 = 0
        var updated = metrics
        if LiGetEstimatedRttInfo(&estimatedRtt, &estimatedRttVar) {
            updated.roundTripTimeMs = Double(estimatedRtt)
            updated.roundTripTimeVarianceMs = Double(estimatedRttVar)
        }

        updated.currentFps = snap.fps
        updated.decodeTimeMs = snap.decodeTime
        updated.totalFramesRendered = snap.rendered
        updated.totalFramesReceived = snap.received
        updated.totalFramesDropped = snap.dropped
        updated.networkDroppedFrames = snap.netDropped

        if let settings = activeSettings {
            updated.targetFps = settings.fps
            let isRemote = (streamConfigRemotely == STREAM_CFG_REMOTE)
            let activeBitrate = (isRemote && settings.enableRemoteBitrate) ? settings.remoteBitrateMbps : settings.bitrateMbps
            updated.bitrateMbps = Double(activeBitrate)
            updated.resolution = "\(settings.width)x\(settings.height)"
            updated.vsyncEnabled = settings.enableVsync
            updated.pacingEnabled = settings.enableFramePacing
            updated.currentCodec = settings.codec.rawValue
        }

        if streamDiagnosticsEnabled {
            let window = WindowManager.shared.currentWindow
            let values = String(format: "decodeFPS=%.1f metalFPS=%.1f decodeMs=%.2f rttMs=%.1f rttVariationMs=%.1f",
                                updated.currentFps, renderer.currentRenderFps, updated.decodeTimeMs,
                                updated.roundTripTimeMs, updated.roundTripTimeVarianceMs)
            AppLogger.shared.info("\(values) active=\(NSApp.isActive) key=\(window?.isKeyWindow == true) visible=\(window?.occlusionState.contains(.visible) == true) coalescing=\(NSEvent.isMouseCoalescingEnabled)", category: "STREAM-DIAGNOSTICS")
        }
        if showPerformanceOverlay { metrics = updated }
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
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.updateStage(stage: Int(stage), name: stageName)
    }
}

private func sessionStageComplete(stage: Int32) {
    let stageName = LiGetStageName(stage).map { String(cString: $0) } ?? "Stage \(stage)"
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.updateStage(stage: Int(stage), name: stageName)
    }
}

private func sessionStageFailed(stage: Int32, errorCode: Int32) {
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.handleStageFailed(stage: Int(stage), code: Int(errorCode))
    }
}

private func sessionConnectionStarted() {
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.markConnected()
    }
}

private func sessionConnectionTerminated(errorCode: Int32) {
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.handleTerminated(code: Int(errorCode))
    }
}

private func sessionRumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
    GameControllerManager.shared.rumble(controllerNumber: controllerNumber, lowFreqMotor: lowFreqMotor, highFreqMotor: highFreqMotor)
}

private func sessionSetMotionEventState(controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
    // Runs on the connection listener thread; the manager locks its own state.
    GameControllerManager.shared.setMotionRequest(category: motionType, reportRateHz: reportRateHz)
    _ = controllerNumber
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

    /// Moves the FPS sampling window forward without producing a snapshot (used while the HUD is hidden
    /// so re-enabling it does not report a spike averaged over the entire hidden period).
    func resetFpsWindow() {
        lock.lock()
        lastFpsSampleTime = CACurrentMediaTime()
        lastFpsFrameCount = framesRendered
        lock.unlock()
    }
}

