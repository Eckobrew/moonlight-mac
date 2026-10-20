import Foundation
import MoonlightCommonC

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case auto = "Auto"
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"
    case av1 = "AV1"

    public var limelightMask: Int32 {
        switch self {
        case .auto:
            return VIDEO_FORMAT_H264 | VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10 | VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_AV1_MAIN10
        case .h264:
            return VIDEO_FORMAT_H264
        case .hevc:
            return VIDEO_FORMAT_H265 | VIDEO_FORMAT_H265_MAIN10
        case .av1:
            return VIDEO_FORMAT_AV1_MAIN8 | VIDEO_FORMAT_AV1_MAIN10
        }
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
}

public struct StreamSettings: Codable, Equatable, Sendable {
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
        remoteBitrateMbps: Int = 15,
        enableClipboardSync: Bool = false,
        hideUnpairedHosts: Bool = false,
        muteHostAudio: Bool = true,
        captureSystemKeys: SystemKeyCaptureMode = .fullscreenOnly,
        keepScreenActive: Bool = true
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
    }

    enum CodingKeys: String, CodingKey {
        case width, height, fps, bitrateMbps, packetSize
        case codec, audioMode, enableHdr, fullRangeColor
        case mouseCaptureMode, swapWinAltKeys, windowMode
        case videoRenderer, enableVsync, enableFramePacing
        case optimizeGameSettings, quitAppOnStop, mouseSensitivity
        case enableRemoteBitrate, remoteBitrateMbps, enableClipboardSync, hideUnpairedHosts
        case muteHostAudio, captureSystemKeys, keepScreenActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        self.remoteBitrateMbps = (try? container.decode(Int.self, forKey: .remoteBitrateMbps)) ?? 15
        self.enableClipboardSync = (try? container.decode(Bool.self, forKey: .enableClipboardSync)) ?? false
        self.hideUnpairedHosts = (try? container.decode(Bool.self, forKey: .hideUnpairedHosts)) ?? false
        self.muteHostAudio = (try? container.decode(Bool.self, forKey: .muteHostAudio)) ?? true
        self.captureSystemKeys = (try? container.decode(SystemKeyCaptureMode.self, forKey: .captureSystemKeys)) ?? .fullscreenOnly
        self.keepScreenActive = (try? container.decode(Bool.self, forKey: .keepScreenActive)) ?? true
    }
}

