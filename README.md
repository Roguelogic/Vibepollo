# Vibepollo (macOS)

**[English](README.md) | [한국어](README.ko.md)**

A fork of [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) (based on [Apollo](https://github.com/ClassicOldSong/Apollo) and [Sunshine](https://github.com/LizardByte/Sunshine)) focused on macOS host support for Apple Silicon Macs and iPad / Moonlight clients.

## Features (macOS)

* **Virtual Display (`CGVirtualDisplay`)**
  * Creates a Retina HiDPI virtual display matching the client's resolution and refresh rate (including HDR).
  * Works on headless Macs without dummy plugs.
  * Can turn off physical displays during a session and restore them on disconnect.

* **Capture & Encoding (`ScreenCaptureKit` + `VideoToolbox`)**
  * Zero-copy `IOSurface` capture to hardware HEVC / H.264 encoding.
  * 10-bit HDR10 and YUV 4:4:4 support.
  * Reduced idle frame rate on static screens and adaptive FEC on stable networks.

* **Input (iPad, Trackpad, Apple Pencil)**
  * **Apple Pencil modes** (selectable from the menu bar):
    * *Scroll & Tap*: Touch/scroll navigation, tap-to-click, window dragging, and hover indicator without moving the desktop cursor.
    * *Drawing Tablet*: Native macOS tablet events (`CGEvent` tablet proximity/point) with pressure, tilt, rotation, and hover.
  * **Trackpad scrolling**: Continuous 120Hz scrolling with selectable MacBook or iPadOS inertia curves from the menu bar.
  * **Keyboard**: Supports Korean/English (`한/영` Caps Lock and Globe) input source switching on iPad keyboards.

* **System Audio**
  * Captures macOS system audio directly via CoreAudio tap without third-party virtual audio drivers.

## Notes on Resolution & Refresh Rate

Single-engine Apple Silicon hardware encoders have a fixed pixel-rate ceiling (roughly `~895 Mpx/s` on base M4):

| Mode | Notes |
| :--- | :--- |
| `2752 × 2064 @ 120Hz` (iPad Pro 13") | Runs at full `120 FPS` (SDR / HDR / 4:4:4) |
| `2560 × 1440 @ 144Hz` | Runs at full `144 FPS` |
| `3840 × 2160` (4K) | Sustains `90–100 FPS` locked (peaks around `~108 FPS` on base M4) |

## Build (macOS Apple Silicon)

### Dependencies
```bash
xcode-select --install
brew install cmake ninja pkg-config openssl@3 opus miniupnpc curl icu4c
```

### Compile
```bash
git clone --recursive https://github.com/Roguelogic/Vibepollo.git
cd Vibepollo

cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
ninja -C build
```

### Install & Permissions
1. Copy `build/Vibepollo.app` to `/Applications/Vibepollo.app` and run it.
2. Grant permissions in **System Settings → Privacy & Security**:
   * **Screen & System Audio Recording**
   * **Accessibility**

*(Optional)* Signing the app bundle with a local self-signed certificate in Keychain Access keeps macOS from resetting permissions after rebuilds.

## Windows & Linux

Upstream Windows and Linux support from [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) is preserved unchanged in this repository.

## Credits & License

* Upstream: [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo), [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo), [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
* License: [GPL-3.0](LICENSE)
