import Foundation

public struct PerformanceMetrics: Sendable {
    public var currentFps: Double
    public var targetFps: Int
    public var bitrateMbps: Double
    public var roundTripTimeMs: Double
    public var roundTripTimeVarianceMs: Double
    public var decodeTimeMs: Double
    public var networkDroppedFrames: Int
    public var totalFramesReceived: UInt64
    public var totalFramesRendered: UInt64
    public var totalFramesDropped: UInt64
    public var currentCodec: String
    public var resolution: String
    public var vsyncEnabled: Bool
    public var pacingEnabled: Bool

    public init(
        currentFps: Double = 0.0,
        targetFps: Int = 60,
        bitrateMbps: Double = 0.0,
        roundTripTimeMs: Double = 0.0,
        roundTripTimeVarianceMs: Double = 0.0,
        decodeTimeMs: Double = 0.0,
        networkDroppedFrames: Int = 0,
        totalFramesReceived: UInt64 = 0,
        totalFramesRendered: UInt64 = 0,
        totalFramesDropped: UInt64 = 0,
        currentCodec: String = "HEVC",
        resolution: String = "1920x1080",
        vsyncEnabled: Bool = true,
        pacingEnabled: Bool = false
    ) {
        self.currentFps = currentFps
        self.targetFps = targetFps
        self.bitrateMbps = bitrateMbps
        self.roundTripTimeMs = roundTripTimeMs
        self.roundTripTimeVarianceMs = roundTripTimeVarianceMs
        self.decodeTimeMs = decodeTimeMs
        self.networkDroppedFrames = networkDroppedFrames
        self.totalFramesReceived = totalFramesReceived
        self.totalFramesRendered = totalFramesRendered
        self.totalFramesDropped = totalFramesDropped
        self.currentCodec = currentCodec
        self.resolution = resolution
        self.vsyncEnabled = vsyncEnabled
        self.pacingEnabled = pacingEnabled
    }

    public var packetLossPercentage: Double {
        let total = totalFramesReceived + UInt64(networkDroppedFrames)
        guard total > 0 else { return 0.0 }
        return (Double(networkDroppedFrames) / Double(total)) * 100.0
    }
}
