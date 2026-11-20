# Vibepollo (macOS)

**[English](README.md) | [한국어](README.ko.md)**

Apple Silicon 맥과 iPad / Moonlight 클라이언트 환경의 macOS 호스트 지원을 보완한 [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) ([Apollo](https://github.com/ClassicOldSong/Apollo) · [Sunshine](https://github.com/LizardByte/Sunshine) 기반) 포크입니다.

## 주요 기능 (macOS)

* **가상 디스플레이 (`CGVirtualDisplay`)**
  * 클라이언트 해상도와 주사율에 맞춘 Retina HiDPI 및 HDR 가상 모니터 생성
  * 더미 플러그 없는 헤드리스(Headless) 맥 미니 구동 지원
  * 스트리밍 중 물리 모니터 소등 및 세션 종료 시 자동 복원

* **화면 캡처 및 인코딩 (`ScreenCaptureKit` + `VideoToolbox`)**
  * `IOSurface` Zero-Copy 캡처 및 하드웨어 HEVC / H.264 인코딩
  * 10-bit HDR10 및 YUV 4:4:4 지원
  * 정지 화면에서의 유휴 전송량 절감 및 네트워크 상태에 따른 적응형 FEC

* **입력 (iPad, 트랙패드, Apple Pencil)**
  * **Apple Pencil 모드 전환** (상단 메뉴바에서 실시간 선택):
    * *Scroll & Tap*: 데스크톱 커서 위치를 유지한 채 스크롤, 탭 클릭, 창 드래그, 호버 포인터 표시
    * *Drawing Tablet*: 필압, 기울기, 회전, 호버를 전달하는 macOS 네이티브 타블렛 이벤트 입력
  * **트랙패드 스크롤**: 120Hz 연속 스크롤 및 메뉴바에서의 MacBook / iPadOS 관성 곡선 선택
  * **키보드**: iPad 매직 키보드의 `한/영`(Caps Lock) 및 지구본 키 입력 소스 전환 지원

* **시스템 오디오**
  * 별도 가상 오디오 드라이버(BlackHole 등) 없이 CoreAudio 탭으로 시스템 오디오 직접 캡처

## 해상도 및 주사율 참고

기본형 Apple Silicon의 단일 미디어 엔진은 초당 처리 가능한 픽셀 수에 하드웨어 상한(M4 기준 약 `8.95억 px/s`)이 있습니다.

| 해상도 / 주사율 | 비고 |
| :--- | :--- |
| `2752 × 2064 @ 120Hz` (iPad Pro 13") | `120 FPS` 유지 (SDR / HDR / 4:4:4) |
| `2560 × 1440 @ 144Hz` | `144 FPS` 유지 |
| `3840 × 2160` (4K) | `90–100 FPS` 안정 유지 (기본형 M4 기준 최대 약 `108 FPS`) |

## 빌드 및 실행 (macOS Apple Silicon)

### 의존성 설치
```bash
xcode-select --install
brew install cmake ninja pkg-config openssl@3 opus miniupnpc curl icu4c
```

### 빌드
```bash
git clone --recursive https://github.com/Roguelogic/Vibepollo.git
cd Vibepollo

cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
ninja -C build
```

### 설치 및 권한 설정
1. `build/Vibepollo.app`을 `/Applications/Vibepollo.app`으로 복사 후 실행합니다.
2. **시스템 설정 → 개인정보 보호 및 보안**에서 아래 권한을 허용합니다.
   * **화면 및 시스템 오디오 녹음**
   * **손쉬운 사용 (Accessibility)**

*(선택)* 키체인 접근에서 로컬 자체 서명 인증서를 만들어 앱에 서명해 두면 재빌드 시 권한이 초기화되지 않습니다.

## Windows 및 Linux

상위 저장소인 [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo)의 Windows 및 Linux 코드는 그대로 포함되어 있습니다.

## 크레딧 및 라이선스

* 기반 프로젝트: [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo), [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo), [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
* 라이선스: [GPL-3.0](LICENSE)
