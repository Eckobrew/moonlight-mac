import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import Copus
import MoonlightCommonC

/// Planar float ring buffer shared between the network/Opus decode thread (writer) and the
/// CoreAudio render thread (reader).
///
/// Channel planes share one allocation. Reads use at most two contiguous copies
/// per channel; writes deinterleave the decoded samples under the same short lock.
final class AudioRingBuffer: @unchecked Sendable {
    let channels: Int
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private var writeHead: Int = 0
    private var readHead: Int = 0
    // Head equality is ambiguous after a full-capacity write; track occupancy explicitly.
    private var bufferedFrames: Int = 0
    /// True initially and after an underrun until a ~20ms cushion accumulates, preventing the
    /// CoreAudio 512-frame callback from repeatedly draining 240/480-frame arrivals and padding
    /// every callback tail with zeros.
    private var isBuffering: Bool = true
    private let lock = NSLock()
    private let sampleRate: Double
    private var renderQuantumFrames = 0

    init(channels: Int, capacity: Int = 48000, sampleRate: Double = 48000) {
        precondition(channels > 0 && capacity > 0 && sampleRate.isFinite && sampleRate > 0)
        self.channels = channels
        self.capacity = capacity
        self.sampleRate = sampleRate
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
        bufferedFrames = 0
        isBuffering = true
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

        // Retain enough for the observed render quantum plus a packet cushion.
        // The prebuffer threshold must remain reachable even for 4096+ frames.
        bufferedFrames = min(capacity, bufferedFrames + framesToWrite)
        let prebuffer = prebufferFrames
        let maxAllowed = min(capacity, max(Int(sampleRate * 0.080), prebuffer + Int(sampleRate * 0.010)))
        let targetCushion = min(capacity, max(Int(sampleRate * 0.030), prebuffer))
        if bufferedFrames > maxAllowed {
            bufferedFrames = targetCushion
        }
        readHead = (writeHead - bufferedFrames + capacity) % capacity
    }

    private var prebufferFrames: Int {
        min(capacity, max(renderQuantumFrames + Int(sampleRate * 0.010), Int(sampleRate * 0.020)))
    }

    func read(into bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard frames > 0 else { return false }
        renderQuantumFrames = min(frames, capacity)
        let available = bufferedFrames
        if isBuffering {
            // Wait for at least ~20ms (or one full callback + two 5ms Opus frames) before starting
            // playback so normal 5ms packet intervals vs 10.67ms (512-frame) CoreAudio callbacks
            // never cause partial-buffer underruns.
            let minPrebuffer = prebufferFrames
            if available < minPrebuffer {
                return false
            }
            isBuffering = false
        } else if available == 0 {
            isBuffering = true
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
                // Smoothly fade the last sample to zero across the underrun tail to avoid a hard
                // step discontinuity (click/pop), and re-enter prebuffering to rebuild the cushion.
                let lastSample = framesToRead > 0 ? dest[framesToRead - 1] : 0.0
                let remaining = frames - framesToRead
                for i in 0..<remaining {
                    let scale = Float(remaining - i - 1) / Float(remaining)
                    dest[framesToRead + i] = lastSample * scale
                }
            }
        }

        if framesToRead < frames {
            isBuffering = true
        }

        bufferedFrames -= framesToRead
        readHead += framesToRead
        if readHead >= capacity { readHead -= capacity }
        return true
    }
}

public final class AudioPlaybackEngine: @unchecked Sendable {
    public static let shared = AudioPlaybackEngine()

    // Protect only decoder resources. Control operations never acquire this lock.
    private let lock = NSLock()
    private let output = AudioPlaybackControl()
    private var ringBuffer: AudioRingBuffer?
    private var opusDecoder: OpaquePointer?
    private var channelCount = 2
    private var samplesPerFrame = 240
    private var didElevateDecodeThreadPriority = false
    private var scratchInterleavedBuffer: [Float] = []
    @MainActor private var focusObservers: [NSObjectProtocol] = []

    private init() {}

    public func setup(sampleRate: Double = 48000, channelCount: UInt32 = 2,
                      streams: Int = 1, coupledStreams: Int = 1,
                      samplesPerFrame: Int = 240, mapping: [UInt8] = [0, 1]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        cleanupInternal()
        guard StreamAudioLayout.tag(channels: channelCount) != nil,
              sampleRate.isFinite, (8000...48000).contains(sampleRate),
              samplesPerFrame > 0, samplesPerFrame <= 5760,
              mapping.count >= Int(channelCount) else { return -1 }
        self.channelCount = Int(channelCount)
        self.samplesPerFrame = samplesPerFrame
        didElevateDecodeThreadPriority = false

        var error: Int32 = 0
        var mapping = mapping
        // Use the negotiated mapping directly: common-c already normalizes GFE.
        guard let decoder = opus_multistream_decoder_create(Int32(sampleRate), Int32(channelCount),
                Int32(clamping: streams), Int32(clamping: coupledStreams), &mapping, &error),
              error == OPUS_OK else { return -1 }
        opusDecoder = decoder
        let maxFrames = max(samplesPerFrame * 2, Int(sampleRate * 0.120))
        scratchInterleavedBuffer = [Float](repeating: 0, count: maxFrames * Int(channelCount))
        let ring = AudioRingBuffer(channels: Int(channelCount), capacity: Int(sampleRate), sampleRate: sampleRate)
        ringBuffer = ring
        let installed = output.install { onChange in
            guard let tag = StreamAudioLayout.tag(channels: channelCount),
                  let layout = AVAudioChannelLayout(layoutTag: tag) else {
                throw NSError(domain: "AudioPlaybackEngine", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Unsupported audio channel layout."])
            }
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
            return NativeAudioOutput(ring: ring, format: format, onChange: onChange)
        }
        if !installed { cleanupInternal(); return -1 }
        return 0
    }

    public func start() {
        lock.withLock { ringBuffer?.reset() }
        output.start()
    }

    public func stop() {
        output.stop()
        lock.withLock { ringBuffer?.reset() }
    }

    public func cleanup() { lock.withLock { cleanupInternal() } }

    @MainActor
    public func configureOutput(deviceUID: String?, muteOnFocusLoss: Bool) {
        if focusObservers.isEmpty {
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: OperationQueue.main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.output.updateFocus(NSApp.isActive && !NSApp.isHidden)
                    }
                }
                focusObservers.append(observer)
            }
        }
        output.configure(deviceUID: deviceUID, muteOnFocusLoss: muteOnFocusLoss,
                         appFocused: NSApp.isActive && !NSApp.isHidden)
    }

    public func applyOutputDevice() { output.applyOutputDevice() }

    private func cleanupInternal() {
        output.cleanup()
        if let decoder = opusDecoder { opus_multistream_decoder_destroy(decoder) }
        opusDecoder = nil
        ringBuffer = nil
        scratchInterleavedBuffer.removeAll(keepingCapacity: false)
        // Output preferences and current focus survive engine replacement.
    }

    public func decodeAndPlaySample(sampleData: UnsafePointer<CChar>?, sampleLength: Int) {
        lock.lock()
        guard let decoder = opusDecoder,
              let ring = ringBuffer else {
            lock.unlock()
            return
        }

        // Match moonlight-qt (Session::arDecodeAndPlaySample -> SDL_SetThreadPriority(SDL_THREAD_PRIORITY_HIGH)):
        // PltCreateThread spawns pthreads at QOS_CLASS_DEFAULT, which macOS preempts under CPU load.
        // Elevate the audio decode thread to QOS_CLASS_USER_INTERACTIVE on its first packet.
        if !didElevateDecodeThreadPriority {
            didElevateDecodeThreadPriority = true
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
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

        // Match moonlight-qt (SdlAudioRenderer::submitAudio): always decode the Opus packet so the
        // decoder's internal prediction state remains valid, then drop the output if more than 30ms
        // of audio packets are already queued behind this one in moonlight-common-c's packetQueue.
        if decodedFrames > 0 && LiGetPendingAudioDuration() <= 30 {
            scratchInterleavedBuffer.withUnsafeBufferPointer { pcmPtr in
                ring.write(interleaved: pcmPtr.baseAddress!, frames: Int(decodedFrames))
            }
        } else if decodedFrames < 0 {
            AppLogger.shared.warning("AudioPlaybackEngine: opus_multistream_decode_float error: \(decodedFrames)")
        }

        lock.unlock()
    }
}
