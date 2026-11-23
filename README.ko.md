# Vibepollo (macOS)

**[English](README.md) | [한국어](README.ko.md)**

**Apple Silicon 맥(`arm64`)** 전용으로 독립 경량화된 네이티브 원격 데스크톱 및 스트리밍 호스트입니다.  
[Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) ([Apollo](https://github.com/ClassicOldSong/Apollo) · [Sunshine](https://github.com/LizardByte/Sunshine) 기반)에서 포크하여 Windows/Linux 레거시를 제거하고 macOS 네이티브 단일 앱 구조로 재설계했습니다.

## 다운로드 및 설치

1. **[GitHub Releases](https://github.com/Roguelogic/Vibepollo/releases/latest)** 에서 최신 **`Vibepollo-macOS-arm64.dmg`** 를 다운로드합니다.
2. DMG를 열고 **`Vibepollo.app`** 을 **`응용 프로그램(/Applications)`** 폴더로 옮긴 뒤 실행합니다.
3. **시스템 설정 → 개인정보 보호 및 보안**에서 아래 두 권한을 허용합니다:
   * **화면 및 시스템 오디오 녹음**
   * **손쉬운 사용 (Accessibility)**
4. 상단 메뉴바 아이콘에서 **설정...** (**Open Vibepollo**)을 누르거나 브라우저에서 `https://localhost:47990` 에 접속해 초기 관리자 계정을 설정하고 클라이언트와 페어링합니다.
   * *클라이언트 참고*: iPadOS / iOS 환경에서는 **VoidLink** 사용을 권장합니다 (손가락 조작은 **트랙패드/마우스 모드** 권장, Apple Pencil 모드 자동 동기화 및 전용 확장 프로토콜 지원).

---

## 주요 기능

* **가상 디스플레이 (`CGVirtualDisplay`)**
  * 클라이언트 해상도와 주사율에 맞춘 Retina HiDPI 및 HDR 가상 모니터 자동 생성 (최대 `120Hz+`)
  * HDMI 더미 플러그 없이 헤드리스(Headless) 맥 미니 단독 구동 지원
  * 스트리밍 중 물리 모니터 자동 소등 및 연결 해제·비정상 종료 시 자동 복원 세이프가드 내장

* **초저지연 화면 캡처 및 하드웨어 인코딩 (`ScreenCaptureKit` + `VideoToolbox`)**
  * `IOSurface` Zero-Copy 캡처 및 Apple Silicon 하드웨어 HEVC / H.264 인코딩 (`ThroughputMode` 터보, 멀티슬라이스, 저지연 VBV 제어)
  * 10-bit HDR10 (`PREFIX_SEI_NUT`) 및 YUV 4:4:4 크로마 서브샘플링 지원
  * 정지 화면 유휴 프레임 절감 및 적응형 FEC

* **무드라이버 시스템 오디오 (`CoreAudio`)**
  * BlackHole 등 별도 가상 오디오 드라이버 설치 없이 macOS 내장 CoreAudio 탭(`CATapDescription`)으로 시스템 오디오 즉시 캡처

* **재부팅 직후 로그인 화면 접속 (`LoginWindow`)**
  * 상단 메뉴바의 **로그인 화면에서 허용** (**Allow on Login Screen**) 옵션으로 `LoginWindow` 및 `Aqua` 세션을 함께 담당하는 LaunchAgent 등록 지원
  * *참고*: FileVault 디스크 암호화가 켜져 있으면 부팅 초기 EFI 잠금 해제 단계에서 대기하므로, 완전 무인 재부팅 시에도 원격 접속하려면 FileVault를 끄거나 `sudo fdesetup authrestart`로 재부팅해야 합니다.

* **macOS 네이티브 입력 처리**
  * 저지연 마우스·키보드(`한/영` 전환 포함), 클라이언트 트랙패드 핀치 줌(`Magnify`), 상단 메뉴바에서 관성 곡선을 선택할 수 있는 120Hz 연속 스크롤 지원
  * **VoidLink Apple Pencil 특화 연동**: 클라이언트 펜슬 모드(`Stylus` / `Touch` / `Mouse`) 자동 동기화, macOS 네이티브 타블렛 입력(필압·기울기·배럴 롤·에어 호버·더블탭 지우개·스퀴즈 우클릭) 및 손바닥 터치 차단(Palm Rejection) 지원

* **USB 유선 스트리밍 (`usbmuxd`)**
  * 별도 드라이버 설치 없이 macOS 기본 내장 `usbmuxd` 데몬을 통해 USB-C / Thunderbolt 케이블만으로 VoidLink 유선 연결 및 전용 USB 비디오 채널 지원 (iPad Wi-Fi를 끈 상태에서도 페어링·스트리밍·충전 동시 가능)

---

## 해상도 및 주사율 참고

기본형 Apple Silicon 단일 미디어 엔진은 초당 처리 픽셀 수에 하드웨어 상한(기본형 M4 기준 약 `8.95억 px/s`)이 있습니다.

| 해상도 / 주사율 | 비고 |
| :--- | :--- |
| `2752 × 2064 @ 120Hz` | `120 FPS` 풀 프레임 유지 (SDR / HDR / 4:4:4) |
| `2560 × 1440 @ 144Hz` | `144 FPS` 풀 프레임 유지 |
| `3840 × 2160` (4K) | `90–100 FPS` 안정 유지 (기본형 M4 기준 최대 약 `108 FPS`) |

## 지원 범위 및 참고 사항

* **macOS Apple Silicon (`arm64`) 전용**: 코드 경량화와 유지보수성을 위해 Windows, Linux 및 타 GPU 인코더 코드는 모두 제거되었습니다. Windows/Linux 호스트는 상위 프로젝트인 [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) 또는 [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo)를 사용해 주세요.
* **가상 게임패드 미지원**: macOS 커널 보안 정책상 별도의 DriverKit 가상 HID 특별 권한 없이는 소프트웨어 가상 컨트롤러 생성이 차단되어 있어 게임패드 입력은 지원하지 않습니다.

---

## 소스에서 직접 빌드하기 (macOS Apple Silicon)

### 의존성 설치
```bash
xcode-select --install
brew install cmake ninja pkg-config openssl@3 opus miniupnpc curl icu4c libwebp
```

### 컴파일
```bash
git clone --recursive https://github.com/Roguelogic/Vibepollo.git
cd Vibepollo

cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTS=OFF \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
cmake --build build --target sunshine -j"$(sysctl -n hw.ncpu)"
```

### 정식 서명 및 Apple 공증 패키징 (배포자용)
```bash
./scripts/notarize_macos.sh
```

---

## 크레딧 및 라이선스

* 기반 프로젝트: [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo), [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo), [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
* 라이선스: [GPL-3.0](LICENSE)
