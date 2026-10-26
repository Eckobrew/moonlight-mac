# Experimental libplacebo/Vulkan renderer

This branch adds a third renderer alongside Metal and AVSampleBufferDisplayLayer.
Select **libplacebo (Vulkan, Experimental)** under Settings → Renderer in an
enabled build. Metal remains the default. Builds without the dependency disable
the picker entry and reject a saved libplacebo selection before contacting a host.

## Build

Install libplacebo **7.360.1** (with its Vulkan backend and a shader compiler),
Vulkan headers, the Vulkan loader (`libvulkan.1.dylib`), and MoltenVK. The bridge
is compile checked against that libplacebo release and Vulkan headers 1.4.313.
Dependencies must match the architecture of the app. The Vulkan loader must be
discoverable by `dlopen`; its ICD discovery must find MoltenVK. For an SDK install,
this normally means configuring `DYLD_LIBRARY_PATH` and `VK_DRIVER_FILES` in the
launch environment to the SDK's library directory and MoltenVK ICD JSON file.
Check your SDK's installation instructions for the actual paths.

Make `libplacebo.pc` discoverable through `PKG_CONFIG_PATH`, and check:

```sh
pkg-config --modversion libplacebo
pkg-config --cflags --libs libplacebo
MOONLIGHT_LIBPLACEBO=1 swift build -c release
MOONLIGHT_LIBPLACEBO=1 swift test
```

Vulkan headers must also be in the compiler's include search path. If your
libplacebo pkg-config flags do not include them, add `-Xcc -I/path/to/vulkan/include`
to the Swift commands. Library search paths must include libplacebo's dylib
directory. For Xcode, launch Xcode with `MOONLIGHT_LIBPLACEBO=1` and the same
dependency environment, then resolve the local package again. Use a separate
SwiftPM scratch path when keeping enabled and normal builds side by side.

The default `swift build` / `swift test` require no additional libraries. The C
bridge compiles an unavailable-backend stub unless `MOONLIGHT_LIBPLACEBO=1` is set.
The flag is explicit; installing a library does not change renderer availability
in an already-built app.

## Self-contained app package

Enabled packages embed the macOS `libMoltenVK.dylib`, libplacebo, and their
non-system dylib dependencies in `Contents/Frameworks`. The bridge loads the
bundled MoltenVK directly, so recipients need no Vulkan SDK, loader installation,
ICD manifest, or environment variables. Unbundled command-line builds still use
the SDK Vulkan loader described above. This follows MoltenVK's supported
[dynamic-library integration](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md).

Obtain the macOS dylib from an official MoltenVK distribution or Vulkan SDK.
Provide its license and notices, libplacebo's license, and license/notice files
for each transitive dylib in a JSON manifest. Keys are the resolved dylib filenames;
values are lists of license files, absolute or relative to the manifest:

```json
{
  "libMoltenVK.dylib": ["MoltenVK/LICENSE", "SPIRV-Cross/LICENSE"],
  "libplacebo.360.dylib": ["libplacebo/LICENSE"]
}
```

List any additional libraries reported by the packager, using the notice paths
from your actual dependency distributions. Files are copied into the app's
`Contents/Resources/Licenses/Vulkan` directory. Dependencies are never downloaded
automatically during packaging.

```sh
MOONLIGHT_LIBPLACEBO=1 \
MOONLIGHT_MOLTENVK_DYLIB=/path/to/libMoltenVK.dylib \
MOONLIGHT_RUNTIME_LICENSES=/path/to/runtime-licenses.json \
MOONLIGHT_PACKAGE_DIR="$PWD/Products/Vulkan-test" \
./Scripts/package_app.sh release
```

`MOONLIGHT_PACKAGE_DIR` selects a separate output directory, leaving the existing
`Products/Moonlight.app` untouched. Use `MOONLIGHT_BUILD_PATH` for a separate
SwiftPM scratch path if desired. `MOONLIGHT_RUNTIME_LIBRARY_DIR` can supply an
extra directory for resolving dependency install names. Normal `pkg-config`
configuration is still required at build time.

Use **Release** packages for streaming and latency comparisons with the main
app. Debug packages compile the shared Swift decoder with `-Onone` and C code
with `-O0`; their CPU overhead can overflow the common decode queue even when
VideoToolbox's measured hardware decode time is low. Debug GPU smoke tests are
correctness checks, not streaming performance measurements. Startup logs and the
`MoonlightBuildConfiguration` Info.plist field identify the build configuration.
The HUD's **Frame Gaps** figure counts missing encoded frame numbers, including
local queue flushes; it does not distinguish those from lost network frames and
does not measure individual UDP packet loss. Diagnostics include decoder backlog
to help distinguish these cases.

The packager resolves the complete linked dylib graph, rejects incompatible
architectures and filename collisions, rewrites dependencies to bundle-relative
paths, removes development-machine rpaths, and requires notices for every copied
library. It signs embedded dylibs before the app using `MOONLIGHT_SIGNING_IDENTITY`
(ad hoc by default). Existing `MOONLIGHT_NOTARY_PROFILE` support applies to the
completed package. This helper supports dylib dependencies; dependencies packaged
as third-party frameworks must first be supplied as dylib builds.

`Scripts/verify_app.sh` checks the library graph, architecture coverage, notices,
and the full app signature. `python3 -B Tests/Packaging/test_vulkan_bundle.py`
builds real Mach-O fixtures and verifies that a relocated, signed app still runs
after its original dependency directory is deleted. Real Vulkan rendering and
Developer ID notarization still require their respective runtime and credentials.

With the same dependency environment, `python3 -B Tests/Packaging/run_vulkan_smoke.py`
builds a separate temporary test app and opens a short-lived rendering window.
It clears Vulkan and dyld environment overrides before exercising the bundled
runtime. It requires direct imports with zero CPU uploads for all eight input
formats, checks SDR/PQ sources, resizing, V-Sync on/off, and context recreation,
and compares GPU-readback pixels against the CPU-upload reference. A separate
non-IOSurface buffer verifies the compatibility fallback. This test has passed
on an Intel Iris Plus Mac with libplacebo 7.360.1 and MoltenVK 1.4.2. End-to-end
color accuracy and input latency still need live-stream comparison.

## Pipeline and limits

VideoToolbox decoding and the existing frame pacer feed a one-frame mailbox.
A dedicated serial render queue owns the Vulkan instance, Metal surface,
swapchain, plane textures, and libplacebo renderer. New frames replace queued
frames while presentation waits. The renderer acquires a drawable **before**
selecting the newest buffer from the mailbox. Disconnecting during acquisition
discards that frame instead of presenting an old session's image. Teardown is
queued so the main thread and decoder do not wait for GPU work.

The acquisition boundary follows Moonlight Qt's macOS workaround: wait for the
previous submission, start the swapchain frame, then render a transparent 1×1
overlay before selecting video. MoltenVK can acquire its drawable lazily when
rendering starts; merely calling `pl_swapchain_start_frame` is insufficient.
The video path uses `pl_render_fast_params`, as Qt does, rather than libplacebo's
default Lanczos scaling/peak-detection preset. These changes preserve Vulkan
swapchain presentation; they do not implement a separate Metal presenter.
See [Qt's renderer](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/video/ffmpeg-renderers/plvk.cpp)
and [macOS renderer flags](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/video/ffmpeg-renderers/plvk.h).

IOSurface-backed decoded buffers are mapped through `CVMetalTextureCache` on the
actual Metal device exported by Vulkan. Their plane textures are imported with
`PL_HANDLE_MTL_TEX`; this path does not lock or read the buffer on the CPU or
upload its pixels. The bridge retains each decoded buffer, CoreVideo wrapper,
and imported texture until GPU reads complete, using a bounded three-slot pool
and nonblocking completion polling. It does not call `pl_gpu_finish` per frame.

The GPU queue depth is one, with asynchronous transfer/compute queues disabled
for this latency-oriented path. V-Sync requests mailbox presentation (FIFO
fallback); disabling it requests immediate presentation (also FIFO fallback if
unsupported). This limits work ahead of the newest input frame. Resizing only
explicitly reconfigures the swapchain when the requested backing-pixel size changes.

Buffers without usable Metal imports use `pl_upload_plane` as a compatibility
fallback. The app logs the selected input path and reports the first fallback;
the bridge exposes import/upload counts for diagnostics and tests. Decoding
remains hardware accelerated where supported; scaling, YUV conversion, tone
mapping, and presentation run on the GPU through Vulkan/MoltenVK. The older
CPU-copy test app can be retained separately for comparison. No numerical
end-to-end latency improvement is claimed from synthetic rendering tests.
With `MOONLIGHT_STREAM_DIAGNOSTICS=1`, logs report average CPU wall times for
acquisition (including drawable waits), render preparation, and submission every
300 presented frames. These component timings are not mouse-to-photon measurements.

Supported input: 8/10-bit biplanar 4:2:0 and 4:4:4, limited/full range, with
explicit row strides and 10-bit high-bit alignment. Matrix, primaries, transfer,
and common chroma-location attachments are read from each pixel buffer. Output
is SDR sRGB; PQ and HLG sources are tone mapped by libplacebo. HDR mastering and
content-light metadata are not yet forwarded, and native EDR output is not yet
implemented. Aspect ratio is preserved with black bars.

Initialization and fatal presentation failures stop that renderer and display an
error in the stream view. Reconnect with Metal to recover. There is no automatic
renderer switch during a session.

## Runtime verification

On a Mac with the dependencies installed, exercise a live host with SDR NV12,
10-bit PQ, full range, and 4:4:4 streams. Verify colors against Metal, aspect ratio,
Retina resizing, monitor moves, fullscreen, V-Sync on/off, minimize/restore,
disconnect/reconnect, and changing resolution. Check that missing ICDs produce
an actionable error. Measure latency and memory bandwidth at 4K/120 before using
this as a primary renderer. Frame pacing adds its own queue when explicitly
enabled; it remains an independent user preference.

API references: [libplacebo v7.360.1](https://github.com/haasn/libplacebo/tree/v7.360.1)
and [Vulkan Metal surface extension](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_metal_surface.html).
