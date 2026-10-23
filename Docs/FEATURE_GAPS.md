# Feature comparison — 23 October 2026

Compared the native client with current moonlight-qt settings, controller/session implementations, and the checked-in common-c interfaces. The goal is similar useful behaviour through native macOS APIs; Qt/SDL dependencies and platform-specific renderer options are not requirements. The implementation pass below addresses the inventoried gaps using native macOS APIs.

Upstream references: [settings UI](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/gui/SettingsView.qml), [preference model](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/settings/streamingpreferences.h), [controller input](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/input/gamepad.cpp), [session diagnostics and callbacks](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/session.cpp), [host launch parameters](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/backend/nvhttp.cpp). These links follow upstream master and may change after this review.

## Implementation status

The previously inventoried gaps are implemented locally, with the following boundaries:

| Area | Added behaviour |
| --- | --- |
| Desktop pointer | Absolute, letterbox-aware native pointer mode; independent capture/mode shortcuts; button swap and scroll reversal. |
| HDR / common-c | Actual host HDR callbacks, launch/resume fields, mastering/light metadata, SDR fallback, worker submission and input/RTT lifetime fixes. See COMMON_C_INTEGRATION_AUDIT.md. |
| Controller protocol | Arrival/type/button/capability packets, motion requests, real contact lifecycle, battery, LED, sustained/trigger rumble and native adaptive-trigger effects. Sunshine permits sixteen slots, GFE four. |
| Controller policy | Face-button swap, opt-in background input, persistent merged player-one mode and controller-presence launch bitmap. |
| Controller mouse / UI | Hold Start to toggle pointer emulation; stick movement, clicks and scroll. Native host/app navigation with visible selection, launch/back/settings actions and local keyboard navigation in sheets. |
| Custom modes | Editable even resolutions and 1–500 FPS globally and per app, with validation before saving/connecting. |
| Decoder / chroma | Automatic/hardware/software VideoToolbox preference. Opt-in H.264/HEVC 4:4:4 and corresponding full-plane Metal texture sizing. AV1 stays at 4:2:0; Auto prefers H.264/HEVC when 4:4:4 is requested. Actual profile support depends on macOS/host; unsupported decoder creation gives an actionable error. |
| Connection guidance | Poor-network overlay, stage/termination explanations, port names and explicit client-network port test. |
| Application options | Discovery opt-out, bundled English/German/French/Spanish localization with English fallback, and opt-in Discord desktop IPC presence with a configurable application ID. |
| Renderer / devices | Native-presenter VSync semantics explained in Settings; visible audio recovery/default-device fallback and Discord availability messages. |

Rich Presence defaults off and uses the supplied public application ID, `1563323903949021204`. It sends activity over local Discord IPC when enabled; no account token is stored. Protocol reference: [Discord RPC](https://docs.discord.com/developers/topics/rpc).

Controller contacts and device-specific effects are advertised only when native GameController exposes them. This does not promise two-finger data for position-only Sony profiles or arbitrary firmware-specific DualSense effects. Adaptive feedback/weapon/vibration translation follows the [public effect format](https://gist.github.com/Nielk1/6d54cc2c00d2201ccb8c2720ad7538db); unknown modes clear instead of leaving a stale effect. Motion axes follow [Moonlight’s native Apple client](https://github.com/moonlight-stream/moonlight-ios/blob/master/Limelight/Input/ControllerSupport.m).

Localization covers the main interface; detailed technical messages without a translation fall back to English. Language changes apply on reopening the app. Hardware/software selection cannot create a codec implementation that macOS does not supply.

These changes do not establish hardware parity. HDR, 4:4:4, native adaptive triggers, multiple controllers and route changes must still pass the real-device checklist. The native sample-buffer presenter retains platform-managed synchronization. Metal exposes its own VSync/unlocked policy.

## Scope exclusions

Cross-platform backends are not missing macOS features. Microphone forwarding, general file transfer and USB redirection were not part of the inventoried Moonlight Qt parity scope. Apollo clipboard actions remain a host extension; standard hosts can report them as unsupported while core streaming continues.

## Validation — 24 October 2026

The full Swift suite passes **64 tests**, including malformed decode chains/Annex-B pictures, RTT readiness and late callbacks, HDR metadata cleanup, absolute pointer mapping in flipped and unflipped views, sixteen-slot motion requests, adaptive-effect decoding, settings compatibility, Discord IPC framing, localization and relocated app resources. Existing audio, input/window, TLS/pairing and shortcut tests also pass.

Shader and localization loading share a packaged-resource resolver. Distributed apps do not evaluate SwiftPM’s generated accessor or depend on its absolute development directory.

A reachable/idle host probe is not an end-to-end stream test. The existing running Moonlight instance was left alone; new HDR/chroma/controller behaviours still need real-device checks in HARDWARE_VALIDATION.md.

Release packaging also passes: `./Scripts/package_app.sh release` produced `Products/Moonlight.app` and verified its Mach-O executable, Metal resources, all four language catalogs, licenses, plist and ad-hoc signature.

## Settings and code cleanup — 24 October 2026

Global and per-game settings now share resolution/FPS controls. Presets show only a dropdown; choosing Custom… reveals explicitly labelled fields. Choosing Custom preserves the current value, and enabling a per-game Native override no longer silently substitutes 1080p. Controller and application settings have dedicated sections, while decoder/color, mouse-axis and Discord application-ID options are tucked under advanced disclosures.

Controls that cannot affect the selected mode are hidden or disabled: manual VSync under native presentation, relative mouse scaling/capture under desktop mode, and 4:4:4 under explicit AV1. NVIDIA-specific game optimization is separated from normal Sunshine/Apollo settings. The unused shortcut-file-picker flow, unused window-mode cycling method and obsolete keyboard-layout forwarding were removed; saved legacy preferences remain readable.

Idle work was reduced without changing the focus/fullscreen recovery state machines: controller UI polling stops without a controller, during streaming and while inactive; unchanged focus selections no longer invalidate the UI. Native controller button/touch layouts are cached, touchpad aliases are deduplicated, and touch packets are skipped for hosts without that extension. Metal uses scheduled, generation-checked drawable retries rather than sleeping the render queue. Repeated identical service-status messages no longer publish redundant UI changes.

The complete regression suite still passes 64 tests. These changes reduce redundant work; they are not a new latency benchmark or a substitute for controller/HDR/device testing.

Release metadata cleanup also removes the global `NSSupportsAppNap`, `NSAppSleepDisabled` and `NSApplicationUpdateCycleEnabled` overrides. The existing stream-scoped process activity and focused display-sleep assertions remain responsible for streaming power behaviour. App metadata identifies v0.2 as version 0.2.0, build 2.
