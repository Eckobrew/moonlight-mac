# Moonlight for macOS

A native macOS game-streaming client for PCs running
[Sunshine](https://github.com/LizardByte/Sunshine) or
[Apollo](https://github.com/ClassicOldSong/Apollo).

The app uses SwiftUI and AppKit for its interface and input, VideoToolbox for
video decoding, Metal or AVSampleBufferDisplayLayer for presentation, and
AVAudioEngine/CoreAudio for audio. The GameStream protocol is provided by
[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c).
It does not use Qt for its interface.

> [!NOTE]
> This project is under active development. Automated tests and release-package
> checks pass locally, but full Moonlight Qt feature parity and end-to-end latency
> have not been established. HDR, surround audio and controller extras still need
> validation across real hardware. See the [validation checklist](Docs/HARDWARE_VALIDATION.md).

## v0.2

This release improves stream startup/focus recovery, fullscreen transitions and
native mouse behaviour. It also fixes audio route recovery, common-c connection
lifetimes, HDR state/metadata and controller capability reporting.

Settings now use one resolution/FPS dropdown each. Choose **Custom…** to enter a
custom value; otherwise there is no second numeric field. Controller options have
their own section, advanced options stay out of the way, and controls that do not
apply to the chosen renderer or mouse mode are hidden or disabled.

The release also adds desktop pointer mode, native controller extras and UI
navigation, optional 4:4:4/decoder preferences, language selection and opt-in
Discord presence. Idle controller polling, repeated profile lookups and sleeping
render retries were removed or reduced. See the [feature report](Docs/FEATURE_GAPS.md)
for implementation details and hardware limits.

## Features

- H.264 and HEVC decoding, with AV1 offered when VideoToolbox reports hardware support.
- Metal and native sample-buffer presentation, configurable V-Sync and frame pacing.
- Native-display, preset and custom resolutions, custom frame rates and bitrates,
  HDR options, and per-game overrides.
- Stereo, 5.1 and 7.1 audio options, output-device selection and background muting.
- Keyboard, relative and desktop mouse modes, sensitivity/button controls and native game-controller input.
- Optional Bonjour discovery, manual host entry, Wake-on-LAN and remote-address fallback.
- Controller UI navigation, mouse emulation, background-input policy and persistent player-one mode.
- Decoder selection, opt-in H.264/HEVC 4:4:4, language selection and optional Discord Rich Presence.
- PIN pairing with server-signature verification and certificate pinning.
- Host/game shortcuts, optional clipboard synchronization and a performance HUD.

Codec, resolution, frame-rate and HDR availability depend on the Mac, host and
display. Controller rumble, touchpad and motion support depend on the controller
and host. Automatic clipboard synchronization requires a compatible host endpoint;
the paste shortcut sends text through the streaming protocol.

## Requirements

- An Apple Silicon or Intel Mac running **macOS 14 Sonoma or newer**.
- A PC running Sunshine or Apollo, reachable from the Mac.
- **Swift 6 or newer** to build from source, supplied by a compatible Xcode or
  Xcode Command Line Tools installation.

## Build and install

```sh
git clone --branch v0.2 https://github.com/Eckobrew/moonlight-mac.git
cd moonlight-mac
./Scripts/package_app.sh release
```

The script creates **`Products/Moonlight.app`** and checks its executable, plist,
Metal/language resources, bundled licenses and signature. Drag the app into `/Applications`,
or install it from the terminal:

```sh
cp -R Products/Moonlight.app /Applications/
```

Local builds use ad-hoc signing. This does not provide Developer ID notarization.
For development, use `swift build` or `./Scripts/package_app.sh debug`.

## Pair and connect

1. Start Sunshine or Apollo on the PC, then open Moonlight on the Mac.
2. Select the discovered PC, or add its IP address/hostname manually.
3. Enter Moonlight's four-digit PIN in the host's web interface.
4. After pairing succeeds, select a game or desktop session.

Clicking an unreachable PC sends Wake-on-LAN using its saved MAC address and
shows **Waking…** until serverinfo responds. The apps screen opens after fetching
a fresh app list. You can cancel the wait; a PC that does not respond within
about a minute shows an error. Wake-on-LAN must be enabled on the PC and supported
by the network. App lists are not stored on disk; cover artwork remains cached.

Pairing verifies the host's signature and PIN challenge, then confirms the
connection over HTTPS using that host's certificate. The certificate is saved
with the PC and checked on later authenticated requests.

**PCs paired with older builds need a one-time re-pair** because those builds did
not save host certificates. Saved PCs and per-game settings are retained. A
changed certificate is never accepted automatically. After intentionally
reinstalling or replacing a host, unpair it and pair again.

Remote connections require a working network route to the host, such as a VPN or
an appropriately configured host/network. Discovery does not configure remote
access automatically. For paired PCs on a directly connected local IPv4 subnet, the
client uses STUN when the host does not report an external address. A remote candidate
is saved only after an HTTPS serverinfo check matches both the paired certificate and
server ID, and the reported HTTP port returns the same server ID. Host Details shows the **Remote IP**, verified HTTPS port and check result.
Verified checks are cached for five minutes; failures retry after 15 seconds.
Discovered addresses remain visible with an unverified status until the checks pass.
**Refresh** in Host Details runs a fresh check. Routers without NAT loopback may prevent verification
from home even when remote access would work from outside. Discovery does not open ports.
Remote port mappings are stored separately from LAN listener ports. The client checks
the primary address first and falls back to the saved remote IP, with the same
certificate and host-identity checks. Unverified candidates cannot provide a fallback.

## Vibepollo host features

The client supports OTP pairing, stable application UUIDs, virtual-display launch
preferences, host-configured server commands, permission-gated sleep, optional host
hardware statistics, live bitrate changes and Remote Monitor sessions. Features
appear according to the paired host's capabilities and permissions. PyroWave is
not included.

Statistics are read-only. Open **Session controls** with **Control + Option + Shift + C**
to change bitrate, choose server commands or enable host statistics. Display
preferences and **Put PC to Sleep** are in **Host Details**; display preferences can
also be overridden per game. Sleep requires a separate host-side device grant and
an explicit confirmation each time. Hardware metrics must be enabled on the host.

Select **Remote Monitor** in the application list to use this Mac as an additional
PC display. A normal disconnect follows the host's retention settings; **Release
remote monitor** explicitly removes it without terminating the host's game. The
client supports one active stream per process. See
[feature details and validation](Docs/VIBEPOLLO_FEATURES.md).

## Streaming shortcuts

Hold **Control + Option + Shift** (`⌃ ⌥ ⇧`) and press:

| Key | Action |
| --- | --- |
| `Q` | Disconnect |
| `Z` | Release or recapture the mouse |
| `M` | Switch relative/desktop mouse mode |
| `X` | Toggle fullscreen/windowed mode |
| `S` | Toggle the performance HUD |
| `C` | Open session controls (bitrate, host commands, monitor release) |
| `D` | Minimize the stream window |
| `V` | Paste text from the Mac clipboard to the PC |

Desktop mode uses the native visible pointer and absolute host coordinates inside
the video area. Hold Start on a controller for ¾ second to toggle controller mouse
control. Whether disconnecting also quits the host game is controlled by session
settings; desktop-shortcut sessions quit the game they launched on exit.

## Settings

- **Resolution and frame rate:** choose the stream size and requested FPS. `Native`
  resolves the physical resolution of the Mac's current display at session start.
  Select **Custom…** in either dropdown to reveal its labelled editor.
- **Bitrate:** set the target stream bitrate. Enabling a custom remote bitrate
  uses that value for connections classified as remote, including Tailscale.
  The default remote value, **0 (Auto)**, uses one quarter of the normal bitrate
  (for example, 25 Mbps becomes 6.25 Mbps). With the remote override disabled,
  both local and remote sessions use the normal bitrate. Changes take effect on
  the next connection; this does not measure bandwidth or tune it during a stream.
  NAT hairpin connections through the same public gateway count as local and keep
  the normal bitrate.
- **Renderer, V-Sync and frame pacing:** select the presentation path and whether
  to pace frames against display refresh. Manual V-Sync control applies to Metal;
  the native renderer manages synchronization automatically.
- **Audio:** select stereo/surround and a Mac output device. Host-speaker muting
  and muting the Mac stream when another app is focused are separate options.
- **Mouse capture:** locks the cursor for continuous relative input. Use the
  release shortcut to return to normal Mac interaction.
- **System keyboard shortcuts:** choose Off, In fullscreen or Always. Capture also
  depends on the app being focused and the mouse being captured.
- **Physical Windows keyboard layout:** when enabled, maps Control → Ctrl,
  Option → Windows and Command → Alt. Disable it to keep Option → Alt and
  Command → Windows.

Keys follow physical positions using GameStream's normalized Windows virtual-key
mapping; the PC applies its active keyboard layout. Keypad Enter and right-side
modifiers carry their extended-key flags. Use clipboard paste when exact text
characters matter. The previous host-layout selector was removed; its saved
values remain readable.

The **Controllers** section contains face-button layout, mouse emulation,
background input and persistent player-one preferences. **Display & Video** has
advanced decoder/chroma options; **Keyboard & Mouse** contains desktop mode and
advanced sensitivity scaling.

**Application** contains discovery, language and Discord settings. Presence is
off by default; enabling it shares the streamed game and host name with the local
Discord desktop app. A default application ID is included; changing it is an
advanced option. English, German, French and Spanish resources are bundled;
untranslated technical messages fall back to English. Restart after changing
language.

Host Details includes a client connectivity test against Moonlight’s public test server.
It tests this network’s outbound ports, rather than the streaming host’s firewall.

## Tests and validation

```sh
swift test --jobs 4
./Scripts/verify_app.sh Products/Moonlight.app
```

The current code passes **73 regression tests** locally, plus optimized app packaging
and verification of the executable, shader/language resources, licenses, plist and
ad-hoc signature. GitHub's [macOS validation run](https://github.com/Eckobrew/moonlight-mac/actions/runs/40039701717)
also passed tests and release packaging for the v0.2 code cleanup.

Coverage includes audio buffering/recovery, input and window state, malformed
video recovery, HDR metadata, RTT lifetime, controller requests, custom settings,
Discord frame parsing, localized/relocated resources, TLS pins and pairing.
Local TLS tests use `/usr/bin/openssl` and Python 3 and need localhost sockets.

Two live tests are opt-in and use an already paired, saved PC. The first may wake
the PC and verifies authenticated app listing and fallback from a deliberately
unreachable primary address. The second opens Desktop, checks decoded frames at
40 and 20 Mbps, then disconnects and closes Desktop if the test launched it:

```sh
MOONLIGHT_LIVE_HOST=Nathan-PC MOONLIGHT_LIVE_STREAM=1 swift test --jobs 4
```

Use your saved PC's name for `MOONLIGHT_LIVE_HOST`. Add `MOONLIGHT_LIVE_WAN=1`
to the command to discover this gateway's public IP through STUN, force fallback
through that address, and assert that a hairpin stream retains the normal bitrate.
This requires working host port forwarding and NAT loopback on the same gateway.
`MOONLIGHT_LIVE_WAN_ADDRESS` optionally specifies the public address explicitly.
These tests do not verify off-site routing or subjective mouse, audio or window
behaviour.


The [macOS CI workflow](.github/workflows/macos.yml) runs tests and release
packaging. See [GitHub Actions](https://github.com/Eckobrew/moonlight-mac/actions/workflows/macos.yml)
for current branch/tag results.

See the [project review](Docs/PROJECT_REVIEW.md) for implementation details and the
[hardware checklist](Docs/HARDWARE_VALIDATION.md) for outstanding live-host checks.
Build success is not a streaming-latency benchmark.

## Developer ID releases

Set `MOONLIGHT_SIGNING_IDENTITY` to an installed Developer ID Application identity.
To notarize and staple during packaging, also set `MOONLIGHT_NOTARY_PROFILE` to a
profile previously stored using `xcrun notarytool store-credentials`.

```sh
MOONLIGHT_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MOONLIGHT_NOTARY_PROFILE="your-notary-profile" \
./Scripts/package_app.sh release
```

Signing/notarization requires the owner's Apple credentials and has not been
validated here. Credentials are not stored in the repository.
`MOONLIGHT_BUILD_PATH` optionally selects the SwiftPM build directory, and
`MOONLIGHT_BUILD_JOBS` controls build parallelism.

Distribute binaries with their matching source revision and build instructions.
Exact historical imported revisions of some vendored libraries were not recorded;
future dependency updates should record immutable upstream commits.

## Credits and license

This project uses [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c),
[ENet](https://github.com/cgutman/enet), [nanors](https://github.com/sleepybishop/nanors)
and [Opus](https://opus-codec.org/).
[Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt) and
[moonlight-macos-enhanced](https://github.com/Mariotaku/moonlight-macos-enhanced)
provided architecture and native-integration references. Sunshine and Apollo
provide the host software.

MoonlightMac is licensed under [GPLv3](LICENSE). Bundled dependencies retain their
own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). Packaging includes
the license texts in `Contents/Resources/Licenses`.
