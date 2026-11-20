# Vibepollo — Apple Silicon macOS & iPad Pro 에디션

**[English](README.md) | [한국어](README.ko.md)**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform: macOS Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon%20(M1--M6)-black?logo=apple)](https://github.com/Roguelogic/Vibepollo)
[![Client: Moonlight / VoidLink](https://img.shields.io/badge/Client-Moonlight%20%7C%20VoidLink-purple)](https://moonlight-stream.org/)

**Apple Silicon 맥(`M1`–`M6`)**과 **iPad Pro · 고주사율 데스크톱 클라이언트** 환경에 맞춰 설계된 초저지연 **Moonlight / Sunshine 스트리밍 호스트**입니다.

[Nonary/Vibepollo](https://github.com/Nonary/Vibepollo)([Apollo](https://github.com/ClassicOldSong/Apollo) 및 [Sunshine](https://github.com/LizardByte/Sunshine) 기반)를 바탕으로 한 오픈소스(`GPL-3.0`) 포크로, macOS 호스트에서 **`120Hz 10-bit HDR10 + YUV 4:4:4`**, **네이티브 Retina 가상 모니터**, **Apple Pencil 필압·기울기·호버 액정 타블렛 입력**, **매직 키보드 트랙패드 스크롤 물리 엔진**을 제공합니다.

---

## 프로젝트 배경

기존 원격 데스크톱 및 스트리밍 환경에서 macOS 호스트 지원에는 뚜렷한 한계가 있었습니다.
* **Apple Sidecar**: 로컬 연결 전용이며 `60Hz`, `SDR`, `YUV 4:2:0` 압축으로 고정되어 미세 텍스트 색 번짐과 주사율 한계가 존재합니다.
* **Parsec**: macOS 호스트 기능 제약이 크며 `HDR10`, `YUV 4:4:4`, Retina 가상 모니터, iPad 트랙패드·펜슬 최적화를 지원하지 않습니다.
* **기존 Sunshine / Apollo**: Windows와 Linux 위주로 개발되어 Apple Silicon의 `ScreenCaptureKit`, `AppleAVE2` 하드웨어 미디어 엔진, iPadOS 입력 생태계를 충분히 활용하지 못했습니다.

이 포크는 Apple Silicon 맥을 데스크톱급 초저지연 호스트이자 무선 액정 타블렛 워크스테이션으로 사용할 수 있도록 모든 구간을 재설계했습니다.

---

## macOS 주요 기능

### 1. 네이티브 Retina HiDPI + HDR10 가상 모니터 (`CGVirtualDisplay`)
* **클라이언트 해상도·주사율 자동 매칭**: 접속 기기에 맞춰 Retina HiDPI 가상 디스플레이(예: iPad Pro 13" **`2752×2064 @ 120Hz` HDR**, `2560×1440 @ 144Hz`, `3840×2160` 4K)를 즉시 생성합니다.
* **헤드리스 맥 미니 완벽 지원**: HDMI 더미 플러그 없이도 단독 구동됩니다.
* **물리 모니터 자동 소등 및 복구 워치독**: 스트리밍 중 물리 모니터를 자동으로 끄고, 연결 해제나 비정상 종료 시에도 원래 디스플레이 구성을 안전하게 복원합니다.

### 2. 초저지연 `ScreenCaptureKit` → `AppleAVE2` 인코딩 파이프라인
* **Zero-Copy `IOSurface` 직결**: CPU 메모리 복사 없이 GPU 서피스를 하드웨어 인코더로 바로 전달하며 Mach 실시간 / `USER_INTERACTIVE` QoS 스레드로 구동됩니다.
* **하드웨어 미디어 엔진 극한 튜닝**: `AppleAVE2` 하드웨어 터보(`ThroughputMode=5`), 저지연 모션 탐색, 4-슬라이스 병렬 HEVC 인코딩, 프레임 재정렬 제거(`max_dec_pic_buffering = 1`)를 통해 첫 프레임부터 즉시 디코딩됩니다.
* **리얼 10-Bit HDR10 & YUV 4:4:4 (`'xf44'`)**: 인밴드 HDR10 메타데이터(`PREFIX_SEI_NUT`) 삽입 및 색 번짐 없는 픽셀 단위 텍스트·브러시 선명도를 제공합니다.
* **스마트 VFR 유휴 절전**: 짧은 작업 멈춤 구간에서는 인코더 클럭 강하를 방지해 즉각적인 반응성을 유지하고, 정지 화면이 지속되면 대역폭을 **`~157 kbps` (`GPU 0%`)**까지 낮췄다가 화면 변화 즉시 `0µs` 지연으로 깨어납니다.
* **Lock-Free 패킷화 및 무손실 적응형 FEC**: 대형 프레임 처리 지연을 제거하고 회선 품질에 따라 FEC 패리티(`20% ↔ 5%`)를 화질 손실 없이 실시간 조절합니다.

### 3. iPad Pro · 매직 키보드 · Apple Pencil 특화 지원
* **실시간 전환 가능한 2가지 Apple Pencil 모드 (상단 메뉴바 → `Apple Pencil`)**:
  * **Scroll & Tap (iPad Style)**: 데스크톱 마우스 커서를 텔레포트시키지 않으면서 아이패드 방식 스크롤, 탭/우클릭, 창 이동 및 바탕화면 드래그, 공중 호버 레티클을 지원합니다.
  * **Drawing Tablet (Pen Input)**: macOS 네이티브 와콤 호환 타블렛 이벤트(`kCGEventTabletProximity` + `kCGEventMouseSubtypeTabletPoint`)를 주입하여 **필압(`0.0–1.0`)**, **기울기(`Tilt X/Y`)**, **배럴 회전(`Rotation`)**, **호버(`Hover`)**를 완벽 지원합니다. Photoshop, Clip Studio Paint, Blender, Illustrator, 메모, 미리보기, Freeform 등에서 iPad Pro를 **`120Hz OLED HDR 4:4:4` 무선 액정 타블렛**처럼 쓸 수 있습니다.
* **120Hz 트랙패드 스크롤 물리 엔진 (상단 메뉴바 → `Scroll Inertia`)**:
  * **MacBook (`_NSScrollingMomentumCalculator` 4차 곡선)**, **iPadOS (`UIScrollView` 지수 감속 곡선)**, **끔(Disabled)** 중 원하는 관성 모드를 실시간으로 선택할 수 있으며, 자연스러운 스크롤 방향 보정과 터치·트랙패드 관성 즉시 정지를 지원합니다.
* **즉각적인 포인터 반응 및 매직 키보드 `한/영` 전환**:
  * 인라인 패스트패스 포인터 처리와 고주사율 커서 동기화, 아이패드 매직 키보드의 **`한/영`(Caps Lock) 및 지구본(`🌐`) 키** 입력 소스 전환을 기본 지원합니다.

### 4. 무드라이버 시스템 오디오 & 간편한 원격 연결
* **네이티브 macOS 시스템 오디오 캡처**: BlackHole이나 Soundflower 같은 가상 오디오 드라이버 설치 없이 CoreAudio 탭으로 `48 kHz` 스테레오(`Opus LOWDELAY`) 사운드를 바로 전송합니다.
* **로컬 네트워크 & 외부 원격 접속 동시 호환**: 내부 유무선 네트워크는 물론 Tailscale / ZeroTier 같은 외부 오버레이 네트워크에서도 별도 라우팅 설정 없이 안정적으로 검색·연결됩니다.

---

## Apple Silicon 권장 스트리밍 프로필

단일 미디어 엔진 기반 Apple Silicon(`M4` 기준 실효 한계 `약 8.95억 px/s`)에서 프레임 드랍 없이 1:1 주사율 동기화가 유지되는 권장 설정입니다.

| 클라이언트 기기 | 권장 해상도 · 주사율 | 초당 픽셀 처리량 | 실측 동작 결과 |
| :--- | :--- | :--- | :--- |
| **iPad Pro 13" (M4)** | `2752 × 2064 @ 120Hz` (HDR10, YUV 4:4:4) | `681.6 Mpx/s` | **`120.0 FPS` 고정** (ProMotion 1:1 동기화) |
| **데스크톱 (QHD 144Hz)** | `2560 × 1440 @ 144Hz` (SDR/HDR) | `530.8 Mpx/s` | **`144.0 FPS` 고정** (유선 LAN 네트워크+디코드+렌더 `~1.5ms`) |
| **데스크톱 (4K 고주사율)** | `3840 × 2160 @ 90–100Hz` *(또는 VRR / G-Sync)* | `746–829 Mpx/s` | **`90–100 FPS` 고정** (기본형 M4 최대 상한 `~108 FPS`) |

---

## macOS 빌드 및 설치 방법 (Apple Silicon)

### 1. 필수 패키지 설치
Xcode Command Line Tools 및 Homebrew 의존성 패키지를 설치합니다.
```bash
xcode-select --install
brew install cmake ninja pkg-config openssl@3 opus miniupnpc curl icu4c
```

### 2. 소스 클론 및 `.app` 번들 빌드
```bash
git clone --recursive https://github.com/Roguelogic/Vibepollo.git
cd Vibepollo

cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
ninja -C build
```

### 3. 설치 및 macOS 권한 허용
생성된 `build/Vibepollo.app`을 `/Applications/Vibepollo.app`으로 복사해 실행한 뒤, **시스템 설정 → 개인정보 보호 및 보안**에서 아래 두 권한을 켜줍니다.
1. **화면 및 시스템 오디오 녹음** (`ScreenCaptureKit` 화면 캡처 및 시스템 오디오 전송용)
2. **손쉬운 사용 (Accessibility)** (키보드, 마우스, 트랙패드 스크롤 및 Apple Pencil 타블렛 입력 주입용)

> **팁:** 키체인 접근(Keychain Access)에서 자체 서명 인증서를 하나 만들어 `/Applications/Vibepollo.app`에 코드 서명해 두면, 재빌드 후에도 macOS 권한 허용이 초기화되지 않고 그대로 유지됩니다.

---

## 크로스 플랫폼 기능 (Windows & Linux)

상위 프로젝트인 [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo)의 Windows 및 Linux 기능도 그대로 포함되어 있습니다.
* **Windows**: 전용 가상 디스플레이 드라이버 및 Direct3D11 Frame-Ring Push, 서비스 모드 WGC 캡처, **NVIDIA Blackwell (SDK 13.0) 9세대 NVENC 프레임 분할 병렬 인코딩(SFE)**, RTX HDR 자동화, RTSS 연동, PyroWave 코덱, 내장 가상 게임패드(DualSense/Xbox) 드라이버 지원.
* **Linux**: Wayland/KMS 네이티브 캡처, 가상 디스플레이, PyroWave 및 SteamOS 지원.

---

## 크레딧 및 라이선스

* **기반 오픈소스 프로젝트**: [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) · [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo) · [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) · [Moonlight Game Streaming Project](https://github.com/moonlight-stream)
* **라이선스**: **GNU General Public License v3.0 ([GPL-3.0](LICENSE))** 하에 배포됩니다.
