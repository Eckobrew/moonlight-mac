# moonlight-common-c integration audit — 23 October 2026

Audited the checked-in `Sources/MoonlightCommonC/include/Limelight.h` contract and corresponding `Connection.c`, `InputStream.c`, `AudioStream.c`, `ControlStream.c`, and `RtspConnection.c` implementations against the native Swift client. This evaluates the library version this app actually builds. It is not a line-by-line audit of the vendored library, and it does not assume every optional protocol extension is mandatory.

The six audio findings and all seven integration findings below have now been addressed locally. The original findings remain below as review history.

## Resolution status

| Finding | Implementation |
| --- | --- |
| 1. Direct video submission | Clear direct-submit capability; let common-c own its decode worker so session setup/recovery cannot block packet reception. |
| 2. Early input / failed sends | Start capture and controller polling only after connectionStarted; cache controller state/arrival only after a successful send; drain keyboard/mouse releases before stopping common-c. |
| 3. Controller metadata | Announce native buttons/type/capabilities on connection and remapping. Forward battery, LED, trigger rumble and native adaptive-trigger effects where available. |
| 4. HDR state | Add launch/resume HDR fields, handle actual host HDR callbacks and metadata, annotate decoded buffers, and choose transfer/presentation from actual state. SDR fallback clears old HDR metadata. |
| 5. Touch lifetime | Require native contact state, track explicit down/move/up, and cancel on focus loss, removal and stop. Position-only profiles do not advertise touch. |
| 6. RTT lifetime | Start metrics after connectionStarted, generation-check queued work and lock RTT access against disabling the connection before destruction. |
| 7. Malformed video | Reject malformed/inconsistent buffer chains, empty picture assembly and NAL append failures with DR_NEED_IDR. Parameter-set-only units remain valid. |

Optional callback coverage now includes connection quality, trigger rumble, motion requests, LED and adaptive triggers. Host Details exposes an explicit client port test using Moonlight’s public test server; stage errors also name relevant ports. A display-refresh hint is captured from the launching display. Sunshine uses up to sixteen controller slots; GFE keeps its four-slot limit.

Hardware-dependent paths still require the matrix in HARDWARE_VALIDATION.md. Adaptive triggers translate public feedback/weapon/vibration modes through GameController; unrecognized firmware-specific modes safely clear the effect. No SDL or raw HID dependency was added.

## Correct integration already present

- All configuration/callback structs use the library initializers. Stack-backed server strings remain allocated until `LiStartConnection()` returns; the library copies the information it retains.
- Connection startup and stop are serialized using `stoppingTask`; interruption is followed by waiting for the original startup task before `LiStopConnection()` and subsequent startup. C listener callbacks hop to the main actor and check the active session generation.
- Video decode-unit bytes are copied/retained before the synchronous submit callback returns; asynchronous VideoToolbox completion does not retain library-owned packet pointers.
- The app does not claim pull-renderer or reference-frame-invalidation support it hasn't implemented.
- Audio uses the negotiated channel count, sample rate, stream counts, mapping and samples-per-frame. `Limelight.h` explicitly defines mapping order as front L/R, center, LFE, back L/R, side L/R. The fixed WAVE 7.1 layout matches it for both negotiated quality modes.
- Audio direct submission is disabled, allowing the common library's separate receive/decode queues. The arbitrary-audio-duration flag is backed by Opus scratch capacity and negotiated PLC duration. PCM is dropped after decoding when compressed-queue backlog is excessive, preserving Opus prediction state.
- `STREAM_CFG_AUTO`, launch/resume extension query parameters, input encryption key/IV setup and per-sensor motion units are wired. Relative mouse packets and ordinary keyboard/controller state use the documented event families.

## Original findings (addressed)

### 1. P2 — Video claims non-blocking direct submission but has blocking setup/recovery paths

Contract: `Limelight.h:242–246` says `CAPABILITY_DIRECT_SUBMIT` is only for non-blocking renderers and runs submission on the receive thread.

Client: `StreamSessionController.startLimelightConnection()` sets that flag. `VideoToolboxDecoder.submitDecodeUnit()` can create a VideoToolbox session on the first format/keyframe and call `VTDecompressionSessionWaitForAsynchronousFrames()` while replacing or recovering a session. These operations can block the video receive thread. Async frame decoding and a separate presentation queue do not remove that synchronous work from submission.

Recommended fix: use the library's decode worker by clearing direct submission, or make every submission path non-blocking before advertising it. Measure loss/latency during initial IDR, resolution changes and decoder failures.

### 2. P2 — Input starts before the library accepts packets, and failed sends are cached as delivered

Contract/implementation: `InputStream.c` sets `initialized = true` in `startInputStream()`. Earlier `LiSend*` calls return `-2`.

Client: input capture/controller polling starts immediately after dispatching `LiStartConnection()` to another task. `GameControllerManager` stores `lastSentStates[index]` before sending and ignores the return value. An initially idle controller can have its first state dropped before input startup and never resent until a button/stick changes. Keyboard/button bookkeeping likewise does not distinguish rejected sends from delivered presses.

Recommended fix: enable host input after `connectionStarted`, or explicitly queue/reset and resend initial state once input is ready. Update deduplication state only on a successful send and handle other queueing errors without permanently suppressing state.

### 3. P2 — Controller metadata never reaches the host

Contract: `Limelight.h:755–791` supports legacy arrival through an empty controller event but recommends `LiSendControllerArrivalEvent()` to report type, buttons and capabilities. It falls back automatically for older hosts.

Client: only regular state packets are sent. Sony controller detection, haptics and motion/touch forwarding exist locally, but no arrival capability announcement tells Sunshine what it can request or emulate. This is a supported legacy integration, not an invalid API call; the advanced controller support is incomplete without capability discovery.

Recommended fix: announce each accepted controller slot after connection/hotplug, accurately advertising only implemented features. Reannounce surviving/remapped slots after disconnect and on reconnect. Advertise motion only when request handling and actual sensor activation are supported.

### 4. P2 — HDR capability is treated as the actual host HDR state

Contract: `ConnListenerSetHdrMode` reports actual host HDR changes and can fire even on an SDR stream. `LiGetHdrMetadata()` exposes host HDR metadata.

Client: Metal's HDR/PQ mode is set from `settings.enableHdr` before negotiation. No `setHdrMode` callback is installed and no host metadata is consumed. The user preference indicates capability, not that every arriving frame is HDR. Additionally, launch/resume omit the HDR query fields used by moonlight-qt, so offering a 10-bit codec is not a complete HDR negotiation path.

Recommended fix: separate requested capability, negotiated pixel format and actual HDR state. Handle host mode changes, populate launch HDR parameters where required, and select presentation transfer/matrix/metadata from the real stream. Verify SDR fallback and switching HDR on/off with both renderers. Upstream comparison: [HDR callback handling](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/session.cpp), [launch negotiation](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/backend/nvhttp.cpp).

### 5. P2 — Controller touch lifetime is inferred from position and can get stuck

Contract: touch events represent explicit down/move/up/cancel interactions with stable pointer IDs.

Client: `sendTouchState()` infers touch-down from an off-center axis value or click. A finger released while the controller retains its last off-center position stays classified as touching. Disconnect clears local tracking without sending a touch cancellation/up. Touchpad coordinates alone cannot establish actual contact lifetime.

Recommended fix: use native contact information where available, or disable unsupported contact reporting rather than fabricate permanent touches. Emit cancellations when removing/remapping slots and send the touchpad-click button independently. Validate two-finger/controller touch behaviour on real hardware.

### 6. P2 — RTT sampling is not explicitly gated to the documented connection lifetime

Contract: `Limelight.h:560–566` restricts `LiGetEstimatedRttInfo()` to between connection start and stop.

Client: metrics polling starts alongside input before the detached connection call necessarily begins. Timer callbacks spawn main-actor tasks; invalidating the timer does not cancel tasks already queued. `updateMetricsIfNeeded()` checks overlay visibility but not connection generation/readiness. A queued update can therefore sample while background stop is running. The library reads an ENet peer without acquiring its mutex and assumes the connection lifetime is protected by the caller.

Recommended fix: sample only after the current connection starts, generation-check queued metric work, disable sampling before stop, and ensure no sample overlaps control-stream destruction. Treat absent metrics as unavailable rather than reusing stale data.

### 7. P2 — Unparseable picture data can be acknowledged as successfully decoded

Contract: `DecoderRendererSubmitDecodeUnit` must return `DR_NEED_IDR` when submitted data cannot be processed.

Client: after scanning picture data for Annex-B NAL units, `VideoToolboxDecoder.submitDecodeUnit()` returns `DR_OK` when the assembled frame length is zero. For a nonempty malformed picture this silently acknowledges a lost reference frame, rather than requesting a keyframe. Parameter-set-only units are a separate, valid no-picture case already handled earlier.

Recommended fix: return `DR_NEED_IDR` for nonempty picture data that cannot form a sample, and propagate NAL assembly failures. Add malformed/truncated decode-unit tests.

## Original optional-feature observations

`connectionStatusUpdate`, extended controller callbacks (trigger rumble, LED and adaptive triggers), detailed connectivity tests, controller battery reports and client-refresh-rate hints are currently unwired. The library permits optional callbacks, so these are capability/diagnostic gaps rather than automatic contract violations. Not advertising 4:4:4 or reference-frame invalidation is correct until the decoder/presentation path supports them.

The motion and rumble fixes from the earlier audit address their immediate state/lifetime defects, but do not by themselves supply controller arrival metadata, real touch contact detection or all device-specific capabilities. Prioritize findings 1, 2, 4 and 6 before adding more advertised protocol features.

## Validation — 24 October 2026

The full Swift suite passes **64 tests**, including malformed decode chains/Annex-B pictures, RTT readiness and late callbacks, HDR metadata cleanup, absolute pointer mapping in flipped and unflipped views, sixteen-slot motion requests, adaptive-effect decoding, settings compatibility, Discord IPC framing, localization and relocated app resources. Existing audio, input/window, TLS/pairing and shortcut tests also pass.

Shader and localization loading share a packaged-resource resolver. Distributed apps do not evaluate SwiftPM’s generated accessor or depend on its absolute development directory.

A reachable/idle host probe is not an end-to-end stream test. The existing running Moonlight instance was left alone; new HDR/chroma/controller behaviours still need real-device checks in HARDWARE_VALIDATION.md.

Release packaging also passes: `./Scripts/package_app.sh release` produced `Products/Moonlight.app` and verified its Mach-O executable, Metal resources, all four language catalogs, licenses, plist and ad-hoc signature.
