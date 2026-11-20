# Vibepollo — Apple Silicon macOS & iPad Pro Edition

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform: macOS Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon%20(M1--M6)-black?logo=apple)](https://github.com/Roguelogic/Vibepollo)
[![Client: Moonlight / VoidLink](https://img.shields.io/badge/Client-Moonlight%20%7C%20VoidLink-purple)](https://moonlight-stream.org/)

An ultra-low-latency **Moonlight / Sunshine streaming host** deeply engineered for **Apple Silicon Macs (`M1`–`M6`)** and **iPad Pro / High-Refresh Desktop clients**.

Built as an open-source (`GPL-3.0`) fork of [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) (derived from [Apollo](https://github.com/ClassicOldSong/Apollo) and [Sunshine](https://github.com/LizardByte/Sunshine)), this edition brings Parsec-beating responsiveness, **120Hz 10-bit HDR10 + YUV 4:4:4**, native Retina virtual displays, **Apple Pencil pressure/tilt/hover tablet input**, and **Magic Keyboard trackpad physics** to macOS hosts.

---

## Why This Exists

macOS has historically been a second-class host in remote desktop and game streaming:
* **Apple Sidecar** is locked to `60Hz`, `SDR`, and `YUV 4:2:0` chroma subsampling over local connections only.
* **Parsec** dropped/restricted macOS hosting features and lacks `HDR10`, `YUV 4:4:4`, Retina virtual displays, and native iPad trackpad/stylus integration.
* **Stock Sunshine / Apollo** focus primarily on Windows and Linux, leaving Apple Silicon's `ScreenCaptureKit`, `AppleAVE2` hardware media engine, and iPadOS input ergonomics largely untapped.

This fork closes every one of those gaps on Apple Silicon.

---

## macOS Highlights

### 1. Native Retina HiDPI + HDR10 Virtual Display (`CGVirtualDisplay`)
* **Automatic Client Resolution & Refresh Matching**: Dynamically creates a native Retina HiDPI virtual display matching your client (e.g., iPad Pro 13" **`2752×2064 @ 120Hz` HDR**, `2560×1440 @ 144Hz`, or `3840×2160` 4K).
* **Headless Mac mini Ready**: Works with zero HDMI dummy plugs attached.
* **Exclusive Mode & Crash-Safe Watchdog**: Automatically blanks physical monitors while streaming and guarantees display layout restoration on disconnect or unexpected termination.

### 2. Ultra-Low-Latency `ScreenCaptureKit` → `AppleAVE2` Pipeline
* **Zero-Copy `IOSurface` Handoff**: Direct GPU-to-`AppleAVE2` delivery with `SCStream` direct callback scheduling and Mach real-time / `USER_INTERACTIVE` QoS threads.
* **Hardware Media Engine Tuning**: Enables `AppleAVE2` hardware turbo (`ThroughputMode=5`), narrow low-latency motion estimation (`96×64`), 4-slice parallel HEVC encoding, and zero-reorder VUI (`max_dec_pic_buffering = 1`) for immediate frame-0 client decode.
* **True 10-Bit HDR10 & YUV 4:4:4 (`'xf44'`)**: Sub-pixel crisp text and brush strokes with in-band HDR10 `PREFIX_SEI_NUT` (`MaxCLL` / `MaxFALL` / mastering luminance) injection.
* **Settled VFR Idle Conservation + DVFS Hold**: Holds turbo clocks for `3.0s` across brief reading/clicking pauses to prevent `AppleAVE2` P-state downclock spikes, then drops static desktop idle bandwidth to **`~157 kbps` (`0%` GPU)** with `0µs` instant wakeup on the next VSync.
* **Lock-Free Single-Pass Annex-B & Lossless Adaptive FEC**: Eliminates large-buffer VM page faults on 4K IDR frames and dynamically scales Reed-Solomon FEC (`20% ↔ 5%`, `min_parity >= 2`) on clean links with zero quality loss (`0.000 dB`).

### 3. First-Class iPad Pro, Magic Keyboard & Apple Pencil Support
* **Live-Switchable Apple Pencil Modes (macOS Menu Bar → `Apple Pencil`)**:
  * **Scroll & Tap (iPad Style)**: Natural iPad-style scrolling, tap/right-click, window & desktop rubber-band dragging, and an air-hover stylus reticle—without teleporting your desktop mouse cursor.
  * **Drawing Tablet (Pen Input)**: Injects native Wacom-grade macOS tablet events (`kCGEventTabletProximity` + `kCGEventMouseSubtypeTabletPoint`) with full **Pressure (`0.0–1.0`)**, **Tilt X/Y**, **Barrel Roll / Rotation**, and **Hover**—turning an M4 iPad Pro into a wireless **`120Hz` Tandem OLED `HDR 4:4:4` pen display** for Photoshop, Clip Studio Paint, Blender, Illustrator, Freeform, and Preview.
* **120Hz Trackpad Scroll Physics (Menu Bar → `Scroll Inertia`)**:
  * Switch anytime between **MacBook (`_NSScrollingMomentumCalculator` quartic)**, **iPadOS (`UIScrollView` exponential)**, or **Disabled** inertia curves, with automatic Natural Scrolling compensation and instant momentum catch.
* **`0µs` Inline Pointer Fast-Path & Korean/English (`한/영`) Keys**:
  * Direct inline control-thread pointer injection with `666Hz` cursor sprite synchronization, plus native `한/영` (Caps Lock) and Globe (`🌐`) input-source switching on iPad Magic Keyboard.

### 4. Multi-Homed LAN + ZeroTier / Tailscale Networking & Native Audio
* **Multi-Interface Bonjour / mDNS & XNU `IP_PKTINFO` Pinning**: Advertises simultaneously across wired Ethernet (`en0`), Wi-Fi, and VPN overlays (ZeroTier / Tailscale) while pinning UDP/HTTP sockets to the exact ingress interface so overlay or secondary NIC routes never hijack local Gigabit/2.5GbE/10GbE LAN traffic.
* **`~1.5ms` LAN Transport + Decode + Render**: `64KB` zero-sleep UDP batching + WMM Voice (`AC_VO`) & L4S `ECT(1)` QoS tagging.
* **Zero-Driver System Audio Capture**: Native macOS CoreAudio system audio tap (`48 kHz` stereo Opus `LOWDELAY`)—no BlackHole or Soundflower required.

---

## Recommended Apple Silicon Profiles

Single-engine Apple Silicon (`M4` `AppleAVE2` ceiling: `~895 Mpx/s`) delivers 1:1 VSync-locked frame rates within its pixel-rate envelope:

| Client Device | Recommended Mode | Pixel Rate | Measured Host + Client Result |
| :--- | :--- | :--- | :--- |
| **iPad Pro 13" (M4)** | `2752 × 2064 @ 120Hz` (HDR10, YUV 4:4:4) | `681.6 Mpx/s` | **`120.0 FPS` locked** (ProMotion 1:1) |
| **Desktop (QHD 144Hz)** | `2560 × 1440 @ 144Hz` (SDR/HDR) | `530.8 Mpx/s` | **`144.0 FPS` locked** (`~1.5ms` net+decode+render on LAN) |
| **Desktop (4K High-Refresh)** | `3840 × 2160 @ 90–100Hz` *(or VRR / G-Sync)* | `746–829 Mpx/s` | **`90–100 FPS` locked** (`~108 FPS` max ceiling on base M4) |

---

## Building on macOS (Apple Silicon)

### Prerequisites
Install Xcode Command Line Tools and Homebrew dependencies:
```bash
xcode-select --install
brew install cmake ninja pkg-config openssl@3 opus miniupnpc curl icu4c
```

### Clone & Build `.app` Bundle
```bash
git clone --recursive https://github.com/Roguelogic/Vibepollo.git
cd Vibepollo

cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
ninja -C build
```

### Install & Grant macOS Permissions
Copy `build/Vibepollo.app` to `/Applications/Vibepollo.app`, launch it, and enable permissions under **System Settings → Privacy & Security**:
1. **Screen & System Audio Recording** (for `ScreenCaptureKit` zero-copy capture & CoreAudio tap)
2. **Accessibility** (for keyboard, mouse, trackpad scroll, and Apple Pencil tablet injection)

> **Tip:** Signing `/Applications/Vibepollo.app` with a persistent self-signed certificate in Keychain Access prevents macOS TCC from re-prompting for Accessibility / Screen Recording permissions across rebuilds.

---

## 한국어 요약 (Korean Overview)

**Apple Silicon 맥(`M1`~`M6`)을 초저지연 원격 데스크톱 및 `120Hz HDR 4:4:4` 무선 액정 타블렛 호스트로 만들어 주는 Vibepollo macOS 특화 오픈소스 포크**입니다.

* **네이티브 Retina 가상 모니터 (`CGVirtualDisplay`)**: 더미 플러그 없이 아이패드 프로(`2752×2064 @ 120Hz HDR`)나 데스크톱 해상도·주사율에 맞춰 자동 생성되며 연결 종료 시 물리 모니터를 자동 복원합니다.
* **초저지연 `AppleAVE2` 하드웨어 인코딩**: `ScreenCaptureKit` `IOSurface` Zero-Copy 직결, 하드웨어 터보 클럭 고정, `10-bit HDR10` + `YUV 4:4:4` 색번짐 없는 텍스트/브러시 표현, 정지 화면 `~157 kbps` 초저전력 대기 및 무손실 적응형 FEC를 지원합니다.
* **iPad Pro · 매직 키보드 · Apple Pencil 완벽 연동**:
  * 상단 메뉴바에서 **`Scroll & Tap (iPad 방식)`** ↔ **`Drawing Tablet (와콤 호환 필압·기울기·회전·호버 타블렛 모드)`** 실시간 전환
  * 메뉴바에서 **`MacBook` / `iPadOS` 스크롤 관성 물리 엔진** 선택 및 트랙패드·터치 관성 즉시 정지
  * 매직 키보드 **`한/영`(Caps Lock) 및 지구본(`🌐`) 키** 네이티브 전환
* **멀티 네트워크(유선 LAN + ZeroTier/Tailscale) 동시 광고 및 인터페이스 핀 고정** + 별도 오디오 드라이버 없는 **macOS 시스템 오디오 캡처**.

---

## Cross-Platform Upstream Features (Windows & Linux)

All upstream [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) capabilities on Windows and Linux remain intact in this tree, including:
* **Windows**: Native virtual display driver + Direct3D11 shared frame-ring push, Windows Graphics Capture in service mode, **NVIDIA Blackwell (SDK 13.0) 9th-Gen NVENC Split-Frame Encoding (SFE)**, RTX HDR automation, RTSS integration, PyroWave GPU wavelet codec, and built-in virtual DualSense/Xbox gamepad driver.
* **Linux**: Native Wayland/KMS capture, managed virtual displays, PyroWave, and SteamOS support.

---

## Credits & License

* **Upstream Projects**: [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) · [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo) · [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) · [Moonlight Game Streaming Project](https://github.com/moonlight-stream)
* **License**: Distributed under the **GNU General Public License v3.0 ([GPL-3.0](LICENSE))**.
