import Foundation
import CoreVideo
import AppKit
import MoonlightCommonC

// Nonisolated engine holder for high-throughput C callbacks
public final class StreamSessionEngine: @unchecked Sendable {
    public static let shared = StreamSessionEngine()

    public let videoDecoder = VideoToolboxDecoder()
    public let audioEngine = AudioPlaybackEngine.shared
    let hdr = StreamHDRState()

    private let callbackLock = NSLock()
    private var callbackGenerationStorage: UInt64 = 0
    fileprivate var callbackGeneration: UInt64 {
        get { callbackLock.withLock { callbackGenerationStorage } }
        set { callbackLock.withLock { callbackGenerationStorage = newValue } }
    }

    private let lifetimeLock = NSLock()
    private var acceptsInput = false
    private var connectionReady = false
    func prepareConnection() { lifetimeLock.withLock { acceptsInput = true; connectionReady = false } }
    func connectionDidStart() { lifetimeLock.withLock { if acceptsInput { connectionReady = true } } }
    func connectionWillStop() { lifetimeLock.withLock { acceptsInput = false; connectionReady = false }; hdr.update(enabled: false) }
    func updateHDR(_ enabled: Bool) {
        lifetimeLock.withLock {
            guard acceptsInput else { return }
            var metadata = SS_HDR_METADATA()
            let available = enabled && LiGetHdrMetadata(&metadata)
            hdr.update(enabled: enabled, metadata: available ? metadata : nil)
        }
    }
    func sampleRtt(read: () -> (Double, Double)? = {
        var rtt: UInt32 = 0, variance: UInt32 = 0
        return LiGetEstimatedRttInfo(&rtt, &variance) ? (Double(rtt), Double(variance)) : nil
    }) -> (Double, Double)? {
        lifetimeLock.withLock { connectionReady ? read() : nil }
    }

    private init() {}
}

@MainActor
public final class StreamSessionController: ObservableObject, VideoDecoderDelegate {
    public static let shared = StreamSessionController()

    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var connectionWarning: String?
    @Published public private(set) var currentStageName: String = ""
    @Published public private(set) var currentStage: Int = 0
    @Published public private(set) var metrics = PerformanceMetrics()
    @Published public private(set) var sessionError: String?
    #if DEBUG
    @Published public var showPerformanceOverlay: Bool = true
    #else
    @Published public var showPerformanceOverlay: Bool = false
    #endif

    @Published public private(set) var runtimeBitrateSupported = false
    @Published public private(set) var runtimeBitrateKbps = 0
    @Published public private(set) var bitrateRequestInProgress = false
    @Published public private(set) var hostStatistics: HostHardwareMetrics?
    @Published public var showHostStatistics = false { didSet { if !showHostStatistics { hostStatistics = nil } } }
    @Published public private(set) var hostControlMessage: String?
    @Published public private(set) var isRemoteMonitorSession = false
    @Published public var showSessionControls = false
    private var controlsWereCaptured = false
    private var controlsGeneration: UInt64 = 0
    public func openSessionControls() {
        guard isStreaming, currentStageName == "Connected", !showSessionControls else { return }
        controlsGeneration = sessionGeneration
        controlsWereCaptured = inputCoordinator.mouseMonitor.isCaptured
        inputCoordinator.keyboardMonitor.raiseAllKeys()
        inputCoordinator.mouseMonitor.isCaptured = false
        showSessionControls = true
    }
    public func closeSessionControls() {
        guard isStreaming, controlsGeneration == sessionGeneration else { return }
        inputCoordinator.mouseMonitor.isCaptured = controlsWereCaptured
    }
    private var bitrateTask: Task<Int, any Error>?
    private var preserveHostApplication = false
    private var hostServicesTask: Task<Void, Never>?

    public func applyRuntimeBitrate(mbps: Double) async {
        guard runtimeBitrateSupported, !bitrateRequestInProgress, isStreaming, currentStageName == "Connected",
              let host = activeHost, mbps.isFinite, (0.001...500).contains(mbps) else { return }
        let generation = sessionGeneration
        bitrateRequestInProgress = true
        defer { if sessionGeneration == generation { bitrateRequestInProgress = false; bitrateTask = nil } }
        do {
            let pending = Task { try await SunshineHTTPClient.shared.setRuntimeBitrate(host: host, kbps: Int((mbps * 1000).rounded())) }
            bitrateTask = pending
            let applied = try await pending.value
            guard acceptsCallback(generation: generation) else { return }
            runtimeBitrateKbps = applied
            hostControlMessage = "Host applied \(String(format: "%.1f", Double(applied) / 1000)) Mbps."
        } catch {
            guard acceptsCallback(generation: generation) else { return }
            hostControlMessage = error.localizedDescription
        }
    }

    public func runServerCommand(index: Int, name: String) async {
        guard isStreaming, currentStageName == "Connected", let host = activeHost,
              host.capabilities?.canRunCommands == true, (0...255).contains(index) else { return }
        let generation = sessionGeneration
        do {
            let (updated, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
            guard acceptsCallback(generation: generation), updated.capabilities?.canRunCommands == true,
                  updated.capabilities?.commands.indices.contains(index) == true,
                  updated.capabilities?.commands[index] == name else {
                if acceptsCallback(generation: generation) { hostControlMessage = "Host commands changed. Reconnect before choosing a command again." }
                return
            }
            // Serialize with queued key releases; never call common-c after teardown.
            let queued = LiSendHostCommand(UInt8(index))
            hostControlMessage = queued == 0 ? "Command submitted to host: \(name)" : "The command could not be queued."
        } catch {
            if acceptsCallback(generation: generation) { hostControlMessage = error.localizedDescription }
        }
    }

    public func disconnectRemoteMonitor() async {
        guard isRemoteMonitorSession, let host = activeHost, currentStageName == "Connected" else { return }
        let generation = sessionGeneration
        do {
            let catalogue = try await SunshineHTTPClient.shared.fetchAppList(host: host)
            guard acceptsCallback(generation: generation), let action = catalogue.first(where: { $0.control == .disconnectMonitor }) else { return }
            // Release local video first; the explicit host action then releases
            // any retained monitor. Never use /cancel for a monitor session.
            stopSession()
            let connectionStop = stoppingTask
            let release = Task.detached {
                await connectionStop?.value
                return try await SunshineHTTPClient.shared.performHostAction(host: host, app: action)
            }
            // A reconnect must not create a new monitor until the old release
            // request has finished; the host endpoint is bound to this client.
            stoppingTask = Task.detached { _ = try? await release.value }
            _ = try await release.value
        } catch {
            hostControlMessage = error.localizedDescription
        }
    }

    private func startHostServices() {
        hostServicesTask?.cancel()
        guard let host = activeHost else { return }
        let generation = sessionGeneration
        hostServicesTask = Task { [weak self] in
            let supported = await SunshineHTTPClient.shared.supportsRuntimeBitrate(host: host)
            guard let self, self.acceptsCallback(generation: generation), !Task.isCancelled else { return }
            self.runtimeBitrateSupported = supported
            var delay = 1.0
            while self.acceptsCallback(generation: generation), !Task.isCancelled {
                if self.showHostStatistics && self.showPerformanceOverlay && host.capabilities?.hardwareMetricsVersion == 1 {
                    do {
                        let sample = try await SunshineHTTPClient.shared.fetchHardwareMetrics(host: host)
                        guard self.acceptsCallback(generation: generation), !Task.isCancelled else { return }
                        if self.showHostStatistics && self.showPerformanceOverlay { self.hostStatistics = sample }
                        delay = max(1, Double(sample.interval_ms) / 1000)
                    } catch {
                        guard self.acceptsCallback(generation: generation), !Task.isCancelled else { return }
                        self.hostStatistics = nil
                        if let error = error as? HostControlError, [403, 409].contains(error.code) {
                            self.showHostStatistics = false
                            self.hostControlMessage = error.message
                        }
                        delay = min(30, max(2, delay * 2))
                    }
                } else {
                    self.hostStatistics = nil
                    delay = 1
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

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
    public var onSessionStarted: (@MainActor () -> Void)?
    public var onSessionStopped: (@MainActor () -> Void)?
    private var activeApp: StreamApp?
    private var negotiatedVideoSize: CGSize?
    private var negotiatedCodec: String?
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
        guard isStreaming, currentStageName != "Connected" else { return }
        self.currentStageName = "Connected"
        startConnectedServices()
    }

    fileprivate func videoWasConfigured(format: Int32, width: Int32, height: Int32) {
        negotiatedVideoSize = CGSize(width: Int(width), height: Int(height))
        negotiatedCodec = format & VIDEO_FORMAT_MASK_AV1 != 0 ? "AV1" : format & VIDEO_FORMAT_MASK_H265 != 0 ? "HEVC" : "H.264"
        if format & VIDEO_FORMAT_MASK_YUV444 != 0 { negotiatedCodec? += " 4:4:4" }
        inputCoordinator.mouseMonitor.videoSize = negotiatedVideoSize!
    }

    func updateHDR(_ enabled: Bool) {
        guard isStreaming else { return }
        MetalStreamRenderer.shared.isHdrActive = enabled && activeSettings?.enableHdr == true
    }
    func updateConnectionStatus(_ status: Int32) {
        guard isStreaming else { return }
        connectionWarning = status == CONN_STATUS_POOR ? "Network quality is poor. Try lowering the bitrate." : nil
    }

    public func handleStageFailed(stage: Int, code: Int) {
        guard isStreaming else { return }
        self.sessionError = ConnectionDiagnostics.stageFailure(stage: Int32(stage), code: Int32(code))
        self.stopSession()
    }

    public func handleTerminated(code: Int) {
        guard isStreaming else { return }
        self.sessionError = ConnectionDiagnostics.termination(Int32(code))
        self.stopSession()
    }

    public func clearError() {
        self.sessionError = nil
    }

    private var didLaunchHostApp = false
    var hostAppIDForShutdown: Int? { isShortcutMode && !isRemoteMonitorSession ? activeApp?.id : nil }
    public var shouldQuitHostAppOnStop: Bool {
        !isRemoteMonitorSession && !preserveHostApplication && (isShortcutMode ? didLaunchHostApp : activeSettings?.quitAppOnStop == true)
    }

    public func startSession(host: Host, app: StreamApp, settings: StreamSettings) async {
        guard !isStreaming else { return }
        if let error = settings.validationMessage { sessionError = error; onSessionStopped?(); return }
        // Snapshot the launching window/display before awaiting teardown or
        // replacing views. AppKit's key window can change during those operations.
        let screen = WindowManager.shared.currentWindow?.screen ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let actualRefresh = displayID.flatMap { CGDisplayCopyDisplayMode($0)?.refreshRate } ?? 0
        displayRefreshRateX100 = Int32((actualRefresh > 0 ? actualRefresh : Double(screen?.maximumFramesPerSecond ?? 60)) * 100)
        var effectiveSettings = settings
        effectiveSettings.controllerMask = GameControllerManager.launchMask(persistent: settings.features.persistentGamepad, extendedSlots: host.supportsExtendedControllers)
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

        self.didLaunchHostApp = false
        self.preserveHostApplication = app.control == .resume
        self.isRemoteMonitorSession = app.isRemoteMonitor || PerAppSettingsStore.shared.overrides(for: host, app: app).remoteMonitorProfile == true
        self.hostControlMessage = nil
        self.runtimeBitrateSupported = false
        self.bitrateRequestInProgress = false
        self.hostStatistics = nil
        self.showHostStatistics = false
        self.activeHost = host
        self.activeApp = app
        self.activeSettings = effectiveSettings
        self.isStreaming = true
        self.sessionError = nil
        self.connectionWarning = nil
        negotiatedVideoSize = nil
        negotiatedCodec = nil
        self.currentStageName = "Requesting session from host..."
        onSessionStarted?()

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
            // Resolve the current route immediately before launching. A saved LAN
            // address may no longer be reachable when the client leaves home.
            let (host, _) = try await SunshineHTTPClient.shared.fetchServerInfo(host: host)
            guard acceptsCallback(generation: generation), !Task.isCancelled else { return }
            self.activeHost = host
            let sessionUrl: String?
            if app.matchesRunning(on: host) || app.control == .resume {
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
                    appUUID: app.uuid,
                    settings: effectiveSettings,
                    rikey: rikeyHex,
                    rikeyId: rikeyId
                )
            }

            guard isStreaming, sessionGeneration == generation else { return }
            try Task.checkCancellation()
            didLaunchHostApp = !app.matchesRunning(on: host) && !isRemoteMonitorSession
            // Custom monitor profiles are not marked in legacy applist XML.
            // The authenticated post-launch catalogue identifies our owned role.
            if host.capabilities?.permission != nil,
               let catalogue = try? await SunshineHTTPClient.shared.fetchAppList(host: host),
               catalogue.contains(where: { $0.control == .disconnectMonitor }) {
                guard acceptsCallback(generation: generation) else { return }
                isRemoteMonitorSession = true
                didLaunchHostApp = false
            }

            MetalStreamRenderer.shared.enableVsync = effectiveSettings.enableVsync
            MetalStreamRenderer.shared.isHdrActive = false
            videoDecoder.decoderPreference = effectiveSettings.features.decoder

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
            self.runtimeBitrateKbps = effectiveSettings.streamBitrateKbps(isRemote: isRemote)
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


        } catch {
            guard sessionGeneration == generation, isStreaming else { return }
            self.sessionError = error.localizedDescription
            self.stopSession()
        }
    }

    private func startConnectedServices() {
        guard let settings = activeSettings else { return }
        GameControllerManager.shared.configure(settings.features, extendedSlots: activeHost?.supportsExtendedControllers == true)
        inputCoordinator.mouseMonitor.desktopMode = settings.features.desktopMouse
        // Input is accepted only after the library has initialized its input stream.
        inputCoordinator.startCapturing(
            captureMouse: settings.mouseCaptureMode || settings.features.desktopMouse,
            mouseSensitivity: settings.mouseSensitivity,
            mouseSensitivityX: settings.mouseSensitivityX,
            mouseSensitivityY: settings.mouseSensitivityY,
            mouseSubPixelAccumulation: settings.mouseSubPixelAccumulation,
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
                    self?.inputCoordinator.mouseMonitor.toggleMode()
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
            },
            onSessionControls: { [weak self] in
                Task { @MainActor [weak self] in self?.openSessionControls() }
            }
        )

        inputCoordinator.mouseMonitor.swapButtons = settings.features.swapMouseButtons
        inputCoordinator.mouseMonitor.reverseScroll = settings.features.reverseScroll
        inputCoordinator.mouseMonitor.videoSize = negotiatedVideoSize ?? CGSize(width: settings.width, height: settings.height)
        if settings.features.discordPresence, let host = activeHost, let app = activeApp {
            DiscordPresence.shared.start(applicationID: settings.features.discordApplicationID, game: app.title, host: host.name)
        }
        startMetricsPolling()
        startHostServices()
        if let host = activeHost, activeSettings?.enableClipboardSync == true {
            ClipboardSyncManager.shared.start(host: host)
        }

    }

    private var streamConfigRemotely: Int32 = STREAM_CFG_LOCAL
    private var displayRefreshRateX100: Int32 = 6000

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
        StreamSessionEngine.shared.prepareConnection()
        let refreshRateX100 = displayRefreshRateX100
        streamTask = Task.detached(priority: .high) {
            guard !Task.isCancelled else { return }
            var streamConfig = STREAM_CONFIGURATION()
            LiInitializeStreamConfiguration(&streamConfig)

            // Let the library classify the connection itself by resolving the address and testing
            // it against private/NAT64 ranges. That classification is what enables its remote
            // packet-size cap (1024 bytes IPv4, 1184 IPv6) and the 500 Kbps bitrate headroom
            // subtraction in the SDP. Passing STREAM_CFG_LOCAL/.REMOTE skipped both.
            streamConfig.streamingRemotely = Int32(STREAM_CFG_AUTO)

            let chosenBitrateKbps = settings.streamBitrateKbps(isRemote: isRemote)
            AppLogger.shared.info("Using \(chosenBitrateKbps) Kbps (\(isRemote ? "remote" : "local") connection)", category: "SESSION")

            streamConfig.width = Int32(settings.width)
            streamConfig.height = Int32(settings.height)
            streamConfig.fps = Int32(settings.fps)
            streamConfig.bitrate = Int32(chosenBitrateKbps)
            streamConfig.packetSize = Int32(settings.packetSize)
            streamConfig.supportedVideoFormats = settings.videoFormatMask
            streamConfig.clientRefreshRateX100 = refreshRateX100
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
            clCallbacks.connectionStatusUpdate = sessionConnectionStatus
            clCallbacks.setHdrMode = sessionHDR
            clCallbacks.rumbleTriggers = sessionTriggerRumble
            clCallbacks.setControllerLED = sessionLED
            clCallbacks.setAdaptiveTriggers = sessionAdaptiveTriggers

            var drCallbacks = DECODER_RENDERER_CALLBACKS()
            LiInitializeVideoCallbacks(&drCallbacks)
            drCallbacks.setup = sessionVideoSetup
            drCallbacks.start = sessionVideoStart
            drCallbacks.stop = sessionVideoStop
            drCallbacks.cleanup = sessionVideoCleanup
            drCallbacks.submitDecodeUnit = sessionVideoSubmitDecodeUnit
            // VideoToolbox setup/recovery can block; use the library's decoder worker.
            drCallbacks.capabilities = 0

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

    func waitForConnectionStop() async { await stoppingTask?.value }

    public func stopSession() {
        // Also invalidate a reconnect that is still waiting for old cleanup.
        sessionGeneration &+= 1
        StreamSessionEngine.shared.connectionWillStop()
        let isShortcut = isShortcutMode
        let hostToQuit = activeHost
        let shouldQuitHostApp = shouldQuitHostAppOnStop
        let expectedAppID = isShortcut ? activeApp?.id : nil

        if isShortcut {
            WindowManager.shared.hideStreamWindow()
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
        hostServicesTask?.cancel()
        hostServicesTask = nil
        let pendingBitrate = bitrateTask
        pendingBitrate?.cancel()
        bitrateTask = nil
        hostStatistics = nil
        runtimeBitrateSupported = false
        bitrateRequestInProgress = false
        showSessionControls = false
        ClipboardSyncManager.shared.stop()
        DiscordPresence.shared.stop()
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
        let inputStop = Task { @MainActor [weak self] in
            guard let self, !self.isStreaming else { return }
            self.inputCoordinator.stopCapturing()
            WindowManager.shared.closeStreamWindow(showBrowser: !self.isShortcutMode)
        }

        // 4. Stop Limelight C connection on background thread (waits for and joins worker threads)
        let connectionTask = streamTask
        connectionTask?.cancel()
        LiInterruptConnection()
        stoppingTask = Task.detached(priority: .userInitiated) {
            // LiStartConnection performs its own cleanup on failure. Never run
            // LiStopConnection concurrently with that cleanup.
            await inputStop.value
            _ = try? await pendingBitrate?.value
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
                await HostAppShutdown.quit(host: host, expectedAppID: expectedAppID)

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

        let generation = sessionGeneration
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.acceptsCallback(generation: generation) else { return }
                self.updateMetricsIfNeeded()
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

        var updated = metrics
        let rtt = StreamSessionEngine.shared.sampleRtt()
        updated.roundTripTimeMs = rtt?.0 ?? 0
        updated.roundTripTimeVarianceMs = rtt?.1 ?? 0

        updated.currentFps = snap.fps
        updated.decodeTimeMs = snap.decodeTime
        updated.totalFramesRendered = snap.rendered
        updated.totalFramesReceived = snap.received
        updated.totalFramesDropped = snap.dropped
        updated.networkDroppedFrames = snap.netDropped

        if let settings = activeSettings {
            updated.targetFps = settings.fps
            let isRemote = (streamConfigRemotely == STREAM_CFG_REMOTE)
            updated.bitrateMbps = Double(runtimeBitrateKbps > 0 ? runtimeBitrateKbps : settings.streamBitrateKbps(isRemote: isRemote)) / 1000
            let size = negotiatedVideoSize ?? CGSize(width: settings.width, height: settings.height)
            updated.resolution = "\(Int(size.width))x\(Int(size.height))"
            updated.vsyncEnabled = settings.videoRenderer == .native || settings.enableVsync
            updated.pacingEnabled = settings.enableFramePacing
            updated.currentCodec = negotiatedCodec ?? settings.codec.rawValue
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
        StreamSessionEngine.shared.hdr.apply(to: pixelBuffer)
        FramePacer.shared.submit(pixelBuffer: pixelBuffer)
        metricsAccumulator.recordRender(decodeTimeMs: decodeTimeMs)
    }

    public nonisolated func decoderDidFail(reason: String) {
        let generation = StreamSessionEngine.shared.callbackGeneration
        Task { @MainActor in
            guard self.acceptsCallback(generation: generation) else { return }
            self.sessionError = reason
            self.stopSession()
        }
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
    StreamSessionEngine.shared.connectionDidStart()
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
    GameControllerManager.shared.setMotionRequest(controllerNumber: controllerNumber, category: motionType, reportRateHz: reportRateHz)
}

private func sessionVideoSetup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32, context: UnsafeMutableRawPointer?, drFlags: Int32) -> Int32 {
    let generation = StreamSessionEngine.shared.callbackGeneration
    let result = StreamSessionEngine.shared.videoDecoder.setup(videoFormat: videoFormat, width: width, height: height)
    if result == 0 {
        Task { @MainActor in
            guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
            StreamSessionController.shared.videoWasConfigured(format: videoFormat, width: width, height: height)
        }
    }
    return result
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


private func sessionConnectionStatus(status: Int32) {
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.updateConnectionStatus(status)
    }
}
private func sessionHDR(enabled: Bool) {
    StreamSessionEngine.shared.updateHDR(enabled)
    let generation = StreamSessionEngine.shared.callbackGeneration
    Task { @MainActor in
        guard StreamSessionController.shared.acceptsCallback(generation: generation) else { return }
        StreamSessionController.shared.updateHDR(enabled)
    }
}
private func sessionTriggerRumble(slot: UInt16, left: UInt16, right: UInt16) {
    GameControllerManager.shared.rumbleTriggers(slot: slot, left: left, right: right)
}
private func sessionLED(slot: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
    GameControllerManager.shared.setLED(slot: slot, red: red, green: green, blue: blue)
}
private func sessionAdaptiveTriggers(slot: UInt16, flags: UInt8, leftType: UInt8, rightType: UInt8, left: UnsafeMutablePointer<UInt8>?, right: UnsafeMutablePointer<UInt8>?) {
    let left = left.map { Array(UnsafeBufferPointer(start: $0, count: 10)) } ?? []
    let right = right.map { Array(UnsafeBufferPointer(start: $0, count: 10)) } ?? []
    GameControllerManager.shared.setAdaptiveTriggers(slot: slot, flags: flags, leftType: leftType, rightType: rightType, left: left, right: right)
}
