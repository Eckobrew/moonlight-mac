import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

public final class AudioPlaybackEngine: @unchecked Sendable {
    public static let shared = AudioPlaybackEngine()

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var audioConverter: AudioConverterRef?

    private var sampleRate: Double = 48000.0
    private var channelCount: UInt32 = 2
    private var isPlaying = false

    private init() {}

    public func setup(sampleRate: Double = 48000.0, channelCount: UInt32 = 2) -> Int32 {
        self.sampleRate = sampleRate
        self.channelCount = channelCount

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount) else {
            return -1
        }

        self.audioFormat = format
        self.audioEngine = engine
        self.playerNode = player

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        setupAudioConverter()

        return 0
    }

    private func setupAudioConverter() {
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        AudioConverterNew(&inputFormat, &outputFormat, &audioConverter)
    }

    public func start() {
        guard let engine = audioEngine, let player = playerNode, !isPlaying else { return }
        do {
            try engine.start()
            player.play()
            isPlaying = true
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    public func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        isPlaying = false
    }

    public func cleanup() {
        stop()
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        playerNode = nil
        audioEngine = nil
    }

    public func decodeAndPlaySample(sampleData: UnsafePointer<CChar>, sampleLength: Int) {
        guard isPlaying, let player = playerNode, let format = audioFormat else { return }

        // If audio converter is available, convert Opus to PCM
        if let converter = audioConverter {
            let packetDesc = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(sampleLength)
            )

            struct InputDataState {
                var data: UnsafeRawPointer
                var size: UInt32
                var packetDesc: AudioStreamPacketDescription
            }

            var state = InputDataState(
                data: UnsafeRawPointer(sampleData),
                size: UInt32(sampleLength),
                packetDesc: packetDesc
            )

            let outputFrames: UInt32 = 960 // standard 20ms @ 48kHz
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames) else { return }

            var ioOutputDataPackets = outputFrames
            var outputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: outputFrames * 4 * channelCount,
                    mData: pcmBuffer.floatChannelData?[0]
                )
            )

            let status = AudioConverterFillComplexBuffer(
                converter,
                { (inConverter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                    guard let inUserData = inUserData else { return -1 }
                    let statePtr = inUserData.assumingMemoryBound(to: InputDataState.self)
                    if statePtr.pointee.size == 0 {
                        ioNumberDataPackets.pointee = 0
                        return noErr
                    }

                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mNumberChannels = 2
                    ioData.pointee.mBuffers.mDataByteSize = statePtr.pointee.size
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: statePtr.pointee.data)

                    if let outDesc = outDataPacketDescription {
                        outDesc.pointee = withUnsafeMutablePointer(to: &statePtr.pointee.packetDesc) { $0 }
                    }

                    ioNumberDataPackets.pointee = 1
                    statePtr.pointee.size = 0
                    return noErr
                },
                &state,
                &ioOutputDataPackets,
                &outputBufferList,
                nil
            )

            if status == noErr && ioOutputDataPackets > 0 {
                pcmBuffer.frameLength = ioOutputDataPackets
                AVPacingClock.shared.registerAudioTimestamp(hostTimeUs: UInt64(CACurrentMediaTime() * 1_000_000))
                player.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
            }
        }
    }
}
