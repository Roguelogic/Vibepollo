import AppKit
import SwiftUI

// MARK: - 1. 일반 (General Settings Pane)

struct GeneralSettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showAdvancedSheet = false
  @ViewState private var hostNameDraft: String = ""
  @FocusState private var hostNameFocused: Bool
  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      if store.restartRequired {
        RestartRequiredSection(store: store)
      }

      if let banner = store.statusBanner {
        Section {
          HStack(spacing: 8) {
            Label(banner, systemImage: "info.circle.fill")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              store.statusBanner = nil
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
      }

      Section {
        Button {
          store.navigate(to: .softwareUpdate)
        } label: {
          HStack(spacing: 10) {
            SidebarIconBadge(symbol: "gearshape.fill", tint: .gray, size: 22, symbolSize: 12)
            SettingsRowLabel(
              title: l10n.pick("소프트웨어 업데이트", "Software Update"),
              subtitle: softwareUpdateRowSubtitle
            )
            Spacer()
            if store.dashboard.updateAvailable {
              SettingsNotificationBadge(count: 1)
            }
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      Section {
        Picker(
          l10n.pick("언어 (Language)", "Language"),
          selection: Binding(
            get: { store.settings.locale.hasPrefix("ko") ? "ko" : "en" },
            set: { v in
              store.settings.locale = v
              store.patchSettings(["locale": v])
            }
          )
        ) {
          Text("한국어").tag("ko")
          Text("English").tag("en")
        }

        LabeledContent(l10n.pick("호스트 이름", "Host Name")) {
          TextField(
            "",
            text: $hostNameDraft,
            prompt: Text(VibepolloHostBridge.shared().defaultHostName())
          )
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 220)
          .focused($hostNameFocused)
          .onSubmit {
            commitHostNameIfNeeded()
          }
          .onChange(of: hostNameFocused) { _, focused in
            if !focused {
              commitHostNameIfNeeded()
            }
          }
        }
      }

      Section(l10n.pick("시동 및 로그인 화면", "Startup & Login Screen")) {
        Toggle(
          isOn: Binding(
            get: { store.settings.opensAtLogin },
            set: { store.toggleOpenAtLogin($0) }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("로그인 시 열기", "Open at Login"),
            subtitle: l10n.pick("Mac에 로그인할 때 메뉴 막대에서 자동으로 호스트를 시작합니다.", "Automatically start Vibepollo in the menu bar when you log in.")
          )
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.allowOnLoginScreen },
            set: { store.toggleAllowOnLoginScreen($0) }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("Mac 잠금 및 로그인 화면에서 허용", "Allow on macOS Login Screen"),
            subtitle: l10n.pick("재부팅 직후 암호 입력 화면에서도 원격 스트리밍 접속을 허용합니다.", "Allow remote connections before signing in to macOS.")
          )
        }
      }

      Section(l10n.pick("시스템 권한", "System Permissions")) {
        LabeledContent {
          if store.dashboard.screenCaptureAllowed {
            Text(l10n.pick("허용됨", "Allowed"))
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          } else {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
              Button(l10n.pick("설정 열기...", "Open Settings...")) {
                VibepolloHostBridge.shared().openScreenCapturePrivacySettings()
              }
            }
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("화면 및 시스템 오디오 기록", "Screen & System Audio Recording"),
            subtitle: l10n.pick("Mac 화면과 오디오 출력을 캡처해 클라이언트로 전송합니다.", "Required to capture your Mac display and system audio.")
          )
        }

        LabeledContent {
          if store.dashboard.accessibilityAllowed {
            Text(l10n.pick("허용됨", "Allowed"))
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          } else {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
              Button(l10n.pick("설정 열기...", "Open Settings...")) {
                VibepolloHostBridge.shared().openAccessibilityPrivacySettings()
              }
            }
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("손쉬운 사용 (원격 입력 제어)", "Accessibility (Remote Input)"),
            subtitle: l10n.pick("원격 키보드, 마우스, 트랙패드 및 Apple Pencil 입력을 전달합니다.", "Required to control mouse, keyboard, trackpad, and Apple Pencil.")
          )
        }
      }

      Section(l10n.pick("자동화 및 고급", "Automation & Advanced")) {
        SettingsDrillInRow(
          title: l10n.pick("호스트 자동화 및 명령어", "Host Automation & Commands"),
          subtitle: l10n.pick("앱 포커스 전환 정책 및 전역 준비 · 상태 · 서버 명령어를 관리합니다.", "Configure app focus policy and global preparation, state, and server commands.")
        ) {
          store.navigate(to: .hostAutomation)
        }

        LabeledContent {
          Button(l10n.pick("고급...", "Advanced...")) {
            showAdvancedSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("메뉴 막대 및 파일 경로", "Menu Bar & File Paths"),
            subtitle: l10n.pick("메뉴 막대 제어 옵션, 환경 변수 호환 모드, 상태 및 인증서 파일 경로를 설정합니다.", "Configure menu bar controls, environment compatibility, and certificate/state file paths.")
          )
        }
      }

      Section(l10n.pick("서비스", "Service")) {
        LabeledContent {
          Button(l10n.pick("재시작", "Restart")) {
            VibepolloHostBridge.shared().restartHost()
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("Vibepollo 재시작", "Restart Vibepollo"),
            subtitle: l10n.pick(
              "현재 버전 \(currentDisplayVersion)",
              "Version \(currentDisplayVersion)"
            )
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .onAppear {
      hostNameDraft = store.settings.sunshineName
    }
    .onDisappear {
      commitHostNameIfNeeded()
    }
    .onChange(of: store.settings.sunshineName) { _, next in
      if hostNameDraft != next {
        hostNameDraft = next
      }
    }
    .sheet(isPresented: $showAdvancedSheet) {
      GeneralAdvancedSheet(store: store)
    }
  }

  private var currentDisplayVersion: String {
    store.dashboard.version.isEmpty ? VibepolloHostBridge.shared().appVersion() : store.dashboard.version
  }

  private var softwareUpdateRowSubtitle: String {
    if store.dashboard.updateAvailable && !store.dashboard.availableUpdateVersion.isEmpty {
      return l10n.pick(
        "Vibepollo \(store.dashboard.availableUpdateVersion) 업데이트 사용 가능",
        "Vibepollo \(store.dashboard.availableUpdateVersion) Update Available"
      )
    }
    return "Vibepollo \(currentDisplayVersion)"
  }

  private func commitHostNameIfNeeded() {
    let trimmed = hostNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if hostNameDraft != trimmed {
      hostNameDraft = trimmed
    }
    if trimmed != store.settings.sunshineName {
      store.settings.sunshineName = trimmed
      store.patchSettings(["sunshine_name": trimmed])
    }
  }
}

// MARK: - 1A. 호스트 자동화 및 명령어 하위 페이지 (Host Automation & Commands Sub-Page)

struct HostAutomationSubView: View {
  @ObservedObject var store: HostStore
  private var l10n: L10n { store.l10n }

  @ViewState private var focusAttempts: Int = 3
  @ViewState private var focusTimeoutSecs: Int = 15
  @ViewState private var prepCmds: [StreamAppPrepCmd] = []
  @ViewState private var stateCmds: [StreamAppPrepCmd] = []
  @ViewState private var serverCmds: [ServerCommandEntry] = []

  var body: some View {
    Form {
      Section(l10n.pick("앱 실행 시 자동 포커스 전환", "Managed App Focus")) {
        LabeledContent {
          TextField("", value: $focusAttempts, format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .onSubmit(commitFocusPolicy)
        } label: {
          SettingsRowLabel(
            title: l10n.pick("포커스 활성화 시도 횟수", "Focus Attempts"),
            subtitle: l10n.pick("스트리밍 앱 실행 직후 창을 전면으로 가져올 최대 시도 횟수입니다 (0 = 비활성).", "Maximum attempts to bring a newly launched app window to the front (0 = off).")
          )
        }

        LabeledContent {
          TextField("", value: $focusTimeoutSecs, format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
            .onSubmit(commitFocusPolicy)
        } label: {
          SettingsRowLabel(
            title: l10n.pick("포커스 감지 제한 시간 (초)", "Focus Timeout (Seconds)"),
            subtitle: l10n.pick("새 창이 나타난 뒤 포커스를 유지할 제한 시간입니다.", "Window focus budget in seconds once the app window appears.")
          )
        }

        Toggle(
          l10n.pick("첫 창 포커스 성공 시 즉시 종료", "Stop After First Focused Window"),
          isOn: Binding(
            get: { store.settings.appFocusExitOnFirst },
            set: { v in
              store.settings.appFocusExitOnFirst = v
              store.patchSettings(["app_focus_exit_on_first": v])
            }
          )
        )
      }

      Section(l10n.pick("전역 준비 명령어 (스트림 시작 / 종료 시 실행)", "Global Prep Commands")) {
        ForEach(prepCmds) { item in
          let itemID = item.id
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(l10n.pick("실행 (Do)", "Do"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
              TextField(
                "",
                text: Binding(
                  get: { prepCmds.first(where: { $0.id == itemID })?.doCmd ?? "" },
                  set: { nextVal in
                    if let idx = prepCmds.firstIndex(where: { $0.id == itemID }) {
                      prepCmds[idx].doCmd = nextVal
                    }
                  }
                ),
                prompt: Text("sh -c ...")
              )
              .font(.system(size: 12, design: .monospaced))
              .onSubmit { store.saveGlobalPrepCmds(prepCmds) }

              Button(role: .destructive) {
                prepCmds.removeAll(where: { $0.id == itemID })
                store.saveGlobalPrepCmds(prepCmds)
              } label: {
                Image(systemName: "minus.circle.fill")
              }
              .buttonStyle(.borderless)
            }

            HStack {
              Text(l10n.pick("복구 (Undo)", "Undo"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
              TextField(
                "",
                text: Binding(
                  get: { prepCmds.first(where: { $0.id == itemID })?.undoCmd ?? "" },
                  set: { nextVal in
                    if let idx = prepCmds.firstIndex(where: { $0.id == itemID }) {
                      prepCmds[idx].undoCmd = nextVal
                    }
                  }
                ),
                prompt: Text("sh -c ...")
              )
              .font(.system(size: 12, design: .monospaced))
              .onSubmit { store.saveGlobalPrepCmds(prepCmds) }
            }
          }
          .padding(.vertical, 2)
        }

        Button(l10n.pick("+ 전역 준비 명령어 추가", "+ Add Global Prep Command")) {
          prepCmds.append(StreamAppPrepCmd())
        }
      }

      Section(l10n.pick("전역 상태 명령어 (일시정지 / 재개 시 실행)", "Global State Commands")) {
        ForEach(stateCmds) { item in
          let itemID = item.id
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(l10n.pick("실행 (Do)", "Do"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
              TextField(
                "",
                text: Binding(
                  get: { stateCmds.first(where: { $0.id == itemID })?.doCmd ?? "" },
                  set: { nextVal in
                    if let idx = stateCmds.firstIndex(where: { $0.id == itemID }) {
                      stateCmds[idx].doCmd = nextVal
                    }
                  }
                ),
                prompt: Text("sh -c ...")
              )
              .font(.system(size: 12, design: .monospaced))
              .onSubmit { store.saveGlobalStateCmds(stateCmds) }

              Button(role: .destructive) {
                stateCmds.removeAll(where: { $0.id == itemID })
                store.saveGlobalStateCmds(stateCmds)
              } label: {
                Image(systemName: "minus.circle.fill")
              }
              .buttonStyle(.borderless)
            }

            HStack {
              Text(l10n.pick("복구 (Undo)", "Undo"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
              TextField(
                "",
                text: Binding(
                  get: { stateCmds.first(where: { $0.id == itemID })?.undoCmd ?? "" },
                  set: { nextVal in
                    if let idx = stateCmds.firstIndex(where: { $0.id == itemID }) {
                      stateCmds[idx].undoCmd = nextVal
                    }
                  }
                ),
                prompt: Text("sh -c ...")
              )
              .font(.system(size: 12, design: .monospaced))
              .onSubmit { store.saveGlobalStateCmds(stateCmds) }
            }
          }
          .padding(.vertical, 2)
        }

        Button(l10n.pick("+ 전역 상태 명령어 추가", "+ Add Global State Command")) {
          stateCmds.append(StreamAppPrepCmd())
        }
      }

      Section(l10n.pick("클라이언트 노출 서버 명령어", "Server Commands")) {
        ForEach(serverCmds) { item in
          let itemID = item.id
          HStack(spacing: 8) {
            TextField(
              "",
              text: Binding(
                get: { serverCmds.first(where: { $0.id == itemID })?.name ?? "" },
                set: { nextVal in
                  if let idx = serverCmds.firstIndex(where: { $0.id == itemID }) {
                    serverCmds[idx].name = nextVal
                  }
                }
              ),
              prompt: Text(l10n.pick("표시 이름", "Menu Name"))
            )
            .frame(width: 140)
            .onSubmit { store.saveServerCmds(serverCmds) }

            TextField(
              "",
              text: Binding(
                get: { serverCmds.first(where: { $0.id == itemID })?.cmd ?? "" },
                set: { nextVal in
                  if let idx = serverCmds.firstIndex(where: { $0.id == itemID }) {
                    serverCmds[idx].cmd = nextVal
                  }
                }
              ),
              prompt: Text("sh -c ...")
            )
            .font(.system(size: 12, design: .monospaced))
            .onSubmit { store.saveServerCmds(serverCmds) }

            Button(role: .destructive) {
              serverCmds.removeAll(where: { $0.id == itemID })
              store.saveServerCmds(serverCmds)
            } label: {
              Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
          }
        }

        Button(l10n.pick("+ 서버 명령어 추가", "+ Add Server Command")) {
          serverCmds.append(ServerCommandEntry())
        }
      }
    }
    .vibepolloSettingsForm()
    .onAppear {
      focusAttempts = store.settings.appFocusAttempts
      focusTimeoutSecs = store.settings.appFocusTimeoutSecs
      prepCmds = store.settings.globalPrepCmds
      stateCmds = store.settings.globalStateCmds
      serverCmds = store.settings.serverCmds
    }
    .onDisappear {
      commitFocusPolicy()
      if prepCmds != store.settings.globalPrepCmds {
        store.saveGlobalPrepCmds(prepCmds)
      }
      if stateCmds != store.settings.globalStateCmds {
        store.saveGlobalStateCmds(stateCmds)
      }
      if serverCmds != store.settings.serverCmds {
        store.saveServerCmds(serverCmds)
      }
    }
  }

  private func commitFocusPolicy() {
    let clampedAttempts = max(0, min(100, focusAttempts))
    let clampedTimeout = max(0, min(300, focusTimeoutSecs))
    if clampedAttempts != store.settings.appFocusAttempts || clampedTimeout != store.settings.appFocusTimeoutSecs {
      store.settings.appFocusAttempts = clampedAttempts
      store.settings.appFocusTimeoutSecs = clampedTimeout
      store.patchSettings([
        "app_focus_attempts": clampedAttempts,
        "app_focus_timeout_secs": clampedTimeout,
      ])
    }
  }
}

// MARK: - 1B. 일반 고급 옵션 시트 (General Advanced Sheet)

struct GeneralAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var credentialsFile: String = ""
  @ViewState private var fileState: String = ""
  @ViewState private var vibeshineFileState: String = ""
  @ViewState private var fileApps: String = ""
  @ViewState private var logPath: String = ""
  @ViewState private var pkey: String = ""
  @ViewState private var cert: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("메뉴 막대 및 환경 호환성", "Menu Bar & Compatibility")) {
          Toggle(
            l10n.pick("메뉴 막대 추가 제어 항목 숨기기", "Hide Extra Menu Bar Controls"),
            isOn: Binding(
              get: { store.settings.hideTrayControls },
              set: { v in
                store.settings.hideTrayControls = v
                store.patchSettings(["hide_tray_controls": v])
              }
            )
          )

          Toggle(
            l10n.pick("레거시 SUNSHINE_* 환경 변수 호환 모드", "Legacy Environment Variable Compatibility"),
            isOn: Binding(
              get: { store.settings.envvarCompatibilityMode },
              set: { v in
                store.settings.envvarCompatibilityMode = v
                store.patchSettings(["envvar_compatibility_mode": v])
              }
            )
          )
        }

        Section(l10n.pick("구성 파일 및 TLS 인증서 경로 (비워 두면 기본 경로)", "Config & Certificate File Paths")) {
          pathRow(l10n.pick("계정 자격증명 파일", "Credentials File"), text: $credentialsFile)
          pathRow(l10n.pick("호스트 상태 파일", "State File"), text: $fileState)
          pathRow(l10n.pick("클라이언트 상태 파일", "Client State File"), text: $vibeshineFileState)
          pathRow(l10n.pick("앱 카탈로그 (apps.json)", "Apps File"), text: $fileApps)
          pathRow(l10n.pick("로그 파일 경로", "Log File"), text: $logPath)
          pathRow(l10n.pick("TLS 개인 키 (pkey)", "TLS Private Key"), text: $pkey)
          pathRow(l10n.pick("TLS 인증서 (cert)", "TLS Certificate"), text: $cert)
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("일반 고급 옵션", "Advanced General Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitPathsIfNeeded()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 520, height: 470)
    .onAppear {
      credentialsFile = store.settings.credentialsFile
      fileState = store.settings.fileState
      vibeshineFileState = store.settings.vibeshineFileState
      fileApps = store.settings.fileApps
      logPath = store.settings.logPath
      pkey = store.settings.pkey
      cert = store.settings.cert
    }
    .onDisappear {
      commitPathsIfNeeded()
    }
  }

  @ViewBuilder
  private func pathRow(_ label: String, text: Binding<String>) -> some View {
    LabeledContent(label) {
      TextField("", text: text, prompt: Text(l10n.pick("기본 경로", "Default")))
        .labelsHidden()
        .font(.system(size: 11.5, design: .monospaced))
        .multilineTextAlignment(.trailing)
        .frame(width: 250)
        .onSubmit(commitPathsIfNeeded)
    }
  }

  private func commitPathsIfNeeded() {
    var patch: [String: Any] = [:]
    func check(_ key: String, _ val: String, _ prev: inout String) {
      let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed != prev {
        prev = trimmed
        patch[key] = trimmed
      }
    }
    check("credentials_file", credentialsFile, &store.settings.credentialsFile)
    check("file_state", fileState, &store.settings.fileState)
    check("vibeshine_file_state", vibeshineFileState, &store.settings.vibeshineFileState)
    check("file_apps", fileApps, &store.settings.fileApps)
    check("log_path", logPath, &store.settings.logPath)
    check("pkey", pkey, &store.settings.pkey)
    check("cert", cert, &store.settings.cert)
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}
