import AudioToolbox
import Foundation
import Testing
@testable import MoonlightMac

private func writeRamp(to ring: AudioRingBuffer, start: Int = 0, frames: Int) {
    let samples = (start..<(start + frames)).flatMap { frame in
        (0..<ring.channels).map { Float(frame * ring.channels + $0) }
    }
    samples.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: frames) }
}

private func read(_ ring: AudioRingBuffer, frames: Int) -> [[Float]]? {
    let buffers = AudioBufferList.allocate(maximumBuffers: ring.channels)
    var planes: [UnsafeMutablePointer<Float>] = []
    for channel in 0..<ring.channels {
        let plane = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        plane.initialize(repeating: .nan, count: frames)
        planes.append(plane)
        buffers[channel] = AudioBuffer(mNumberChannels: 1,
                                       mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                       mData: plane)
    }
    defer {
        for plane in planes {
            plane.deinitialize(count: frames)
            plane.deallocate()
        }
        buffers.unsafeMutablePointer.deallocate()
    }
    guard ring.read(into: buffers.unsafeMutablePointer, frames: frames) else { return nil }
    return planes.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
}

@Test func fullAudioBufferDoesNotAppearEmpty() throws {
    let ring = AudioRingBuffer(channels: 2, capacity: 2048)
    writeRamp(to: ring, frames: 2048)
    let samples = try #require(read(ring, frames: 512))
    #expect(samples[0] == (0..<512).map { Float($0 * 2) })
    #expect(samples[1] == (0..<512).map { Float($0 * 2 + 1) })
}

@Test func audioWrapPreservesUnreadSamples() throws {
    let ring = AudioRingBuffer(channels: 1, capacity: 2048)
    writeRamp(to: ring, frames: 1536)
    _ = try #require(read(ring, frames: 1024))
    writeRamp(to: ring, start: 1536, frames: 1536)
    let samples = try #require(read(ring, frames: 1024))
    #expect(samples[0] == (1024..<2048).map { Float($0) })
}

@Test func audioOverflowRetainsNewestCushion() throws {
    let ring = AudioRingBuffer(channels: 1)
    writeRamp(to: ring, frames: 48000)
    let samples = try #require(read(ring, frames: 512))
    #expect(samples[0] == (46560..<47072).map { Float($0) })
}

@Test func audioUnderrunFadesAndRebuffers() throws {
    let ring = AudioRingBuffer(channels: 1)
    writeRamp(to: ring, frames: 1200)
    _ = try #require(read(ring, frames: 512))
    let tail = try #require(read(ring, frames: 1024))
    #expect(tail[0][687] == 1199)
    #expect(tail[0].last == 0)
    writeRamp(to: ring, frames: 480)
    #expect(read(ring, frames: 512) == nil)
    writeRamp(to: ring, start: 480, frames: 720)
    #expect(read(ring, frames: 512) != nil)
    ring.reset()
    #expect(read(ring, frames: 512) == nil)
}
