# Real-host validation

These checks require a Sunshine/Apollo PC, appropriate displays/audio devices and
controllers. Record Mac model, macOS version, host version, display, codec,
resolution, frame rate, bitrate and renderer for each run. Run optimized builds.

| Area | Check | Expected result |
| --- | --- | --- |
| Pairing migration | Select a previously saved PC without a pin, cancel, retry and complete pairing | PC/settings stay saved; cancellation cannot later add a pin; success requires a fresh PIN |
| Host trust | Reinstall/change the host certificate | Stream/clipboard/app requests fail; no silent trust replacement; explicit re-pair recovers |
| Host addresses | Connect by LAN IP, Bonjour name and remote fallback | Saved certificate authenticates the same PC at each address |
| Reconnect | Disconnect while launching/negotiating, then reconnect repeatedly | No background stream resurrection, hang, stale error or lost input |
| Decode | H.264 and HEVC; AV1 on supported Macs; unsupported AV1 selection behavior | Correct picture, useful errors/capability gating and keyframe recovery |
| HDR | SDR/HDR content, Metal/native renderers, fullscreen/windowed, display changes | No washed-out blacks, clipped highlights, unexpected tone mapping or blank stream |
| Refresh | 60/120/high-refresh modes, pacing on/off, move between displays | No shutdown hang; sensible frame drops and latency; no stale frames after stop |
| Native resolution | With laptop and external displays attached, launch repeatedly from the external display; repeat with settings sheets and fullscreen changes | Native resolution follows the content window; `Resolved Native display resolution` and HTTP `requested mode` log entries agree on every launch/resume |
| Audio | Stereo/5.1/7.1 channel test; default/external/Bluetooth devices; route/focus changes | Correct channel order, no persistent underruns, recovery after route changes |
| Keyboard | UK/German/AZERTY, dead keys, AltGr, ISO/JIS keys, keypad Enter, Caps Lock, host paste | Physical position mapping is consistent; exact text paste works; no stuck modifiers |
| Mouse | High-polling mouse, fractional movement, focus loss, Spaces/fullscreen changes | Smooth relative input and reliable cursor release/recapture |
| Startup capture | Start a desktop stream directly into each fullscreen mode, then compare before/after Cmd+Tab | Smooth input from the first capture; switching apps is not required to recover |
| Wi-Fi latency | Compare against moonlight-qt with identical codec, resolution, FPS and bitrate; record RTT and RTT variation while idle and moving the mouse | Distinguish network spikes from decode and presentation delay; capture HUD readings before/after switching apps |
| Controllers | 1–16 controllers with Sunshine; four-slot GFE limit; unplug/reorder/reconnect | No crash/stuck buttons; correct player slots |
| Controller extras | Xbox/PS rumble, trigger rumble, native contact/motion, sensor rates, battery/LED, DualSense adaptive feedback/weapon/vibration | Features actually work with the intended host/controller combination |
| Clipboard | Copy while sends/pulls are delayed; unsupported host clipboard endpoint | New local text is not overwritten; one failed direction does not disable the other |
| Release | Launch the packaged .app on another supported Mac | Native frameworks/resources load; signing/permissions work; no dependency on build paths |
| Public release | Developer ID sign, notarize, staple, assess on a separate Mac | Gatekeeper accepts the distributed app; corresponding source revision is available |

Measure input-to-photon and audio delay with a real setup before making numerical
latency or “lowest latency” claims. Unit tests and build success are not latency
benchmarks.

When comparing FPS, use continuous motion (a game, animation, or moving a window)
as well as a static desktop. A host may send fewer frames when the desktop is idle.

For startup/focus investigations, enable opt-in diagnostics when launching the
release binary (substitute your saved host and app names):

```sh
MOONLIGHT_STREAM_DIAGNOSTICS=1 ./Products/Moonlight.app/Contents/MacOS/MoonlightMac stream 'PC name' 'Desktop'
```

The `STREAM-DIAGNOSTICS` log records decode FPS, Metal submission FPS (only relevant
for the Metal renderer), decode time, network RTT/variation, window visibility/focus
and mouse coalescing state twice per second, even with the HUD hidden. It is disabled
by default. Compare continuous-motion readings before and after switching apps;
these counters do not measure input-to-photon latency.

## Desktop startup check — 2026-10-22

Tested the packaged release against a real Sunshine desktop over Wi-Fi using
HEVC, 1920×1080 at 60 FPS, 40 Mbps, the native AVSampleBuffer renderer, pacing off
and native fullscreen. On a fresh connection, before the first focus switch:

- Decode throughput reached 60 FPS; moving-desktop samples repeatedly reported
  58–60 FPS. Idle desktop samples still fell to 16 FPS.
- RTT was mostly 2–3 ms after startup, with occasional Wi-Fi spikes (up to 13 ms
  in this run).
- The user reported smooth mouse movement at startup without the previous
  Cmd+Tab workaround.

This verifies the desktop symptom improved on that setup. Games, sustained motion,
other mice/displays and the Metal path still need separate real-host checks.

Native-resolution startup was also checked with three consecutive fresh Desktop
launches. Each detected the Portable Monitor at 1920×1080, sent
`requested mode=1920x1080x60`, received video and exited cleanly. Only the portable
monitor was exposed by the display probe during this run; the alternating
internal/external-display case still needs confirmation with both displays active.

## New feature pass — device checks still required

- Compare SDR, requested-HDR/SDR fallback, live host HDR toggles and mastering metadata on both presenters.
- Test 4:2:0 and opt-in 4:4:4 H.264/HEVC at 8/10 bits using automatic, hardware-only and software decoders; check readable text, colour and unsupported-profile errors.
- In desktop pointer mode, test letterbox bars, display scaling, capture release and switching back to a relative game.
- Test controller UI focus, scrolling through long libraries, launch/back/settings, and sheet navigation. During streaming, check background policy and merged player-one mode before and after unplugging.
- Verify hardware-reported contact down/up and cancellation; do not infer two-finger support from axis values. Verify each advertised haptic/LED/motion capability on a real device.
- Enable Discord presence, verify activity/cleanup, quit/reopen Discord and check reconnect. Confirm disabled presence opens no connection.
- Disable discovery while a host probe is pending, reopen the app, and confirm manual hosts still work. Reopen under each language and check layout/fallback text.
