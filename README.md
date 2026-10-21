# Moonlight for macOS

**Moonlight** lets you stream games from your gaming PC directly to your Mac. Play your PC games anywhere on your home network or across the internet with low latency, high frame rates, and crystal-clear image quality.

Works seamlessly with **[Sunshine](https://github.com/LizardByte/Sunshine)**, **[Apollo](https://github.com/ClassicOldSong/Apollo)**.

> [!NOTE]
> Native macOS app built from the ground up using Swift, SwiftUI, Metal, VideoToolbox, and AVFoundation using AI by a monkey with no clue what he's doing or how to effectively prompt a AI

---

## Highlights

- **Smooth & Responsive**: Hardware-accelerated video decoding with Apple Metal rendering for lowest possible input lag.
- **High Refresh Rates**: Supports 60, 90, 120 (Apple ProMotion), 144, and up to 240 FPS.
- **HDR & Vibrant Color**: 10-bit High Dynamic Range (HDR) color support for HDR-capable displays and MacBooks.
- **Surround Sound Audio**: Crisp, low-latency audio with support for Stereo, 5.1, and 7.1 surround sound.
- **Game Controllers**: Plug and play with Xbox, PlayStation, Nintendo Switch, and MFi Bluetooth controllers (with rumble vibration support).
- **Physical PC Keyboard Layout**: Your Mac keyboard's bottom row automatically matches a real Windows PC keyboard (`[Control]` `[Windows]` `[Alt]`), so game controls and shortcuts like Alt+Tab feel natural.
- **System Shortcut Capture**: Send ⌘Tab, Mission Control, and other Mac shortcuts straight into your PC game without accidentally switching Mac apps.

---

## Quick Start Guide

### 1. Requirements
- A Mac running **macOS Sonoma (14.0)** or newer (Apple Silicon or Intel).
- A gaming PC on your network running **Sunshine** (recommended) or Apollo.

### 2. Pair Your Mac with Your PC
1. Open **Moonlight** on your Mac.
2. Your PC will appear automatically in the list. Click on it.
3. Moonlight will display a 4-digit PIN.
4. On your PC, open the Sunshine web interface (or click the pairing notification) and type in the 4-digit PIN.
5. Your PC is now paired! Click any game to start playing.

---

## In-Game Keyboard Shortcuts

While streaming a game, hold down **Control + Option + Shift** (`⌃ ⌥ ⇧`) and press any of the following keys:

| Shortcut | What It Does |
| :--- | :--- |
| **`⌃ ⌥ ⇧ Q`** | **Disconnect** / Quit the streaming session |
| **`⌃ ⌥ ⇧ Z`** | **Release or Recapture mouse cursor** (free your mouse to use other Mac apps) |
| **`⌃ ⌥ ⇧ X`** | **Toggle Fullscreen** / Windowed mode |
| **`⌃ ⌥ ⇧ S`** | **Toggle Performance HUD** (shows live FPS, latency, and packet stats) |
| **`⌃ ⌥ ⇧ M`** | **Toggle Mouse Mode** |
| **`⌃ ⌥ ⇧ D`** | **Minimize** streaming window |
| **`⌃ ⌥ ⇧ V`** | **Paste clipboard text** from your Mac into the host PC |

---

## Helpful Settings Explained

Open **Settings** (gear icon) to adjust how your games look and feel:

### Display & Video
- **Resolution**: Choose `Native` to automatically match your Mac display's exact sharp resolution, or pick 1080p / 1440p / 4K.
- **Frame Rate**: Match your monitor's refresh rate (e.g. 120 FPS on MacBook ProMotion displays).
- **Target Bitrate**: Controls video quality. 25–50 Mbps looks great on local Wi-Fi / Ethernet.
- **Remote Bitrate**: Automatically lowers the bitrate when connecting over the internet or Tailscale to prevent lag.
- **V-Sync**: Keeps the picture smooth and prevents horizontal screen tearing.

### Audio
- **Channel Layout**: Choose Stereo or 5.1/7.1 surround sound.
- **Mute Host PC Speakers**: Silences the physical speakers on your PC while you are streaming to your Mac.

### Keyboard & Mouse
- **Capture Mouse Pointer Automatically**: Keeps the mouse locked inside the game window so first-person games and camera controls work properly.
- **Capture System Keyboard Shortcuts**: Sends shortcuts like `⌘ Tab` directly to Windows instead of triggering macOS app switching. Press `⌃ ⌥ ⇧ Z` whenever you want to release the cursor back to your Mac.
- **Match Physical Windows PC Keyboard Layout**: Enabled by default. Maps your bottom-row keys (`Control`, `Option`, `Command`) to (`Ctrl`, `Windows`, `Alt`), so key positions match a real Windows keyboard.

---

## Installing and Building

### Ready-to-Use App
Download or package **`Moonlight.app`** and drag it into your **`/Applications`** folder.

### Building from Source (Command Line)
If you want to compile Moonlight yourself:

1. Make sure Xcode Command Line Tools are installed:
   ```bash
   xcode-select --install
   ```
2. Clone this repository:
   ```bash
   git clone https://github.com/Eckobrew/moonlight-mac.git
   cd moonlight-mac
   ```
3. Run the packaging script:
   ```bash
   ./Scripts/package_app.sh release
   ```
4. Copy the app to Applications:
   ```bash
   cp -R Products/Moonlight.app /Applications/
   ```

---

## Acknowledgments & Credits

Moonlight for macOS is built upon these open-source projects:
- **[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)** (GPLv3): Core GameStream protocol and packet pipeline.
- **[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)** (GPLv3): Architecture reference for sub-pixel cursor handling and keyboard grab behavior.
- **[moonlight-macos-enhanced](https://github.com/Mariotaku/moonlight-macos-enhanced)** (GPLv3): Reference patterns for native macOS integration.
- **[libopus](https://opus-codec.org/)**: High-fidelity, low-latency audio codec.
- **[Sunshine](https://github.com/LizardByte/Sunshine)** & **[Apollo](https://github.com/ClassicOldSong/Apollo)**: GameStream host server software.

---

## License

This project is licensed under the **GNU General Public License v3.0** (GPLv3). Bundled Opus components are licensed under the **BSD 3-Clause License**.
