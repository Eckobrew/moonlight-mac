# Moonlight Mac

[Moonlight Mac](https://moonlight-stream.org) is an open source, fully native macOS client for [Sunshine](https://github.com/LizardByte/Sunshine), [Apollo](https://github.com/ClassicOldSong/Apollo), and NVIDIA GameStream.

Built from the ground up in Swift with SwiftUI, Metal, VideoToolbox, and AVFoundation, powered by `moonlight-common-c`.

> [!NOTE]
> The whole thing is vibe coded by a monkey who has no idea what he's doing.

---

## What's New

- **Low-Latency Native Audio Pipeline**: Powered by `AVAudioEngine`, `AVAudioSourceNode`, and lock-free `AudioRingBuffer` with automatic 50ms backlog clamping.
- **Fixed AES-CBC PKCS#7 Audio Decryption**: Solved the high-frequency distortion and packet corruption bug in CommonCrypto by properly stripping trailing PKCS#7 padding on incoming audio packets.
- **Host Speaker Mute Option**: Added toggle under Audio Settings to mute host PC speakers while streaming via `localAudioPlayMode`.
- **Retina High-DPI & Display Safe Area Detection**: Native resolution matching with automatic MacBook camera notch avoidance and aspect-ratio letterboxing.
- **Sub-Pixel Hardware Mouse Capture**: Low-latency raw mouse capture via `GCMouse` (1000Hz+ polling), sub-pixel fractional delta accumulation, and uncoalesced cursor event processing.
- **Strictly Hide Unpaired PCs**: Keep the host list clean by hiding unpaired PCs while preserving pairing status and Wake-on-LAN for sleeping hosts.
- **Bidirectional Clipboard Sync**: Seamlessly sync clipboard text with Sunshine, Apollo, and Vibepollo.

---

## Features

- **Hardware Video Acceleration**: Zero-copy VideoToolbox hardware decoding for H.264, HEVC, and AV1 across Apple Silicon and Intel Macs.
- **Metal Presentation Engine**: Low-latency double-buffered presentation using `CAMetalLayer` with custom BT.709 and BT.2020 (HDR) Metal shaders.
- **High Frame Rates**: Up to 240 FPS streaming with Apple ProMotion (120Hz) display pacing via `CVDisplayLink`.
- **Multi-Channel Surround Sound**: Stereo, 5.1, and 7.1 surround sound audio playback.
- **Raw Hardware Mouse Input**: Native `GCMouse` hardware cursor capture without acceleration or event batching delays.
- **Gamepad & Controller Support**: Native MFi, Xbox, and PlayStation controller support with rumble force feedback.
- **Keyboard Shortcuts**: System shortcut passing with optional Command/Control key swapping.
- **Standalone Game Shortcuts**: Create standalone desktop `.app` shortcuts for games with custom icons and automatic Wake-on-LAN.
- **Smart Remote Bitrate**: Automatic NAT hairpinning detection and configurable separate bitrates for remote vs. local network streaming.
- **Keychain-Free Security**: In-memory TLS client certificate import (`kSecImportToMemoryOnly`), completely eliminating macOS keychain password prompts.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌃ ⌥ ⇧ Q` or `⌘ ⌃ Q` | Terminate stream session |
| `⌃ ⌥ ⇧ Z` | Release / recapture mouse cursor |
| `⌃ ⌥ ⇧ X` | Toggle between Fullscreen and Windowed mode |
| `⌃ ⌥ ⇧ S` or `⌘ ⇧ H` | Toggle real-time performance overlay HUD |

---

## External Projects & Dependencies

Moonlight Mac incorporates and builds upon several open source projects:

- **[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)** (GPLv3): Core protocol implementation handling RTSP handshakes, SDP negotiation, UDP streaming queues, and input event serialization.
  - **[enet](http://enet.bespin.org/)**: Reliable UDP networking engine.
  - **[nanors](https://github.com/Sleepy-Tee/nanors)**: Reed-Solomon forward error correction (FEC) for video packet recovery.
- **[libopus / Copus](https://opus-codec.org/)** (BSD-3-Clause): High-efficiency IETF Opus audio codec, bundled directly for multi-stream surround and stereo decoding.
- **[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)** (GPLv3): Architecture reference for sub-pixel cursor delta accumulation, screen mode queries, aspect ratio preservation, and keyboard event routing.
- **[moonlight-macos-enhanced](https://github.com/Mariotaku/moonlight-macos-enhanced)** (GPLv3): Reference patterns for in-memory macOS certificate imports and multi-channel CoreAudio layout mappings.
- **[Sunshine](https://github.com/LizardByte/Sunshine)** & **[Apollo](https://github.com/ClassicOldSong/Apollo)**: Upstream self-hosted GameStream server software.

---

## Build Requirements

- **Operating System**: macOS Sonoma 14.0 or newer (Apple Silicon & Intel Macs supported).
- **Apple Developer Tools**:
  - Command Line Tools for Xcode (Swift 6.0 toolchain or newer)
  - Or full **Xcode 15.0+** (optional, for IDE development).
- **Git**: Installed with Xcode Command Line Tools.

### Installing Build Requirements

1. Install the Xcode Command Line Tools:
   ```bash
   xcode-select --install
   ```
2. Verify that Swift and Clang are accessible in your terminal:
   ```bash
   swift --version
   clang --version
   ```

No external package managers (Homebrew, MacPorts) or third-party package dependencies are required — all C libraries (`moonlight-common-c`, `libopus`, `enet`) are bundled directly within the repository.

---

## Building and Installing

### Command Line (Automated Package Script)

1. Clone the repository:
   ```bash
   git clone https://github.com/Eckobrew/moonlight-mac.git
   cd moonlight-mac
   ```

2. Build and package the release application:
   ```bash
   ./Scripts/package_app.sh release
   ```

3. Install to your Applications directory:
   ```bash
   cp -R Products/MoonlightMac.app /Applications/
   ```

### Xcode IDE

1. Open `MoonlightMac.xcodeproj` in Xcode.
2. Select the **MoonlightMac** scheme and your Mac as the build target.
3. Press `⌘ R` to build and run, or `Product > Archive` to create a standalone build.

---

## License

This project incorporates `moonlight-common-c` licensed under the **GNU General Public License v3.0** (GPLv3). Bundled Opus components are licensed under the **BSD 3-Clause License**.
