# Moonlight for macOS

A high-performance, native macOS client for the [Moonlight](https://moonlight-stream.org) game streaming protocol, engineered from the ground up for low-latency streaming from **Sunshine** and **Apollo** host servers.

Built with **SwiftUI**, **VideoToolbox**, **Metal**, and **CoreAudio**, powered by the battle-tested `moonlight-common-c` core with native Apple CommonCrypto.

---

## Features

- **Hardware-Accelerated Decoding**: Real-time H.264, HEVC (H.265), and AV1 decoding via `VTDecompressionSession` with low-latency decompression attributes.
- **Zero-Copy Metal Rendering**: Direct binding of decoded `CVPixelBuffer` Y/UV planes to Metal textures using `CVMetalTextureCache` with color space conversion shaders (BT.709 SDR and BT.2020 HDR).
- **A/V Sync & Frame Pacing**: Microsecond-accurate timestamp correlation via `AVPacingClock`, eliminating A/V drift and micro-stutters.
- **Low-Latency Input Capture**:
  - **Mouse**: Raw relative delta tracking (`CGAssociateMouseAndMouseCursorPosition(0)`) bypassing macOS acceleration curves with cursor clipping and window centering.
  - **Keyboard**: Full macOS keycode mapping to Win32 Virtual Key codes (`VK_*`).
  - **Gamepad**: Apple `GameController` framework integration with 120Hz polling loop and host rumble haptics.
  - **Escape Shortcut**: `Cmd + Ctrl + Q` immediately releases captured cursor and keyboard.
- **Automatic Host Discovery & Pairing**: mDNS / Bonjour network scanning (`_nvstream._tcp`) using `Network.framework`, Wake-on-LAN support, and Sunshine 4-digit PIN challenge-response handshake.
- **Telemetry HUD**: Lightweight toggleable performance overlay (`Cmd + Shift + H`) reporting real-time FPS, frame decode time (ms), network RTT latency (ms), bitrate, and packet loss %.
- **Native Apple Crypto**: Custom `PlatformCrypto_Apple.c` leveraging `<CommonCrypto/CommonCryptor.h>`, eliminating any external OpenSSL or MbedTLS dependencies.

---

## Requirements

- **macOS**: 14.0 (Sonoma) or newer (Apple Silicon & Intel)
- **Xcode**: 15.0+ or Swift 6.0+ Command Line Tools
- **Host**: Sunshine (recommended) or NVIDIA GeForce Experience / Apollo

---

## Quick Start

### 1. Build and Package `.app` Bundle

Run the packaging script to build the release binary, generate the high-resolution app icon, bundle resources, and ad-hoc sign the application:

```bash
./Scripts/package_app.sh
```

The resulting application will be located at:
```
Products/Moonlight.app
```

### 2. Launch the Application

```bash
open Products/Moonlight.app
```

Or copy to your Applications folder:
```bash
cp -R Products/Moonlight.app /Applications/
```

### 3. Run Unit Tests

```bash
TMPDIR=/tmp swift test --disable-sandbox
```

---

## Architecture Overview

```
moonlight-mac/
├── Package.swift                    # Swift Package definition (C interop + Swift target)
├── Resources/
│   ├── AppIcon.icns                 # Multi-resolution macOS icon (16x16 up to 1024x1024)
│   ├── Info.plist                   # App bundle configuration & Bonjour service declarations
│   └── MoonlightMac.entitlements    # macOS security & network entitlements
├── Scripts/
│   ├── package_app.sh               # Automated release build & .app bundling script
│   └── generate_icon.swift          # Procedural CoreGraphics icon generator
├── Sources/
│   ├── MoonlightCommonC/            # C core protocol (moonlight-common-c, nanors FEC, enet)
│   │   ├── include/Limelight.h      # Public C bridging interface
│   │   └── src/PlatformCrypto_Apple.c # Native CommonCrypto AES-GCM/CBC backend
│   └── MoonlightMac/
│       ├── Core/                    # State models, configs, crypto & X.509 cert generator
│       ├── Networking/              # mDNS Bonjour discovery, HTTP pairing, Wake-on-LAN
│       ├── Pipeline/                # VideoToolbox decoder, Metal renderer, A/V sync clock
│       ├── Input/                   # GameController, raw delta mouse & keyboard monitors
│       └── UI/                      # SwiftUI host grid, pairing dialog, settings & stream view
└── Tests/
    └── MoonlightMacTests/           # Unit tests for crypto, pairing, and configurations
```

---

## License

This project incorporates `moonlight-common-c` licensed under the GNU General Public License v3.0.
