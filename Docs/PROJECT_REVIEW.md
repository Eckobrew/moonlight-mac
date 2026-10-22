# Project review — 22 October 2026

The application already uses native macOS APIs: SwiftUI/AppKit for UI and input,
VideoToolbox for decoding, Metal or AVSampleBufferDisplayLayer for presentation,
and AVAudioEngine/CoreAudio for sound. Reusing moonlight-common-c for GameStream
is compatible with that architecture. Replacing its transport layer would be a
large undertaking without an evident user benefit.

This was a source review and local build/test pass, not a full comparison with
every moonlight-qt feature or an end-to-end test against a streaming host. The
eight files that were already modified when the review began were preserved;
changes described below were made on top of that working tree.

## Changes made

- Frame pacing: stop CVDisplayLink outside the callback's lock to avoid deadlock;
  serialize lifecycle changes on the main actor; avoid restarting for the same
  display; fall back to immediate presentation if display-link setup fails.
- Session lifecycle: reject stale startup completions after a disconnect; check
  cancellation after network waits; interrupt startup and wait for it before
  stopping the C connection; finish previous connection cleanup and any requested
  host-app quit before reconnecting. Invalidate reconnect requests canceled while
  waiting for cleanup and reject queued C callbacks from earlier sessions. Keep
  deferred input cleanup from stopping a newer session. Move RTSP probes off the main actor and validate the RTSP port
  before converting it to UInt16.
- App state: deliver session-stop updates synchronously on the main actor; ignore
  game-list results belonging to a previously selected host; keep an old host's
  authorization failure from clearing another host's selection; reject duplicate
  stream launch requests.
- Controllers: avoid a reversed-range crash with more than four controllers;
  protect polling state from concurrent disconnect/reset/motion changes; clear
  old host slots on disconnect and resend states after topology changes.
- Keyboard: use the same event encoding for presses and releases in host-layout
  mode, release held keys when the monitor stops, and snapshot the layout before
  dispatching input to its queue.
- Audio ring: track occupancy explicitly so a full-capacity write cannot look
  empty; preserve the newest samples on overflow and unread samples across wrap;
  keep the existing prebuffer and underrun-fade behavior.
- Clipboard: disable only the failing direction; acknowledge local text after a
  successful push so failed pushes can retry; retain changes made during a push;
  prevent a delayed pull from overwriting text copied locally during the request.
- Networking: bracket IPv6 literals in HTTP URLs, including pairing and artwork;
  try every resolved TCP address with a shared connection timeout; validate
  socket setup and SO_ERROR results.
- Logging: remove pairing PIN/AES key output, launch/resume query strings carrying
  `rikey`, and raw pairing request/response contents from logs.
- Tests: make the Swift app importable by the test target and add actual streaming
  regression coverage alongside the existing C-library smoke tests.

## Follow-up fixes — 22 October 2026

The subsequent implementation addressed the remaining source-level issues:

- Pairing now verifies the RSA-SHA256 signature on the server secret, validates
  the PIN challenge, and confirms the pair over HTTPS pinned to that certificate.
  Only then is the certificate saved with the host. Certificate signatures are
  parsed from ASN.1 instead of assuming an RSA-2048 signature at the end of DER.
- Every authenticated HTTP operation uses a session bound to the saved leaf
  certificate. Missing, changed or invalid pins fail closed. Redirects are refused
  so launch keys and clipboard content cannot be forwarded elsewhere. Hosts with
  a saved pin never fall back to unauthenticated HTTP metadata, and discovery
  cannot replace a pinned host's saved identity. Server IDs are checked on refresh.
- Legacy saved hosts stay in the list and need one explicit re-pair to establish
  their missing certificate pin. The UI and README explain this migration. Pairing
  no longer regenerates the global client ID and breaks other paired PCs. Cancel
  stops the pairing attempt; cleanup is awaited before permitting another attempt.
- VideoToolbox now owns a per-frame output handler capturing immutable metadata.
  The rotating 64-slot raw-pointer pool and unretained decoder refcon are gone.
  This avoids reuse while callbacks are pending and makes error/teardown ownership
  follow the framework's handler lifetime. Explicit frame drops are counted as
  drops rather than decoder failures. No allocation/latency speedup is claimed.
- Keyboard events use normalized position-based Windows VK codes, with protocol
  tagging in both legacy settings modes. NON_NORMALIZED is limited to the JIS
  special cases used upstream. Extended flags distinguish main/keypad Enter and
  right modifiers; tracked keys retain their complete encoding for releases.
  Missing keypad, navigation and ISO/JIS mappings were added, and Caps Lock sends
  complete presses. The misleading layout selector was removed while retaining
  compatibility with its saved values.
- CI runs Swift tests and release packaging on macOS. Packaging stages the app
  before replacing the previous bundle, requires resources, checks its executable,
  plist, shader resource, licenses and signature, and supports optional Developer
  ID signing/notarization via locally configured credentials. The renderer looks
  for packaged shader source in Contents/Resources instead of depending on
  SwiftPM's absolute build-directory fallback; embedded shaders remain available.
  A relocation test covers both present and missing packaged shader resources.
  Unneeded JIT and library-validation exceptions were removed.
- Root GPLv3 and bundled dependency licenses/notices were restored and are copied
  into packaged apps. Exact historical dependency revisions were not present in
  the checkout, so none are invented; future updates should record commit IDs.

Protocol references: [Moonlight Qt pairing](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/backend/nvpairingmanager.cpp),
[Moonlight Qt keyboard](https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/input/keyboard.cpp).
VideoToolbox's installed SDK documents that its output handler is owned per decode
and that a synchronous submission error does not invoke the handler.

## Checks requiring hardware or credentials

See [HARDWARE_VALIDATION.md](HARDWARE_VALIDATION.md) for the remaining real-host
checks. Automated local tests cannot establish visual HDR correctness, surround
speaker order, controller hardware behavior or end-to-end streaming latency.
Developer ID signing/notarization requires the owner's Apple signing identity and
notary profile; the script supports them but does not create or obtain credentials.

## Validation

Regression tests cover full audio buffers, planar channels, wraparound, overflow,
underrun recovery/reset, stopped/restarted frame presentation, SDR/HDR codec masks,
IPv6 URL authorities, and TCP address fallback against a local IPv4 listener.

The first pass passed 15 tests. The follow-up adds signature tampering, exact
certificate pinning, malformed DER, legacy-host migration, extended keyboard
mapping, redirect rejection and an actual local TLS handshake. The TLS server
uses a temporary certificate/key and never loads the user's client identity or
contacts a streaming host.

Final regression result: **25 tests passed**, including the real localhost TLS
handshake against correct, different valid, invalid and missing pins; redirect
rejection; signature tampering; malformed certificates; legacy saved hosts; key
mapping; relocated app resources; and the initial streaming regressions.

Commands used:

```sh
swift test --disable-sandbox --scratch-path /tmp/moonlight-review-build --jobs 4
MOONLIGHT_BUILD_PATH=/tmp/moonlight-review-build ./Scripts/package_app.sh release
```

The full application compiled in debug and optimized release configurations.
The final optimized release build and ad-hoc-signed package passed executable,
plist, shader resource, bundled license and strict code-signature verification.
The resulting app is `Products/Moonlight.app`. Shell syntax checks, workflow YAML
parsing and `git diff --check` also passed. CI itself has not run on GitHub, and
Developer ID notarization has not been exercised without the owner's credentials.

No actual game stream, hardware latency benchmark, surround/HDR listening/viewing
check, or packaged app launch was performed as part of this review.
