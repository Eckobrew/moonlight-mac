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

## Features

- H.264 and HEVC decoding, with AV1 offered when VideoToolbox reports hardware support.
- Metal and native sample-buffer presentation, configurable V-Sync and frame pacing.
- Native-display and preset resolutions, configurable frame rates and bitrates,
  HDR options, and per-game overrides.
- Stereo, 5.1 and 7.1 audio options, output-device selection and background muting.
- Keyboard and relative mouse capture, sensitivity controls and game-controller input.
- Bonjour discovery, manual host entry, Wake-on-LAN and remote-address fallback.
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
git clone https://github.com/Eckobrew/moonlight-mac.git
cd moonlight-mac
./Scripts/package_app.sh release
```

The script creates **`Products/Moonlight.app`** and checks its executable, plist,
Metal resources, bundled licenses and signature. Drag the app into `/Applications`,
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

Pairing verifies the host's signature and PIN challenge, then confirms the
connection over HTTPS using that host's certificate. The certificate is saved
with the PC and checked on later authenticated requests.

**PCs paired with older builds need a one-time re-pair** because those builds did
not save host certificates. Saved PCs and per-game settings are retained. A
changed certificate is never accepted automatically. After intentionally
reinstalling or replacing a host, unpair it and pair again.

Remote connections require a working network route to the host, such as a VPN or
an appropriately configured host/network. Discovery does not configure remote
access automatically.

## Streaming shortcuts

Hold **Control + Option + Shift** (`⌃ ⌥ ⇧`) and press:

| Key | Action |
| --- | --- |
| `Q` | Disconnect |
| `Z` or `M` | Release or recapture the mouse |
| `X` | Toggle fullscreen/windowed mode |
| `S` | Toggle the performance HUD |
| `D` | Minimize the stream window |
| `V` | Paste text from the Mac clipboard to the PC |

`M` currently performs the same capture action as `Z`; it does not select a
separate absolute-mouse mode. Whether disconnecting also quits the host game
is controlled by the session settings; desktop-shortcut sessions quit it on exit.

## Settings

- **Resolution and frame rate:** choose the stream size and requested FPS. `Native`
  resolves the physical resolution of the Mac's current display at session start.
- **Bitrate:** set the target stream bitrate. Enabling a custom remote bitrate
  uses that value for connections classified as remote, including Tailscale; it
  does not measure bandwidth or automatically tune the value.
- **Renderer, V-Sync and frame pacing:** select the presentation path and whether
  to synchronize/pace frames against display refresh. The latency/smoothness
  tradeoff depends on the setup.
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

## Tests and validation

```sh
swift test --jobs 4
./Scripts/verify_app.sh Products/Moonlight.app
```

The regression suite covers audio buffering, frame-pacer lifecycle, codec masks,
TCP fallback, IPv6 URLs, keyboard mapping, certificate/signature checks, legacy
host migration, redirect rejection and relocated shader resources. Its local TLS
server checks correct, incorrect and missing certificate pins. Tests use
`/usr/bin/openssl` and Python 3 and require permission to open localhost sockets.

The [macOS CI workflow](.github/workflows/macos.yml) runs tests and release
packaging. The latest local validation passed **25 tests** and built and verified
an optimized, ad-hoc-signed app. CI has not yet been exercised on GitHub.

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
