import Foundation
import CoreMedia
import VideoToolbox
import MoonlightCommonC

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case auto = "Auto"
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"
    case av1 = "AV1"

    public var limelightMask: Int32 {
        limelightMask(enableHdr: false)
    }

    public func limelightMask(enableHdr: Bool) -> Int32 {
        let hevcMask = enableHdr ? (VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10) : VIDEO_FORMAT_H265
        let av1Mask = Self.av1MaskIfSupported(enableHdr: enableHdr)
        switch self {
        case .auto:
            return VIDEO_FORMAT_H264 | hevcMask | av1Mask
        case .h264:
            return VIDEO_FORMAT_H264
        case .hevc:
            return hevcMask
        case .av1:
            return av1Mask
        }
    }

    /// Whether this Mac's VideoToolbox hardware can decode AV1.
    ///
    /// Advertising AV1 to a host on a Mac without an AV1 hardware decoder (pre-M3) yields a failing
    /// decompression session, so both the codec picker and the advertised format mask are gated on
    /// `VTIsHardwareDecodeSupported`. Cached for the process lifetime.
    public static let isAV1DecodingSupported: Bool = {
        guard #available(macOS 13.0, *) else { return false }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()

    private static func av1MaskIfSupported(enableHdr: Bool) -> Int32 {
        guard isAV1DecodingSupported else { return 0 }
        return enableHdr ? (VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_AV1_MAIN10) : VIDEO_FORMAT_AV1_MAIN8
    }
}

public enum AudioConfigurationMode: String, Codable, CaseIterable, Sendable {
    case stereo = "Stereo"
    case surround51 = "5.1 Surround"
    case surround71 = "7.1 Surround"

    public var limelightValue: Int32 {
        switch self {
        case .stereo:
            // MAKE_AUDIO_CONFIGURATION(2, 0x3)
            return Int32((0x3 << 16) | (2 << 8) | 0xCA)
        case .surround51:
            // MAKE_AUDIO_CONFIGURATION(6, 0x3F)
            return Int32((0x3F << 16) | (6 << 8) | 0xCA)
        case .surround71:
            // MAKE_AUDIO_CONFIGURATION(8, 0x63F)
            return Int32((0x63F << 16) | (8 << 8) | 0xCA)
        }
    }

    /// Macro SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION: (channelMask << 16) | channelCount
    public var surroundAudioInfo: Int32 {
        let channelCount = (limelightValue >> 8) & 0xFF
        let channelMask = (limelightValue >> 16) & 0xFFFF
        return (channelMask << 16) | channelCount
    }
}

public enum WindowMode: String, Codable, CaseIterable, Sendable {
    case fullscreenDesktop = "Fullscreen (Windowed)"
    case fullscreen = "Fullscreen"
    case windowed = "Windowed"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let val = try container.decode(String.self)
        switch val {
        case "Windowed":
            self = .windowed
        case "Fullscreen":
            self = .fullscreen
        case "Fullscreen (Windowed)", "borderless":
            self = .fullscreenDesktop
        default:
            self = .fullscreenDesktop
        }
    }
}

/// Matches moonlight-qt's "Capture system keyboard shortcuts" option (CSK_OFF / CSK_FULLSCREEN / CSK_ALWAYS)
public enum SystemKeyCaptureMode: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case fullscreenOnly = "In fullscreen"
    case always = "Always"
}

public enum VideoRendererMode: String, Codable, CaseIterable, Sendable {
    case metal = "Metal"
    case native = "Native (AVSampleBuffer)"
    case libplacebo = "libplacebo (Vulkan, Experimental)"
}

public struct StreamSettings: Codable, Equatable, Sendable {
    public var features = ClientFeatures()
    public var controllerMask: UInt16 = 0
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateMbps: Int
    public var packetSize: Int
    public var codec: VideoCodec
    public var audioMode: AudioConfigurationMode
    public var enableHdr: Bool
    public var fullRangeColor: Bool
    public var mouseCaptureMode: Bool
    public var swapWinAltKeys: Bool
    public var windowMode: WindowMode
    public var videoRenderer: VideoRendererMode
    public var enableVsync: Bool
    public var enableFramePacing: Bool
    public var optimizeGameSettings: Bool
    public var quitAppOnStop: Bool
    public var mouseSensitivity: Double
    public var enableRemoteBitrate: Bool
    public var remoteBitrateMbps: Int
    public var enableClipboardSync: Bool
    public var hideUnpairedHosts: Bool
    public var muteHostAudio: Bool
    public var captureSystemKeys: SystemKeyCaptureMode
    public var keepScreenActive: Bool

    // Mouse scaling
    public var mouseSensitivityX: Double
    public var mouseSensitivityY: Double
    public var mouseSubPixelAccumulation: Bool

    // Audio
    /// Unique ID (`UID`) of the chosen CoreAudio output device, or nil for the system default.
    public var audioOutputDeviceUID: String?
    /// Silence playback while Moonlight is not the focused app.
    public var muteAudioOnFocusLoss: Bool

    // Keyboard
    /// Host keyboard layout used to translate non-US key positions.
    public var keyboardLayout: KeyboardLayout

    public init(
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60,
        bitrateMbps: Int = 25,
        packetSize: Int = 1024,
        codec: VideoCodec = .auto,
        audioMode: AudioConfigurationMode = .stereo,
        enableHdr: Bool = false,
        fullRangeColor: Bool = false,
        mouseCaptureMode: Bool = true,
        swapWinAltKeys: Bool = true,
        windowMode: WindowMode = .fullscreenDesktop,
        videoRenderer: VideoRendererMode = .metal,
        enableVsync: Bool = true,
        enableFramePacing: Bool = false,
        optimizeGameSettings: Bool = true,
        quitAppOnStop: Bool = false,
        mouseSensitivity: Double = 1.0,
        enableRemoteBitrate: Bool = false,
        remoteBitrateMbps: Int = 0,
        enableClipboardSync: Bool = false,
        hideUnpairedHosts: Bool = false,
        muteHostAudio: Bool = true,
        captureSystemKeys: SystemKeyCaptureMode = .fullscreenOnly,
        keepScreenActive: Bool = true,
        mouseSensitivityX: Double = 1.0,
        mouseSensitivityY: Double = 1.0,
        mouseSubPixelAccumulation: Bool = true,
        audioOutputDeviceUID: String? = nil,
        muteAudioOnFocusLoss: Bool = false,
        keyboardLayout: KeyboardLayout = .us
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.packetSize = packetSize
        self.codec = codec
        self.audioMode = audioMode
        self.enableHdr = enableHdr
        self.fullRangeColor = fullRangeColor
        self.mouseCaptureMode = mouseCaptureMode
        self.swapWinAltKeys = swapWinAltKeys
        self.windowMode = windowMode
        self.videoRenderer = videoRenderer
        self.enableVsync = enableVsync
        self.enableFramePacing = enableFramePacing
        self.optimizeGameSettings = optimizeGameSettings
        self.quitAppOnStop = quitAppOnStop
        self.mouseSensitivity = mouseSensitivity
        self.enableRemoteBitrate = enableRemoteBitrate
        self.remoteBitrateMbps = remoteBitrateMbps
        self.enableClipboardSync = enableClipboardSync
        self.hideUnpairedHosts = hideUnpairedHosts
        self.muteHostAudio = muteHostAudio
        self.captureSystemKeys = captureSystemKeys
        self.keepScreenActive = keepScreenActive
        self.mouseSensitivityX = mouseSensitivityX
        self.mouseSensitivityY = mouseSensitivityY
        self.mouseSubPixelAccumulation = mouseSubPixelAccumulation
        self.audioOutputDeviceUID = audioOutputDeviceUID
        self.muteAudioOnFocusLoss = muteAudioOnFocusLoss
        self.keyboardLayout = keyboardLayout
    }

    enum CodingKeys: String, CodingKey {
        case features, controllerMask
        case width, height, fps, bitrateMbps, packetSize
        case codec, audioMode, enableHdr, fullRangeColor
        case mouseCaptureMode, swapWinAltKeys, windowMode
        case videoRenderer, enableVsync, enableFramePacing
        case optimizeGameSettings, quitAppOnStop, mouseSensitivity
        case enableRemoteBitrate, remoteBitrateMbps, enableClipboardSync, hideUnpairedHosts
        case muteHostAudio, captureSystemKeys, keepScreenActive
        case mouseSensitivityX, mouseSensitivityY, mouseSubPixelAccumulation
        case audioOutputDeviceUID, muteAudioOnFocusLoss, keyboardLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.controllerMask = try container.decodeIfPresent(UInt16.self, forKey: .controllerMask) ?? 0
        self.features = try container.decodeIfPresent(ClientFeatures.self, forKey: .features) ?? ClientFeatures()
        self.width = try container.decode(Int.self, forKey: .width)
        self.height = try container.decode(Int.self, forKey: .height)
        self.fps = try container.decode(Int.self, forKey: .fps)
        self.bitrateMbps = try container.decode(Int.self, forKey: .bitrateMbps)
        self.packetSize = try container.decode(Int.self, forKey: .packetSize)
        self.codec = try container.decode(VideoCodec.self, forKey: .codec)
        self.audioMode = try container.decode(AudioConfigurationMode.self, forKey: .audioMode)
        self.enableHdr = try container.decode(Bool.self, forKey: .enableHdr)
        self.fullRangeColor = try container.decode(Bool.self, forKey: .fullRangeColor)
        self.mouseCaptureMode = try container.decode(Bool.self, forKey: .mouseCaptureMode)
        self.swapWinAltKeys = (try? container.decode(Bool.self, forKey: .swapWinAltKeys)) ?? true
        self.windowMode = (try? container.decode(WindowMode.self, forKey: .windowMode)) ?? .fullscreenDesktop
        self.videoRenderer = (try? container.decode(VideoRendererMode.self, forKey: .videoRenderer)) ?? .metal
        self.enableVsync = (try? container.decode(Bool.self, forKey: .enableVsync)) ?? true
        self.enableFramePacing = (try? container.decode(Bool.self, forKey: .enableFramePacing)) ?? false
        self.optimizeGameSettings = (try? container.decode(Bool.self, forKey: .optimizeGameSettings)) ?? true
        self.quitAppOnStop = (try? container.decode(Bool.self, forKey: .quitAppOnStop)) ?? false
        self.mouseSensitivity = (try? container.decode(Double.self, forKey: .mouseSensitivity)) ?? 1.0
        self.enableRemoteBitrate = (try? container.decode(Bool.self, forKey: .enableRemoteBitrate)) ?? false
        self.remoteBitrateMbps = (try? container.decode(Int.self, forKey: .remoteBitrateMbps)) ?? 0
        self.enableClipboardSync = (try? container.decode(Bool.self, forKey: .enableClipboardSync)) ?? false
        self.hideUnpairedHosts = (try? container.decode(Bool.self, forKey: .hideUnpairedHosts)) ?? false
        self.muteHostAudio = (try? container.decode(Bool.self, forKey: .muteHostAudio)) ?? true
        self.captureSystemKeys = (try? container.decode(SystemKeyCaptureMode.self, forKey: .captureSystemKeys)) ?? .fullscreenOnly
        self.keepScreenActive = (try? container.decode(Bool.self, forKey: .keepScreenActive)) ?? true
        self.mouseSensitivityX = (try? container.decode(Double.self, forKey: .mouseSensitivityX)) ?? 1.0
        self.mouseSensitivityY = (try? container.decode(Double.self, forKey: .mouseSensitivityY)) ?? 1.0
        self.mouseSubPixelAccumulation = (try? container.decode(Bool.self, forKey: .mouseSubPixelAccumulation)) ?? true
        self.audioOutputDeviceUID = try? container.decode(String.self, forKey: .audioOutputDeviceUID)
        self.muteAudioOnFocusLoss = (try? container.decode(Bool.self, forKey: .muteAudioOnFocusLoss)) ?? false
        self.keyboardLayout = (try? container.decode(KeyboardLayout.self, forKey: .keyboardLayout)) ?? .us
    }
}


public extension StreamSettings {
    var videoFormatMask: Int32 {
        var mask = codec.limelightMask(enableHdr: enableHdr)
        if features.yuv444 {
            if codec == .auto { mask &= ~VIDEO_FORMAT_MASK_AV1 }
            if mask & VIDEO_FORMAT_MASK_H264 != 0 { mask |= VIDEO_FORMAT_H264_HIGH8_444 }
            if mask & VIDEO_FORMAT_MASK_H265 != 0 { mask |= VIDEO_FORMAT_H265_REXT8_444; if enableHdr { mask |= VIDEO_FORMAT_H265_REXT10_444 } }
            // AV1 High-profile hardware decoding is not exposed by the AV1 Main capability probe.
            // Keep AV1 at 4:2:0 until that profile can be verified independently.
        }
        return mask
    }
}
