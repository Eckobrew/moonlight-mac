import Darwin
import Testing
@testable import MoonlightMac

@Test func nalPackingPreservesBytesAndCompactsAnnexBPadding() throws {
    for padding in 0..<16 {
        for payloadSize in 1...32 {
            var bytes = [UInt8](repeating: 0, count: padding)
            var expected: [UInt8] = []
            for nal in 0..<4 {
                bytes += [0, 0, 0, 1]
                let payload = [UInt8](repeating: UInt8(0x41 + nal), count: payloadSize)
                bytes += payload + [0, 0]
                var length = UInt32(payload.count).bigEndian
                expected += withUnsafeBytes(of: &length) { Array($0) } + payload
            }
            let ranges = try #require(bytes.withUnsafeBufferPointer { VideoToolboxDecoder.pictureNALRanges(in: $0) })
            let memory = try #require(malloc(bytes.count)?.assumingMemoryBound(to: UInt8.self))
            defer { free(memory) }
            bytes.withUnsafeBufferPointer { memcpy(memory, $0.baseAddress!, bytes.count) }
            let length = try #require(VideoToolboxDecoder.packNALPayloadsInPlace(memory, ranges: ranges))
            #expect(Array(UnsafeBufferPointer(start: memory, count: length)) == expected)
        }
    }
}

@Test func expandingNALPackingLeavesReferencePathUnmodified() throws {
    // Include a late expansion: checking only the first NAL would corrupt bytes
    // before discovering that a later three-byte prefix does not fit.
    let cases: [[UInt8]] = [[0, 0, 1, 0x65, 0x80],
                           [0, 0, 0, 1, 0x65, 0x80, 0, 0, 1, 0x41, 0x80]]
    for bytes in cases {
        let ranges = try #require(bytes.withUnsafeBufferPointer { VideoToolboxDecoder.pictureNALRanges(in: $0) })
        let memory = try #require(malloc(bytes.count)?.assumingMemoryBound(to: UInt8.self))
        defer { free(memory) }
        bytes.withUnsafeBufferPointer { memcpy(memory, $0.baseAddress!, bytes.count) }
        #expect(VideoToolboxDecoder.packNALPayloadsInPlace(memory, ranges: ranges) == nil)
        #expect(Array(UnsafeBufferPointer(start: memory, count: bytes.count)) == bytes)
    }
}
