# Vibepollo compatibility plan

Research date: 24 October 2026. Status: proposal; no client implementation or host changes have been made for this plan. PyroWave is excluded throughout.

## Research baseline

Reviewed Vibepollo host commit [`1b316787099b1b808f04ad865407e71785d58487`](https://github.com/Nonary/Vibepollo/tree/1b316787099b1b808f04ad865407e71785d58487), its native GameStream and management endpoints, Remote Monitor/Input dispatch, and the companion Moonlight Qt client at [`d6205e1e7af5ee162529f817833c2710307b4ccd`](https://github.com/Nonary/moonlight-qt/tree/d6205e1e7af5ee162529f817833c2710307b4ccd). Compared these with this client's networking, models, launch/resume handling, clipboard, common-c, controller callbacks and frame presentation.

These commits describe upstream source, not the version installed on the user's PC. The implementation must discover authenticated capabilities at runtime and tolerate older Vibepollo, Apollo, Sunshine and GameStream hosts. Brand names and an advertised version alone do not prove a feature is available.

## What is already usable

Vibepollo's capture backend, display recovery, virtual-display driver, host-side game library synchronization, RTSS/NVIDIA integration and frame-generation helpers run on the host. Normal H.264/HEVC/AV1 clients benefit from those host facilities without recreating them locally. Native resolution, HDR requests, text clipboard synchronization, controller arrival/type reporting, motion, rumble, LEDs, battery and adaptive-trigger handling already exist in this client. They still need Vibepollo-specific hardware acceptance tests. See the [host overview](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/README.md).

We should preserve those implementations and add the missing protocol integration.

## Features and feasibility

| Feature | Current client gap | Proposed support | Effort / confidence |
| --- | --- | --- | --- |
| Permissions | Does not interpret host permission masks. | Show granted permissions; gate launch, input and each clipboard direction independently; explain revocation and permission errors. | Small–medium; high. |
| Stable application identity and ordering | Stores numeric IDs and titles; ignores UUID, IDX, ArtVersion and currentgameuuid. | Preserve host ordering; launch/resume/artwork by UUID where supported; migrate per-game settings, shortcuts and artwork keys without losing existing entries. | Medium; high. |
| Virtual-display launch control | Sends resolution/HDR but no explicit virtual-display preference. | Per-host/per-game Host default / Virtual / Physical preference, driver readiness, HDR capability and host launch warnings. | Medium; high. |
| Render-resolution scaling | No scaleFactor launch option. | Optional render-resolution multiplier with accurate descriptions and host-override handling. This parameter scales requested dimensions; it is not a promise of Windows UI DPI control. | Small–medium; high. |
| Fractional refresh | Requested FPS is an integer. | Exact refresh representation, e.g. 59.94/119.88, with correct launch, transport and display-rate conversion. | Medium; medium pending transport audit. |
| Host runtime bitrate | Bitrate chosen only at startup. | In-session manual bitrate changes with host acknowledgement and applied-value feedback; then optional client-driven adaptation. | Medium; high for manual control. |
| Host telemetry | HUD reports client/stream measurements. | Optional host CPU/GPU/encoder/VRAM/temperature readings, clearly distinct from local metrics. | Small–medium; high. |
| Put PC to Sleep | Wake-on-LAN exists; no host sleep action. | Explicit confirmed, permission-gated sleep control through the paired-client protocol. | Small–medium; high for protocol, Windows hardware testing required. |
| Server commands | Ignores repeated command names; common-c has no sending API. | In-session menu for commands already configured on the host; send the advertised index through encrypted control transport. | Medium; high after common-c integration. |
| OTP pairing | Only ordinary PIN pairing. | Consume a host-generated OTP/passphrase through the normal cryptographic pairing flow. | Medium; high. |
| Remote Monitor | A normal stream path may display its catalogue entry, but role/control lifecycle is not implemented. | Use the Mac as an additional streamed display of the PC; preserve monitor-specific settings and host-owned display lifetime. | Medium–large; feasible. |
| Remote Input | Startup assumes video/audio streams. | Keyboard/mouse/controller-only session with suitable control-only transport and local capture UI. | Large; transport feasibility spike first. |
| VRR capture/presentation | No clientVrrRequested negotiation; current frame pacer receives buffers without their presentation timestamps. | Separate opt-in mode with timestamp-aware presentation and host VRR capture negotiation. | Large; experimental until measured on macOS. |
| DualSense waveform haptics / speaker | Ordinary rumble/adaptive triggers exist; PCM extensions and physical playback do not. | Investigate a macOS backend, then port protocol extensions only if real hardware playback is viable. | Large; uncertain. Companion waveform backend currently excludes macOS. |
| Host display arrangement / advanced configuration | No management API integration. | Initially link to the host UI. Optional later scoped-token management connection for selected operations. | Medium–large; separate opt-in feature. |

Protocol evidence: [GameStream endpoints and launch fields](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/src/nvhttp.cpp), [permission definitions](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/src/crypto.h), [remote session identities and dispatch](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/src/remote_session.cpp), [control extensions](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/src/stream.cpp).

## Implementation sequence

### Phase 1 — Compatibility foundation

1. Replace the flat metadata parsing boundary with typed, additive host capabilities and an app catalogue parser that preserves repeated elements. Retain ordinary serverinfo/app list compatibility and authenticated provenance.
2. Parse Permission and make absent permission information mean unknown/legacy, not zero permissions. Unknown bits remain uninterpreted. Refresh on reconnect and handle runtime denials without losing pairing.
3. Add application UUID, host order/index, artwork revision and current-app UUID. Migrate numeric-ID-based settings and shortcuts lazily, scoped by server identity. Do not use title text as identity.
4. Distinguish a streamable application from a host action. Handle the host's intentional XML 410 action-completion responses and confirmation requests contextually; do not reinterpret every 410 as success or wait for nonexistent video.
5. Give newly paired Macs a useful device label instead of the current hard-coded legacy `roth` name.

Acceptance: old saved hosts/settings load; stock hosts behave as before; repeated commands survive parsing; app reordering/ID changes preserve settings and shortcuts; permission changes update available actions.

### Phase 2 — Useful session controls

Deliver as independently reviewable changes:

- Virtual-display preference, readiness and launch-warning handling, consistently applied to launch and resume. Leave per-client topology/GPU/driver administration on the host. Add render scaling only after a live test confirms that stream negotiation and absolute mouse geometry agree with the host's effective dimensions.
- Add the PlayStation controller launch mask (`psmap`) alongside the existing controller bitmap, including persistent-controller mode and hotplug tests. Existing controller feedback remains native GameController based.
- Fractional refresh: retain exact requested timing separately from common-c's integer FPS. Audit launch `mode`, SDP maxFPS, clientRefreshRateX100 and local scheduling together. Never put a millihertz value into an integer-FPS field indiscriminately. Preserve integer defaults for stock hosts.
- Manual runtime bitrate via authenticated `GET /bitrate?bitrate=<kbps>`. Respect the returned applied bitrate, host ceilings and permission/session errors. The host advertises `runtime_bitrate` but explicitly reports host ABR unsupported; automatic adaptation would be our own later controller, with bounds, hysteresis and measured network feedback.
- Optional host telemetry, enabled only by authenticated HardwareMetricsVersion. Poll only while this client owns running video, at most one request in flight and no faster than interval_ms; stop on 403/409, back off on 503, and clear missing/stale values. Never treat missing readings as zero or persist GPU IDs across host restarts. See the [metrics contract](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/docs/hardware-metrics.md).
- Put PC to Sleep using the separate host grant, confirmation, fresh short-lived one-use token and empty POST. Do not create a stream or a game shortcut. An accepted request is not proof Windows finished sleeping, and an unknown outcome must not be retried automatically. Test with fake endpoints before a separately authorized physical sleep/wake test. See the [sleep contract](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/docs/power-actions.md).
- Host-configured server command menu. Add a narrow common-c API for encrypted control packet 0x3000 and the one-byte command index. Preserve advertised order, refresh before use, enforce permission and stream lifetime, and report submission rather than claiming remote execution completed. Do not add a free-form shell interface.
- OTP consumption: add an alternative pairing form, validate expiry/failure paths, and retain signature/challenge verification plus certificate pinning. Generating/managing OTPs remains a host UI operation initially.

Acceptance: each control appears only when supported; no extra operations occur on stock hosts; bad pins/IDs/redirects fail; cancellation/reconnect cannot apply a previous session's result. Validate native resolution, HDR, clipboard directions and controller feedback against the real host.

### Phase 3 — Remote Monitor and Remote Input

Remote Monitor first. Model game, monitor and input roles explicitly. Use host-advertised identities and documented synthetic identities as compatibility fallbacks; configured monitor profiles may use their own UUIDs, so do not classify an arbitrary title as a control. Keep profile-specific settings, reconnect/resume behaviour, retained monitor release, client ownership and host-confirmed termination separate.

The initial Mac implementation supports one active transport. Vibepollo supporting several clients does not give this app several concurrent streams: vendored common-c has process-global state. Concurrent local stream windows require a separate architecture project, likely process isolation or a multi-instance library refactor.

Remote Input starts with a transport prototype. Prove control-only setup, keepalives, disconnect, permissions and input release without waiting for absent video/audio, initializing the decoder, or running normal video watchdogs. Then add a small connected/control status UI and clear keyboard/mouse capture/release controls. Avoid pretending that suppressing video rendering creates an input-only session.

Acceptance: run a main game on another client while this Mac attaches as monitor or input; verify disconnecting this Mac affects only its role; handle host display-capacity limits, revoked permissions, dropped connections, profile changes and termination confirmation.

### Phase 4 — Experimental timing and controller extensions

VRR is a rendering project, not a launch-checkbox change. Propagate existing decoded presentation timing into the frame queue, implement cadence/jitter/drift handling and bounded buffering, and validate Metal presentation on fixed-refresh and ProMotion displays. Enable `clientVrrRequested=1` only when the selected presentation mode implements the semantics claimed by that flag. Measure latency, stutter, frame drops, HDR and variable-rate games before making it a default. Keep the existing path as fallback. See the [companion launch negotiation](https://github.com/Nonary/moonlight-qt/blob/d6205e1e7af5ee162529f817833c2710307b4ccd/app/backend/nvhttp.cpp).

DualSense waveform haptics needs a macOS hardware spike first. CoreHaptics' existing rumble translation is not arbitrary stereo actuator PCM playback. Determine whether wired controller audio/HID output is usable on supported Macs; investigate Bluetooth separately. Only then plan common-c feature flags/callbacks, bounded sample queues, per-slot ownership, reconnect and teardown. Advertise support only after a real playback backend is ready. Speaker PCM is a distinct extension and hardware path, not automatically included with actuator support. References: [Windows waveform contract](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/docs/windows-dualsense-haptics.md), [speaker protocol](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/docs/controller_speaker_pcm.md), [companion platform gates](https://github.com/Nonary/moonlight-qt/blob/d6205e1e7af5ee162529f817833c2710307b4ccd/app/streaming/input/dualsensehaptics.cpp).

## Optional host management integration

Arrange-client-displays is a management operation (`/api/clients/display-layout`), not granted by ordinary streaming pairing. If native editing is wanted later, use a separately configured management endpoint and narrowly scoped token stored in Keychain, with explicit server trust. Retain the host's apply-on-next-activation semantics. Do not assume the streaming pin, authentication mechanism or port automatically carries over. See [management authentication](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/docs/api.md) and [layout handlers](https://github.com/Nonary/Vibepollo/blob/1b316787099b1b808f04ad865407e71785d58487/src/confighttp.cpp).

Driver installation, WGC selection, RTSS/NVIDIA/Lossless Scaling configuration, library-provider synchronization, device permissions, host updates and administrative token creation can stay in the existing host UI. Add focused native management only when it improves an actual client workflow.

## Explicit boundaries and validation

- No PyroWave codec, calibration, probe or FEC work.
- No file-transfer commitment from the existence of permission bits: the reviewed streaming nonce handler checks permission but does not implement a complete transfer workflow. A complete host/client contract would be required first.
- No microphone-forwarding promise; it is not established by the reviewed client extension contracts.
- No guarantee of waveform/speaker haptics or VRR benefits on macOS before hardware prototypes.
- No automatic host setting/driver changes, sleep transitions, commit/push, or installed-app replacement as part of this planning task. The previous app replacement authorization was one time only.

Use parser/HTTP/TLS fixtures and control-packet tests for protocol changes, migration fixtures for persistence, and state-machine tests for session lifetimes. Hardware acceptance must cover the user's installed Vibepollo version, an older Apollo/Sunshine host, normal codecs, native/custom/fractional modes, HDR, permissions, reconnection, multiple devices, role ownership and cleanup. Benchmarks are required before claiming timing or latency improvements. This research pass did not exercise or modify the live host.

Recommended first delivery: Phase 1, then virtual-display controls, manual runtime bitrate and optional host telemetry. Follow with sleep, server commands and OTP; then Remote Monitor/Input. Keep VRR and waveform haptics as explicitly experimental milestones.
