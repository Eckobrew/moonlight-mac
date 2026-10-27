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
10 trials and checks matching ranges. Every fixture must parse as a valid picture;
dense start codes are aligned so fixture insertion cannot empty a preceding NAL. The synthetic inputs isolate scanning;
they are not a replacement for live-stream measurements.

Intel i3-1000NG4, macOS 15.8.1, median microseconds per scan:

| Payload | Pattern | Main | Optimized | Speedup |
| --- | --- | ---: | ---: | ---: |
| 83,334 bytes | Random EBSP | 45.84 | 12.06 | 3.80x |
| 262,144 bytes | Random EBSP | 144.39 | 36.63 | 3.94x |
| 1,048,576 bytes | Random EBSP | 511.43 | 143.80 | 3.56x |
| 83,334 bytes | Zero-heavy EBSP | 58.03 | 11.92 | 4.87x |
| 83,334 bytes | One-heavy | 35.20 | 12.94 | 2.72x |
| 83,334 bytes | Dense NALs | 294.06 | 192.74 | 1.53x |
| 1,048,576 bytes | Dense NALs | 6493.37 | 4959.03 | 1.31x |

All 97 Release tests passed, including generated payload/vector-boundary cases,
malformed/empty NALs at different offsets, and buffers ending at a protected
memory page. The initial motion Time Profiler attributed about 1% of process
samples to the old scanner; these microbenchmark speedups must not be described
as whole-app CPU speedups. GPU work is unchanged by this parser change.

## Contiguous sample assembly

The four-byte-prefix path can reuse the encoded allocation that already belongs
to the decoder. Validate all destination/source offsets first, then write length
prefixes and compact padding with memmove only when source/destination differ.
CoreMedia owns that same allocation until asynchronous consumers release it.
No common-c-owned pointer escapes its callback.

When any prefix would expand into its payload, return without changing a byte
and use the original per-NAL CoreMedia references. A prototype that allocated
and copied a second expanded buffer was rejected: it regressed large frames with
few three-byte-prefix NALs. AV1 stays on its original unmodified OBU path.

Reproduce assembly-only timings with `python3 Scripts/benchmark_nal_packing.py`.
Both paths include the initial owned copy; ranges are precomputed to isolate
assembly from scanning. Representative median microseconds on this Mac:

| Payload | NALs | Prefix | Main | Fast path/fallback |
| --- | ---: | ---: | ---: | ---: |
| 83,334 bytes | 1 | 4 bytes | 4.33 | 3.38 |
| 83,334 bytes | 4 | 4 bytes | 7.47 | 3.23 |
| 83,334 bytes | 64 | 4 bytes | 68.35 | 3.68 |
| 1,048,576 bytes | 64 | 4 bytes | 121.22 | 52.70 |
| 1,048,576 bytes | 4 | 3 bytes | 59.37 | 58.29 |

The three-byte-prefix cases use the original assembly path and varied within
roughly -5% to +14% across these microbenchmarks; no fallback speedup is claimed.
The main benefit is fewer prefix allocations/reference blocks for contiguous
NAL layouts, without introducing a second full-payload copy.

## Validation and limits — 26 October 2026

All **99 Release tests** pass on the Intel test Mac, including byte-for-byte
packing/padding tests and a late-expansion case that must leave the entire source
unchanged. The separate `Products/Optimization-test/Moonlight.app` contains the
tested Release executable and passed the app signature/resource verifier. The
installed app and unchanged-main baseline remain available.

NATHAN-PC Desktop, configured 2560x1600 / 60 FPS / 40 Mbps, SDR 4:2:0, V-Sync on,
pacing off; actual changing-desktop delivery varied with the video playlist:

| Presenter | Codec | Decoded callbacks observed | Decoder drops | Inferred frame gaps |
| --- | --- | ---: | ---: | ---: |
| AVSampleBuffer | HEVC | 4496 | 0 | 0 |
| AVSampleBuffer | H.264 | 1482 | 0 | 0 |
| Metal | H.264 | 1993 | 0 | 0 |
| Metal | HEVC | At least 1800 | 0 | 0 |

Pictures were visually checked; no VideoToolbox output/submission errors or
common-c decode-queue overflow was logged. Separate processes exercised fresh
connections/teardown and both codec/presenter combinations. An optimized native
HEVC trace contained 535 decode/scan intervals and no segmented-assembly
intervals, confirming use of the contiguous path on this workload.

Whole-process measurements are context, not a controlled improvement claim:
the baseline native window used 19.36% of one logical CPU at 38.78 decoded FPS;
the optimized native window used 17.39% at 34.37 decoded FPS. Both work out to
about 5 ms process CPU per decoded frame. The playlist, encoded complexity and
frame rate changed, and transport/audio/framework work dominate these totals.
The isolated preparation benchmarks establish the retained CPU improvements;
this live comparison does not establish a whole-app percentage reduction.

GPU commands, shaders, texture formats, scaling, display queues and input routing
are unchanged. GPU tracing worked, but this pass does not claim GPU savings.
No extra buffering or synchronization waits were added. Numerical input-to-photon
latency is not measured by these tools; user responsiveness feedback remains a
separate validation. HDR/4:4:4 and unsupported AV1 hardware are not claimed as new
real-device validation; AV1's OBU path and HDR/presentation behavior are unchanged.

The Apple Silicon CI run exposed main's existing one-second shutdown assertions
under load. Only the previously validated deterministic shutdown/TLS test fixes
were carried over; no Vulkan renderer/dependency code is part of this branch.
