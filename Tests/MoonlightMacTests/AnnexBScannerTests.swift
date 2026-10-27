import Darwin
import Testing
@testable import MoonlightMac

@Test func annexBScannerPreservesPayloadsAcrossVectorBoundaries() {
    for padding in 0..<32 {
        for payloadSize in 1...64 {
            var bytes = [UInt8](repeating: 0, count: padding)
            var expected: [Range<Int>] = []
            for nal in 0..<4 {
                bytes += nal.isMultiple(of: 2) ? [0, 0, 1] : [0, 0, 0, 1]
                let start = bytes.count
                // Include escaped zeros and dense 0x01 runs inside the payload.
                let pattern: [UInt8] = [0x65, 0, 0, 3, 1, 1, 1, 0xFF]
                bytes += (0..<payloadSize).map { pattern[$0 % pattern.count] }
                bytes += [0x80] // Nonzero final byte, followed by Annex-B padding.
                expected.append(start..<bytes.count)
                bytes += [0, 0]
            }
            let actual = bytes.withUnsafeBufferPointer { VideoToolboxDecoder.pictureNALRanges(in: $0) }
            #expect(actual == expected)
        }
    }
}

@Test func annexBScannerRejectsEmptyNALsAtEveryVectorPosition() {
    for offset in 0..<64 {
        let picture: [UInt8] = [0, 0, 1, 0x65] + [UInt8](repeating: 2, count: offset)
        let endings: [[UInt8]] = [[0, 0, 1], [0, 0, 0, 1], [0, 0, 1, 0, 0, 1, 0x41]]
        for emptyEnding in endings {
            let bytes = picture + emptyEnding
            #expect(bytes.withUnsafeBufferPointer { VideoToolboxDecoder.pictureNALRanges(in: $0) } == nil)
        }
    }
}

@Test func annexBScannerNeverReadsBeyondBufferEnd() throws {
    let pageSize = Int(getpagesize())
    let mapping = mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
    let base = try #require(mapping != MAP_FAILED ? mapping : nil)
    defer { munmap(base, pageSize * 2) }
    try #require(mprotect(base.advanced(by: pageSize), pageSize, PROT_NONE) == 0)
    // Every alignment and vector-tail length ends immediately before a guard
    // page. An over-read would fault instead of silently reading spare capacity.
    for count in 0...128 {
        let start = base.advanced(by: pageSize - count).assumingMemoryBound(to: UInt8.self)
        for index in 0..<count { start[index] = 2 }
        if count >= 4 { start[0] = 0; start[1] = 0; start[2] = 1 }
        let actual = VideoToolboxDecoder.pictureNALRanges(in: UnsafeBufferPointer(start: start, count: count))
        #expect(actual == (count >= 4 ? [3..<count] : nil))
    }
}
