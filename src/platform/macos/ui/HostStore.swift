import Combine
import Foundation

@MainActor
final class HostStore: ObservableObject {
  static let shared = HostStore()

  @Published private(set) var currentRoute: NavigationRoute = .section(.general)
  @Published private(set) var backStack: [NavigationRoute] = []
  @Published private(set) var forwardStack: [NavigationRoute] = []

  @Published var searchQuery: String = ""
  @Published var showPinSheet: Bool = false
  @Published var dashboard: DashboardSnapshot = .empty
  @Published var softwareUpdate: SoftwareUpdateSnapshot = .empty
  @Published var clients: [PairedClientItem] = []
  @Published var apps: [StreamAppItem] = []
  @Published var sessionHistory: [SessionHistoryItem] = []
  @Published var settings: HostSettingsState = HostSettingsState()
  @Published var statusBanner: String?
  @Published var restartRequired: Bool = false
  @Published var logsText: String = ""
  @Published var steamInstalled: Bool = false

  // Bounded 30-sample (~60s at 2s polling) live ring buffers for Monitor sparklines.
  @Published var cpuHistory: [Double] = []
  @Published var gpuHistory: [Double] = []
  @Published var ramHistory: [Double] = []
  @Published var netTxHistory: [Double] = []
  @Published var streamFpsHistory: [Double] = []
  @Published var streamEncodeMsHistory: [Double] = []

  private static let maxHistorySamples = 30
  private var lastTrackedSessionUUID: String?

  private var pollTimer: Timer?
  private var fastUpdateTimer: Timer?
  private var bannerDismissTask: Task<Void, Never>?
  private var settingsLoadedOnce = false

  var isMonitorRoute: Bool {
    currentRoute == .telemetry
  }

  var l10n: L10n {
    L10n(locale: settings.locale.isEmpty ? dashboard.locale : settings.locale)
  }

  var selectedSection: SidebarSection {
    currentRoute.parentSection
  }

  var canGoBack: Bool { !backStack.isEmpty }
  var canGoForward: Bool { !forwardStack.isEmpty }

  var currentWindowTitle: String {
    switch currentRoute {
    case .section(let sec):
      return l10n.sectionTitle(sec)
    case .softwareUpdate:
      return l10n.pick("소프트웨어 업데이트", "Software Update")
    case .hostAutomation:
      return l10n.pick("호스트 자동화 및 명령어", "Host Automation & Commands")
    case .deviceDetail(let uuid):
      return clients.first(where: { $0.uuid == uuid })?.name ?? l10n.sectionTitle(.devices)
    case .logs:
      return l10n.pick("시스템 로그", "System Logs")
    case .telemetry:
      return l10n.pick("세션 기록 및 통계", "Session History & Stats")
    }
  }

  private init() {}

  func navigate(to route: NavigationRoute) {
    guard route != currentRoute else { return }
    backStack.append(currentRoute)
    if backStack.count > 32 {
      backStack.removeFirst()
    }
    forwardStack.removeAll()
    currentRoute = route
    if isMonitorRoute {
      refreshLiveState()
    } else if route == .softwareUpdate {
      refreshSoftwareUpdate()
    } else {
      syncFastUpdatePolling()
    }
  }

  func selectSidebar(_ section: SidebarSection) {
    navigate(to: .section(section))
  }

  func goBack() {
    guard let prev = backStack.popLast() else { return }
    forwardStack.append(currentRoute)
    currentRoute = prev
    if isMonitorRoute {
      refreshLiveState()
    } else if prev == .softwareUpdate {
      refreshSoftwareUpdate()
    } else {
      syncFastUpdatePolling()
    }
  }

  func goForward() {
    guard let next = forwardStack.popLast() else { return }
    backStack.append(currentRoute)
    currentRoute = next
    if isMonitorRoute {
      refreshLiveState()
    } else if next == .softwareUpdate {
      refreshSoftwareUpdate()
    } else {
      syncFastUpdatePolling()
    }
  }

  func popToSectionRoot(_ section: SidebarSection) {
    forwardStack.removeAll()
    currentRoute = .section(section)
    syncFastUpdatePolling()
  }

  func startWindowSession(initialRoute: String?) {
    bannerDismissTask?.cancel()
    bannerDismissTask = nil
    statusBanner = nil
    refreshAll()
    if !settingsLoadedOnce {
      loadSettings()
      settingsLoadedOnce = true
    }
    handleRoute(initialRoute)
    syncFastUpdatePolling()

    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshLiveState()
      }
    }
  }

  func stopWindowSession() {
    pollTimer?.invalidate()
    pollTimer = nil
    fastUpdateTimer?.invalidate()
    fastUpdateTimer = nil
    bannerDismissTask?.cancel()
    bannerDismissTask = nil
    statusBanner = nil
    showPinSheet = false
    searchQuery = ""
    logsText = ""
    sessionHistory.removeAll()
    clients.removeAll()
    apps.removeAll()
    backStack.removeAll()
    forwardStack.removeAll()
    cpuHistory.removeAll()
    gpuHistory.removeAll()
    ramHistory.removeAll()
    netTxHistory.removeAll()
    streamFpsHistory.removeAll()
    streamEncodeMsHistory.removeAll()
    lastTrackedSessionUUID = nil
  }

  func handleRoute(_ route: String?) {
    guard let route = route?.trimmingCharacters(in: .whitespacesAndNewlines), !route.isEmpty else {
      return
    }
    let lower = route.lowercased()
    if lower.contains("pin") || lower.contains("pair") {
      navigate(to: .section(.devices))
      showPinSheet = true
    } else if lower.contains("monitor") || lower.contains("telemetry") || lower.contains("stats") {
      navigate(to: .telemetry)
    } else if lower.contains("update") {
      navigate(to: .softwareUpdate)
    } else if lower.contains("device") || lower.contains("client") {
      navigate(to: .section(.devices))
    } else if lower.contains("app") || lower.contains("library") || lower.contains("steam") {
      navigate(to: .section(.apps))
    } else if lower.contains("display") {
      navigate(to: .section(.display))
    } else if lower.contains("log") {
      navigate(to: .logs)
    } else if lower.contains("network") {
      navigate(to: .section(.networkSystem))
    } else if lower.contains("setting") || lower.contains("config") {
      navigate(to: .section(.general))
    }
  }

  func refreshAll() {
    refreshLiveState()
    loadApps()
    loadSettings()
    steamInstalled = VibepolloHostBridge.shared().isSteamAvailable()
  }

  private static func appendBounded(_ value: Double, to buffer: inout [Double]) {
    buffer.append(value)
    if buffer.count > maxHistorySamples {
      buffer.removeFirst(buffer.count - maxHistorySamples)
    }
  }

  func refreshLiveState() {
    let wantHostStats = isMonitorRoute
    let snapJSON = VibepolloHostBridge.shared().fetchDashboardSnapshotJSON(
      includeHostStats: wantHostStats
    )
    if let data = snapJSON.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(DashboardSnapshot.self, from: data) {
      if self.dashboard != decoded {
        self.dashboard = decoded
      }
      if wantHostStats {
        let hs = decoded.hostStats
        if hs.cpuPercent >= 0 {
          Self.appendBounded(min(max(hs.cpuPercent, 0), 100), to: &cpuHistory)
        }
        if hs.gpuPercent >= 0 {
          Self.appendBounded(min(max(hs.gpuPercent, 0), 100), to: &gpuHistory)
        }
        if hs.ramUsedGB > 0 && hs.ramTotalGB > 0 {
          let pct = min(max((hs.ramUsedGB / hs.ramTotalGB) * 100.0, 0), 100)
          Self.appendBounded(pct, to: &ramHistory)
        }
        if let tx = hs.netTxMbps, tx >= 0 {
          Self.appendBounded(tx, to: &netTxHistory)
        }
        if let first = decoded.sessions.first {
          if lastTrackedSessionUUID != first.uuid {
            streamFpsHistory.removeAll()
            streamEncodeMsHistory.removeAll()
            lastTrackedSessionUUID = first.uuid
          }
          if let fps = first.actualFps, fps >= 0 {
            Self.appendBounded(fps, to: &streamFpsHistory)
          }
          let encMs = first.encodeP95Ms ?? first.encodeLatencyMs
          if encMs > 0 {
            Self.appendBounded(encMs, to: &streamEncodeMsHistory)
          }
        } else if lastTrackedSessionUUID != nil {
          streamFpsHistory.removeAll()
          streamEncodeMsHistory.removeAll()
          lastTrackedSessionUUID = nil
        }
      }
      if decoded.sessions.isEmpty || !decoded.deferredReloadPending {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        if statusBanner != nil {
          statusBanner = nil
        }
      }
    }
    refreshSoftwareUpdate()
    loadClients()
  }

  func refreshSoftwareUpdate() {
    let raw = VibepolloHostBridge.shared().fetchSoftwareUpdateStatusJSON()
    if let data = raw.data(using: .utf8),
       let decoded = try? JSONDecoder().decode(SoftwareUpdateSnapshot.self, from: data) {
      if self.softwareUpdate != decoded {
        self.softwareUpdate = decoded
      }
      if decoded.hasAvailableUpdate != dashboard.updateAvailable ||
         (decoded.hasAvailableUpdate && decoded.availableVersion != dashboard.availableUpdateVersion) {
        dashboard.updateAvailable = decoded.hasAvailableUpdate
        dashboard.availableUpdateVersion = decoded.hasAvailableUpdate ? decoded.availableVersion : ""
      }
    }
    syncFastUpdatePolling()
  }

  private func syncFastUpdatePolling() {
    let needsFastPoll = softwareUpdate.isBusy
    if needsFastPoll {
      guard fastUpdateTimer == nil else { return }
      fastUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.refreshSoftwareUpdate()
        }
      }
    } else {
      fastUpdateTimer?.invalidate()
      fastUpdateTimer = nil
    }
  }

  func checkForUpdatesNow() {
    VibepolloHostBridge.shared().checkForUpdates()
    refreshSoftwareUpdate()
  }

  func installUpdateNow() {
    VibepolloHostBridge.shared().startSoftwareUpdateNow()
    refreshSoftwareUpdate()
  }

  func cancelUpdateDownload() {
    VibepolloHostBridge.shared().cancelSoftwareUpdateDownload()
    refreshSoftwareUpdate()
  }

  func setUpdateScheduledOnIdle(_ scheduled: Bool) {
    VibepolloHostBridge.shared().setSoftwareUpdateScheduledOnIdle(scheduled)
    refreshSoftwareUpdate()
  }

  func openExternalURL(_ urlString: String) {
    VibepolloHostBridge.shared().openExternalURL(urlString)
  }

  func loadClients() {
    let raw = VibepolloHostBridge.shared().fetchClientsJSON()
    guard let data = raw.data(using: .utf8),
          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
      return
    }
    let parsed: [PairedClientItem] = arr.compactMap { dict -> PairedClientItem? in
      guard let uuid = dict["uuid"] as? String, !uuid.isEmpty else { return nil }
      let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let enabled = (dict["enabled"] as? Bool) ?? true
      let connected = (dict["connected"] as? Bool) ?? false
      let lastSeen = (dict["last_seen"] as? NSNumber)?.int64Value ?? 0
      let perm = (dict["perm"] as? NSNumber)?.uint32Value ?? 0x071F_1F00
      let allowSleep = (dict["allow_sleep"] as? Bool) ?? false
      let allowCmds = (dict["allow_client_commands"] as? Bool) ?? true
      let legacyOrder = (dict["enable_legacy_ordering"] as? Bool) ?? true
      let alwaysVD = (dict["always_use_virtual_display"] as? Bool) ?? false
      let vdMode = (dict["virtual_display_mode"] as? String) ?? ""
      let vdLayout = (dict["virtual_display_layout"] as? String) ?? ""
      let displayMode = (dict["display_mode"] as? String) ?? ""
      let outputOverride = (dict["output_name_override"] as? String) ?? ""
      let prefer10Bit = (dict["prefer_10bit_sdr"] as? Bool) ?? false

      func parseCmds(_ key: String) -> [ClientCommandEntry] {
        guard let list = dict[key] as? [[String: Any]] else { return [] }
        return list.map { row in
          ClientCommandEntry(
            cmd: (row["cmd"] as? String) ?? "",
            elevated: (row["elevated"] as? Bool) ?? false
          )
        }
      }

      var overrides: [String: String] = [:]
      if let rawMap = dict["config_overrides"] as? [String: Any] {
        for (k, v) in rawMap where !k.isEmpty {
          if let s = v as? String {
            overrides[k] = s
          } else if let n = v as? NSNumber {
            overrides[k] = n.stringValue
          }
        }
      }

      return PairedClientItem(
        uuid: uuid,
        name: name.isEmpty ? "Client" : name,
        enabled: enabled,
        connected: connected,
        lastSeen: lastSeen,
        perm: perm,
        allowSleep: allowSleep,
        allowClientCommands: allowCmds,
        enableLegacyOrdering: legacyOrder,
        alwaysUseVirtualDisplay: alwaysVD,
        virtualDisplayMode: vdMode,
        virtualDisplayLayout: vdLayout,
        displayMode: displayMode,
        outputNameOverride: outputOverride,
        prefer10BitSdr: prefer10Bit,
        doCommands: parseCmds("do"),
        undoCommands: parseCmds("undo"),
        configOverrides: overrides
      )
    }
    if self.clients != parsed {
      self.clients = parsed
    }
  }

  func pairDevice(pin: String, name: String) async -> Bool {
    let trimmedPin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let ok = await Task.detached(priority: .userInitiated) {
      VibepolloHostBridge.shared().pair(withPIN: trimmedPin, deviceName: trimmedName)
    }.value
    refreshLiveState()
    return ok
  }

  @discardableResult
  func saveClient(_ client: PairedClientItem) -> Bool {
    let payload: [String: Any] = [
      "uuid": client.uuid,
      "name": client.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Client" : client.name,
      "enabled": client.enabled,
      "allow_sleep": client.allowSleep,
      "allow_client_commands": client.allowClientCommands,
      "enable_legacy_ordering": client.enableLegacyOrdering,
      "always_use_virtual_display": client.alwaysUseVirtualDisplay,
      "virtual_display_mode": client.virtualDisplayMode,
      "virtual_display_layout": client.virtualDisplayLayout,
      "display_mode": client.displayMode.trimmingCharacters(in: .whitespacesAndNewlines),
      "output_name_override": client.outputNameOverride.trimmingCharacters(in: .whitespacesAndNewlines),
      "prefer_10bit_sdr": client.prefer10BitSdr,
      "perm": client.perm,
      "config_overrides": client.configOverrides,
      "do": client.doCommands
        .filter { !$0.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { ["cmd": $0.cmd, "elevated": $0.elevated] },
      "undo": client.undoCommands
        .filter { !$0.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { ["cmd": $0.cmd, "elevated": $0.elevated] },
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else {
      return false
    }
    let ok = VibepolloHostBridge.shared().updateClient(withJSON: json)
    refreshLiveState()
    return ok
  }

  func renameClient(uuid: String, newName: String) -> Bool {
    let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    guard !trimmed.isEmpty, trimmed.lowercased() != "self",
          var target = clients.first(where: { $0.uuid == uuid }) else {
      return false
    }
    target.name = trimmed
    return saveClient(target)
  }

  func disconnectClient(uuid: String) {
    _ = VibepolloHostBridge.shared().disconnectClient(uuid)
    refreshLiveState()
  }

  func unpairClient(uuid: String) {
    _ = VibepolloHostBridge.shared().unpairClient(uuid)
    refreshLiveState()
  }

  func loadApps() {
    let raw = VibepolloHostBridge.shared().fetchAppsJSON()
    if let data = raw.data(using: .utf8),
       let decoded = try? JSONDecoder().decode([StreamAppItem].self, from: data) {
      self.apps = decoded
    }
  }

  func saveApp(_ app: StreamAppItem) -> String? {
    guard let data = try? JSONEncoder().encode(app),
          let json = String(data: data, encoding: .utf8) else {
      return "Encoding error"
    }
    var err: NSString?
    let ok = VibepolloHostBridge.shared().saveApp(withJSON: json, errorMessage: &err)
    loadApps()
    return ok ? nil : ((err as String?) ?? "Failed to save application")
  }

  func deleteApp(uuid: String) {
    _ = VibepolloHostBridge.shared().deleteApp(withUUID: uuid)
    loadApps()
  }

  func terminateRunningApp() {
    VibepolloHostBridge.shared().terminateRunningApp()
    refreshLiveState()
  }

  func syncSteamCatalog() -> Bool {
    let ok = VibepolloHostBridge.shared().syncSteamCatalogNow()
    steamInstalled = VibepolloHostBridge.shared().isSteamAvailable()
    loadApps()
    return ok
  }

  func reloadSessionHistory() {
    let raw = VibepolloHostBridge.shared().fetchSessionHistoryJSON(40)
    if let data = raw.data(using: .utf8),
       let decoded = try? JSONDecoder().decode([SessionHistoryItem].self, from: data) {
      self.sessionHistory = decoded
    }
  }

  func deleteSessionHistory(uuid: String) {
    _ = VibepolloHostBridge.shared().deleteSessionHistory(withUUID: uuid)
    reloadSessionHistory()
  }

  func loadSettings() {
    let raw = VibepolloHostBridge.shared().fetchSettingsJSON()
    guard let data = raw.data(using: .utf8),
          let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return
    }

    func s(_ key: String, _ def: String = "") -> String {
      (d[key] as? String) ?? def
    }
    func b(_ key: String, _ def: Bool) -> Bool {
      if let val = d[key] as? Bool { return val }
      if let num = d[key] as? NSNumber { return num.boolValue }
      return def
    }
    func i(_ key: String, _ def: Int) -> Int {
      (d[key] as? NSNumber)?.intValue ?? def
    }
    func dbl(_ key: String, _ def: Double) -> Double {
      (d[key] as? NSNumber)?.doubleValue ?? def
    }
    func parsePrepList(_ key: String) -> [StreamAppPrepCmd] {
      guard let arr = d[key] as? [[String: Any]] else { return [] }
      return arr.map { row in
        StreamAppPrepCmd(
          doCmd: (row["do"] as? String) ?? "",
          undoCmd: (row["undo"] as? String) ?? ""
        )
      }
    }
    func parseServerCmds(_ key: String) -> [ServerCommandEntry] {
      guard let arr = d[key] as? [[String: Any]] else { return [] }
      return arr.map { row in
        ServerCommandEntry(
          name: (row["name"] as? String) ?? "",
          cmd: (row["cmd"] as? String) ?? ""
        )
      }
    }

    var next = HostSettingsState()
    next.locale = s("locale", "ko")
    next.sunshineName = s("sunshineName")
    next.minLogLevel = i("minLogLevel", 2)
    next.opensAtLogin = b("opensAtLogin", false)
    next.allowOnLoginScreen = b("allowOnLoginScreen", false)
    next.lidCloseEndsStreams = b("lidCloseEndsStreams", true)
    next.updateCheckInterval = i("updateCheckInterval", 86400)
    next.notifyPreReleases = b("notifyPreReleases", true)
    next.autoDownloadUpdates = b("autoDownloadUpdates", true)
    next.autoInstallUpdates = b("autoInstallUpdates", true)
    next.hideTrayControls = b("hideTrayControls", false)
    next.envvarCompatibilityMode = b("envvarCompatibilityMode", false)
    next.legacyOrdering = b("legacyOrdering", false)

    next.appFocusAttempts = i("appFocusAttempts", 3)
    next.appFocusTimeoutSecs = i("appFocusTimeoutSecs", 15)
    next.appFocusExitOnFirst = b("appFocusExitOnFirst", false)
    next.globalPrepCmds = parsePrepList("globalPrepCmds")
    next.globalStateCmds = parsePrepList("globalStateCmds")
    next.serverCmds = parseServerCmds("serverCmds")

    next.credentialsFile = s("credentialsFile")
    next.fileState = s("fileState")
    next.vibeshineFileState = s("vibeshineFileState")
    next.fileApps = s("fileApps")
    next.logPath = s("logPath")
    next.pkey = s("pkey")
    next.cert = s("cert")

    next.virtualDisplayMode = s("virtualDisplayMode", "per_client")
    next.virtualDisplayLayout = s("virtualDisplayLayout", "exclusive")
    next.virtualDisplayScale = i("virtualDisplayScale", 0)
    next.keepDisplayWhilePaused = b("keepDisplayWhilePaused", true)
    next.pausedDisplayTimeoutSecs = i("pausedDisplayTimeoutSecs", 7200)
    next.hdrRequestOverride = s("hdrRequestOverride", "auto")
    next.virtualDisplayMaxClients = i("virtualDisplayMaxClients", 4)
    next.outputName = s("outputName")
    next.fallbackMode = s("fallbackMode", "1920x1080x60")
    next.remoteMonitorConfirmAppReplacement = b("remoteMonitorConfirmAppReplacement", true)
    next.remoteMonitorMuteAudio = b("remoteMonitorMuteAudio", false)
    next.remoteMonitorDisconnectOnStreamEnd = b("remoteMonitorDisconnectOnStreamEnd", false)

    next.encoder = s("encoder")
    next.maxBitrateKbps = i("maxBitrateKbps", 0)
    next.minimumFpsTarget = dbl("minimumFpsTarget", 20.0)
    next.hevcMode = i("hevcMode", 0)
    next.av1Mode = i("av1Mode", 0)
    next.fecPercentage = i("fecPercentage", 20)
    next.videoMaxBatchSizeKb = i("videoMaxBatchSizeKb", 64)
    next.pyrowave = b("pyrowave", true)
    next.hostAdaptivePacing = b("hostAdaptivePacing", false)
    next.ignoreEncoderProbeFailure = b("ignoreEncoderProbeFailure", false)
    next.vtRealtime = b("vtRealtime", true)
    next.vtCoder = s("vtCoder", "auto")
    next.vtSoftware = s("vtSoftware", "auto")
    next.swPreset = s("swPreset", "superfast")
    next.swTune = s("swTune", "zerolatency")
    next.qp = i("qp", 28)
    next.minThreads = i("minThreads", 2)

    next.keyboard = b("keyboard", true)
    next.mouse = b("mouse", true)
    next.controller = b("controller", true)
    next.enableInputOnlyMode = b("enableInputOnlyMode", false)
    next.forwardRumble = b("forwardRumble", true)
    next.motionAsDs4 = b("motionAsDs4", true)
    next.touchpadAsDs4 = b("touchpadAsDs4", true)
    next.ds4BackAsTouchpadClick = b("ds4BackAsTouchpadClick", false)
    next.alwaysSendScancodes = b("alwaysSendScancodes", true)
    next.keyRightAltToKeyWin = b("keyRightAltToKeyWin", false)
    next.backButtonTimeout = i("backButtonTimeout", -1)
    next.guideButtonKey = i("guideButtonKey", 0)
    next.guideButtonController = i("guideButtonController", 0)
    next.keyRepeatDelay = i("keyRepeatDelay", 500)
    next.keyRepeatFrequency = dbl("keyRepeatFrequency", 24.9)
    next.keybindings = s("keybindings")
    next.scrollInertia = s("scrollInertia", "macos")
    next.pencilMode = s("pencilMode", "auto")
    next.palmRejection = b("palmRejection", true)
    next.highResScrolling = b("highResScrolling", true)
    next.nativePenTouch = b("nativePenTouch", true)

    next.streamAudio = b("streamAudio", true)
    next.audioFormat = s("audioFormat", "opus")
    next.highQualityAudio = b("highQualityAudio", false)
    next.keepSinkDefault = b("keepSinkDefault", true)
    next.autoCaptureSink = b("autoCaptureSink", true)
    next.audioSink = s("audioSink")
    next.virtualSink = s("virtualSink")

    next.port = i("port", 47989)
    next.addressFamily = s("addressFamily", "ipv4")
    next.upnp = b("upnp", false)
    next.enableDiscovery = b("enableDiscovery", true)
    next.enablePairing = b("enablePairing", true)
    next.webUsername = s("webUsername")
    next.originWebUiAllowed = s("originWebUiAllowed", "lan")
    next.bindAddress = s("bindAddress")
    next.externalIp = s("externalIp")
    next.pingTimeout = i("pingTimeout", 10000)
    next.controlPeerTimeout = i("controlPeerTimeout", 0)
    next.pacingMaxBitrateKbps = i("pacingMaxBitrateKbps", 0)
    next.packetsize = i("packetsize", 0)
    next.lanEncryptionMode = i("lanEncryptionMode", 0)
    next.wanEncryptionMode = i("wanEncryptionMode", 1)
    next.sessionTokenTtlSeconds = i("sessionTokenTtlSeconds", 7200)
    next.rememberMeRefreshTokenTtlSeconds = i("rememberMeRefreshTokenTtlSeconds", 604800)
    next.csrfAllowedOrigins = s("csrfAllowedOrigins")

    next.sessionHistoryEnabled = b("sessionHistoryEnabled", true)
    next.sessionHistoryTtlDays = i("sessionHistoryTtlDays", 0)
    next.sessionHistoryDbSizeLimitMb = i("sessionHistoryDbSizeLimitMb", 0)
    next.hardwareMetrics = b("hardwareMetrics", false)
    next.hardwareMetricsInterval = i("hardwareMetricsInterval", 1000)
    next.realtimeStatsEnabled = b("realtimeStatsEnabled", true)
    next.realtimeStatsPollIntervalMs = i("realtimeStatsPollIntervalMs", 2000)

    next.steamEnabled = b("steamEnabled", false)
    next.steamAutoSync = b("steamAutoSync", false)
    next.steamSyncAllInstalled = b("steamSyncAllInstalled", false)
    next.steamRecentGames = i("steamRecentGames", 10)
    next.steamRecentMaxAgeDays = i("steamRecentMaxAgeDays", 30)
    next.steamAutosyncRemoveUninstalled = b("steamAutosyncRemoveUninstalled", true)
    next.steamIncludeTools = b("steamIncludeTools", false)

    self.settings = next
  }

  func patchSettings(_ patch: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: patch),
          let json = String(data: data, encoding: .utf8) else {
      return
    }
    let result = VibepolloHostBridge.shared().saveSettings(withJSON: json)
    if let req = result["restartRequired"] as? Bool, req {
      restartRequired = true
    }
    if let deferred = result["deferred"] as? Bool, deferred {
      statusBanner = l10n.pick("스트리밍 종료 후 일부 설정이 적용됩니다.", "Some changes will apply after the active stream ends.")
      bannerDismissTask?.cancel()
      bannerDismissTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        self?.statusBanner = nil
      }
    } else {
      bannerDismissTask?.cancel()
      bannerDismissTask = nil
      statusBanner = nil
    }
    refreshLiveState()
  }

  func saveGlobalPrepCmds(_ cmds: [StreamAppPrepCmd]) {
    settings.globalPrepCmds = cmds
    let payload = cmds
      .filter { !$0.doCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.undoCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { ["do": $0.doCmd, "undo": $0.undoCmd] }
    patchSettings(["global_prep_cmd": payload])
  }

  func saveGlobalStateCmds(_ cmds: [StreamAppPrepCmd]) {
    settings.globalStateCmds = cmds
    let payload = cmds
      .filter { !$0.doCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.undoCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { ["do": $0.doCmd, "undo": $0.undoCmd] }
    patchSettings(["global_state_cmd": payload])
  }

  func saveServerCmds(_ cmds: [ServerCommandEntry]) {
    settings.serverCmds = cmds
    let payload = cmds
      .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { ["name": $0.name, "cmd": $0.cmd] }
    patchSettings(["server_cmd": payload])
  }

  func toggleOpenAtLogin(_ enabled: Bool) {
    settings.opensAtLogin = enabled
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      _ = VibepolloHostBridge.shared().setOpenAtLogin(enabled)
      self.settings.opensAtLogin = VibepolloHostBridge.shared().isOpenAtLoginEnabled()
      self.settings.allowOnLoginScreen = VibepolloHostBridge.shared().isAllowOnLoginScreenEnabled()
    }
  }

  func toggleAllowOnLoginScreen(_ enabled: Bool) {
    settings.allowOnLoginScreen = enabled
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      _ = VibepolloHostBridge.shared().setAllowOnLoginScreen(enabled)
      self.settings.allowOnLoginScreen = VibepolloHostBridge.shared().isAllowOnLoginScreenEnabled()
      self.settings.opensAtLogin = VibepolloHostBridge.shared().isOpenAtLoginEnabled()
    }
  }

  func updateWebCredentials(username: String, password: String) -> Bool {
    let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUser.isEmpty, !password.isEmpty else {
      return false
    }
    let ok = VibepolloHostBridge.shared().updateWebCredentials(
      withUsername: trimmedUser,
      password: password
    )
    if ok {
      settings.webUsername = trimmedUser
      loadSettings()
    }
    return ok
  }

  func reloadLogs() {
    logsText = VibepolloHostBridge.shared().fetchLogsTail(400)
  }

  func setAutomaticCheckEnabled(_ enabled: Bool) {
    if enabled {
      let interval = settings.updateCheckInterval > 0 ? settings.updateCheckInterval : 86400
      settings.updateCheckInterval = interval
      patchSettings(["update_check_interval": interval])
    } else {
      settings.updateCheckInterval = 0
      settings.autoDownloadUpdates = false
      settings.autoInstallUpdates = false
      patchSettings([
        "update_check_interval": 0,
        "auto_download_updates": false,
        "auto_install_updates": false,
      ])
    }
    refreshSoftwareUpdate()
  }

  func setAutomaticDownloadEnabled(_ enabled: Bool) {
    if enabled {
      var patch: [String: Any] = ["auto_download_updates": true]
      if settings.updateCheckInterval <= 0 {
        settings.updateCheckInterval = 86400
        patch["update_check_interval"] = 86400
      }
      settings.autoDownloadUpdates = true
      patchSettings(patch)
    } else {
      settings.autoDownloadUpdates = false
      settings.autoInstallUpdates = false
      patchSettings([
        "auto_download_updates": false,
        "auto_install_updates": false,
      ])
    }
    refreshSoftwareUpdate()
  }

  func setAutomaticInstallEnabled(_ enabled: Bool) {
    if enabled {
      var patch: [String: Any] = [
        "auto_download_updates": true,
        "auto_install_updates": true,
      ]
      if settings.updateCheckInterval <= 0 {
        settings.updateCheckInterval = 86400
        patch["update_check_interval"] = 86400
      }
      settings.autoDownloadUpdates = true
      settings.autoInstallUpdates = true
      patchSettings(patch)
    } else {
      settings.autoInstallUpdates = false
      patchSettings(["auto_install_updates": false])
    }
    refreshSoftwareUpdate()
  }

  func setBetaUpdatesEnabled(_ enabled: Bool) {
    settings.notifyPreReleases = enabled
    patchSettings(["notify_pre_releases": enabled])
    refreshSoftwareUpdate()
  }
}
