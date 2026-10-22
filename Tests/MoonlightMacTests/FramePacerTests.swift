import CoreVideo
import Foundation
import Testing
@testable import MoonlightMac

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

@Test @MainActor func stoppedPacerDoesNotPresentFrames() throws {
    let pacer = FramePacer.shared
    defer { pacer.stop() }
    let counter = FrameCounter()
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                              kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let frame = try #require(buffer)
    pacer.configure(enabled: false) { _ in counter.increment() }
    pacer.submit(pixelBuffer: frame)
    #expect(counter.value == 1)
    pacer.stop()
    pacer.submit(pixelBuffer: frame)
    #expect(counter.value == 1)
    pacer.configure(enabled: false) { _ in counter.increment() }
    pacer.submit(pixelBuffer: frame)
    #expect(counter.value == 2)
}
