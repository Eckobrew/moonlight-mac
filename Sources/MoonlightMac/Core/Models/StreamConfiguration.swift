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
    public var swapCommandControl: Bool

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
        swapCommandControl: Bool = false
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
        self.swapCommandControl = swapCommandControl
    }
}
