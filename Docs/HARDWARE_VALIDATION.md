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
| Audio | Stereo/5.1/7.1 channel test; default/external/Bluetooth devices; route/focus changes | Correct channel order, no persistent underruns, recovery after route changes |
| Keyboard | UK/German/AZERTY, dead keys, AltGr, ISO/JIS keys, keypad Enter, Caps Lock, host paste | Physical position mapping is consistent; exact text paste works; no stuck modifiers |
| Mouse | High-polling mouse, fractional movement, focus loss, Spaces/fullscreen changes | Smooth relative input and reliable cursor release/recapture |
| Controllers | 1–4 controllers, a fifth attached, unplug/reorder/reconnect | No crash/stuck buttons; correct player slots |
| Controller extras | Xbox/PS rumble, DualSense touchpad/motion, host-requested sensor rates | Features actually work with the intended host/controller combination |
| Clipboard | Copy while sends/pulls are delayed; unsupported host clipboard endpoint | New local text is not overwritten; one failed direction does not disable the other |
| Release | Launch the packaged .app on another supported Mac | Native frameworks/resources load; signing/permissions work; no dependency on build paths |
| Public release | Developer ID sign, notarize, staple, assess on a separate Mac | Gatekeeper accepts the distributed app; corresponding source revision is available |

Measure input-to-photon and audio delay with a real setup before making numerical
latency or “lowest latency” claims. Unit tests and build success are not latency
benchmarks.
