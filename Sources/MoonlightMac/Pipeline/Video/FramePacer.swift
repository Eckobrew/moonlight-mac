import AppKit
import CoreVideo
import Foundation

/// FramePacer paces video frames to match display refresh cycles using a high-precision CVDisplayLink.
///
/// Modes:
/// - Frame Pacing OFF (Opt-in disabled, default): Decoded frames are presented immediately with lowest latency.
/// - Frame Pacing ON (Opt-in enabled): Decoded frames are queued and presented in sync with CVDisplayLink ticks,
///   absorbing network jitter and eliminating micro-stutter/judder on 60Hz and 120Hz ProMotion displays.
public final class FramePacer: @unchecked Sendable {
    public static let shared = FramePacer()

    private let lock = NSLock()
    private var isPacingEnabled: Bool = false
    private var displayLink: CVDisplayLink?
    private var frameQueue: [CVPixelBuffer] = []
    private let maxQueuedFrames: Int = 2
    private var onFrameCallback: (@Sendable (CVPixelBuffer) -> Void)?
    private var currentDisplayID: CGDirectDisplayID?
    public private(set) var currentDisplayRefreshRate: Double = 60.0

    private init() {}

    /// Configure the pacing behavior and callback for presented frames.
    public func configure(
        enabled: Bool,
        displayID: CGDirectDisplayID? = nil,
        onFrame: @escaping @Sendable (CVPixelBuffer) -> Void
    ) {
        lock.lock()
        self.onFrameCallback = onFrame
        self.isPacingEnabled = enabled
        self.currentDisplayID = displayID
        self.frameQueue.removeAll()

        stopDisplayLinkLocked()

        if enabled {
            startDisplayLinkLocked(displayID: displayID)
        }
        lock.unlock()

        AppLogger.shared.info("[FramePacer] Configured pacing enabled=\(enabled), displayFps=\(String(format: "%.1f", currentDisplayRefreshRate))")
    }

    /// Update display link if window moved to another display.
    @MainActor
    public func updateWindow(_ window: NSWindow) {
        let displayID = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        updateDisplayID(displayID)
    }

    /// Update display link for a given display ID.
    public func updateDisplayID(_ displayID: CGDirectDisplayID?) {
        lock.lock()
        defer { lock.unlock() }

        self.currentDisplayID = displayID
        if isPacingEnabled {
            stopDisplayLinkLocked()
            startDisplayLinkLocked(displayID: displayID)
        }
    }

    /// Submit a decoded pixel buffer from the video decompression session.
    public func submit(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard isPacingEnabled else {
            let callback = self.onFrameCallback
            lock.unlock()
            callback?(pixelBuffer)
            return
        }

        // Pacing enabled: enqueue frame
        frameQueue.append(pixelBuffer)
        while frameQueue.count > maxQueuedFrames {
            _ = frameQueue.removeFirst()
        }
        lock.unlock()
    }

    /// Callback invoked by CVDisplayLink at display refresh intervals.
    private func displayLinkFired() {
        lock.lock()
        guard isPacingEnabled, !frameQueue.isEmpty else {
            lock.unlock()
            return
        }
        let frame = frameQueue.removeFirst()
        let callback = self.onFrameCallback
        lock.unlock()

        callback?(frame)
    }

    /// Stop display link and flush pending frames.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        stopDisplayLinkLocked()
        frameQueue.removeAll()
        onFrameCallback = nil
        currentDisplayID = nil
    }

    private func startDisplayLinkLocked(displayID: CGDirectDisplayID?) {
        var link: CVDisplayLink?
        var status: CVReturn = -1

        if let id = displayID {
            status = CVDisplayLinkCreateWithCGDisplay(id, &link)
        }

        if status != kCVReturnSuccess || link == nil {
            status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        }

        guard status == kCVReturnSuccess, let validLink = link else {
            AppLogger.shared.error("[FramePacer] Failed to create CVDisplayLink (status: \(status))")
            return
        }

        let cvCallback: CVDisplayLinkOutputCallback = { (_, _, _, _, _, context) -> CVReturn in
            guard let ctx = context else { return kCVReturnSuccess }
            let pacer = Unmanaged<FramePacer>.fromOpaque(ctx).takeUnretainedValue()
            pacer.displayLinkFired()
            return kCVReturnSuccess
        }

        let setStatus = CVDisplayLinkSetOutputCallback(
            validLink,
            cvCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard setStatus == kCVReturnSuccess else {
            AppLogger.shared.error("[FramePacer] Failed to set CVDisplayLink output callback (status: \(setStatus))")
            return
        }

        let period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(validLink)
        if period > 0.0 {
            currentDisplayRefreshRate = 1.0 / period
        } else {
            currentDisplayRefreshRate = 60.0
        }

        CVDisplayLinkStart(validLink)
        self.displayLink = validLink
        AppLogger.shared.info("[FramePacer] CVDisplayLink active at \(String(format: "%.1f", currentDisplayRefreshRate)) Hz")
    }

    private func stopDisplayLinkLocked() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            self.displayLink = nil
        }
    }
}
