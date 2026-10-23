# Audio audit — 23 October 2026

## Scope and evidence

Reviewed `AudioPlaybackEngine.swift`, `AudioOutputDevices.swift`, audio callback setup/teardown in `StreamSessionController.swift`, the ring-buffer regression tests, the vendored Opus/GameStream channel mapping, and `AVPacingClock.swift`. The initial audit snapshot below has now been followed by fixes to all six findings. The eight earlier behaviour fixes are recorded separately in `BEHAVIOR_AUDIT.md`.

Evidence includes source tracing, the local macOS SDK's channel-layout definitions, and an isolated simulation using the current `AudioRingBuffer` implementation. No speakers were driven, output devices switched, or live surround/latency measurements performed. The existing four ring-buffer tests pass as part of the 42-test suite; they do not cover device recovery or the larger callback reproduced below.

## Resolution

All six findings are fixed in the working tree:

- The 7.1 format uses CoreAudio's WAVE 7.1 layout, matching the common library's documented channel order without remapping decoded samples again.
- Focus policy survives engine replacement; mute is applied before every start/restart.
- Buffer thresholds scale with sample rate and the current render quantum. Large callbacks can prebuffer, and shrinking callbacks recover without retaining an oversized startup requirement.
- Start failures propagate to a shared recovery loop with capped backoff. Desired playback is tracked separately from the backend's actual running state.
- `AudioPlaybackControl` serializes device, graph and lifecycle operations. Generation checks reject old configuration/retry callbacks; stopping cancels pending recovery. CoreAudio device/default-output listeners cover route changes not reported by the engine.
- The unused `AVPacingClock` and decode-time timestamp calls are removed. No claim of hardware-clock A/V synchronization is made.

Validation: **49 tests pass**. New tests expand the actual CoreAudio 7.1 tag to verify speaker labels, simulate mute-before-start and engine replacement, inject failed route restarts, test pending retry cancellation/stale callbacks, force a device-operation/cleanup overlap, and exercise 128–8,192-frame render callbacks. Existing wrap, overflow and underrun tests still pass. Release packaging also passed executable, resource, license, plist and code-signature verification. Actual surround speaker routing, Bluetooth/HDMI hotplug and end-to-end latency still require hardware validation.

The findings, source references and measurements below describe the **pre-fix audit snapshot**.

## Findings

### 1. P2 — 7.1 side and rear channels have the wrong CoreAudio labels

Source: `Sources/MoonlightMac/Pipeline/Audio/AudioPlaybackEngine.swift:252–265`; `Sources/MoonlightCommonC/src/RtspConnection.c:786–799`.

The common library normalizes the normal-quality decoded channel order to `FL FR C LFE RL RR SL SR`. The engine selects `kAudioChannelLayoutTag_AudioUnit_7_1` and claims in its comment that this means rear channels before side channels. The installed SDK's `CoreAudioBaseTypes.h` defines that tag as `kAudioChannelLayoutTag_MPEG_7_1_C`, ordered `L R C LFE Ls Rs Rls Rrs`: side channels precede rear channels. Thus the normal-quality 7.1 path labels decoded rear samples as side speakers and vice versa. Stereo and the existing 5.1 tag do not have this particular mismatch.

Recommended fix: describe the actual output order with explicit channel descriptions or reorder the planes once to the chosen CoreAudio layout. Cover normal- and high-quality negotiated mappings with per-channel impulses, then validate on a real 7.1 device. Do not reapply the GFE-to-canonical remap already performed by the common library.

### 2. P2 — Background stream startup can ignore focus-loss muting

Source: `Sources/MoonlightMac/Core/State/StreamSessionController.swift:178–182`; `Sources/MoonlightMac/Pipeline/Audio/AudioPlaybackEngine.swift:207,345–346,372–385,481`.

The controller configures output/focus muting before Limelight initializes the audio engine. That configuration can correctly set `isMutedForFocus = true` while Moonlight is inactive. `setup()` immediately calls `cleanupInternal()`, which resets the flag to false. Starting the newly created engine uses that cleared flag, and setup does not resample the current application focus. If the app remains in the background, no later focus transition necessarily arrives to correct it. Audio can therefore play despite the mute-on-focus-loss preference until the next focus event.

Recommended fix: preserve the focus policy across engine replacement and derive/apply the actual current mute state before starting playback. Test a delayed/background connection and engine recreation while inactive, without requiring another Cmd+Tab.

### 3. P2 — Large audio callbacks can remain silent forever

Source: `Sources/MoonlightMac/Pipeline/Audio/AudioPlaybackEngine.swift:100–124`.

The writer never retains more than 3,840 frames; crossing that limit trims occupancy back to 1,440. The reader refuses to leave prebuffering until it has `max(callbackFrames + 480, 960)` frames. A 4,096-frame callback therefore requires 4,576 frames that the writer can never retain. It stays in prebuffering indefinitely even with a steady stream of valid packets. More generally, the thresholds are incompatible once the callback plus margin exceeds the retention ceiling.

Reproduction: copied the current ring-buffer class into an isolated Swift probe, wrote 4,000 successive 240-frame packets, and requested callbacks at the corresponding playback cadence:

| Callback size | Callbacks | Callbacks with audio |
| --- | ---: | ---: |
| 512 frames | 1,875 | 1,874 |
| 4,096 frames | 234 | **0** |

This is a deterministic buffer-policy failure, not a measurement of the user's current audio device. The probe is `/tmp/moonlight-audio-audit.swift` for this session.

Recommended fix: make prebuffer and overflow thresholds agree with the actual maximum render quantum and sample rate, or support partial callback filling without an unreachable startup requirement. Add tests for 128/512/1,024/2,048/4,096-frame callbacks, underrun recovery and variable packet duration.

### 4. P2 — A failed device restart can leave the engine permanently silent

Source: `Sources/MoonlightMac/Pipeline/Audio/AudioOutputDevices.swift:123–145`; `Sources/MoonlightMac/Pipeline/Audio/AudioPlaybackEngine.swift:485–505,525–535`.

Output selection stops a running engine, switches devices, then suppresses any restart error with `try?`. It can return true even when restart failed. The engine wrapper still records `isPlaying = true`. The configuration-change handler similarly logs a failed restart without correcting that flag. Subsequent decoded packets only attempt auto-start when `!isPlaying`, so they do not repair the stopped engine. This can produce lasting silence after a transient route/device failure.

Recommended fix: propagate restart success separately from device-selection success, reconcile desired playback with `engine.isRunning`, and retry recovery with backoff on a control queue. Test device removal, temporary restart failure and recovery without reconnecting the stream.

### 5. P2 — Route recovery can race stream teardown and restart an obsolete engine

Source: `Sources/MoonlightMac/Pipeline/Audio/AudioPlaybackEngine.swift:389–399,455–482,485–505`; `Sources/MoonlightMac/Pipeline/Audio/AudioOutputDevices.swift:123–138`.

`applyOutputDevice()` and the configuration-change handler capture an engine under the lock, then release it before stopping/restarting that engine. Meanwhile, Limelight's cleanup callback can acquire the lock, stop/detach/discard the same engine, and reset wrapper state. The first operation still owns its local engine reference and can restart it after cleanup. These operations have no session generation check or serial execution context, so the wrapper can lose track of the actual running engine during rapid disconnect/reconnect or an output change.

Recommended fix: serialize engine graph/routing/start/stop operations on one control queue, keep Opus decoding separate, and invalidate old recovery work when the session ends. Exercise output changes concurrently with disconnect/reconnect. A lock around only the initial reference lookup does not cover the lifetime of the operation.

### 6. P3 — The advertised A/V clock is unused and does not measure playback

Source: `Sources/MoonlightMac/Pipeline/Audio/AudioPlaybackEngine.swift:582`; `Sources/MoonlightMac/Pipeline/Video/AVPacingClock.swift:27–59`.

Every audio packet registers a host timestamp after decoding/queueing, including paths where PCM was discarded. This timestamp measures decode completion, not when CoreAudio plays the samples. No production caller invokes `shouldRenderFrame()` or `reset()`, so this clock does not currently synchronize audio and video at all. Its comments can mislead future latency work, and its per-packet locking does no useful work today.

Recommended fix: remove the unused clock path if independent low-latency presentation is intended. If explicit synchronization is required, design it around actual audio render timestamps, queued-frame/device latency and corresponding video timestamps. Do not wire the current decode-time estimate into video dropping as though it were an audio playback clock.

## Initial latency and optimization observations

- At 48 kHz with 512-frame callbacks, the ring initially waits for 992 frames, about **20.7 ms**, before playback can start. Device and mixer latency are additional. The current 3,840-frame overflow ceiling represents **80 ms** of retained PCM; trimming returns it to 30 ms. These are configured buffer amounts, not measured end-to-end latency.
- The real-time source callback takes an `NSLock` also held during planar writes. Writes deinterleave samples in loops, despite the comment suggesting they are only `memcpy`s. Treat contention under CPU load and surround audio as a profiling target; no measured bottleneck justifies a speculative lock-free rewrite yet.
- `AudioOutputDevices` does not observe CoreAudio device-list/default-device properties. Recovery currently depends on engine configuration notifications. Following a changed default or returning to a preferred device after fallback needs explicit hardware validation and may require property listeners.
- The existing mapping avoids a redundant GFE remap, decoding is decoupled from UDP reception, compressed-queue backpressure preserves decoder prediction state, and the ring has occupancy tracking, wrap handling and underrun fading. Retain those behaviours while correcting the issues above.

## Recommended next validation

The automated checks above cover policy and recovery. Next validate with wired output, Bluetooth, HDMI/DisplayPort audio and a real surround receiver. Record route, sample rate, callback size, underruns and queue depth before making numerical latency claims.
