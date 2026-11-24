import Foundation

struct ActiveStreamSession: Codable, Identifiable, Equatable {
  var uuid: String
  var deviceName: String
  var width: Int
  var height: Int
  var fps: Int
  var bitrateKbps: Int
  var codec: String
  var hdr: Bool
  var bitDepth: Int
  var yuv444: Bool
  var directUsb: Bool
  var encodeLatencyMs: Double
  var captureToSubmitP95Ms: Double?
  var encodeP95Ms: Double?
  var completeToSendP95Ms: Double?
  var framesSent: UInt64
  var losses: Int64
  var uptimeSeconds: Double

  var id: String { uuid.isEmpty ? deviceName : uuid }
}

struct HostStatsSnapshot: Codable, Equatable {
  var cpuPercent: Double
  var gpuPercent: Double
  var ramUsedGB: Double
  var ramTotalGB: Double
  var cpuModel: String
  var gpuModel: String

  static let empty = HostStatsSnapshot(
    cpuPercent: -1,
    gpuPercent: -1,
    ramUsedGB: -1,
    ramTotalGB: -1,
    cpuModel: "",
    gpuModel: ""
  )
}

struct DashboardSnapshot: Codable, Equatable {
  var version: String
  var hostName: String
  var locale: String
  var virtualDisplayMode: String
  var pairedCount: Int
  var appRunning: Bool
  var runningAppName: String
  var sessions: [ActiveStreamSession]
  var hostStats: HostStatsSnapshot
  var screenCaptureAllowed: Bool
  var accessibilityAllowed: Bool
  var deferredReloadPending: Bool
  var updateAvailable: Bool
  var availableUpdateVersion: String

  static let empty = DashboardSnapshot(
    version: "",
    hostName: "",
    locale: "ko",
    virtualDisplayMode: "per_client",
    pairedCount: 0,
    appRunning: false,
    runningAppName: "",
    sessions: [],
    hostStats: .empty,
    screenCaptureAllowed: true,
    accessibilityAllowed: true,
    deferredReloadPending: false,
    updateAvailable: false,
    availableUpdateVersion: ""
  )
}

struct SoftwareUpdateSnapshot: Codable, Equatable {
  var phase: String
  var currentVersion: String
  var currentChannel: String
  var currentCommit: String
  var availableVersion: String
  var availableName: String
  var availableUrl: String
  var availableBody: String
  var availablePublishedAt: String
  var isPrerelease: Bool
  var assetName: String
  var assetSize: Int64
  var downloadedBytes: Int64
  var totalBytes: Int64
  var lastCheckedUnix: Int64
  var scheduledOnIdle: Bool
  var checkInProgress: Bool
  var canSelfUpdate: Bool
  var bundlePath: String
  var bundleReason: String
  var errorCode: String
  var errorDetail: String

  var isBusy: Bool {
    checkInProgress || ["checking", "downloading", "verifying", "installing", "restarting"].contains(phase)
  }

  var hasAvailableUpdate: Bool {
    !availableVersion.isEmpty && ["available", "downloading", "verifying", "downloaded", "installing", "restarting"].contains(phase)
  }

  static let empty = SoftwareUpdateSnapshot(
    phase: "idle",
    currentVersion: "",
    currentChannel: "stable",
    currentCommit: "",
    availableVersion: "",
    availableName: "",
    availableUrl: "",
    availableBody: "",
    availablePublishedAt: "",
    isPrerelease: false,
    assetName: "",
    assetSize: 0,
    downloadedBytes: 0,
    totalBytes: 0,
    lastCheckedUnix: 0,
    scheduledOnIdle: false,
    checkInProgress: false,
    canSelfUpdate: true,
    bundlePath: "",
    bundleReason: "",
    errorCode: "",
    errorDetail: ""
  )
}

struct SessionHistoryItem: Codable, Identifiable, Equatable {
  var uuid: String
  var protocolName: String
  var clientName: String
  var deviceName: String
  var appName: String
  var width: Int
  var height: Int
  var targetFps: Int
  var bitrateKbps: Int
  var codec: String
  var hdr: Bool
  var yuv444: Bool
  var startTimeUnix: Double
  var endTimeUnix: Double
  var durationSeconds: Double
  var verdict: String

  var id: String { uuid }

  enum CodingKeys: String, CodingKey {
    case uuid
    case protocolName = "protocol"
    case clientName
    case deviceName
    case appName
    case width
    case height
    case targetFps
    case bitrateKbps
    case codec
    case hdr
    case yuv444
    case startTimeUnix
    case endTimeUnix
    case durationSeconds
    case verdict
  }
}

struct ClientCommandEntry: Codable, Equatable, Identifiable {
  var id: UUID = UUID()
  var cmd: String
  var elevated: Bool

  enum CodingKeys: String, CodingKey {
    case cmd
    case elevated
  }

  init(id: UUID = UUID(), cmd: String = "", elevated: Bool = false) {
    self.id = id
    self.cmd = cmd
    self.elevated = elevated
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = UUID()
    self.cmd = (try? c.decode(String.self, forKey: .cmd)) ?? ""
    self.elevated = (try? c.decode(Bool.self, forKey: .elevated)) ?? false
  }
}

struct ServerCommandEntry: Codable, Equatable, Identifiable {
  var id: UUID = UUID()
  var name: String
  var cmd: String

  enum CodingKeys: String, CodingKey {
    case name
    case cmd
  }

  init(id: UUID = UUID(), name: String = "", cmd: String = "") {
    self.id = id
    self.name = name
    self.cmd = cmd
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = UUID()
    self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
    self.cmd = (try? c.decode(String.self, forKey: .cmd)) ?? ""
  }
}

struct PairedClientItem: Identifiable, Equatable, Hashable {
  var uuid: String
  var name: String
  var enabled: Bool
  var connected: Bool
  var lastSeen: Int64
  var perm: UInt32
  var allowSleep: Bool
  var allowClientCommands: Bool
  var enableLegacyOrdering: Bool
  var alwaysUseVirtualDisplay: Bool
  var virtualDisplayMode: String
  var virtualDisplayLayout: String
  var displayMode: String
  var outputNameOverride: String
  var prefer10BitSdr: Bool
  var doCommands: [ClientCommandEntry]
  var undoCommands: [ClientCommandEntry]
  var configOverrides: [String: String]

  var id: String { uuid }
  var configOverridesCount: Int { configOverrides.count }

  static func == (lhs: PairedClientItem, rhs: PairedClientItem) -> Bool {
    lhs.uuid == rhs.uuid &&
      lhs.name == rhs.name &&
      lhs.enabled == rhs.enabled &&
      lhs.connected == rhs.connected &&
      lhs.lastSeen == rhs.lastSeen &&
      lhs.perm == rhs.perm &&
      lhs.allowSleep == rhs.allowSleep &&
      lhs.allowClientCommands == rhs.allowClientCommands &&
      lhs.enableLegacyOrdering == rhs.enableLegacyOrdering &&
      lhs.alwaysUseVirtualDisplay == rhs.alwaysUseVirtualDisplay &&
      lhs.virtualDisplayMode == rhs.virtualDisplayMode &&
      lhs.virtualDisplayLayout == rhs.virtualDisplayLayout &&
      lhs.displayMode == rhs.displayMode &&
      lhs.outputNameOverride == rhs.outputNameOverride &&
      lhs.prefer10BitSdr == rhs.prefer10BitSdr &&
      lhs.doCommands == rhs.doCommands &&
      lhs.undoCommands == rhs.undoCommands &&
      lhs.configOverrides == rhs.configOverrides
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(uuid)
  }

  // Permission masks matching crypto::PERM in src/crypto.h
  static let maskList: UInt32 = 0x0100_0000
  static let maskView: UInt32 = 0x0200_0000
  static let maskLaunch: UInt32 = 0x0400_0000
  static let maskClipboardSet: UInt32 = 0x0001_0000
  static let maskClipboardRead: UInt32 = 0x0002_0000
  static let maskServerCmd: UInt32 = 0x0010_0000
  static let maskInputController: UInt32 = 0x0000_0100
  static let maskInputTouch: UInt32 = 0x0000_0200
  static let maskInputPen: UInt32 = 0x0000_0400
  static let maskInputMouse: UInt32 = 0x0000_0800
  static let maskInputKeyboard: UInt32 = 0x0000_1000
  static let maskAllInputs: UInt32 = 0x0000_1F00
  static let maskAllClipboard: UInt32 = 0x0003_0000

  func hasPerm(_ mask: UInt32) -> Bool {
    (perm & mask) == mask
  }

  mutating func setPerm(_ mask: UInt32, enabled: Bool) {
    if enabled {
      perm |= mask
    } else {
      perm &= ~mask
    }
  }
}

struct StreamAppPrepCmd: Codable, Equatable, Identifiable {
  var id: UUID = UUID()
  var doCmd: String
  var undoCmd: String

  enum CodingKeys: String, CodingKey {
    case doCmd = "do"
    case undoCmd = "undo"
  }

  init(id: UUID = UUID(), doCmd: String = "", undoCmd: String = "") {
    self.id = id
    self.doCmd = doCmd
    self.undoCmd = undoCmd
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = UUID()
    self.doCmd = (try? c.decode(String.self, forKey: .doCmd)) ?? ""
    self.undoCmd = (try? c.decode(String.self, forKey: .undoCmd)) ?? ""
  }
}

struct StreamAppItem: Codable, Identifiable, Equatable {
  var uuid: String = ""
  var name: String = ""
  var cmd: String = ""
  var workingDir: String = ""
  var autoDetach: Bool = true
  var waitAll: Bool = true
  var terminateOnPause: Bool = false
  var virtualScreen: Bool = false
  var prefer10BitSdr: Bool = false
  var excludeGlobalPrepCmd: Bool = false
  var exitTimeout: Int = 5
  var isSystem: Bool = false
  var detached: [String] = []
  var configOverrides: [String: String] = [:]
  var prepCmds: [StreamAppPrepCmd] = []

  var id: String { uuid.isEmpty ? name : uuid }
}

struct HostSettingsState: Equatable {
  // General, Identity, Automation & Files
  var locale: String = "ko"
  var sunshineName: String = ""
  var minLogLevel: Int = 2
  var opensAtLogin: Bool = false
  var allowOnLoginScreen: Bool = false
  var lidCloseEndsStreams: Bool = true
  var updateCheckInterval: Int = 86400
  var notifyPreReleases: Bool = true
  var autoDownloadUpdates: Bool = true
  var autoInstallUpdates: Bool = true
  var hideTrayControls: Bool = false
  var envvarCompatibilityMode: Bool = false
  var legacyOrdering: Bool = false

  var appFocusAttempts: Int = 3
  var appFocusTimeoutSecs: Int = 15
  var appFocusExitOnFirst: Bool = false
  var globalPrepCmds: [StreamAppPrepCmd] = []
  var globalStateCmds: [StreamAppPrepCmd] = []
  var serverCmds: [ServerCommandEntry] = []

  var credentialsFile: String = ""
  var fileState: String = ""
  var vibeshineFileState: String = ""
  var fileApps: String = ""
  var logPath: String = ""
  var pkey: String = ""
  var cert: String = ""

  // Display & Remote Monitor
  var virtualDisplayMode: String = "per_client"
  var virtualDisplayLayout: String = "exclusive"
  var virtualDisplayScale: Int = 0
  var keepDisplayWhilePaused: Bool = true
  var pausedDisplayTimeoutSecs: Int = 7200
  var hdrRequestOverride: String = "auto"
  var virtualDisplayMaxClients: Int = 4
  var outputName: String = ""
  var fallbackMode: String = "1920x1080x60"
  var remoteMonitorConfirmAppReplacement: Bool = true
  var remoteMonitorMuteAudio: Bool = false
  var remoteMonitorDisconnectOnStreamEnd: Bool = false

  // Video & Encoder
  var encoder: String = ""
  var maxBitrateKbps: Int = 0
  var minimumFpsTarget: Double = 20.0
  var hevcMode: Int = 0
  var av1Mode: Int = 0
  var fecPercentage: Int = 20
  var videoMaxBatchSizeKb: Int = 64
  var pyrowave: Bool = true
  var hostAdaptivePacing: Bool = false
  var ignoreEncoderProbeFailure: Bool = false

  var vtRealtime: Bool = true
  var vtCoder: String = "auto"
  var vtSoftware: String = "auto"

  var swPreset: String = "superfast"
  var swTune: String = "zerolatency"
  var qp: Int = 28
  var minThreads: Int = 2

  // Input & Audio
  var keyboard: Bool = true
  var mouse: Bool = true
  var controller: Bool = true
  var enableInputOnlyMode: Bool = false
  var forwardRumble: Bool = true
  var motionAsDs4: Bool = true
  var touchpadAsDs4: Bool = true
  var ds4BackAsTouchpadClick: Bool = false
  var alwaysSendScancodes: Bool = true
  var keyRightAltToKeyWin: Bool = false
  var backButtonTimeout: Int = -1
  var guideButtonKey: Int = 0
  var guideButtonController: Int = 0
  var keyRepeatDelay: Int = 500
  var keyRepeatFrequency: Double = 24.9
  var keybindings: String = ""

  var scrollInertia: String = "macos"
  var pencilMode: String = "auto"
  var palmRejection: Bool = true
  var highResScrolling: Bool = true
  var nativePenTouch: Bool = true

  var streamAudio: Bool = true
  var audioFormat: String = "opus"
  var highQualityAudio: Bool = false
  var keepSinkDefault: Bool = true
  var autoCaptureSink: Bool = true
  var audioSink: String = ""
  var virtualSink: String = ""

  // Network, Security & Session History
  var port: Int = 47989
  var addressFamily: String = "ipv4"
  var upnp: Bool = false
  var enableDiscovery: Bool = true
  var enablePairing: Bool = true
  var webUsername: String = ""
  var originWebUiAllowed: String = "lan"
  var bindAddress: String = ""
  var externalIp: String = ""
  var pingTimeout: Int = 10000
  var controlPeerTimeout: Int = 0
  var pacingMaxBitrateKbps: Int = 0
  var packetsize: Int = 0
  var lanEncryptionMode: Int = 0
  var wanEncryptionMode: Int = 1
  var sessionTokenTtlSeconds: Int = 7200
  var rememberMeRefreshTokenTtlSeconds: Int = 604800
  var csrfAllowedOrigins: String = ""

  var sessionHistoryEnabled: Bool = true
  var sessionHistoryTtlDays: Int = 0
  var sessionHistoryDbSizeLimitMb: Int = 0
  var hardwareMetrics: Bool = false
  var hardwareMetricsInterval: Int = 1000
  var realtimeStatsEnabled: Bool = true
  var realtimeStatsPollIntervalMs: Int = 2000

  // Steam Integration
  var steamEnabled: Bool = false
  var steamAutoSync: Bool = false
  var steamSyncAllInstalled: Bool = false
  var steamRecentGames: Int = 10
  var steamRecentMaxAgeDays: Int = 30
  var steamAutosyncRemoveUninstalled: Bool = true
  var steamIncludeTools: Bool = false
}

enum OverrideableSettingCatalog {
  static let keys: [String] = [
    "max_bitrate",
    "minimum_fps_target",
    "fec_percentage",
    "hevc_mode",
    "encoder",
    "vt_realtime",
    "vt_software",
    "vt_coder",
    "sw_preset",
    "sw_tune",
    "qp",
    "min_threads",
    "video_max_batch_size_kb",
    "dd_virtual_display_scale",
    "dd_hdr_request_override",
    "dd_paused_virtual_display_timeout_secs",
    "macos_scroll_inertia",
    "macos_pencil_mode",
    "macos_palm_rejection",
    "high_resolution_scrolling",
    "native_pen_touch",
    "keyboard",
    "mouse",
    "key_repeat_delay",
    "key_repeat_frequency",
    "key_rightalt_to_key_win",
    "keybindings",
    "stream_audio",
    "audio_sink",
  ]
}
