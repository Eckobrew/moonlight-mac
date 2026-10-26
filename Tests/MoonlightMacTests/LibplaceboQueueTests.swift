import CoreVideo
import Foundation
import QuartzCore
import Testing
@testable import MoonlightMac

private final class BlockedLibplaceboBackend: LibplaceboBackend, @unchecked Sendable {
    let acquired = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let rendered = DispatchSemaphore(value: 0)
    let discarded = DispatchSemaphore(value: 0)
    let destroyed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    private var widths: [Int] = []
    private var created = false
    var presentedWidths: [Int] { lock.withLock { widths } }

    func create(layer: CAMetalLayer, vsync: Bool) { lock.withLock { created = true } }
    func beginFrame(width: Int32, height: Int32) -> Bool {
        let shouldBlock = lock.withLock {
            if blocked { return false }
            blocked = true
            return true
        }
        if shouldBlock {
            acquired.signal()
            _ = resume.wait(timeout: .now() + 5)
        }
        return true
    }
    func render(_ buffer: CVPixelBuffer, width: Int32, height: Int32) -> Bool {
        lock.withLock { widths.append(CVPixelBufferGetWidth(buffer)) }
        rendered.signal()
        return true
    }
    func discardFrame() { discarded.signal() }
    func destroy() {
        let wasCreated = lock.withLock {
            let previous = created
            created = false
            return previous
        }
        if wasCreated { destroyed.signal() }
    }
}

private func pixelBuffer(width: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
    try #require(status == kCVReturnSuccess)
    return try #require(buffer)
}

private func signaled(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
        }
    }
}

@Test @MainActor func libplaceboChoosesLatestFrameAfterDrawableWait() async throws {
    let backend = BlockedLibplaceboBackend()
    let renderer = LibplaceboStreamRenderer(backend: backend)
    let layer = CAMetalLayer()
    layer.drawableSize = CGSize(width: 640, height: 480)
    renderer.attachLayer(layer, vsync: false)
    renderer.render(pixelBuffer: try pixelBuffer(width: 2))
    #expect(await signaled(backend.acquired))
    // Both calls must return while acquisition is still blocked. Only the
    // newest buffer should be rendered once the compositor releases a drawable.
    renderer.render(pixelBuffer: try pixelBuffer(width: 4))
    renderer.render(pixelBuffer: try pixelBuffer(width: 6))
    backend.resume.signal()
    #expect(await signaled(backend.rendered))
    #expect(backend.presentedWidths == [6])
    renderer.reset()
}

@Test @MainActor func libplaceboResetDuringDrawableWaitDiscardsOldFrame() async throws {
    let backend = BlockedLibplaceboBackend()
    let renderer = LibplaceboStreamRenderer(backend: backend)
    let layer = CAMetalLayer()
    layer.drawableSize = CGSize(width: 640, height: 480)
    renderer.attachLayer(layer, vsync: true)
    renderer.render(pixelBuffer: try pixelBuffer(width: 2))
    #expect(await signaled(backend.acquired))
    renderer.reset()
    backend.resume.signal()
    #expect(await signaled(backend.discarded))
    #expect(await signaled(backend.destroyed))
    #expect(backend.presentedWidths.isEmpty)
}
