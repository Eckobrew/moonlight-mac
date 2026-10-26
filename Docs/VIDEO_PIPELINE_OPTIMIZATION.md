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
