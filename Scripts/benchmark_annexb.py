#!/usr/bin/env python3
"""Compile the actual baseline/current Annex-B scanners with swiftc -O and compare.

Run with no builds/profilers in the background. The baseline defaults to the main
revision used for this optimization. Temporary sources/binary are removed on exit.
No streaming host or saved settings are accessed.
"""
import argparse
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Sources/MoonlightMac/Pipeline/Video/VideoToolboxDecoder.swift'


def scanner(source):
    start = source.index('    static func pictureNALRanges(')
    end = source.index('\n    private func appendNalu', start)
    method = source[start:end]
    # Keep instrumentation out of the isolated scanner comparison.
    method = re.sub(r'^        let trace = VideoPipelineTrace.begin.*\n', '', method, flags=re.M)
    method = re.sub(r'^        defer \{ VideoPipelineTrace.end.*\n', '', method, flags=re.M)
    return method


FIXTURE = r"""var checksum = 0
for pattern in ["random", "zero-heavy", "one-heavy", "dense-NALs"] {
for size in [83_334, 262_144, 1_048_576] {
    var state: UInt64 = 0x123456789abcdef
    var bytes = [UInt8](repeating: 0, count: size)
    for i in bytes.indices {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        bytes[i] = pattern == "dense-NALs" ? [0, 0, 1, 0x65][i % 4] : (pattern == "random" ? UInt8(truncatingIfNeeded: state) : (pattern == "zero-heavy" ? 0 : 1))
        // EBSP escapes 00 00 00/01/02; keep random payloads valid.
        if pattern != "dense-NALs" && i >= 2 && bytes[i-2] == 0 && bytes[i-1] == 0 && bytes[i] <= 3 { bytes[i] = 3 }
    }
    for offset in [0, size / 4, size / 2, 3 * size / 4] {
        bytes.replaceSubrange(offset..<(offset+5), with: [0,0,0,1,0x26])
    }
    let rounds = max(200, 30_000_000 / size)
    bytes.withUnsafeBufferPointer { buffer in
        precondition(Baseline.pictureNALRanges(in: buffer) == Candidate.pictureNALRanges(in: buffer))
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for trial in 0..<10 {
            for candidate in (trial % 2 == 0 ? [false,true] : [true,false]) {
                let start = ContinuousClock.now
                for _ in 0..<rounds {
                    let result = candidate ? Candidate.pictureNALRanges(in: buffer) : Baseline.pictureNALRanges(in: buffer)
                    checksum &+= result?.reduce(0) { $0 &+ $1.count } ?? 0
                }
                let duration = start.duration(to: .now).components
                let ns = (Double(duration.seconds)*1e9 + Double(duration.attoseconds)/1e9)/Double(rounds)
                if candidate { newTimes.append(ns) } else { oldTimes.append(ns) }
            }
        }
        oldTimes.sort(); newTimes.sort()
        print("pattern=\(pattern) bytes=\(size) baseline_ns=\(oldTimes[5]) candidate_ns=\(newTimes[5]) speedup=\(oldTimes[5]/newTimes[5])")
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
    source = ('import Foundation\nimport simd\nenum Baseline {\n' + scanner(baseline)
              + '\n}\nenum Candidate {\n' + scanner(current) + '\n}\n' + FIXTURE)
    with tempfile.TemporaryDirectory(prefix='moonlight-annexb-') as folder:
        swift = Path(folder) / 'Benchmark.swift'
        binary = Path(folder) / 'benchmark'
        swift.write_text(source)
        subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
