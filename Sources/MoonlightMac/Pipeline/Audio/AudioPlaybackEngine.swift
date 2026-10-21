import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import Copus
import MoonlightCommonC
import QuartzCore

/// Planar float ring buffer shared between the network/Opus decode thread (writer) and the
/// CoreAudio render thread (reader).
///
/// All channel planes live in a single allocation so a wrapped write/read is at most two
/// `memcpy`s per channel instead of a per-element modulo + bounds-checked loop. This keeps the
/// lock hold time low enough that the real-time audio callback never blocks long enough to
/// underrun.
final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private var writeHead: Int = 0
    private var readHead: Int = 0
    private let lock = NSLock()

    init(channels: Int, capacity: Int = 48000) {
        self.channels = channels
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: channels * capacity)
        self.storage.initialize(repeating: 0, count: channels * capacity)
    }

    deinit {
        storage.deinitialize(count: channels * capacity)
        storage.deallocate()
    }

    /// Base pointer of one channel plane.
    private func plane(_ channel: Int) -> UnsafeMutablePointer<Float> {
        storage + channel * capacity
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeHead = 0
        readHead = 0
    }

    func write(interleaved: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        // Never write more than one full buffer; keeping the newest tail of the packet.
        let framesToWrite = min(frames, capacity)
        let source = interleaved + (frames - framesToWrite) * channels
        let firstChunk = min(framesToWrite, capacity - writeHead)
        let secondChunk = framesToWrite - firstChunk

        for ch in 0..<channels {
            let dest = plane(ch)
            if secondChunk == 0 {
                // Contiguous: de-interleave directly into the plane.
                var src = source + ch
                var dst = dest + writeHead
                for _ in 0..<framesToWrite {
                    dst.pointee = src.pointee
                    src += channels
                    dst += 1
                }
            } else {
                var src = source + ch
                var dst = dest + writeHead
                for _ in 0..<firstChunk {
                    dst.pointee = src.pointee
                    src += channels
                    dst += 1
                }
                dst = dest
                for _ in 0..<secondChunk {
                    dst.pointee = src.pointee
                    src += channels
                    dst += 1
                }
            }
        }

        writeHead += framesToWrite
        if writeHead >= capacity { writeHead -= capacity }

        // Low-latency buffer clamp: if accumulated buffer exceeds 50ms (2400 frames at 48kHz), drop the oldest audio
        let available = (writeHead >= readHead) ? (writeHead - readHead) : (capacity - readHead + writeHead)
        let maxAllowed = 2400
        if available > maxAllowed {
            readHead = writeHead - maxAllowed
            if readHead < 0 { readHead += capacity }
        }
    }

    func read(into bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let available = (writeHead >= readHead) ? (writeHead - readHead) : (capacity - readHead + writeHead)
        if available == 0 {
            return false
        }

        let framesToRead = min(available, frames)
        let firstChunk = min(framesToRead, capacity - readHead)
        let secondChunk = framesToRead - firstChunk
        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)

        for ch in 0..<min(channels, bufferListPtr.count) {
            guard let dest = bufferListPtr[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let source = plane(ch)

            dest.update(from: source + readHead, count: firstChunk)
            if secondChunk > 0 {
                (dest + firstChunk).update(from: source, count: secondChunk)
            }
            if framesToRead < frames {
                // Zero out remaining frames in underrun
                (dest + framesToRead).initialize(repeating: 0, count: frames - framesToRead)
            }
        }

        readHead += framesToRead
        if readHead >= capacity { readHead -= capacity }
        return true
    }
}

public final class AudioPlaybackEngine: @unchecked Sendable {
    public static let shared = AudioPlaybackEngine()

    private let lock = NSLock()
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var audioFormat: AVAudioFormat?
    private var ringBuffer: AudioRingBuffer?

    private var opusDecoder: OpaquePointer?
    private var sampleRate: Double = 48000.0
    private var channelCount: Int = 2
    private var samplesPerFrame: Int = 240
    private var isPlaying = false
    private var scratchInterleavedBuffer: [Float] = []
    private var configurationObserver: NSObjectProtocol?
    private var focusObservers: [NSObjectProtocol] = []

    /// CoreAudio UID of the requested output device (nil = system default).
    private var preferredOutputDeviceUID: String?
    /// Silence output while another app is focused (user preference).
    private var muteOnFocusLoss = false
    /// Whether playback is currently muted because Moonlight is not frontmost.
    private var isMutedForFocus = false

    private init() {}

    public func setup(
        sampleRate: Double = 48000.0,
        channelCount: UInt32 = 2,
        streams: Int = 1,
        coupledStreams: Int = 1,
        samplesPerFrame: Int = 240,
        mapping: [UInt8] = [0, 1]
    ) -> Int32 {
        lock.lock()
        defer { lock.unlock() }

        cleanupInternal()

        self.sampleRate = sampleRate
        self.channelCount = Int(channelCount)
        self.samplesPerFrame = samplesPerFrame

        AppLogger.shared.info("AudioPlaybackEngine: Initializing original low-latency AVAudioEngine (\(sampleRate) Hz, \(channelCount) ch, \(streams) streams, \(coupledStreams) coupled, \(samplesPerFrame) samples/frame)")

        var error: Int32 = 0
        var mappingArray = mapping
        if mappingArray.count < Int(channelCount) {
            mappingArray = (0..<UInt8(channelCount)).map { $0 }
        }

        // Do NOT reorder the mapping here. moonlight-common-c already rewrites GFE's
        // `FL FR C RL RR SL SR LFE` order into `FL FR C LFE RL RR SL SR` for 5.1 and 7.1
        // (RtspConnection.c, right after parseOpusConfigFromParamString), and that remapped order
        // is exactly the interleaved order opus_multistream_decode_float produces. Swapping
        // mapping[4..7] here applied the GFE reorder a second time and scrambled surround channels.

        let decoder = opus_multistream_decoder_create(
            Int32(sampleRate),
            Int32(channelCount),
            Int32(streams),
            Int32(coupledStreams),
            &mappingArray,
            &error
        )

        guard let decoder = decoder, error == OPUS_OK else {
            AppLogger.shared.error("AudioPlaybackEngine: opus_multistream_decoder_create failed with error: \(error)")
            return -1
        }

        self.opusDecoder = decoder

        // Pre-allocate the scratch buffer for the largest legal Opus packet: 120ms at 48kHz =
        // 5760 frames. The library advertises CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION, so the
        // host may legitimately send more than samplesPerFrame*2 and previously the decode would
        // silently truncate to a smaller buffer.
        let maxFrames = max(samplesPerFrame * 2, 5760)
        self.scratchInterleavedBuffer = [Float](repeating: 0, count: maxFrames * Int(channelCount))

        // Create AudioRingBuffer (48000 frames capacity = 1.0 second buffer)
        let ring = AudioRingBuffer(channels: Int(channelCount), capacity: 48000)
        self.ringBuffer = ring

        // Select CoreAudio Channel Layout.
        //
        // The decoder emits the library's canonical order FL FR C LFE RL RR SL SR. CoreAudio's
        // AudioUnit_7_1 is L R C LFE Rls Rrs Ls Rs, which is that same 6.1-ordered layout, so it
        // matches directly. MPEG_5_1_A is L R C LFE Ls Rs, also matching FL FR C LFE RL RR.
        let layoutTag: AudioChannelLayoutTag
        switch channelCount {
        case 6:
            layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        case 8:
            layoutTag = kAudioChannelLayoutTag_AudioUnit_7_1
        default:
            layoutTag = kAudioChannelLayoutTag_Stereo
        }

        guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            AppLogger.shared.error("AudioPlaybackEngine: Failed to create AVAudioChannelLayout for tag \(layoutTag)")
            return -1
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: channelLayout)
        self.audioFormat = format

        // Create the engine and pick up the requested output device lazily on start, because
        // kAudioOutputUnitProperty_CurrentDevice can only be set once the output unit exists.
        let engine = AVAudioEngine()

        let source = AVAudioSourceNode(format: format) { [weak ring] isSilence, _, frameCount, outputData -> OSStatus in
            guard let ring = ring else {
                isSilence.pointee = ObjCBool(true)
                let abl = UnsafeMutableAudioBufferListPointer(outputData)
                for buf in abl {
                    if let ptr = buf.mData {
                        memset(ptr, 0, Int(buf.mDataByteSize))
                    }
                }
                return noErr
            }
            let hasData = ring.read(into: outputData, frames: Int(frameCount))
            if hasData {
                isSilence.pointee = ObjCBool(false)
            } else {
                isSilence.pointee = ObjCBool(true)
                let abl = UnsafeMutableAudioBufferListPointer(outputData)
                for buf in abl {
                    if let ptr = buf.mData {
                        memset(ptr, 0, Int(buf.mDataByteSize))
                    }
                }
            }
            return noErr
        }

        self.audioEngine = engine
        self.sourceNode = source

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // Output device selection and focus-loss muting are applied per start; register the focus
        // observers here so they live as long as the engine.
        installFocusObservers()

        // Observe route and configuration changes to resume playback seamlessly
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        AppLogger.shared.info("AudioPlaybackEngine: Successfully initialized original low-latency AVAudioEngine (\(channelCount) channels)")
        return 0
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard let engine = audioEngine, !isPlaying else { return }

        ringBuffer?.reset()
        do {
            try engine.start()
            isPlaying = true

            // The output unit exists only after start(), so route to the selected device now.
            AudioOutputDevices.apply(deviceUID: preferredOutputDeviceUID, to: engine)
            // Re-apply a pending mute (e.g. session started while another app had focus).
            engine.mainMixerNode.outputVolume = isMutedForFocus ? 0.0 : 1.0

            AppLogger.shared.info("AudioPlaybackEngine: AVAudioEngine started successfully")
        } catch {
            AppLogger.shared.error("AudioPlaybackEngine: Failed to start AVAudioEngine: \(error.localizedDescription)")
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isPlaying else { return }
        audioEngine?.stop()
        isPlaying = false
        ringBuffer?.reset()
        AppLogger.shared.info("AudioPlaybackEngine: AVAudioEngine stopped")
    }

    public func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        cleanupInternal()
    }

    /// Configures audio output routing and focus-loss muting for the next/current session.
    public func configureOutput(deviceUID: String?, muteOnFocusLoss: Bool) {
        lock.lock()
        self.preferredOutputDeviceUID = deviceUID
        self.muteOnFocusLoss = muteOnFocusLoss
        lock.unlock()

        if muteOnFocusLoss {
            updateFocusMuteState()
        } else {
            lock.lock()
            isMutedForFocus = false
            audioEngine?.mainMixerNode.outputVolume = 1.0
            lock.unlock()
        }
    }

    /// Applies the selected output device while a session is running.
    public func applyOutputDevice() {
        lock.lock()
        guard let engine = audioEngine, isPlaying else {
            lock.unlock()
            return
        }
        let uid = preferredOutputDeviceUID
        lock.unlock()

        AudioOutputDevices.apply(deviceUID: uid, to: engine)
    }

    private func installFocusObservers() {
        removeFocusObservers()
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateFocusMuteState()
            }
            focusObservers.append(observer)
        }
    }

    private func removeFocusObservers() {
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        focusObservers.removeAll()
    }

    private func updateFocusMuteState() {
        // NSApplication is MainActor-isolated; observers are registered on the main queue, but the
        // compiler cannot prove it, so hop explicitly.
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyFocusMuteState() }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyFocusMuteState() }
            }
        }
    }

    @MainActor
    private func applyFocusMuteState() {
        lock.lock()
        defer { lock.unlock() }
        guard muteOnFocusLoss else {
            isMutedForFocus = false
            audioEngine?.mainMixerNode.outputVolume = 1.0
            return
        }
        let app = NSApplication.shared
        let isActive = app.isActive && !app.isHidden
        isMutedForFocus = !isActive
        audioEngine?.mainMixerNode.outputVolume = isActive ? 1.0 : 0.0
    }

    private func cleanupInternal() {
        if isPlaying {
            audioEngine?.stop()
            isPlaying = false
        }

        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }

        if let decoder = opusDecoder {
            opus_multistream_decoder_destroy(decoder)
            opusDecoder = nil
        }

        if let source = sourceNode, let engine = audioEngine {
            engine.disconnectNodeOutput(source)
            engine.detach(source)
        }

        sourceNode = nil
        audioEngine = nil
        audioFormat = nil
        ringBuffer = nil
        scratchInterleavedBuffer.removeAll(keepingCapacity: false)
        isMutedForFocus = false
        removeFocusObservers()
    }

    private func handleConfigurationChange() {
        lock.lock()
        defer { lock.unlock() }
        guard let engine = audioEngine, isPlaying else { return }
        AppLogger.shared.info("AudioPlaybackEngine: Output route changed, restarting audio engine...")
        do {
            try engine.start()
        } catch {
            AppLogger.shared.error("AudioPlaybackEngine: Restart after route change failed: \(error.localizedDescription)")
        }
    }

    public func decodeAndPlaySample(sampleData: UnsafePointer<CChar>?, sampleLength: Int) {
        lock.lock()
        guard let decoder = opusDecoder,
              let ring = ringBuffer else {
            lock.unlock()
            return
        }

        if !isPlaying {
            do {
                ring.reset()
                try audioEngine?.start()
                isPlaying = true
            } catch {
                AppLogger.shared.error("AudioPlaybackEngine: Auto-start failed: \(error.localizedDescription)")
                lock.unlock()
                return
            }
        }

        let chCount = channelCount
        let frameCapacity = scratchInterleavedBuffer.count / chCount

        let decodedFrames: Int32
        if let data = sampleData, sampleLength > 0 {
            decodedFrames = scratchInterleavedBuffer.withUnsafeMutableBufferPointer { pcmPtr in
                opus_multistream_decode_float(
                    decoder,
                    UnsafePointer<UInt8>(OpaquePointer(data)),
                    Int32(sampleLength),
                    pcmPtr.baseAddress!,
                    Int32(frameCapacity),
                    0
                )
            }
        } else {
            // Packet loss concealment (PLC)
            decodedFrames = scratchInterleavedBuffer.withUnsafeMutableBufferPointer { pcmPtr in
                opus_multistream_decode_float(
                    decoder,
                    nil,
                    0,
                    pcmPtr.baseAddress!,
                    Int32(samplesPerFrame),
                    0
                )
            }
        }

        if decodedFrames > 0 {
            scratchInterleavedBuffer.withUnsafeBufferPointer { pcmPtr in
                ring.write(interleaved: pcmPtr.baseAddress!, frames: Int(decodedFrames))
            }
        } else if decodedFrames < 0 {
            AppLogger.shared.warning("AudioPlaybackEngine: opus_multistream_decode_float error: \(decodedFrames)")
        }

        lock.unlock()

        AVPacingClock.shared.registerAudioTimestamp(hostTimeUs: UInt64(CACurrentMediaTime() * 1_000_000))
    }
}
