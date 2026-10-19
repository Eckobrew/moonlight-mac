import Foundation
import AVFoundation
import AudioToolbox
import Copus
import MoonlightCommonC
import QuartzCore

final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int
    private var channelData: [UnsafeMutablePointer<Float>]
    private var writeHead: Int = 0
    private var readHead: Int = 0
    private let lock = NSLock()

    init(channels: Int, capacity: Int = 48000) {
        self.channels = channels
        self.capacity = capacity
        self.channelData = (0..<channels).map { _ in
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            ptr.initialize(repeating: 0, count: capacity)
            return ptr
        }
    }

    deinit {
        for ptr in channelData {
            ptr.deinitialize(count: capacity)
            ptr.deallocate()
        }
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

        let chCount = channels
        for f in 0..<frames {
            let writePos = (writeHead + f) % capacity
            let frameOffset = f * chCount
            for ch in 0..<chCount {
                channelData[ch][writePos] = interleaved[frameOffset + ch]
            }
        }
        writeHead = (writeHead + frames) % capacity

        // Low-latency buffer clamp: if accumulated buffer exceeds 50ms (2400 frames at 48kHz), drain excess
        let available = (writeHead >= readHead) ? (writeHead - readHead) : (capacity - readHead + writeHead)
        let maxAllowed = 2400
        if available > maxAllowed {
            readHead = (writeHead - maxAllowed + capacity) % capacity
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
        let chCount = channels
        let bufferListPtr = UnsafeMutableAudioBufferListPointer(bufferList)

        for ch in 0..<min(chCount, bufferListPtr.count) {
            guard let dest = bufferListPtr[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<framesToRead {
                let readPos = (readHead + f) % capacity
                dest[f] = channelData[ch][readPos]
            }
            if framesToRead < frames {
                // Zero out remaining frames in underrun
                for f in framesToRead..<frames {
                    dest[f] = 0
                }
            }
        }

        readHead = (readHead + framesToRead) % capacity
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

        if channelCount == 8 && mappingArray.count >= 8 {
            mappingArray.swapAt(4, 6)
            mappingArray.swapAt(5, 7)
        }

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

        // Pre-allocate scratch buffer for decoding up to 120ms of audio (5760 frames)
        let maxFrames = max(samplesPerFrame * 2, 5760)
        self.scratchInterleavedBuffer = [Float](repeating: 0, count: maxFrames * Int(channelCount))

        // Create AudioRingBuffer (48000 frames capacity = 1.0 second buffer)
        let ring = AudioRingBuffer(channels: Int(channelCount), capacity: 48000)
        self.ringBuffer = ring

        // Select CoreAudio Channel Layout
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
