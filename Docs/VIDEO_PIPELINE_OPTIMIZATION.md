# Main-branch video pipeline optimization

Base: `a4ce42d` (`main`). Branch: `codex/main-video-pipeline-optimization`.
The Vulkan experiment is excluded. Existing UI edits remain in the original checkout.

## Acceptance criteria

Reduce CPU time per decoded/presented frame and avoid unnecessary GPU work,
without adding buffering, changing input timing, dropping additional frames,
reducing resolution/quality, or changing color/HDR semantics. Keep native
AVSampleBuffer and Metal presentation available. Treat utilization measured with
fewer frames, a different host scene, or an occluded window as incomparable.

Keep moonlight-common-c's decode worker and capability flags. Copy/own all
asynchronously consumed data before returning from submitDecodeUnit. Preserve
DR_NEED_IDR on malformed input or submission failure, reference-frame recovery,
serialized teardown, and bounded surface lifetimes. Do not change the vendored
library to conceal a client bottleneck.

## Sequence

1. Build unchanged main in Release and package it separately. On NATHAN-PC,
   record actual resolution/codec/FPS/bitrate, renderer, pacing, V-Sync, foreground
   state, decode delivery, CPU time, memory, and sampled stacks. Warm up first;
   separate profiling from utilization measurements.
2. Rank measured costs in packet handling, frame assembly, VideoToolbox,
   metadata, presentation, audio, and UI. Add narrowly scoped opt-in stage
   measurements only where stack sampling cannot resolve the cost.
3. Make one small optimization at a time. Keep ownership and callback contracts
   explicit. Use representative release microbenchmarks to isolate small costs,
   then repeat the same live workload to assess the whole app.
4. Run regression tests and relevant malformed-input, color/HDR, queue/lifetime,
   reconnection and real-host checks. Compare both presenters. Retain only
   measured improvements; record noise and unsupported hardware cases honestly.
5. Commit retained changes and deliver a separate Release test app. Numerical
   input-to-photon claims require physical latency measurement; frame/decode
   timings alone cannot establish them. GPU claims require GPU measurements,
   not CPU utilization or a reduced frame rate.

## Tools and setup

Builds use the existing Command Line Tools selection. Xcode 16.4 is also
installed; its xctrace is available through
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Use Time Profiler /
Metal System Trace where permitted, `sample` for a lower-overhead CPU stack
cross-check, process CPU-time deltas for CPU usage, and existing opt-in
MOONLIGHT_STREAM_DIAGNOSTICS logs for delivery and network/decode timing.
Do not infer GPU utilization from CPU samples.

Baseline package: `Products/Optimization-baseline/Moonlight.app` in the original
repository. The installed app is preserved. Private profiles/logs stay outside
Git; this document records only reproducible settings and aggregate results.

## Profiling support

`MOONLIGHT_PIPELINE_PROFILE=1` adds Points of Interest intervals for decode-unit
submission, encoded-chain copying, Annex-B scanning, sample assembly,
VideoToolbox submission, HDR attachments, native presentation, and Metal drawable
acquisition/presentation. The default is off. Spans retain no buffers and add no
queues, timers, waits, or per-frame logging. These are wall-time measurements;
framework waits must not be reported as CPU time.

`MOONLIGHT_STREAM_DIAGNOSTICS=1` also records cumulative decoded callbacks,
decode drops and inferred missing frame numbers, plus renderer/codec/resolution
and pacing/V-Sync. Frame gaps do not count individual lost network packets.

For utilization, run `python3 Scripts/measure_stream.py PID --log LOG --seconds 30`.
It uses process CPU-time deltas (100% means one logical CPU), resident memory,
and diagnostic delivery averages. Run CPU/GPU/allocations profilers separately,
and exclude all build activity from measurement windows. FPS in these logs is
not an input-to-photon or physical display-present measurement.

The profiling-only changes passed all 94 regression tests in Release mode.
Time Profiler and Metal System Trace attached successfully to the packaged app.
Allocations could not attach; no security settings were changed to enable it.

## First retained change: Annex-B scanning

Use 16-byte SIMD comparisons and construct payload ranges directly, avoiding the
intermediate start-position array. Scalar tail handling, leading/trailing zero
rules, empty-NAL rejection and returned ranges are preserved. Loads are
unaligned and bounded to accessible bytes; the code uses standard Swift SIMD on
both supported Mac architectures. No common-c code/capabilities, packet ownership,
decode flags, rendering quality, frame queues or presentation timing are changed.

Reproduce with `python3 Scripts/benchmark_annexb.py`. It extracts the actual old
and current methods and compiles them with `swiftc -O`; alternates order across
10 trials and checks matching ranges. The synthetic inputs isolate scanning;
they are not a replacement for live-stream measurements.

Intel i3-1000NG4, macOS 15.8.1, median microseconds per scan:

| Payload | Pattern | Main | Optimized | Speedup |
| --- | --- | ---: | ---: | ---: |
| 83,334 bytes | Random EBSP | 50.10 | 14.78 | 3.39x |
| 262,144 bytes | Random EBSP | 159.58 | 43.33 | 3.68x |
| 1,048,576 bytes | Random EBSP | 647.86 | 194.74 | 3.33x |
| 83,334 bytes | Zero-heavy EBSP | 72.32 | 14.96 | 4.83x |
| 83,334 bytes | One-heavy | 45.69 | 16.67 | 2.74x |
| 83,334 bytes | Dense NALs | 241.99 | 90.86 | 2.66x |
| 1,048,576 bytes | Dense NALs | 6332.79 | 4702.25 | 1.35x |

All 97 Release tests passed, including generated payload/vector-boundary cases,
malformed/empty NALs at different offsets, and buffers ending at a protected
memory page. The initial motion Time Profiler attributed about 1% of process
samples to the old scanner; these microbenchmark speedups must not be described
as whole-app CPU speedups. GPU work is unchanged by this parser change.
