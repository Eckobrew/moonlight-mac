# Moonlight for macOS

A high-performance, native macOS client for the [Moonlight](https://moonlight-stream.org) game streaming protocol, engineered from the ground up for low-latency streaming from **Sunshine**, **Apollo**, and **Vibepollo** host servers.

Built natively in Swift with **SwiftUI**, **Metal**, **VideoToolbox**, and **CoreAudio**, powered by the battle-tested `moonlight-common-c` core with native Apple CommonCrypto.

---

## Key Features

### 🎬 Video & Display Pipeline
- **Retina High-DPI Precision**: Full 1:1 physical backing scale rendering (`layer.contentsScale = window.backingScaleFactor`), eliminating Retina downsampling blur and delivering crisp text and visuals.
- **Display Native Resolution Detection**: Resolves your Mac's physical display geometry and accounts for the MacBook camera notch safe area margins (`NSScreen.safeAreaInsets`), ensuring video streams match your display without letterboxing or distortion.
- **Zero-Copy Metal Rendering**: Decoded `CVPixelBuffer` Y and UV planes are bound directly to Metal textures via `CVMetalTextureCache` with hardware color space conversions for BT.709 SDR and BT.2020 HDR (10-bit color).
- **Hardware-Accelerated Decoding**: Real-time H.264, HEVC (H.265), and AV1 decoding via Apple's `VTDecompressionSession` with low-latency decompression attributes.
- **Microsecond Frame Pacing & V-Sync**: Integrated `AVPacingClock` eliminates micro-stutters and A/V drift. V-Sync can be toggled off when using the Metal renderer for minimum input display latency.
- **High Refresh Rate Support**: Stream up to 240 FPS, fully optimized for Apple ProMotion 120Hz displays.

### ⚡ Ultra-Low Latency Input Capture
- **Hardware-Level Mouse Polling (`GCMouse`)**: Hooks directly into Apple's GameController `GCMouse` driver to capture unaccelerated hardware counts at native mouse polling rates (1000Hz+), matching `moonlight-qt`.
- **Sub-Pixel Delta Accumulator**: Preserves fractional mouse deltas across poll intervals, completely eliminating truncation deadzones and floaty mouse feel.
- **Warpless Relative Mouse Capture**: Relative cursor tracking via `CGAssociateMouseAndMouseCursorPosition(0)` with automated cursor centering and configurable sensitivity multipliers.
- **Gamepad Integration & Haptics**: Full multi-controller support via Apple `GameController` framework with analog stick deadzones and host rumble haptics.
- **Keyboard Navigation**: Complete macOS keycode translation to Win32 Virtual Key codes (`VK_*`) with an optional toggle to swap Command and Control keys for seamless Windows gaming shortcuts.

### 🌐 Intelligent Networking & Remote Connectivity
- **Verified Bonjour / mDNS Discovery**: Background local network scanning (`_nvstream._tcp.local.`) with metadata validation, keeping unverified network devices off your dashboard.
- **NAT Hairpinning Detection & Remote IP Backup**: Automatically detects when a public IP address loops back to your local gateway to route traffic as local LAN, while preserving Tailscale and WAN connections as remote.
- **Dual-Bitrate Engine**: Configure separate target bitrates for local network play (up to 150 Mbps) and remote sessions over WAN or Tailscale (up to 100 Mbps).
- **Wake-on-LAN (WoL)**: Wake sleeping hosts directly from the UI with automatic re-transmission broadcasts and quick double-click waking.
- **Hide Unpaired PCs Setting**: Filter out unverified local network neighbors while keeping paired offline PCs accessible for Wake-on-LAN.
- **Cryptographically Persistent Pairing**: Client certificates and pairing states are preserved across reboots and network transitions. Transient network drops or unauthenticated HTTP fallbacks during host sleep never unpair your machines.

### 🛠️ Productivity & Ecosystem Features
- **Opt-In Bidirectional Clipboard Sync**: Automatically synchronizes text between your Mac clipboard and Apollo, Vibepollo, or Sunshine hosts over authenticated HTTPS (`/actions/clipboard`), with loop prevention and privacy toggles.
- **Desktop Game Shortcuts**: Right-click any streamable application to generate a standalone `.app` bundle on your macOS Desktop with custom icon selection, embedded game artwork, automated Wake-on-LAN, and direct launch into the game.
- **Host Behavior Controls**: Toggle "Optimize game settings for streaming" (`sops=1/0`) and "Quit game on host when ending stream" to match your preferred workflow.
- **In-App Performance HUD & Diagnostics**: Toggleable telemetry overlay (`Cmd + Shift + H` / `Ctrl + Option + Shift + S`) reporting real-time FPS, decode latency (ms), network RTT (ms), bitrate, and packet loss %, plus an integrated live log viewer.

---

## In-Stream Shortcuts

| Shortcut | Description |
| :--- | :--- |
| `⌃ ⌥ ⇧ Q` or `⌘ ⌃ Q` | Terminate active stream and return to host grid |
| `⌃ ⌥ ⇧ Z` | Release mouse cursor capture |
| `⌃ ⌥ ⇧ X` | Toggle between Fullscreen and Windowed mode |
| `⌃ ⌥ ⇧ S` or `⌘ ⇧ H` | Toggle Performance & Telemetry HUD overlay |

---

## Requirements

- **macOS**: 14.0 (Sonoma) or newer (Apple Silicon & Intel)
- **Xcode**: 15.0+ or Swift 6.0+ Command Line Tools
- **Host**: [Sunshine](https://github.com/LizardByte/Sunshine), [Apollo](https://github.com/ClassicOldSong/Apollo), or NVIDIA GeForce Experience

---

## Quick Start

### 1. Build and Package `.app` Bundle

Run the packaging script to build the release binary, assemble resources, and apply code signing:

```bash
./Scripts/package_app.sh
```

The resulting application will be located at:
```
Products/MoonlightMac.app
```

### 2. Install to Applications

```bash
cp -R Products/MoonlightMac.app /Applications/
open /Applications/MoonlightMac.app
```

### 3. Run Unit Tests

```bash
TMPDIR=/tmp swift test --disable-sandbox
```

---

## Architecture Overview

```
moonlight-mac/
├── Package.swift                     # Swift Package definition (C bridge + Swift modules)
├── Resources/
│   ├── AppIcon.icns                  # Multi-resolution macOS icon (up to 1024x1024)
│   ├── Info.plist                    # App bundle configuration & Bonjour service declarations
│   └── MoonlightMac.entitlements     # macOS security, network, and sandbox entitlements
├── Scripts/
│   ├── package_app.sh                # Automated release build & .app bundling script
│   └── generate_icon.swift           # Procedural CoreGraphics icon generator
├── Sources/
│   ├── MoonlightCommonC/             # C core protocol (moonlight-common-c, nanors FEC, enet)
│   │   ├── include/Limelight.h       # Public C bridging interface
│   │   └── src/PlatformCrypto_Apple.c# Native CommonCrypto AES-GCM/CBC backend
│   └── MoonlightMac/
│       ├── Core/                     # AppState, StreamConfiguration, CertificateManager
│       │   ├── Models/               # Host, Application, StreamConfiguration, PerformanceMetrics
│       │   ├── State/                # AppState, StreamSessionController
│       │   ├── Security/             # CertificateManager, CryptoUtils
│       │   └── Utils/                # DisplayManager, ClipboardSyncManager, GameShortcutManager
│       ├── Input/                    # GCMouse hardware polling, delta accumulator, keyboard mappings
│       ├── Networking/               # Bonjour discovery, Sunshine HTTP/HTTPS client, WakeOnLAN
│       ├── Pipeline/                 # VideoToolbox decoder, Metal renderer, AVPacingClock, CoreAudio
│       └── UI/                       # SwiftUI host grid, pairing sheets, stream views, performance HUD
└── Tests/
    └── MoonlightMacTests/            # Unit tests for crypto, pairing, and configurations
```

---

## License

This project incorporates `moonlight-common-c` licensed under the **GNU General Public License v3.0**.
