# Frame loss during Vulkan branch testing

Investigated 26 October 2026.

The test app's console repeatedly reported `Video decode unit queue overflow`,
followed by IDR requests and waits for keyframes, across renderer selections.
The common decoder queue is bounded to 15 frames; overflow flushes that queue
and requests recovery. Vulkan diagnostics showed direct GPU imports with no
video uploads and approximately 1 ms of render preparation while frame delivery
fell well below the 60 FPS target.

The branch's decoder and moonlight-common-c sources were unchanged from main.
The supplied branch test apps were **Debug** builds: Swift `-Onone` and C `-O0`.
Main's release build uses Swift `-O` with whole-module optimization. Comparing
these configurations was unsuitable for evaluating renderer performance.

A standalone benchmark extracted the unchanged `pictureNALRanges` scanner,
used synthetic Annex-B buffers, and ran 60 iterations with a consumed checksum.
The compiler and source were the same; only `-Onone` versus `-O` differed:

| Encoded frame bytes | Debug scan time | Release scan time |
| --- | ---: | ---: |
| 83,334 | 70.176 ms | 0.079 ms |
| 262,144 | 227.762 ms | 0.130 ms |
| 1,048,576 | 953.107 ms | 0.633 ms |

At 40 Mbps / 60 FPS, 83,334 bytes is approximately the average encoded payload
per frame. The scan alone exceeded the 16.7 ms frame budget in Debug. Existing
"decode time" measurements begin just before VideoToolbox submission and omit
this CPU preparation, explaining the apparently healthy ~3 ms decode metric.
These measurements isolate scanner overhead; they are not full-stream latency
or network benchmarks. Live verification of the optimized app is still needed.

The HUD previously labeled missing encoded frame numbers as "Packet Loss".
Those gaps also include locally flushed frames and cannot establish UDP packet
loss. It now says **Frame Gaps**. Diagnostics include the selected renderer,
process ID, decoder queue depth, frame gaps, and decoder drops. Startup logs and
the packaged Info.plist identify the build configuration. Future performance
comparisons should use separate **Release** packages with matching stream settings.
