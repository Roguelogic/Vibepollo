import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
  case monitor
  case general
  case display
  case video
  case inputAudio
  case networkSystem
  case devices
  case apps

  var id: String { rawValue }

  static let monitorGroup: [SidebarSection] = [.monitor]
  static let settingsGroup: [SidebarSection] = [.general, .display, .video, .inputAudio, .networkSystem]
  static let clientGroup: [SidebarSection] = [.devices, .apps]

  var symbolName: String {
    switch self {
    case .monitor: return "waveform.path.ecg"
    case .general: return "gearshape.fill"
    case .display: return "sun.max.fill"
    case .video: return "film.fill"
    case .inputAudio: return "magicmouse.fill"
    case .networkSystem: return "network"
    case .devices: return "ipad.and.iphone"
    case .apps: return "square.stack.3d.up.fill"
    }
  }

  var badgeTint: Color {
    switch self {
    case .monitor: return .green
    case .general: return .gray
    case .display: return .blue
    case .video: return .cyan
    case .inputAudio: return .orange
    case .networkSystem: return .blue
    case .devices: return .blue
    case .apps: return .indigo
    }
  }
}

enum NavigationRoute: Equatable, Hashable {
  case section(SidebarSection)
  case softwareUpdate
  case hostAutomation
  case deviceDetail(String)
  case logs
  case telemetry

  var parentSection: SidebarSection {
    switch self {
    case .section(let sec): return sec
    case .softwareUpdate, .hostAutomation: return .general
    case .deviceDetail: return .devices
    case .logs: return .networkSystem
    case .telemetry: return .monitor
    }
  }
}

struct L10n {
  let isKo: Bool

  init(locale: String) {
    self.isKo = locale.lowercased().hasPrefix("ko")
  }

  func pick(_ ko: String, _ en: String) -> String {
    isKo ? ko : en
  }

  func sectionTitle(_ section: SidebarSection) -> String {
    switch section {
    case .monitor: return pick("모니터", "Monitor")
    case .general: return pick("일반", "General")
    case .display: return pick("디스플레이", "Displays")
    case .video: return pick("화질 및 인코더", "Video & Encoder")
    case .inputAudio: return pick("입력 및 오디오", "Input & Audio")
    case .networkSystem: return pick("네트워크 및 로그", "Network & Logs")
    case .devices: return pick("연결된 기기", "Devices")
    case .apps: return pick("스트리밍 앱", "Applications")
    }
  }

  func sectionKeywords(_ section: SidebarSection) -> [String] {
    switch section {
    case .monitor:
      return ["모니터", "상태", "리소스", "성능", "cpu", "gpu", "메모리", "ram", "네트워크", "인코더", "인코딩", "스펙", "하드웨어", "지연", "레이턴시", "fps", "비트레이트", "지터", "idr", "세션", "기록", "이력", "통계", "monitor", "activity", "resource", "memory", "network", "encoder", "spec", "latency", "bitrate", "jitter", "history", "telemetry", "stats"]
    case .general:
      return ["일반", "언어", "한국어", "호스트", "이름", "로그인", "시동", "권한", "화면 기록", "손쉬운 사용", "원격 입력", "소프트웨어 업데이트", "자동 업데이트", "베타 업데이트", "버전", "업데이트", "재시작", "자동화", "준비 명령어", "상태 명령어", "서버 명령어", "포커스", "인증서", "경로", "프리릴리스", "general", "language", "login", "permission", "accessibility", "screen", "software update", "automatic updates", "beta updates", "version", "update", "automation", "focus", "cert"]
    case .display:
      return ["디스플레이", "모니터", "가상", "해상도", "레티나", "hidpi", "배율", "배치", "덮개", "클램셸", "hdr", "일시정지", "원격 모니터", "대체 해상도", "고급", "display", "retina", "scale", "lid", "clamshell", "fallback"]
    case .video:
      return ["화질", "인코더", "인코딩", "스펙", "비디오", "비트레이트", "hevc", "av1", "h264", "4:4:4", "hdr", "프레임", "fps", "fec", "videotoolbox", "소프트웨어", "cabac", "cavlc", "qp", "스레드", "프리셋", "페이싱", "고급", "video", "bitrate", "encoder", "spec"]
    case .inputAudio:
      return ["입력", "오디오", "사운드", "트랙패드", "팜 리젝션", "손바닥", "스크롤", "관성", "펜슬", "pencil", "키보드", "마우스", "키 반복", "바인딩", "opus", "ac3", "eac3", "돌비", "싱크", "input", "audio", "scroll", "palm"]
    case .networkSystem:
      return ["네트워크", "검색", "bonjour", "페어링", "비밀번호", "계정", "포트", "upnp", "웹", "콘솔", "암호화", "lan", "wan", "ipv6", "바인딩", "외부 ip", "타임아웃", "패킷", "로그", "고급", "network", "discovery", "password", "port", "encryption", "log"]
    case .devices:
      return ["기기", "클라이언트", "페어링", "pin", "아이패드", "권한", "절전", "명령어", "연결 해제", "덮어쓰기", "override", "device", "client", "pair", "sleep", "ipad"]
    case .apps:
      return ["앱", "애플리케이션", "선택", "불러오기", "데스크톱", "게임", "명령어", "steam", "스팀", "동기화", "덮어쓰기", "app", "desktop"]
    }
  }
}
