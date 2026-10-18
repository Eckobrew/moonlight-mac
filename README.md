# Moonlight Mac

[Moonlight Mac](https://moonlight-stream.org) is an open source, native macOS client for [Sunshine](https://github.com/LizardByte/Sunshine), [Apollo](https://github.com/ClassicOldSong/Apollo), and NVIDIA GameStream.

Built natively in Swift with SwiftUI, Metal, VideoToolbox, and CoreAudio, powered by `moonlight-common-c`.

> [!NOTE]
> The whole thing is vibe coded by a monkey who has no idea what he's doing.

## Features
 - Hardware-accelerated video decoding via VideoToolbox (Apple Silicon and Intel)
 - H.264, HEVC, and AV1 codec support
 - Native Retina High-DPI 1:1 rendering and automatic display resolution matching
 - HDR streaming and full dynamic range color support
 - Streaming up to 240 FPS with Apple ProMotion (120Hz) display pacing
 - 5.1 and 7.1 surround sound audio support
 - Raw hardware mouse capture with 1000Hz+ polling via GameController `GCMouse`
 - Gamepad support with rumble force feedback
 - Passing system-wide keyboard shortcuts and optional Command/Control swap
 - Opt-in host clipboard synchronization (Sunshine, Apollo, Vibepollo)
 - Standalone desktop game shortcut creation with custom icons and Wake-on-LAN
 - NAT hairpinning detection and custom bitrate for remote sessions
 - Wake-on-LAN support and option to hide unpaired PCs

## Keyboard Shortcuts
 - `⌃ ⌥ ⇧ Q` or `⌘ ⌃ Q`: Terminate stream
 - `⌃ ⌥ ⇧ Z`: Release mouse cursor capture
 - `⌃ ⌥ ⇧ X`: Toggle between Fullscreen and Windowed mode
 - `⌃ ⌥ ⇧ S` or `⌘ ⇧ H`: Toggle performance overlay HUD

## Requirements
 - macOS 14.0 or newer (Apple Silicon & Intel)
 - Xcode 15.0+ or Swift 6.0+ Command Line Tools
 - Host: [Sunshine](https://github.com/LizardByte/Sunshine), [Apollo](https://github.com/ClassicOldSong/Apollo), or GeForce Experience

## Building

Run the packaging script to build the release binary, assemble resources, and apply code signing:

```bash
./Scripts/package_app.sh
```

The resulting application will be located at `Products/MoonlightMac.app`.

To install to Applications:
```bash
cp -R Products/MoonlightMac.app /Applications/
```

## License

This project incorporates `moonlight-common-c` licensed under the **GNU General Public License v3.0**.
