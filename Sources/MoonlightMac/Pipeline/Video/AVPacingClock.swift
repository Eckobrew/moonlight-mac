import Foundation
import CoreMedia
import QuartzCore

public final class AVPacingClock: @unchecked Sendable {
    public static let shared = AVPacingClock()

    private let lock = NSLock()
    private var baseVideoPtsUs: UInt64 = 0
    private var baseAudioHostTimeUs: UInt64 = 0
    private var isSynchronized = false

    // Frame jitter smoothing
    private var lastRenderedPtsUs: UInt64 = 0
    private var maxAllowedDriftUs: UInt64 = 30_000 // 30ms

    private init() {}

    public func reset() {
        lock.lock()
        baseVideoPtsUs = 0
        baseAudioHostTimeUs = 0
        isSynchronized = false
        lastRenderedPtsUs = 0
        lock.unlock()
    }

    public func registerAudioTimestamp(hostTimeUs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if !isSynchronized {
            baseAudioHostTimeUs = hostTimeUs
        }
    }

    public func shouldRenderFrame(presentationTimeUs: UInt64, currentHostTimeUs: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if !isSynchronized {
            baseVideoPtsUs = presentationTimeUs
            baseAudioHostTimeUs = currentHostTimeUs
            isSynchronized = true
            lastRenderedPtsUs = presentationTimeUs
            return true
        }

        // Drop out-of-order or duplicate frames
        if presentationTimeUs <= lastRenderedPtsUs {
            return false
        }

        let elapsedAudioTimeUs = currentHostTimeUs > baseAudioHostTimeUs ? currentHostTimeUs - baseAudioHostTimeUs : 0
        let elapsedVideoPtsUs = presentationTimeUs > baseVideoPtsUs ? presentationTimeUs - baseVideoPtsUs : 0

        // If video frame is significantly behind audio playback (> 40ms late), drop frame to prevent audio desync
        if elapsedAudioTimeUs > elapsedVideoPtsUs + 40_000 {
            return false // Conceal & drop stale frame
        }

        lastRenderedPtsUs = presentationTimeUs
        return true
    }
}
