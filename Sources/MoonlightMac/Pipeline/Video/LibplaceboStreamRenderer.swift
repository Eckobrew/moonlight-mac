import AppKit
import CPlaceboBridge
import CoreVideo
import QuartzCore

/// Direct GPU import path. The decoder only writes to a one-frame
/// mailbox; Vulkan operations and teardown run on a dedicated serial queue.
public final class LibplaceboStreamRenderer: @unchecked Sendable {
    public static let shared = LibplaceboStreamRenderer()
    public static var isAvailable: Bool { MLPlaceboIsAvailable() }
    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.moonlight.libplacebo.render", qos: .userInteractive)
    private var layer: CAMetalLayer?
    private var drawableSize = CGSize.zero
    private var vsync = true
    private var revision: UInt64 = 0
    private var pending: CVPixelBuffer?
    private var scheduled = false
    private var failed = false
    // Accessed exclusively on renderQueue. Retain the layer until GPU teardown.
    private let backend: any LibplaceboBackend
    private var contextLayer: CAMetalLayer?
    private var contextRevision: UInt64 = .max

    init() { backend = NativeLibplaceboBackend() }
    init(backend: any LibplaceboBackend) { self.backend = backend }

    @MainActor
    public func attachLayer(_ layer: CAMetalLayer, vsync: Bool) {
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.wantsExtendedDynamicRangeContent = false
        layer.displaySyncEnabled = vsync
        lock.withLock {
            drawableSize = layer.drawableSize
            guard self.layer !== layer || self.vsync != vsync else { return }
            self.layer = layer
            self.vsync = vsync
            revision &+= 1
            failed = false
        }
    }

    @MainActor
    public func resize(_ size: CGSize) {
        lock.withLock { drawableSize = size }
    }

    public func render(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard !failed, layer != nil else { lock.unlock(); return }
        pending = pixelBuffer
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        renderQueue.async { [self] in drain() }
    }

    public func reset() {
        lock.withLock {
            revision &+= 1
            pending = nil
            layer = nil
            failed = false
        }
        renderQueue.async { [self] in destroyContext() }
    }

    private func destroyContext() {
        backend.destroy()
        contextLayer = nil
        contextRevision = .max
    }

    private func drain() {
        let state = lock.withLock { () -> (CVPixelBuffer, CAMetalLayer, CGSize, Bool, UInt64)? in
            guard !failed, let buffer = pending, let layer else {
                pending = nil
                scheduled = false
                return nil
            }
            pending = nil
            return (buffer, layer, drawableSize, vsync, revision)
        }
        guard let (buffer, layer, size, vsync, revision) = state else { return }
        var result: Int32 = 0
        do {
            if size.width > 0 && size.height > 0 {
                if contextRevision != revision {
                    destroyContext()
                    contextLayer = layer
                    try backend.create(layer: layer, vsync: vsync)
                    contextRevision = revision
                }
                let width = Int32(clamping: Int(size.width)), height = Int32(clamping: Int(size.height))
                if try backend.beginFrame(width: width, height: height) {
                    // Acquiring a drawable may wait. Choose the newest decoded frame
                    // now, rather than presenting the buffer captured before that wait.
                    let newest = lock.withLock { () -> CVPixelBuffer? in
                        guard self.revision == revision, !failed else { return nil }
                        let selected = pending ?? buffer
                        pending = nil
                        return selected
                    }
                    if let newest {
                        result = try backend.render(newest, width: width, height: height) ? 1 : 0
                    } else {
                        backend.discardFrame()
                    }
                }
            }
        } catch {
            result = -1
            let message = String(describing: error)
            let shouldReport = lock.withLock { () -> Bool in
                guard self.revision == revision else { return false }
                failed = true
                pending = nil
                return true
            }
            destroyContext()
            if shouldReport {
                AppLogger.shared.error("[Libplacebo] \(message)")
                Task { @MainActor in
                    guard self.lock.withLock({ self.revision == revision && self.failed }) else { return }
                    RuntimeServiceStatus.shared.renderer = "libplacebo/Vulkan: \(message). Reconnect with Metal if needed."
                }
            }
        }
        // Yield between frames so detach/reset cannot be starved by a stream.
        renderQueue.asyncAfter(deadline: .now() + (result == 0 ? .milliseconds(16) : .milliseconds(0))) { [self] in drain() }
    }
}
