# Vibepollo (macOS)

**[English](README.md) | [한국어](README.ko.md)**

**Apple Silicon 맥(`arm64`)** 전용으로 독립 경량화된 원격 데스크톱·스트리밍 호스트입니다. **iPad (VoidLink / Moonlight)**, **Magic Keyboard**, **Apple Pencil**을 이용한 원격 데스크톱 작업에 최적화되어 있습니다.  
[Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) ([Apollo](https://github.com/ClassicOldSong/Apollo) · [Sunshine](https://github.com/LizardByte/Sunshine) 기반)에서 포크하여 Windows/Linux 레거시를 제거하고 macOS 네이티브 단일 앱 구조로 재설계했습니다.

## 다운로드 및 설치 (권장)

1. **[GitHub Releases](https://github.com/Roguelogic/Vibepollo/releases/latest)** 에서 최신 **`Vibepollo-macOS-arm64.dmg`** 를 다운로드합니다.  
   *(Apple Developer ID 정식 서명 및 Apple 공증 완료 — Gatekeeper 차단 경고 없이 바로 실행 가능)*
2. DMG를 열고 **`Vibepollo.app`** 을 **`응용 프로그램(/Applications)`** 폴더로 옮긴 뒤 실행합니다.
3. **시스템 설정 → 개인정보 보호 및 보안**에서 아래 두 권한을 허용합니다:
   * **화면 및 시스템 오디오 녹음**
   * **손쉬운 사용 (Accessibility)**
4. 상단 메뉴바 아이콘에서 **Configure**를 누르거나 브라우저에서 `https://localhost:47990` 에 접속해 초기 관리자 계정을 설정하고 iPad(VoidLink / Moonlight)와 페어링합니다.

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

* **iPad · 매직 키보드 · Apple Pencil 특화 입력**
  * **Apple Pencil 모드 실시간 전환** (상단 메뉴바에서 선택):
    * *Scroll & Tap*: 데스크톱 마우스 커서 위치를 어지럽히지 않고 스크롤, 탭 클릭, 창 이동 드래그, 에어 호버 포인터 표시
    * *Drawing Tablet*: 필압, 기울기, 회전, 에어 호버를 전달하는 macOS 네이티브 타블렛 이벤트 입력
  * **트랙패드 스크롤**: 120Hz 연속 스크롤, 메뉴바 **MacBook / iPadOS 관성 곡선** 선택, 가로 화면비 감도 보정 및 VoidLink / Moonlight-iOS 좌우 스크롤 프레임 유실·속도 복원 엔진 내장
  * **키보드**: iPad 매직 키보드의 `한/영`(Caps Lock) 및 지구본 키 입력 소스 전환 지원

* **무드라이버 시스템 오디오**
  * BlackHole 등 별도 가상 오디오 드라이버 설치 없이 macOS 내장 CoreAudio 탭(`CATapDescription`)으로 시스템 오디오 즉시 캡처

* **재부팅 직후 로그인 화면 접속 (`LoginWindow`)**
  * 상단 메뉴바의 **Allow on Login Screen** 옵션으로 `LoginWindow` 및 `Aqua` 세션을 함께 담당하는 LaunchAgent 등록 지원
  * *참고*: FileVault 디스크 암호화가 켜져 있으면 부팅 초기 EFI 잠금 해제 단계에서 대기하므로, 완전 무인 재부팅 시에도 원격 접속하려면 FileVault를 끄거나 `sudo fdesetup authrestart`로 재부팅해야 합니다.

---

## 해상도 및 주사율 참고

기본형 Apple Silicon 단일 미디어 엔진은 초당 처리 픽셀 수에 하드웨어 상한(기본형 M4 기준 약 `8.95억 px/s`)이 있습니다.

| 해상도 / 주사율 | 비고 |
| :--- | :--- |
| `2752 × 2064 @ 120Hz` (iPad Pro 13") | `120 FPS` 풀 프레임 유지 (SDR / HDR / 4:4:4) |
| `2560 × 1440 @ 144Hz` | `144 FPS` 풀 프레임 유지 |
| `3840 × 2160` (4K) | `90–100 FPS` 안정 유지 (기본형 M4 기준 최대 약 `108 FPS`) |

## 지원 범위 및 참고 사항

* **macOS Apple Silicon (`arm64`) 전용**: 코드 경량화와 유지보수성을 위해 Windows, Linux 및 타 GPU 인코더 코드는 모두 제거되었습니다. Windows/Linux 호스트는 상위 프로젝트인 [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) 또는 [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo)를 사용해 주세요.
* **가상 게임패드 미지원**: macOS 커널 보안 정책상 별도의 DriverKit 가상 HID 특별 권한 없이는 소프트웨어 가상 컨트롤러 생성이 차단되어 있어 게임패드 입력은 지원하지 않습니다.
* **macOS 앱 스토어 가로 선반**: `App Store.app` 내부 배너/선반은 실물 멀티터치 하드웨어 제스처(`trackSwipeEvent`)만 허용하므로 커서를 올려 양쪽 `<` / `>` 화살표 버튼으로 넘겨 주세요.

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
