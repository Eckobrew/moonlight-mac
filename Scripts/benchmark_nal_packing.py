#!/usr/bin/env python3
"""Compare the actual in-place NAL packing helper with baseline CoreMedia assembly.

Compile with swiftc -O; compare 3/4-byte prefixes and 1/4/64 NALs. Includes the
initial owned payload copy in both paths. Scanning is measured separately by
benchmark_annexb.py. Run with other builds/profilers stopped.
"""
import argparse
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Sources/MoonlightMac/Pipeline/Video/VideoToolboxDecoder.swift'
TEMPLATE = r"""import Foundation
import CoreMedia
struct AppLogger { static let shared = AppLogger(); func error(_ message: String) {} }
func ownedBlock(_ data: UnsafeMutablePointer<UInt8>, _ length: Int) -> CMBlockBuffer {
    var block: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: data, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
    precondition(status == noErr)
    return block!
}
struct Baseline {
    func build(_ data: UnsafeMutablePointer<UInt8>, count: Int, ranges: [Range<Int>]) -> CMBlockBuffer {
        let original = ownedBlock(data, count)
        var frame: CMBlockBuffer?
        precondition(CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 0, flags: 0, blockBufferOut: &frame) == noErr)
        for range in ranges { precondition(appendNalu(to: frame!, from: original, data: data, startOffset: range.lowerBound, endOffset: range.upperBound)) }
        return frame!
    }
__APPEND_NAL__
}
enum Candidate {
__PACK_NAL__

}
var checksum = 0
for size in [83_334, 1_048_576] {
 for nalCount in [1,4,64] {
  for prefixLength in [3,4] {
    var bytes: [UInt8] = [], ranges: [Range<Int>] = []
    for _ in 0..<nalCount {
        bytes += [UInt8](repeating: 0, count: prefixLength-1) + [1]
        let start = bytes.count
        bytes += [UInt8](repeating: 0x65, count: size/nalCount)
        ranges.append(start..<bytes.count)
    }
    bytes.withUnsafeBufferPointer { input in
      var before: [Double] = [], after: [Double] = []
      for trial in 0..<10 {
        for candidate in (trial.isMultiple(of: 2) ? [false,true] : [true,false]) {
          let start = ContinuousClock.now
          for _ in 0..<200 {
            autoreleasepool {
              let data = malloc(bytes.count)!.assumingMemoryBound(to: UInt8.self)
              memcpy(data, input.baseAddress!, bytes.count)
              let block: CMBlockBuffer
              if candidate {
                if let length = Candidate.packNALPayloadsInPlace(data, ranges: ranges) {
                    block = ownedBlock(data, length)
                } else {
                    block = Baseline().build(data, count: bytes.count, ranges: ranges)
                }
              } else { block = Baseline().build(data, count: bytes.count, ranges: ranges) }
              checksum &+= CMBlockBufferGetDataLength(block)
            }
          }
          let elapsed = start.duration(to: .now).components
          let ns = (Double(elapsed.seconds)*1e9+Double(elapsed.attoseconds)/1e9)/200
          if candidate {after.append(ns)} else {before.append(ns)}
        }
      }
      before.sort();after.sort()
      print("bytes=\(size) nals=\(nalCount) prefix=\(prefixLength) baseline_ns=\(before[5]) candidate_ns=\(after[5]) speedup=\(before[5]/after[5])")
    }
  }
 }
}
print("checksum=\(checksum)")
"""

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='a4ce42d')
    args = parser.parse_args()
    baseline = subprocess.check_output(['git', 'show', f'{args.baseline}:{SOURCE}'], cwd=ROOT, text=True)
    current = (ROOT / SOURCE).read_text()
    start = baseline.index('    private func appendNalu(')
    end = baseline.index('\n}\n\nprivate struct DecodeContext', start)
    append = baseline[start:end]
    start = current.index('    static func packNALPayloadsInPlace(')
    end = current.index('\n    private func appendNalu(', start)
    pack = current[start:end]
    source = TEMPLATE.replace('__APPEND_NAL__', append).replace('__PACK_NAL__', pack)
    with tempfile.TemporaryDirectory(prefix='moonlight-nal-packing-') as folder:
        swift = Path(folder) / 'Benchmark.swift'
        binary = Path(folder) / 'benchmark'
        swift.write_text(source)
        subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
