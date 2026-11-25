import AppKit
import SwiftUI

// MARK: - 5. 네트워크 및 로그 (Network & Logs Pane)

struct NetworkSystemPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showCredentialsSheet = false
  @ViewState private var showAdvancedSheet = false
  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      if store.restartRequired {
        RestartRequiredSection(store: store)
      }

      Section {
        Toggle(
          isOn: Binding(
            get: { store.settings.enableDiscovery },
            set: { v in
              store.settings.enableDiscovery = v
              store.patchSettings(["enable_discovery": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("로컬 네트워크 자동 검색 (Bonjour)", "Local Network Discovery (Bonjour)"),
            subtitle: l10n.pick("같은 네트워크의 Moonlight · VoidLink 앱에 이 Mac을 자동으로 표시합니다.", "Advertise this Mac automatically to Moonlight and VoidLink clients on the local network.")
          )
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.enablePairing },
            set: { v in
              store.settings.enablePairing = v
              store.patchSettings(["enable_pairing": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("새 기기 PIN 페어링 허용", "Allow New PIN Pairing"),
            subtitle: l10n.pick("모든 기기를 등록한 뒤 비활성화하면 외부의 새 페어링 요청을 차단합니다.", "Turn off after registering your devices to block new pairing requests.")
          )
        }
      }

      Section(l10n.pick("원격 웹 콘솔", "Web Console")) {
        LabeledContent {
          Button(l10n.pick("브라우저에서 열기 ↗", "Open in Browser ↗")) {
            VibepolloHostBridge.shared().openWebConsoleInBrowser()
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("웹 콘솔 주소", "Console Address"),
            subtitle: VibepolloHostBridge.shared().webConsoleURL()
          )
        }

        Picker(
          l10n.pick("웹 콘솔 접속 허용 범위", "Web UI Access Scope"),
          selection: Binding(
            get: { store.settings.originWebUiAllowed },
            set: { v in
              store.settings.originWebUiAllowed = v
              store.patchSettings(["origin_web_ui_allowed": v])
            }
          )
        ) {
          Text(l10n.pick("이 Mac에서만 (localhost)", "This Mac Only (localhost)")).tag("pc")
          Text(l10n.pick("로컬 네트워크 허용 (LAN)", "Local Network (LAN)")).tag("lan")
          Text(l10n.pick("외부 네트워크 포함 전체 (WAN)", "All Networks (WAN)")).tag("wan")
        }

        LabeledContent {
          Button(l10n.pick("비밀번호 재설정...", "Reset Password...")) {
            showCredentialsSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("관리자 계정 및 비밀번호", "Administrator Credentials"),
            subtitle: store.settings.webUsername.isEmpty
              ? l10n.pick("웹 콘솔 로그인 계정을 설정하거나 재설정합니다.", "Set or reset the login credentials for the web console.")
              : l10n.pick("현재 계정: \(store.settings.webUsername)", "Username: \(store.settings.webUsername)")
          )
        }
      }

      Section(l10n.pick("진단 및 기록", "Diagnostics & History")) {
        SettingsDrillInRow(
          title: l10n.pick("시스템 로그", "System Logs"),
          subtitle: l10n.pick("로그 기록 수준을 변경하거나 실행 로그를 검색합니다.", "Change log verbosity or search live host log output.")
        ) {
          store.navigate(to: .logs)
        }

        SettingsDrillInRow(
          title: l10n.pick("세션 기록 및 통계", "Session History & Stats"),
          subtitle: l10n.pick("과거 스트리밍 기록과 통계 샘플링·보관 기간을 관리합니다. 실시간 모니터는 상단 메뉴 막대 아이콘을 클릭해 확인할 수 있습니다.", "Manage past session history and retention. Click the menu bar icon anytime for the live Liquid Glass monitor.")
        ) {
          store.navigate(to: .telemetry)
        }
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("고급...", "Advanced...")) {
            showAdvancedSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("포트 · 스트림 암호화 · IP 및 타임아웃", "Ports, Stream Encryption, IP & Timeouts"),
            subtitle: l10n.pick("기본 포트(\(store.settings.port)), UPnP, LAN/WAN 암호화, 바인딩 IP 및 세션 보안 시간을 설정합니다.", "Configure base port (\(store.settings.port)), UPnP, LAN/WAN encryption, bind IP, and timeouts.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showCredentialsSheet) {
      WebCredentialsSheet(store: store, initialUsername: store.settings.webUsername)
    }
    .sheet(isPresented: $showAdvancedSheet) {
      NetworkAdvancedSheet(store: store)
    }
  }
}

private struct WebCredentialsSheet: View {
  @ObservedObject var store: HostStore
  @ViewState private var username: String
  @ViewState private var password: String = ""
  @ViewState private var confirmPassword: String = ""
  @ViewState private var errorText: String? = nil
  @Environment(\.dismiss) private var dismiss

  init(store: HostStore, initialUsername: String) {
    self.store = store
    self._username = ViewState(wrappedValue: initialUsername.isEmpty ? "admin" : initialUsername)
  }

  private var l10n: L10n { store.l10n }
  private var trimmedUsername: String {
    username.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private var canSave: Bool {
    !trimmedUsername.isEmpty && password.count >= 4 && password == confirmPassword
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent(l10n.pick("사용자 이름", "Username")) {
            TextField("", text: $username, prompt: Text("admin"))
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 210)
          }

          LabeledContent(l10n.pick("새 비밀번호", "New Password")) {
            SecureField("", text: $password, prompt: Text(l10n.pick("4자 이상", "At least 4 characters")))
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 210)
          }

          LabeledContent(l10n.pick("비밀번호 확인", "Verify Password")) {
            SecureField("", text: $confirmPassword, prompt: Text(l10n.pick("다시 입력", "Re-enter password")))
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 210)
              .onSubmit {
                if canSave { submit() }
              }
          }
        } footer: {
          if !confirmPassword.isEmpty && password != confirmPassword {
            Text(l10n.pick("입력한 비밀번호가 서로 일치하지 않습니다.", "Passwords do not match."))
              .font(.system(size: 11.5))
              .foregroundStyle(.red)
          }
        }

        if let errorText {
          Section {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 11.5))
              .foregroundStyle(.red)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("웹 콘솔 비밀번호 재설정", "Reset Web Console Password"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(l10n.pick("취소", "Cancel")) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("저장", "Save")) {
            submit()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
        }
      }
    }
    .frame(width: 430, height: errorText == nil ? 240 : 290)
  }

  private func submit() {
    if store.updateWebCredentials(username: trimmedUsername, password: password) {
      dismiss()
    } else {
      errorText = l10n.pick("계정 정보를 저장하지 못했습니다.", "Failed to save credentials.")
    }
  }
}

// MARK: - 시스템 로그 & 리소스 / 세션 기록 (Diagnostics Sub-Pages)

struct LogViewerSubView: View {
  @ObservedObject var store: HostStore
  @ViewState private var filterText: String = ""
  private var l10n: L10n { store.l10n }

  private var displayedLines: String {
    let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return store.logsText }
    return store.logsText
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.localizedCaseInsensitiveContains(q) }
      .joined(separator: "\n")
  }

  private static let logLevelNames: [(Int, String, String)] = [
    (0, "0 - Verbose (상세 디버그)", "0 - Verbose"),
    (1, "1 - Debug (디버그)", "1 - Debug"),
    (2, "2 - Info (기본 정보)", "2 - Info"),
    (3, "3 - Warning (경고)", "3 - Warning"),
    (4, "4 - Error (오류)", "4 - Error"),
    (5, "5 - Fatal (치명적 오류)", "5 - Fatal"),
    (6, "6 - None (기록 안 함)", "6 - None"),
  ]

  var body: some View {
    Form {
      Section {
        Picker(
          l10n.pick("최소 로그 기록 수준", "Minimum Log Level"),
          selection: Binding(
            get: { store.settings.minLogLevel },
            set: { v in
              store.settings.minLogLevel = v
              store.patchSettings(["min_log_level": String(v)])
            }
          )
        ) {
          ForEach(Self.logLevelNames, id: \.0) { code, ko, en in
            Text(l10n.pick(ko, en)).tag(code)
          }
        }

        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("", text: $filterText, prompt: Text(l10n.pick("로그 검색...", "Filter logs...")))
            .textFieldStyle(.plain)
          if !filterText.isEmpty {
            Button {
              filterText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }
          Spacer()
          Button(l10n.pick("새로고침", "Refresh")) {
            store.reloadLogs()
          }
          .controlSize(.small)
          Button(l10n.pick("Finder에서 보기", "Reveal in Finder")) {
            VibepolloHostBridge.shared().revealLogFileInFinder()
          }
          .controlSize(.small)
        }
      }

      Section {
        ScrollView {
          Text(displayedLines.isEmpty ? l10n.pick("표시할 로그가 없습니다.", "No log entries.") : displayedLines)
            .font(.system(size: 11.5, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(4)
        }
        .frame(minHeight: 340)
      }
    }
    .vibepolloSettingsForm()
    .onAppear {
      store.reloadLogs()
    }
  }
}

struct SessionHistorySubView: View {
  @ObservedObject var store: HostStore
  @ViewState private var showTelemetrySettings = false
  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      Section {
        LabeledContent {
          Button(l10n.pick("통계 설정...", "Telemetry Options...")) {
            showTelemetrySettings = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("통계 샘플링 및 세션 기록 보관", "Sampling & History Retention"),
            subtitle: l10n.pick("실시간 하드웨어 지표 주기와 SQLite 세션 이력 보관 기간을 설정합니다. 실시간 모니터는 상단 메뉴 막대 아이콘에서 바로 확인할 수 있습니다.", "Configure hardware metrics sampling and SQLite session history retention. Click the menu bar icon anytime for the live monitor.")
          )
        }
      }

      Section(l10n.pick("최근 스트리밍 기록", "Recent Session History")) {
        if store.sessionHistory.isEmpty {
          Text(l10n.pick("저장된 이전 세션 기록이 없습니다.", "No recorded past sessions."))
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.sessionHistory) { item in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text("\(item.deviceName.isEmpty ? item.clientName : item.deviceName) · \(item.appName.isEmpty ? "Desktop" : item.appName)")
                  .font(.system(size: 13, weight: .medium))
                Text(historySubtitle(item))
                  .font(.system(size: 11.5).monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) {
                store.deleteSessionHistory(uuid: item.uuid)
              } label: {
                Image(systemName: "trash")
                  .font(.system(size: 11.5))
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .vibepolloSettingsForm()
    .onAppear {
      store.reloadSessionHistory()
    }
    .sheet(isPresented: $showTelemetrySettings) {
      TelemetrySettingsSheet(store: store)
    }
  }

  private static let historyDateKoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateStyle = .short
    f.timeStyle = .short
    return f
  }()

  private static let historyDateEnFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateStyle = .short
    f.timeStyle = .short
    return f
  }()

  private func historySubtitle(_ item: SessionHistoryItem) -> String {
    let mins = max(1, Int(item.durationSeconds / 60.0))
    let dateStr: String = {
      guard item.startTimeUnix > 0 else { return "" }
      let f = l10n.isKo ? Self.historyDateKoFormatter : Self.historyDateEnFormatter
      return f.string(from: Date(timeIntervalSince1970: item.startTimeUnix))
    }()
    let spec = "\(String(format: "%d×%d", item.width, item.height)) \(item.targetFps)Hz · \(item.codec)\(item.hdr ? " HDR" : "") · \(mins)\(l10n.pick("분", "m"))"
    return dateStr.isEmpty ? spec : "\(dateStr) · \(spec)"
  }
}

// MARK: - 5B. 네트워크 고급 옵션 시트 (Network Advanced Sheet)

struct NetworkAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var portDraft: Int = 47989
  @ViewState private var bindAddressDraft: String = ""
  @ViewState private var externalIpDraft: String = ""
  @ViewState private var pingTimeoutDraft: Int = 10000
  @ViewState private var controlTimeoutDraft: Int = 0
  @ViewState private var pacingCapDraft: Int = 0
  @ViewState private var packetSizeDraft: Int = 1392
  @ViewState private var sessionTtlDraft: Int = 7200
  @ViewState private var rememberTtlDraft: Int = 604800
  @ViewState private var csrfOriginsDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent {
            TextField("", value: $portDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 13, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 96)
              .onSubmit(commitFields)
          } label: {
            SettingsRowLabel(
              title: l10n.pick("기본 포트 번호", "Base Port"),
              subtitle: l10n.pick("HTTPS \(portDraft - 5) · HTTP \(portDraft) · Web \(portDraft + 1) · RTSP \(portDraft + 21) · UDP \(portDraft + 9)–\(portDraft + 11)", "HTTPS \(portDraft - 5) · HTTP \(portDraft) · Web \(portDraft + 1) · RTSP \(portDraft + 21) · UDP \(portDraft + 9)–\(portDraft + 11)")
            )
          }

          Picker(
            l10n.pick("IP 주소 체계", "Address Family"),
            selection: Binding(
              get: { store.settings.addressFamily },
              set: { v in
                store.settings.addressFamily = v
                store.patchSettings(["address_family": v])
              }
            )
          ) {
            Text("IPv4").tag("ipv4")
            Text("IPv4 + IPv6").tag("both")
          }

          Toggle(
            l10n.pick("UPnP 자동 포트포워딩", "Enable UPnP"),
            isOn: Binding(
              get: { store.settings.upnp },
              set: { v in
                store.settings.upnp = v
                store.patchSettings(["upnp": v])
              }
            )
          )

          LabeledContent(l10n.pick("바인딩 IP 주소", "Bind IP Address")) {
            TextField("", text: $bindAddressDraft, prompt: Text("0.0.0.0"))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 170)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("외부 공인 IP 주소", "External WAN IP")) {
            TextField("", text: $externalIpDraft, prompt: Text(l10n.pick("자동 감지", "Auto-detect")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 170)
              .onSubmit(commitFields)
          }
        }

        Section(l10n.pick("스트림 암호화 및 전송 제한", "Stream Encryption & Transport")) {
          Picker(
            l10n.pick("LAN 스트림 암호화", "LAN Stream Encryption"),
            selection: Binding(
              get: { store.settings.lanEncryptionMode },
              set: { v in
                store.settings.lanEncryptionMode = v
                store.patchSettings(["lan_encryption_mode": v])
              }
            )
          ) {
            Text(l10n.pick("사용 안 함", "Disabled")).tag(0)
            Text(l10n.pick("지원 시 사용", "Opportunistic")).tag(1)
            Text(l10n.pick("암호화 필수", "Mandatory")).tag(2)
          }

          Picker(
            l10n.pick("WAN(외부) 스트림 암호화", "WAN Stream Encryption"),
            selection: Binding(
              get: { store.settings.wanEncryptionMode },
              set: { v in
                store.settings.wanEncryptionMode = v
                store.patchSettings(["wan_encryption_mode": v])
              }
            )
          ) {
            Text(l10n.pick("사용 안 함", "Disabled")).tag(0)
            Text(l10n.pick("지원 시 사용 (기본)", "Opportunistic (Default)")).tag(1)
            Text(l10n.pick("암호화 필수", "Mandatory")).tag(2)
          }

          LabeledContent(l10n.pick("클라이언트 핑 타임아웃 (ms)", "Ping Timeout (ms)")) {
            TextField("", value: $pingTimeoutDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 100)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("제어 채널 타임아웃 (ms, 0=기본)", "Control Peer Timeout (ms)")) {
            TextField("", value: $controlTimeoutDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 100)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("페이싱 대역폭 상한 (kbps, 0=끔)", "Pacing Bitrate Ceiling (kbps)")) {
            TextField("", value: $pacingCapDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 100)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("최대 UDP 패킷 크기 (바이트)", "Max Packet Size (Bytes)")) {
            TextField("", value: $packetSizeDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 100)
              .onSubmit(commitFields)
          }
        }

        Section(l10n.pick("웹 콘솔 세션 보안", "Web Session Security")) {
          LabeledContent(l10n.pick("세션 토큰 만료 시간 (초)", "Session Token TTL (s)")) {
            TextField("", value: $sessionTtlDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 110)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("로그인 유지 토큰 만료 (초)", "Remember-Me TTL (s)")) {
            TextField("", value: $rememberTtlDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 110)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("추가 허용 CSRF 출처", "Allowed CSRF Origins")) {
            TextField("", text: $csrfOriginsDraft, prompt: Text("https://..."))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 200)
              .onSubmit(commitFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("고급 네트워크 및 보안 옵션", "Advanced Network & Security"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 520, height: 500)
    .onAppear {
      portDraft = store.settings.port
      bindAddressDraft = store.settings.bindAddress
      externalIpDraft = store.settings.externalIp
      pingTimeoutDraft = store.settings.pingTimeout
      controlTimeoutDraft = store.settings.controlPeerTimeout
      pacingCapDraft = store.settings.pacingMaxBitrateKbps
      packetSizeDraft = store.settings.packetsize
      sessionTtlDraft = store.settings.sessionTokenTtlSeconds
      rememberTtlDraft = store.settings.rememberMeRefreshTokenTtlSeconds
      csrfOriginsDraft = store.settings.csrfAllowedOrigins
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    var patch: [String: Any] = [:]
    if portDraft != store.settings.port, (1024...65514).contains(portDraft) {
      store.settings.port = portDraft
      patch["port"] = portDraft
    }
    let ba = bindAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if ba != store.settings.bindAddress {
      store.settings.bindAddress = ba
      patch["bind_address"] = ba
    }
    let ext = externalIpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if ext != store.settings.externalIp {
      store.settings.externalIp = ext
      patch["external_ip"] = ext
    }
    let pt = max(0, pingTimeoutDraft)
    if pt != store.settings.pingTimeout {
      store.settings.pingTimeout = pt
      patch["ping_timeout"] = pt
    }
    let ct = max(0, controlTimeoutDraft)
    if ct != store.settings.controlPeerTimeout {
      store.settings.controlPeerTimeout = ct
      patch["control_peer_timeout"] = ct
    }
    let pc = max(0, pacingCapDraft)
    if pc != store.settings.pacingMaxBitrateKbps {
      store.settings.pacingMaxBitrateKbps = pc
      patch["pacing_max_bitrate_kbps"] = pc
    }
    let ps = max(0, min(65535, packetSizeDraft))
    if ps != store.settings.packetsize {
      store.settings.packetsize = ps
      patch["packetsize"] = ps
    }
    let sttl = max(60, sessionTtlDraft)
    if sttl != store.settings.sessionTokenTtlSeconds {
      store.settings.sessionTokenTtlSeconds = sttl
      patch["session_token_ttl_seconds"] = sttl
    }
    let rttl = max(60, rememberTtlDraft)
    if rttl != store.settings.rememberMeRefreshTokenTtlSeconds {
      store.settings.rememberMeRefreshTokenTtlSeconds = rttl
      patch["remember_me_refresh_token_ttl_seconds"] = rttl
    }
    let csrf = csrfOriginsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if csrf != store.settings.csrfAllowedOrigins {
      store.settings.csrfAllowedOrigins = csrf
      patch["csrf_allowed_origins"] = csrf
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

// MARK: - 5C. 통계 샘플링 및 세션 이력 설정 시트 (Telemetry & History Settings Sheet)

struct TelemetrySettingsSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var ttlDaysDraft: Int = 0
  @ViewState private var dbLimitMbDraft: Int = 0
  @ViewState private var hwIntervalDraft: Int = 1000
  @ViewState private var pollMsDraft: Int = 2000

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("세션 기록 저장 (SQLite)", "Session History Persistence")) {
          Toggle(
            l10n.pick("스트리밍 세션 기록 저장 활성화", "Save Session History"),
            isOn: Binding(
              get: { store.settings.sessionHistoryEnabled },
              set: { v in
                store.settings.sessionHistoryEnabled = v
                store.patchSettings(["session_history_enabled": v])
              }
            )
          )

          LabeledContent(l10n.pick("기록 보관 일수 (0 = 무제한)", "Retention Days (0 = Unlimited)")) {
            TextField("", value: $ttlDaysDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("최대 DB 용량 제한 (MB, 0 = 무제한)", "DB Size Limit (MB)")) {
            TextField("", value: $dbLimitMbDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }
        }

        Section(l10n.pick("실시간 하드웨어 지표 샘플링", "Real-Time Hardware Metrics")) {
          Toggle(
            l10n.pick("실시간 호스트 CPU/GPU 통계 수집", "Enable Real-Time Host Stats"),
            isOn: Binding(
              get: { store.settings.realtimeStatsEnabled },
              set: { v in
                store.settings.realtimeStatsEnabled = v
                store.patchSettings(["realtime_stats_enabled": v])
              }
            )
          )

          LabeledContent(l10n.pick("호스트 통계 샘플링 주기 (ms)", "Stats Poll Interval (ms)")) {
            TextField("", value: $pollMsDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          Toggle(
            l10n.pick("클라이언트 오버레이에 하드웨어 지표 제공", "Share Hardware Metrics with Clients"),
            isOn: Binding(
              get: { store.settings.hardwareMetrics },
              set: { v in
                store.settings.hardwareMetrics = v
                store.patchSettings(["hardware_metrics": v])
              }
            )
          )

          LabeledContent(l10n.pick("클라이언트 지표 최소 주기 (ms)", "Client Metrics Interval (ms)")) {
            TextField("", value: $hwIntervalDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("통계 및 세션 기록 설정", "Telemetry & History Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 470, height: 375)
    .onAppear {
      ttlDaysDraft = store.settings.sessionHistoryTtlDays
      dbLimitMbDraft = store.settings.sessionHistoryDbSizeLimitMb
      hwIntervalDraft = store.settings.hardwareMetricsInterval
      pollMsDraft = store.settings.realtimeStatsPollIntervalMs
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    var patch: [String: Any] = [:]
    let days = max(0, ttlDaysDraft)
    if days != store.settings.sessionHistoryTtlDays {
      store.settings.sessionHistoryTtlDays = days
      patch["session_history_ttl_days"] = days
    }
    let mb = max(0, dbLimitMbDraft)
    if mb != store.settings.sessionHistoryDbSizeLimitMb {
      store.settings.sessionHistoryDbSizeLimitMb = mb
      patch["session_history_db_size_limit_mb"] = mb
    }
    let hw = max(500, min(10000, hwIntervalDraft))
    if hw != store.settings.hardwareMetricsInterval {
      store.settings.hardwareMetricsInterval = hw
      patch["hardware_metrics_interval"] = hw
    }
    let poll = max(250, min(60000, pollMsDraft))
    if poll != store.settings.realtimeStatsPollIntervalMs {
      store.settings.realtimeStatsPollIntervalMs = poll
      patch["realtime_stats_poll_interval_ms"] = poll
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}
