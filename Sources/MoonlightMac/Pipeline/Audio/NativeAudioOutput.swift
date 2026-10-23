import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// The common library supplies FL FR C LFE RL RR SL SR samples. WAVE 7.1
/// describes that order; AudioUnit 7.1 puts side channels before rear channels.
enum StreamAudioLayout {
    static func tag(channels: UInt32) -> AudioChannelLayoutTag? {
        switch channels {
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
        case 8: return kAudioChannelLayoutTag_WAVE_7_1
        default: return nil
        }
    }
}

/// Confined to AudioPlaybackControl's queue, except the source callback, which
/// accesses only the separately synchronized ring buffer.
final class NativeAudioOutput: AudioOutputBackend, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private var configurationObserver: NSObjectProtocol?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "com.moonlight.audio.devices")

    init(ring: AudioRingBuffer, format: AVAudioFormat, onChange: @escaping @Sendable () -> Void) {
        source = AVAudioSourceNode(format: format) { [weak ring] isSilence, _, frameCount, outputData in
            let hasData = ring?.read(into: outputData, frames: Int(frameCount)) == true
            isSilence.pointee = ObjCBool(!hasData)
            if !hasData {
                for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onChange() }
        // Engine notifications alone don't cover a returning preferred device or
        // a new system default when we're currently bound to a specific device.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block) == noErr {
                deviceListeners.append((address, block))
            }
        }
    }

    var isRunning: Bool { engine.isRunning }
    private(set) var statusMessage: String?
    func selectDevice(uid: String?) throws {
        try AudioOutputDevices.select(deviceUID: uid, on: engine)
        statusMessage = uid.map { !$0.isEmpty && AudioOutputDevices.deviceID(forUID: $0) == nil } == true ? "Selected audio device is disconnected. Using the system default until it returns." : nil
    }
    func setMuted(_ muted: Bool) { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
    func dispose() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        for (var address, block) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        }
        deviceListeners.removeAll()
        engine.stop()
        engine.disconnectNodeOutput(source)
        engine.detach(source)
    }
}
