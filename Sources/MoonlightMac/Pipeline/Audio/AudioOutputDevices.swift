import AVFoundation
import CoreAudio
import Foundation

/// A selectable CoreAudio output device.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: String       // kAudioDevicePropertyDeviceUID
    public let name: String     // human-readable device name
    public let isSystemDefault: Bool

    public init(id: String, name: String, isSystemDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isSystemDefault = isSystemDefault
    }
}

/// Enumerates CoreAudio outputs and configures the engine's output unit.
/// Call selection only from the audio control queue; the owner restarts playback.
public enum AudioOutputDevices {
    /// All devices that can be used for output, ordered with the system default first.
    public static func available() -> [AudioOutputDevice] {
        var devices: [AudioOutputDevice] = []
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        let defaultID = systemDefaultOutputDeviceID()

        for deviceID in deviceIDs where outputStreamCount(deviceID) > 0 {
            guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, kAudioObjectPropertyName) else { continue }
            devices.append(AudioOutputDevice(
                id: uid,
                name: name,
                isSystemDefault: deviceID == defaultID
            ))
        }

        return devices.sorted {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Looks up the AudioDeviceID for a device UID.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID: CFString = uid as CFString
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Select a route without hiding restart errors or starting an old engine.
    /// The serialized playback controller owns all start/stop/recovery decisions.
    static func select(deviceUID uid: String?, on engine: AVAudioEngine) throws {
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw NSError(domain: "AudioOutputDevices", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio output unit is unavailable."])
        }

        var targetDeviceID: AudioDeviceID
        if let uid = uid, !uid.isEmpty, let resolved = deviceID(forUID: uid) {
            targetDeviceID = resolved
        } else {
            // Explicitly follow the system default when no override is configured.
            guard let systemDefault = systemDefaultOutputDeviceID() else {
                throw NSError(domain: "AudioOutputDevices", code: -2, userInfo: [NSLocalizedDescriptionKey: "No audio output device is available."])
            }
            targetDeviceID = systemDefault
        }

        var currentDeviceID = AudioDeviceID(0)
        var currentSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getStatus = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            &currentSize
        )
        if getStatus == noErr && currentDeviceID == targetDeviceID {
            return
        }

        if engine.isRunning {
            engine.stop()
        }

        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &targetDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to select audio output device (\(status))."])
        }
    }

    // MARK: - Helpers

    private static func systemDefaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Number of output channels, used to skip input-only devices.
    private static func outputStreamCount(_ deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return 0
        }
        return Int(dataSize) / MemoryLayout<AudioStreamID>.size
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value = value else { return nil }
        return value as String
    }
}
