# Vibepollo (macOS)

**[English](README.md) | [한국어](README.ko.md)**

A lightweight, standalone remote desktop and streaming host built natively for **Apple Silicon Macs (`arm64`)**.  
Forked from [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) (based on [Apollo](https://github.com/ClassicOldSong/Apollo) and [Sunshine](https://github.com/LizardByte/Sunshine)) and refactored into a dedicated macOS-only codebase.

## Download & Install

1. Download **`Vibepollo-macOS-arm64.dmg`** from **[GitHub Releases](https://github.com/Roguelogic/Vibepollo/releases/latest)**.
2. Open the DMG and move **`Vibepollo.app`** to **`/Applications`**.
3. Launch **Vibepollo** and grant permissions in **System Settings → Privacy & Security**:
   * **Screen & System Audio Recording**
   * **Accessibility**
4. Open `https://localhost:47990` (or click **Open Vibepollo** from the menu bar icon) to create your admin login and pair your client.
   * *Client note*: On iPadOS / iOS, **VoidLink** is recommended (standard Moonlight lacks native touch and stylus protocol support).

---

## Features

* **Virtual Display (`CGVirtualDisplay`)**
  * Automatically creates a Retina HiDPI virtual display matching the client's exact resolution and refresh rate (up to `120Hz+`, including HDR).
  * Runs on headless Mac minis without HDMI dummy plugs.
  * Blanks physical displays during a remote session and safely restores them on disconnect or unexpected exit.

* **Low-Latency Capture & Hardware Encoding (`ScreenCaptureKit` + `VideoToolbox`)**
  * Zero-copy `IOSurface` capture piped directly into Apple Silicon hardware HEVC / H.264 encoding (`ThroughputMode` turbo, multi-slice, low-latency VBV).
  * 10-bit HDR10 (in-band `PREFIX_SEI_NUT`) and YUV 4:4:4 chroma support.
  * Reduced idle frame rate on static desktops and adaptive FEC.

* **Driverless System Audio (`CoreAudio`)**
  * Captures macOS system audio directly via native CoreAudio process tap (`CATapDescription`) with no third-party virtual audio driver (e.g. BlackHole) required.

* **Pre-Login Access (`LoginWindow`)**
  * Optional **Allow on Login Screen** toggle in the menu bar registers a `LoginWindow` + `Aqua` LaunchAgent (`CGDisplayStream` pre-login fallback), allowing remote password entry right after a reboot.
  * *Note*: If FileVault full-disk encryption is enabled, macOS waits at the pre-boot EFI unlock screen before starting `launchd` agents; unattended cold reboots require turning FileVault off or rebooting via `sudo fdesetup authrestart`.

* **Native macOS Input**
  * Low-latency mouse, keyboard (including Korean/English input source switching), and 120Hz continuous scrolling with selectable inertia curves in the menu bar.
  * Supports native multi-touch and stylus tablet protocols (pressure, tilt, barrel roll, and side gestures) for VoidLink clients.

---

## Resolution & Refresh Rate Notes

Single-engine Apple Silicon hardware encoders have a fixed pixel-rate ceiling (roughly `~895 Mpx/s` on base M4):

| Mode | Notes |
| :--- | :--- |
| `2752 × 2064 @ 120Hz` | Sustains full `120 FPS` (SDR / HDR / 4:4:4) |
| `2560 × 1440 @ 144Hz` | Sustains full `144 FPS` |
| `3840 × 2160` (4K) | Sustains `90–100 FPS` locked (peaks around `~108 FPS` on base M4) |

## Platform Scope & Known Limitations

* **macOS Apple Silicon (`arm64`) Only**: Windows, Linux, X11/Wayland, and NVIDIA/AMD/Intel host code paths have been removed to keep the codebase lean and macOS-native. For Windows/Linux hosting, use upstream [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) or [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo).
* **Virtual Gamepad Input**: macOS blocks user-space virtual HID gamepads without Apple's restricted DriverKit HID entitlement (`com.apple.developer.hid.virtual.device`), so virtual controller emulation is currently unsupported.

---

## Build from Source (macOS Apple Silicon)

### Dependencies
```bash
xcode-select --install
brew install cmake ninja pkg-config openssl@3 opus miniupnpc curl icu4c libwebp
```

### Compile
```bash
git clone --recursive https://github.com/Roguelogic/Vibepollo.git
cd Vibepollo

cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTS=OFF \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
cmake --build build --target sunshine -j"$(sysctl -n hw.ncpu)"
```

### Sign & Notarize (Optional, Maintainers)
```bash
./scripts/notarize_macos.sh
```

---

## Credits & License

* Upstream: [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo), [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo), [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
* License: [GPL-3.0](LICENSE)
