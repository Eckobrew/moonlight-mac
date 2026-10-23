# Behaviour audit — 23 October 2026

## Scope and validation

Reviewed the native app for conflicting lifecycle state, forced system changes, blocking work, input forwarding, and timer-based workarounds. The pass covered application/window/session lifecycle, mouse and keyboard capture, controller input, clipboard/power management, discovery/HTTP/pairing, settings persistence, video/audio presentation, artwork/shortcuts, and packaging/CI. This is a source audit with regression/build validation, not a claim of exhaustive hardware testing or a new security audit of the vendored C libraries.

The mouse and window work is in two local commits. It uses AppKit/CoreGraphics; no SDL dependency was added. Mouse capture distinguishes requested capture from an actual relative lock, recovers only on the active stream window/Space, preserves native event coalescing, and avoids repeated cursor warps. Window mode requests are serialized around AppKit completion callbacks, preserve the starting window state, keep borderless streams at normal window level, and remove repeated activation/hide-all-window workarounds. Fullscreen failures use AppKit delegate callbacks while forwarding the existing SwiftUI delegate.

Validation: 35 regression tests passed, including new mouse-policy/delta and window-transition tests. Release packaging verifies the executable, resources, licenses, plist and code signature. Physical mouse feel, real notification banners, failed fullscreen animations, mixed-refresh displays and controller hardware still need interactive validation.

## Resolution of the eight findings

All eight findings below have now been addressed in the working tree:

| Finding | Implemented change |
| --- | --- |
| 1. Shortcut replacement | Stable host/app identity, collision checks, validated staging, atomic replacement of owned bundles; unrelated apps and symlinks are preserved. |
| 2. Shortcut cancellation | Owned cancellable launch tasks; negotiation cancellation never quits a host app. Shortcut shutdown only targets an acknowledged launch and checks the current app ID before requesting quit. |
| 3. Dock/cache side effects | Removed cache deletion, Dock restart and all shortcut subprocess waits. PNG-backed ICNS generation and native LaunchServices registration replace the subprocesses. |
| 4. Sustained rumble | A looping advanced haptic player runs until a changed/zero request; engine reset invalidates and reapplies cached state. |
| 5. Motion requests | Request state, rate and sample history are independent per controller and sensor; disabled sensors are not sent. |
| 6. Bounded quit | A shared deadline helper cancels the losing task; application quit completes through AppKit's termination reply. |
| 7. Display pacing | Stream-window screen changes and display reconfiguration retarget/restart the pacing display link; observers are removed on stop. |
| 8. Clipboard recovery | Transient failures retry with capped backoff; only explicit unsupported endpoint responses disable a direction. The stream displays interruption/recovery status. |

Validation: **42 tests pass**, including replacement/collision/symlink safety, per-controller sensor rates and disable, retry recovery, and deadline cancellation. Controller rumble hardware and mixed-refresh display moves still need interactive validation. Release packaging passed executable, resource, license, plist and code-signature verification.

The descriptions and line references below are the original audit snapshot, retained to explain each fix.

## Findings

### 1. P1 — Creating a shortcut can delete an unrelated Desktop app

Source: `Sources/MoonlightMac/Core/Utils/GameShortcutManager.swift:129–138`.

The destination is derived only from the game title. If `Desktop/<title>.app` already exists, the implementation recursively removes it without checking its bundle identifier or ownership. Creating the same game shortcut for another host also overwrites the first host's shortcut. A later icon/write failure leaves the old app deleted because replacement is performed in place.

Trigger: an existing Desktop app or shortcut has the same sanitized name as the selected game. No destructive reproduction was performed.

Recommended fix: distinguish shortcuts by stable host/app identity, preserve unrelated destinations, and assemble replacements in a temporary sibling before replacing an owned shortcut.

### 2. P1 — Cancelling a shortcut launch can terminate a game it never launched

Source: `Sources/MoonlightMac/Core/State/AppState.swift:391–404`.

The negotiation screen's Cancel action looks up the saved host and sends `/cancel` through `quitApp`, even before a session has started. That endpoint quits the current host app, regardless of which title the shortcut requested. Cancelling while locating a host or loading the app list can therefore close an already-running game, including one being used by another client. The negotiation task is not explicitly cancelled before the quit request either.

Trigger: a host already runs game A, a shortcut for game B is opened, and Cancel is pressed before B is launched. No host game was terminated to test this.

Recommended fix: cancel and invalidate the pending launch task first. Only request host termination when this invocation actually launched an identified app and its stop policy calls for termination.

### 3. P2 — Shortcut icon refresh mutates system caches and restarts the Dock

Source: `Sources/MoonlightMac/Core/Utils/GameShortcutManager.swift:267–305`.

Every shortcut creation attempts to delete the user's Dock and IconServices caches. If any Moonlight shortcut is pinned, it launches `killall Dock`, even if the changed shortcut is not the pinned item. This affects unrelated applications and desktop/Spaces behaviour just to refresh an icon. The helper also performs subprocess waits on the main actor. It waits for `defaults` to exit before draining its output pipe; sufficiently large Dock output can block both the child and the app.

Recommended fix: remove global cache deletion and Dock restart. Use normal bundle registration/Finder icon updates and let the Dock refresh naturally. Move necessary subprocess work off the main actor and drain pipes while the child runs. No cache deletion or Dock restart was executed during this audit.

### 4. P2 — Sustained controller rumble ends after 250 ms

Source: `Sources/MoonlightMac/Input/GameControllerManager.swift:45,70–108`.

Each haptic pattern lasts 0.25 seconds, but identical motor values are suppressed indefinitely by `packed != lastApplied`. There is no timer renewing the pattern. A constant nonzero motor request therefore produces one short pulse, then silence until the requested value changes, despite the comment promising refreshes.

Recommended fix: keep a continuous player active until a zero request, or renew finite patterns on a controlled timer. Reset cached state after engine resets and playback failures. Validate a steady multi-second rumble and explicit stop on controller hardware.

### 5. P2 — Controller motion requests lose sensor and controller identity

Source: `Sources/MoonlightMac/Core/State/StreamSessionController.swift:653–655`; `Sources/MoonlightMac/Input/GameControllerManager.swift:149–187,411–439`.

The callback drops `controllerNumber`. The manager merges accelerometer and gyro requests into one global maximum rate, then sends both categories for every eligible controller. Requesting only gyro still transmits accelerometer data; disabling motion for one controller can change reporting for all controllers. Different requested sensor rates are also lost.

Recommended fix: store enabled state, interval and sample history per controller slot and sensor category. Send each category only when that specific request is enabled and due. Clear all request state on session stop.

### 6. P2 — Application quit does not enforce its advertised two-second bound

Source: `Sources/MoonlightMac/MoonlightMacApp.swift:36–49`.

The termination task races host quit against a two-second sleep, but after `group.next()` it leaves a structured task group without cancelling the other child. Leaving the group waits for both children. The windows are hidden during this wait, so a failed network request can leave an invisible process running until its longer HTTP timeout. A successful fast request also waits for the timer unnecessarily. The session controller's separate stop path already calls `group.cancelAll()`, demonstrating the inconsistent implementations.

Recommended fix: share one bounded shutdown helper, cancel the losing request/timer, and complete termination using the AppKit termination contract. Test successful, failed and hanging host requests.

### 7. P2 — Frame pacing remains bound to the previous display after a window move

Source: `Sources/MoonlightMac/Pipeline/Video/FramePacer.swift:49–67`; `Sources/MoonlightMac/Pipeline/Metal/MTKViewRepresentable.swift:67–85`; `Sources/MoonlightMac/UI/Stream/StreamingSessionView.swift:18–35`.

The pacer can update its display, but its callers only do so when the stream view attaches or a window mode is applied. There is no screen-change observer. The Metal view updates drawable sizing when its backing properties change without updating the pacer. Moving a windowed stream between monitors can leave its CVDisplayLink ticking at the old display's refresh rate, which can cause judder or cap visible presentation on mixed-refresh setups when pacing is enabled.

Recommended fix: observe screen/display configuration changes for the stream window and retarget the pacer on the main actor. Validate moves between displays with different refresh rates and display disconnects.

### 8. P2 — Brief network failures permanently disable clipboard sync for the session

Source: `Sources/MoonlightMac/Core/Utils/ClipboardSyncManager.swift:114–159,165–198`.

After three errors in a direction, every later attempt returns immediately. Error handling does not distinguish an unsupported clipboard endpoint from temporary Wi-Fi/network failure, and only a new stream resets the counters. Clipboard sync silently stays broken after connectivity recovers.

Recommended fix: disable permanently only for a confirmed unsupported endpoint. Use bounded backoff and recovery probes for transient failures, and expose persistent failure state to the user. Test recovery without restarting the stream.

## Suggested follow-up order

1. Shortcut destination safety and cancellation ownership.
2. Remove Dock/cache side effects and blocking shortcut subprocesses.
3. Controller rumble and per-controller/per-sensor motion state.
4. Shared bounded shutdown, display pacing updates, and clipboard recovery.

No new optimizations are justified solely by this audit. The findings concern correctness and observable behaviour; performance claims should be checked with live streaming diagnostics and hardware measurements.
