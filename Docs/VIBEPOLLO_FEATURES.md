# Vibepollo client integration

Implemented on `codex/vibepollo-client-features`, 24 October 2026. This implements the selected features from [the research plan](VIBEPOLLO_COMPATIBILITY_PLAN.md); PyroWave, Remote Input, fractional FPS, waveform haptics and native host administration are outside this change.

## User controls

- Pairing offers ordinary host PIN entry or a host-generated four-digit OTP plus its passphrase. OTP authorization uses the host's exact uppercase SHA-256 wire format. All existing challenge/signature verification and pinned HTTPS confirmation remain mandatory. Codes/passphrases are not persisted or logged. Newly paired devices identify as “Moonlight Mac”.
- Host Details has Host default / Virtual / Physical display selection and driver readiness. Per-game settings can override the preference. The choice is sent on both launch and resume only to hosts advertising virtual-display support.
- Host Details offers Put PC to Sleep when the host advertises the separate device grant. Every attempt requires confirmation, fetches a fresh token and sends one empty POST. Busy hosts are refused. Lost acknowledgement is an unknown outcome; there is no automatic retry.
- Statistics remains a read-only overlay. Control + Option + Shift + S toggles it. Control + Option + Shift + C opens a separate Session controls sheet and releases local input capture while the sheet is open.
- Session controls exposes live bitrate when the runtime endpoint advertises support. It shows the actual applied host target and does not change saved preferences. Host automatic ABR is not assumed from runtime bitrate support.
- Optional host statistics appears in the overlay when enabled in Session controls and advertised by the host. CPU, GPU, encoder, temperature and VRAM are distinct from client/stream measurements. Missing values remain unavailable, not zero. Sampling is sequential, respects the host interval, stops on permission/session denial, backs off on temporary failure and ends with the stream.
- Server commands appear only when the host advertises names and grants permission. Each selection is confirmed and checked against fresh authenticated command metadata before being queued. The client sends the advertised index; it does not accept arbitrary shell text or claim execution completed.

## Identity and compatibility

Host capabilities and commands are read from pinned HTTPS responses. Legacy hosts with no permission field retain unknown permission state rather than being interpreted as having no permissions. Clipboard push/pull respects separately advertised grants.

Application parsing preserves UUID, host order and artwork revision. Launch and artwork requests include valid application UUIDs. Per-game overrides migrate lazily from the existing host/numeric-app key to the host/UUID key, after which numeric ID or name changes do not affect them. New shortcuts use the server ID and application UUID; existing title-based shortcuts remain accepted. Artwork caches use a hashed host/application/revision identity. Old saves missing the new optional fields remain readable.

## Remote Monitor lifecycle

Built-in monitor/control identities are recognized by UUID and documented numeric identities, including older cached IDs. Custom monitor profiles can be marked in per-game settings; an authenticated post-launch catalogue also identifies the client's owned monitor role. Names alone are never interpreted as actions.

A monitor uses the normal codec/video transport. It has a distinct lifecycle: closing it never applies “quit game on disconnect”, including shortcut shutdown. Explicit Release stops local transport and invokes only the host's monitor-disconnect action. Reconnect waits for the release to finish so it cannot release a newly created monitor. Host action tiles never start local RTSP/video/audio; their documented XML 410 completion is distinguished from a 410 requiring confirmation. Unknown responses are errors and are not retried automatically.

The vendored common-c library remains single-instance. This integration supports one Mac stream acting as a monitor alongside sessions on other devices; it does not add concurrent Mac stream windows. Remote Input tiles are explained as unsupported rather than routed into a video startup that would time out.

## Common-c changes

Added `LiSendHostCommand(uint8_t)` to both public header copies. It validates the input lifetime and encrypted Sunshine-compatible transport, then queues an internal marker through the existing input worker. The worker emits encrypted Apollo control packet `0x3000` with the one-byte index. The marker itself is never transmitted as input. This shares the input worker's shutdown ordering and the control stream's encryption/ENet locking. No wholesale upstream merge or callback-table ABI change was necessary for normal Remote Monitor video.

## Remote IP correction

An intermittent failed startup verification previously stayed cached for five minutes and left the Remote IP row at “Not reported”. New candidates are displayed independently of verified fallback routes. Failed attempts retry after 15 seconds; verified attempts retain the five-minute cache; Refresh forces a check. Unverified candidates are never used as connection fallbacks. Existing pinned-certificate and server-ID checks remain in place.

## Validation

Protocol tests cover OTP hashing/validation, sleep token encoding and exact request sequence, busy/lost-response behaviour, runtime bitrate acknowledgement, repeated command XML, permissions, virtual-display launch fields, stable catalogue identity/order, override migration, missing versus zero telemetry, host-action completion/confirmation, and short retry of failed remote verification. TLS fixtures exercise pin rejection, route/port fallback and extension requests over the winning route. The common-c command API is checked outside its input lifetime.

Read-only validation against NATHAN-PC confirmed the public endpoint's pinned certificate/server ID and matching HTTP ID. Wake-on-LAN and authenticated LAN/fallback app listing also succeeded. At inspection, the host advertised virtual-display and Remote Monitor support, HardwareMetricsVersion=0, no sleep grant and no configured server commands. Host settings/grants must be changed by the operator before those three live behaviours can be exercised; no sleep, command execution or re-pairing is performed automatically by the test suite.

Optional hardware tests are gated by environment variables. `MOONLIGHT_REMOTE_DIAGNOSTIC=Nathan-PC` wakes if needed and reads metadata only. `MOONLIGHT_LIVE_MONITOR=1 MOONLIGHT_LIVE_HOST=Nathan-PC` creates a temporary monitor, verifies decoded frames and live bitrate, and explicitly releases that monitor. It refuses to start if this paired client already owns a Remote Monitor/Input role, and never calls the normal game cancel endpoint.

Live Remote Monitor validation succeeded on NATHAN-PC: 67 decoded frames, an acknowledged runtime bitrate change to 15,000 Kbps, and explicit release of the temporary monitor. The post-release catalogue had no owned monitor-disconnect action. No game cancellation, server command, sleep transition or pairing change was performed.

Final default regression suite: **94 tests passed**, with hardware tests opt-in. Release packaging verifies the executable, resource bundle, Metal source/library, translations, licenses, plist and code signature. The updated app is packaged in `Products/Moonlight.app`; the installed `/Applications/Moonlight.app` is not replaced by this feature task.

A second live run verified the final statistics behaviour: 61 decoded monitor frames, host-applied 15,000 Kbps, and a read-only statistics target of 15.0 Mbps after the change. Monitor release again completed and the default 94-test regression suite passed afterward.
