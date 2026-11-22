import AppKit
import SwiftUI

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
        Section(l10n.pick("업데이트 및 메뉴 막대", "Updates & Menu Bar")) {
          Picker(
            l10n.pick("자동 업데이트 확인 주기", "Update Check Interval"),
            selection: Binding(
              get: { store.settings.updateCheckInterval },
              set: { v in
                store.settings.updateCheckInterval = v
                store.patchSettings(["update_check_interval": v])
              }
            )
          ) {
            Text(l10n.pick("자동 확인 안 함", "Never")).tag(0)
            Text(l10n.pick("매시간", "Hourly")).tag(3600)
            Text(l10n.pick("매일 (기본)", "Daily (Default)")).tag(86400)
            Text(l10n.pick("매주", "Weekly")).tag(604800)
            if ![0, 3600, 86400, 604800].contains(store.settings.updateCheckInterval) {
              Text("\(store.settings.updateCheckInterval)s").tag(store.settings.updateCheckInterval)
            }
          }

          Toggle(
            l10n.pick("프리릴리스(베타) 업데이트 알림 받기", "Notify About Pre-Releases"),
            isOn: Binding(
              get: { store.settings.notifyPreReleases },
              set: { v in
                store.settings.notifyPreReleases = v
                store.patchSettings(["notify_pre_releases": v])
              }
            )
          )

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

// MARK: - 2B. 디스플레이 고급 옵션 시트 (Display Advanced Sheet)

struct DisplayAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var outputNameDraft: String = ""
  @ViewState private var fallbackModeDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("가상 모니터 배치 및 유지", "Virtual Display Policy")) {
          Picker(
            l10n.pick("모니터 배치 정책", "Layout Policy"),
            selection: Binding(
              get: { store.settings.virtualDisplayLayout },
              set: { v in
                store.settings.virtualDisplayLayout = v
                store.patchSettings(["virtual_display_layout": v])
              }
            )
          ) {
            Text(l10n.pick("단독 표시 (물리 화면 숨김)", "Exclusive")).tag("exclusive")
            Text(l10n.pick("데스크톱 확장 (기본)", "Extended (Default)")).tag("extended")
            Text(l10n.pick("확장 + 주 모니터 지정", "Extended Primary")).tag("extended_primary")
            Text(l10n.pick("확장 + 커서 격리 배치", "Extended Isolated")).tag("extended_isolated")
            Text(l10n.pick("확장 + 주 모니터 및 커서 격리", "Extended Primary & Isolated")).tag("extended_primary_isolated")
          }

          Picker(
            l10n.pick("일시정지 모니터 자동 해제 시간", "Paused Display Timeout"),
            selection: Binding(
              get: { store.settings.pausedDisplayTimeoutSecs },
              set: { v in
                store.settings.pausedDisplayTimeoutSecs = v
                store.patchSettings(["dd_paused_virtual_display_timeout_secs": v])
              }
            )
          ) {
            Text(l10n.pick("앱 종료 시까지 계속 유지", "Keep Until App Closes")).tag(0)
            Text(l10n.pick("30분", "30 Minutes")).tag(1800)
            Text(l10n.pick("1시간", "1 Hour")).tag(3600)
            Text(l10n.pick("2시간 (기본)", "2 Hours (Default)")).tag(7200)
            Text(l10n.pick("4시간", "4 Hours")).tag(14400)
            if ![0, 1800, 3600, 7200, 14400].contains(store.settings.pausedDisplayTimeoutSecs) {
              Text("\(store.settings.pausedDisplayTimeoutSecs)s").tag(store.settings.pausedDisplayTimeoutSecs)
            }
          }

          Picker(
            l10n.pick("가상 모니터 최대 동시 클라이언트", "Max Virtual Display Clients"),
            selection: Binding(
              get: { store.settings.virtualDisplayMaxClients },
              set: { v in
                store.settings.virtualDisplayMaxClients = v
                store.patchSettings(["virtual_display_max_clients": v])
              }
            )
          ) {
            ForEach(1...8, id: \.self) { count in
              Text("\(count)").tag(count)
            }
            if !(1...8).contains(store.settings.virtualDisplayMaxClients) {
              Text("\(store.settings.virtualDisplayMaxClients)").tag(store.settings.virtualDisplayMaxClients)
            }
          }
        }

        Section(l10n.pick("물리 모니터 타겟 및 대체 해상도", "Target Output & Fallback Mode")) {
          LabeledContent(l10n.pick("캡처 대상 모니터 ID", "Target Display ID")) {
            TextField("", text: $outputNameDraft, prompt: Text(l10n.pick("자동 (주 모니터)", "Auto (Main Display)")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 180)
              .onSubmit(commitFieldsIfNeeded)
          }

          LabeledContent(l10n.pick("기본 대체 해상도", "Fallback Resolution")) {
            TextField("", text: $fallbackModeDraft, prompt: Text("1920x1080x60"))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 180)
              .onSubmit(commitFieldsIfNeeded)
          }
        }

        Section(l10n.pick("원격 보조 모니터 (Remote Monitor)", "Remote Monitor Sessions")) {
          Toggle(
            l10n.pick("실행 중인 앱 교체 시 확인 요청", "Confirm Before Replacing Running App"),
            isOn: Binding(
              get: { store.settings.remoteMonitorConfirmAppReplacement },
              set: { v in
                store.settings.remoteMonitorConfirmAppReplacement = v
                store.patchSettings(["remote_monitor_confirm_app_replacement": v])
              }
            )
          )

          Toggle(
            l10n.pick("원격 모니터 전용 세션 오디오 음소거", "Mute Audio for Remote Monitor"),
            isOn: Binding(
              get: { store.settings.remoteMonitorMuteAudio },
              set: { v in
                store.settings.remoteMonitorMuteAudio = v
                store.patchSettings(["remote_monitor_mute_audio": v])
              }
            )
          )

          Toggle(
            l10n.pick("스트림 종료 시 원격 모니터 즉시 해제", "Release Remote Monitor When Stream Ends"),
            isOn: Binding(
              get: { store.settings.remoteMonitorDisconnectOnStreamEnd },
              set: { v in
                store.settings.remoteMonitorDisconnectOnStreamEnd = v
                store.patchSettings(["remote_monitor_disconnect_on_stream_end": v])
              }
            )
          )
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("고급 디스플레이 옵션", "Advanced Display Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            commitFieldsIfNeeded()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 500, height: 440)
    .onAppear {
      outputNameDraft = store.settings.outputName
      fallbackModeDraft = store.settings.fallbackMode
    }
    .onDisappear {
      commitFieldsIfNeeded()
    }
  }

  private func commitFieldsIfNeeded() {
    var patch: [String: Any] = [:]
    let outTrim = outputNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if outTrim != store.settings.outputName {
      store.settings.outputName = outTrim
      patch["output_name"] = outTrim
    }
    let fbTrim = fallbackModeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if fbTrim != store.settings.fallbackMode {
      store.settings.fallbackMode = fbTrim
      patch["fallback_mode"] = fbTrim
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

// MARK: - 3B. 화질 및 인코더 고급 옵션 시트 (Video Advanced Sheet)

struct VideoAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var bitrateDraft: Int = 0
  @ViewState private var minFpsDraft: Double = 20.0
  @ViewState private var fecDraft: Int = 20
  @ViewState private var qpDraft: Int = 28
  @ViewState private var minThreadsDraft: Int = 2

  private static let swPresets = [
    "ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow",
  ]
  private static let swTunes = [
    "zerolatency", "film", "animation", "grain", "stillimage", "fastdecode",
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("비트레이트 · 프레임 및 패킷 복구", "Bitrate, Frame Pacing & FEC")) {
          LabeledContent {
            TextField("", value: $bitrateDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 110)
              .onSubmit(commitNumericFields)
          } label: {
            SettingsRowLabel(
              title: l10n.pick("최대 비트레이트 상한 (kbps)", "Max Bitrate (kbps)"),
              subtitle: l10n.pick("0 입력 시 클라이언트 요청 비트레이트를 제한 없이 따릅니다.", "Set 0 to follow the client's requested bitrate without cap.")
            )
          }

          LabeledContent(l10n.pick("유휴 화면 최소 프레임 (FPS)", "Minimum Idle FPS")) {
            TextField("", value: $minFpsDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitNumericFields)
          }

          LabeledContent(l10n.pick("패킷 손실 복구율 (FEC %)", "FEC Percentage (0–255)")) {
            TextField("", value: $fecDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitNumericFields)
          }

          Picker(
            l10n.pick("최대 비디오 배치 크기", "Max Video Batch Size"),
            selection: Binding(
              get: { store.settings.videoMaxBatchSizeKb },
              set: { v in
                store.settings.videoMaxBatchSizeKb = v
                store.patchSettings(["video_max_batch_size_kb": v])
              }
            )
          ) {
            Text("16 KB").tag(16)
            Text("32 KB").tag(32)
            Text(l10n.pick("64 KB (기본)", "64 KB (Default)")).tag(64)
            if ![16, 32, 64].contains(store.settings.videoMaxBatchSizeKb) {
              Text("\(store.settings.videoMaxBatchSizeKb) KB").tag(store.settings.videoMaxBatchSizeKb)
            }
          }

          Toggle(
            l10n.pick("호스트 적응형 패킷 페이싱", "Host Adaptive Packet Pacing"),
            isOn: Binding(
              get: { store.settings.hostAdaptivePacing },
              set: { v in
                store.settings.hostAdaptivePacing = v
                store.patchSettings(["host_adaptive_pacing": v])
              }
            )
          )

          Toggle(
            l10n.pick("PyroWave 초저지연 코덱 광고", "Enable PyroWave Codec"),
            isOn: Binding(
              get: { store.settings.pyrowave },
              set: { v in
                store.settings.pyrowave = v
                store.patchSettings(["pyrowave": v])
              }
            )
          )
        }

        Section("Apple VideoToolbox") {
          Picker(
            l10n.pick("H.264 엔트로피 코딩 (vt_coder)", "H.264 Entropy Coding"),
            selection: Binding(
              get: { store.settings.vtCoder },
              set: { v in
                store.settings.vtCoder = v
                store.patchSettings(["vt_coder": v])
              }
            )
          ) {
            Text(l10n.pick("자동", "Automatic")).tag("auto")
            Text("CABAC").tag("cabac")
            Text("CAVLC").tag("cavlc")
          }

          Picker(
            l10n.pick("소프트웨어 인코더 폴백 (vt_software)", "Software Fallback"),
            selection: Binding(
              get: { store.settings.vtSoftware },
              set: { v in
                store.settings.vtSoftware = v
                store.patchSettings(["vt_software": v])
              }
            )
          ) {
            Text(l10n.pick("자동", "Automatic")).tag("auto")
            Text(l10n.pick("비활성 (하드웨어 전용)", "Disabled")).tag("disabled")
            Text(l10n.pick("허용", "Allowed")).tag("allowed")
            Text(l10n.pick("소프트웨어 강제", "Forced")).tag("forced")
          }

          Toggle(
            l10n.pick("시작 시 인코더 점검 실패 무시", "Ignore Encoder Probe Failure"),
            isOn: Binding(
              get: { store.settings.ignoreEncoderProbeFailure },
              set: { v in
                store.settings.ignoreEncoderProbeFailure = v
                store.patchSettings(["ignore_encoder_probe_failure": v])
              }
            )
          )
        }

        Section(l10n.pick("소프트웨어(CPU) 인코더 세부 설정", "Software (CPU) Encoder")) {
          Picker(
            l10n.pick("인코딩 프리셋 (sw_preset)", "Preset"),
            selection: Binding(
              get: { store.settings.swPreset },
              set: { v in
                store.settings.swPreset = v
                store.patchSettings(["sw_preset": v])
              }
            )
          ) {
            ForEach(Self.swPresets, id: \.self) { p in
              Text(p).tag(p)
            }
          }

          Picker(
            l10n.pick("인코딩 튜닝 (sw_tune)", "Tune"),
            selection: Binding(
              get: { store.settings.swTune },
              set: { v in
                store.settings.swTune = v
                store.patchSettings(["sw_tune": v])
              }
            )
          ) {
            ForEach(Self.swTunes, id: \.self) { t in
              Text(t).tag(t)
            }
          }

          LabeledContent(l10n.pick("양자화 계수 QP (0–51)", "Quantizer Parameter (QP)")) {
            TextField("", value: $qpDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 80)
              .onSubmit(commitNumericFields)
          }

          LabeledContent(l10n.pick("최소 인코딩 스레드 수", "Minimum CPU Threads")) {
            TextField("", value: $minThreadsDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 80)
              .onSubmit(commitNumericFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("고급 화질 및 인코더 옵션", "Advanced Video Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            commitNumericFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 500, height: 500)
    .onAppear {
      bitrateDraft = store.settings.maxBitrateKbps
      minFpsDraft = store.settings.minimumFpsTarget
      fecDraft = store.settings.fecPercentage
      qpDraft = store.settings.qp
      minThreadsDraft = store.settings.minThreads
    }
    .onDisappear {
      commitNumericFields()
    }
  }

  private func commitNumericFields() {
    var patch: [String: Any] = [:]
    let cleanBitrate = max(0, bitrateDraft)
    if cleanBitrate != store.settings.maxBitrateKbps {
      store.settings.maxBitrateKbps = cleanBitrate
      patch["max_bitrate"] = cleanBitrate
    }
    let cleanFps = max(0.0, min(1000.0, minFpsDraft))
    if abs(cleanFps - store.settings.minimumFpsTarget) > 0.01 {
      store.settings.minimumFpsTarget = cleanFps
      patch["minimum_fps_target"] = cleanFps
    }
    let cleanFec = max(0, min(255, fecDraft))
    if cleanFec != store.settings.fecPercentage {
      store.settings.fecPercentage = cleanFec
      patch["fec_percentage"] = cleanFec
    }
    let cleanQp = max(0, min(51, qpDraft))
    if cleanQp != store.settings.qp {
      store.settings.qp = cleanQp
      patch["qp"] = cleanQp
    }
    let cleanThreads = max(1, min(64, minThreadsDraft))
    if cleanThreads != store.settings.minThreads {
      store.settings.minThreads = cleanThreads
      patch["min_threads"] = cleanThreads
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

// MARK: - 4B. 입력 및 오디오 고급 옵션 시트 (Input & Audio Advanced Sheets)

struct InputAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var backTimeoutDraft: Int = -1
  @ViewState private var guideKeyDraft: Int = 0
  @ViewState private var guideSlotDraft: Int = 0
  @ViewState private var repeatDelayDraft: Int = 500
  @ViewState private var repeatFreqDraft: Double = 24.9
  @ViewState private var keybindingsDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("게임 컨트롤러 및 세션", "Controller & Input Session")) {
          Toggle(
            l10n.pick("입력 전용(Input-Only) 스트림 모드 허용", "Enable Input-Only Mode"),
            isOn: Binding(
              get: { store.settings.enableInputOnlyMode },
              set: { v in
                store.settings.enableInputOnlyMode = v
                store.patchSettings(["enable_input_only_mode": v])
              }
            )
          )

          Toggle(
            l10n.pick("컨트롤러 진동(럼블) 전달", "Forward Controller Rumble"),
            isOn: Binding(
              get: { store.settings.forwardRumble },
              set: { v in
                store.settings.forwardRumble = v
                store.patchSettings(["forward_rumble": v])
              }
            )
          )

          Toggle(
            l10n.pick("자이로/모션 센서를 DualShock 4로 전달", "Motion as DualShock 4"),
            isOn: Binding(
              get: { store.settings.motionAsDs4 },
              set: { v in
                store.settings.motionAsDs4 = v
                store.patchSettings(["motion_as_ds4": v])
              }
            )
          )

          Toggle(
            l10n.pick("트랙패드를 DualShock 4 터치패드로 전달", "Touchpad as DualShock 4"),
            isOn: Binding(
              get: { store.settings.touchpadAsDs4 },
              set: { v in
                store.settings.touchpadAsDs4 = v
                store.patchSettings(["touchpad_as_ds4": v])
              }
            )
          )

          Toggle(
            l10n.pick("Back 버튼을 DS4 터치패드 클릭으로 처리", "DS4 Back as Touchpad Click"),
            isOn: Binding(
              get: { store.settings.ds4BackAsTouchpadClick },
              set: { v in
                store.settings.ds4BackAsTouchpadClick = v
                store.patchSettings(["ds4_back_as_touchpad_click": v])
              }
            )
          )

          LabeledContent(l10n.pick("Back→Guide 에뮬레이션 시간 (ms)", "Back Button Timeout (ms)")) {
            TextField("", value: $backTimeoutDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("가이드 버튼 가상 키코드 (0–255)", "Guide Button Keycode")) {
            TextField("", value: $guideKeyDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("가이드 버튼 컨트롤러 슬롯 (0–15)", "Guide Button Controller Slot")) {
            TextField("", value: $guideSlotDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }
        }

        Section(l10n.pick("키보드 반복 및 키 매핑", "Keyboard Repeat & Key Mapping")) {
          Toggle(
            l10n.pick("우측 Option(Alt) 키를 Command 키로 매핑", "Map Right Option to Command"),
            isOn: Binding(
              get: { store.settings.keyRightAltToKeyWin },
              set: { v in
                store.settings.keyRightAltToKeyWin = v
                store.patchSettings(["key_rightalt_to_key_win": v])
              }
            )
          )

          Toggle(
            l10n.pick("항상 물리 키 스캔코드 전송", "Always Send Scancodes"),
            isOn: Binding(
              get: { store.settings.alwaysSendScancodes },
              set: { v in
                store.settings.alwaysSendScancodes = v
                store.patchSettings(["always_send_scancodes": v])
              }
            )
          )

          LabeledContent(l10n.pick("키 반복 시작 지연 (ms)", "Key Repeat Delay (ms)")) {
            TextField("", value: $repeatDelayDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("키 반복 속도 (회/초)", "Key Repeat Frequency (Hz)")) {
            TextField("", value: $repeatFreqDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("커스텀 키 바인딩 목록", "Custom Keybindings")) {
            TextField("", text: $keybindingsDraft, prompt: Text("[0x10, 0xA0, ...]"))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 200)
              .onSubmit(commitFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("입력 고급 옵션", "Advanced Input Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 500, height: 490)
    .onAppear {
      backTimeoutDraft = store.settings.backButtonTimeout
      guideKeyDraft = store.settings.guideButtonKey
      guideSlotDraft = store.settings.guideButtonController
      repeatDelayDraft = store.settings.keyRepeatDelay
      repeatFreqDraft = store.settings.keyRepeatFrequency
      keybindingsDraft = store.settings.keybindings
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    var patch: [String: Any] = [:]
    if backTimeoutDraft != store.settings.backButtonTimeout {
      store.settings.backButtonTimeout = backTimeoutDraft
      patch["back_button_timeout"] = backTimeoutDraft
    }
    let gk = max(0, min(255, guideKeyDraft))
    if gk != store.settings.guideButtonKey {
      store.settings.guideButtonKey = gk
      patch["guide_button_key"] = gk
    }
    let gs = max(0, min(15, guideSlotDraft))
    if gs != store.settings.guideButtonController {
      store.settings.guideButtonController = gs
      patch["guide_button_controller"] = gs
    }
    let rd = max(0, repeatDelayDraft)
    if rd != store.settings.keyRepeatDelay {
      store.settings.keyRepeatDelay = rd
      patch["key_repeat_delay"] = rd
    }
    let rf = max(0.1, repeatFreqDraft)
    if abs(rf - store.settings.keyRepeatFrequency) > 0.01 {
      store.settings.keyRepeatFrequency = rf
      patch["key_repeat_frequency"] = rf
    }
    let kb = keybindingsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if kb != store.settings.keybindings {
      store.settings.keybindings = kb
      patch["keybindings"] = kb
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

struct AudioAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var audioSinkDraft: String = ""
  @ViewState private var virtualSinkDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(
            l10n.pick("Dolby 서라운드 고음질 비트레이트 (AC-3 / E-AC-3)", "High-Quality Dolby Bitrate"),
            isOn: Binding(
              get: { store.settings.highQualityAudio },
              set: { v in
                store.settings.highQualityAudio = v
                store.patchSettings(["high_quality_audio": v])
              }
            )
          )

          Toggle(
            l10n.pick("기본 오디오 출력 장치 유지", "Keep Default Audio Output"),
            isOn: Binding(
              get: { store.settings.keepSinkDefault },
              set: { v in
                store.settings.keepSinkDefault = v
                store.patchSettings(["keep_sink_default": v])
              }
            )
          )

          Toggle(
            l10n.pick("활성 오디오 출력 자동 캡처", "Auto-Capture Active Sink"),
            isOn: Binding(
              get: { store.settings.autoCaptureSink },
              set: { v in
                store.settings.autoCaptureSink = v
                store.patchSettings(["auto_capture_sink": v])
              }
            )
          )
        }

        Section(l10n.pick("오디오 장치 지정 (비워 두면 시스템 기본)", "Audio Sink Override")) {
          LabeledContent(l10n.pick("오디오 싱크 (audio_sink)", "Audio Sink")) {
            TextField("", text: $audioSinkDraft, prompt: Text(l10n.pick("시스템 기본", "System Default")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 210)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("가상 오디오 싱크 (virtual_sink)", "Virtual Sink")) {
            TextField("", text: $virtualSinkDraft, prompt: Text(l10n.pick("선택 사항", "Optional")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 210)
              .onSubmit(commitFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("오디오 고급 옵션", "Advanced Audio Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 470, height: 315)
    .onAppear {
      audioSinkDraft = store.settings.audioSink
      virtualSinkDraft = store.settings.virtualSink
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    var patch: [String: Any] = [:]
    let s1 = audioSinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if s1 != store.settings.audioSink {
      store.settings.audioSink = s1
      patch["audio_sink"] = s1
    }
    let s2 = virtualSinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if s2 != store.settings.virtualSink {
      store.settings.virtualSink = s2
      patch["virtual_sink"] = s2
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
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

// MARK: - 7B. Steam 라이브러리 연동 시트 (Steam Integration Sheet)

struct SteamIntegrationSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var recentGamesDraft: Int = 10
  @ViewState private var recentDaysDraft: Int = 30
  @ViewState private var syncFeedback: String? = nil

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent(l10n.pick("Steam 설치 상태", "Steam Status")) {
            Text(store.steamInstalled ? l10n.pick("감지됨", "Detected") : l10n.pick("설치되지 않음", "Not Installed"))
              .foregroundStyle(.secondary)
          }

          Toggle(
            l10n.pick("Steam 연동 활성화", "Enable Steam Integration"),
            isOn: Binding(
              get: { store.settings.steamEnabled },
              set: { v in
                store.settings.steamEnabled = v
                store.patchSettings(["steam_enabled": v])
              }
            )
          )

          Toggle(
            l10n.pick("백그라운드 자동 동기화", "Automatic Background Sync"),
            isOn: Binding(
              get: { store.settings.steamAutoSync },
              set: { v in
                store.settings.steamAutoSync = v
                store.patchSettings(["steam_auto_sync": v])
              }
            )
          )
        }

        Section(l10n.pick("동기화 범위", "Sync Policy")) {
          Toggle(
            l10n.pick("설치된 전체 게임 등록 (끄면 최근 플레이 기준)", "Sync All Installed Games"),
            isOn: Binding(
              get: { store.settings.steamSyncAllInstalled },
              set: { v in
                store.settings.steamSyncAllInstalled = v
                store.patchSettings(["steam_sync_all_installed": v])
              }
            )
          )

          if !store.settings.steamSyncAllInstalled {
            LabeledContent(l10n.pick("최근 플레이 게임 최대 개수", "Max Recent Games")) {
              TextField("", value: $recentGamesDraft, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onSubmit(commitFields)
            }

            LabeledContent(l10n.pick("최근 플레이 기준 일수", "Max Recent Age (Days)")) {
              TextField("", value: $recentDaysDraft, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onSubmit(commitFields)
            }
          }

          Toggle(
            l10n.pick("제거된 Steam 게임 앱 목록에서 자동 삭제", "Remove Uninstalled Games Automatically"),
            isOn: Binding(
              get: { store.settings.steamAutosyncRemoveUninstalled },
              set: { v in
                store.settings.steamAutosyncRemoveUninstalled = v
                store.patchSettings(["steam_autosync_remove_uninstalled": v])
              }
            )
          )

          Toggle(
            l10n.pick("도구 및 런타임 항목 포함", "Include Steam Tools & Runtimes"),
            isOn: Binding(
              get: { store.settings.steamIncludeTools },
              set: { v in
                store.settings.steamIncludeTools = v
                store.patchSettings(["steam_include_tools": v])
              }
            )
          )
        }

        Section {
          HStack {
            if let syncFeedback {
              Text(syncFeedback)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.pick("지금 동기화", "Sync Now")) {
              commitFields()
              let ok = store.syncSteamCatalog()
              syncFeedback = ok
                ? l10n.pick("동기화를 완료했습니다.", "Steam library synced.")
                : l10n.pick("Steam 카탈로그를 찾지 못했습니다.", "Steam catalog not found.")
            }
            .disabled(!store.steamInstalled)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("Steam 라이브러리 연동", "Steam Library Integration"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 470, height: 420)
    .onAppear {
      recentGamesDraft = store.settings.steamRecentGames
      recentDaysDraft = store.settings.steamRecentMaxAgeDays
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    var patch: [String: Any] = [:]
    let rg = max(1, recentGamesDraft)
    if rg != store.settings.steamRecentGames {
      store.settings.steamRecentGames = rg
      patch["steam_recent_games"] = rg
    }
    let rd = max(1, recentDaysDraft)
    if rd != store.settings.steamRecentMaxAgeDays {
      store.settings.steamRecentMaxAgeDays = rd
      patch["steam_recent_max_age_days"] = rd
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

// MARK: - 7C. 앱 고급 실행 정책 시트 (App Advanced Launch Options Sheet)

private struct DetachedCmdDraftRow: Identifiable, Equatable {
  var id: UUID = UUID()
  var cmd: String
}

struct AppAdvancedOptionsSheet: View {
  @Binding var app: StreamAppItem
  let l10n: L10n
  @Environment(\.dismiss) private var dismiss
  @ViewState private var detachedRows: [DetachedCmdDraftRow] = []

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("프로세스 및 디스플레이 정책", "Process & Display Policy")) {
          Toggle(l10n.pick("하위 프로세스가 모두 종료될 때까지 대기 (wait-all)", "Wait for All Child Processes"), isOn: $app.waitAll)
          Toggle(l10n.pick("스트림 일시정지 시 앱 자동 종료", "Terminate App on Stream Pause"), isOn: $app.terminateOnPause)
          Toggle(l10n.pick("전용 가상 디스플레이 항상 활성화", "Always Use Virtual Display"), isOn: $app.virtualScreen)
          Toggle(l10n.pick("HDR 요청 시 10-bit SDR 우선 사용", "Prefer 10-bit SDR over HDR"), isOn: $app.prefer10BitSdr)
          Toggle(l10n.pick("호스트 전역 준비 명령어 건너뛰기", "Exclude Global Prep Commands"), isOn: $app.excludeGlobalPrepCmd)

          LabeledContent(l10n.pick("앱 종료 대기 제한 시간 (초)", "Exit Timeout (Seconds)")) {
            TextField("", value: $app.exitTimeout, format: .number.grouping(.never))
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 80)
          }
        }

        Section(l10n.pick("앱 준비 명령어 (실행 전 Do / 종료 후 Undo)", "Application Prep Commands")) {
          ForEach(app.prepCmds) { item in
            let itemID = item.id
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("Do")
                  .font(.system(size: 11.5))
                  .foregroundStyle(.secondary)
                  .frame(width: 44, alignment: .leading)
                TextField(
                  "",
                  text: Binding(
                    get: { app.prepCmds.first(where: { $0.id == itemID })?.doCmd ?? "" },
                    set: { nextVal in
                      if let idx = app.prepCmds.firstIndex(where: { $0.id == itemID }) {
                        app.prepCmds[idx].doCmd = nextVal
                      }
                    }
                  ),
                  prompt: Text("sh -c ...")
                )
                .font(.system(size: 12, design: .monospaced))

                Button(role: .destructive) {
                  app.prepCmds.removeAll(where: { $0.id == itemID })
                } label: {
                  Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
              }

              HStack {
                Text("Undo")
                  .font(.system(size: 11.5))
                  .foregroundStyle(.secondary)
                  .frame(width: 44, alignment: .leading)
                TextField(
                  "",
                  text: Binding(
                    get: { app.prepCmds.first(where: { $0.id == itemID })?.undoCmd ?? "" },
                    set: { nextVal in
                      if let idx = app.prepCmds.firstIndex(where: { $0.id == itemID }) {
                        app.prepCmds[idx].undoCmd = nextVal
                      }
                    }
                  ),
                  prompt: Text("sh -c ...")
                )
                .font(.system(size: 12, design: .monospaced))
              }
            }
            .padding(.vertical, 2)
          }

          Button(l10n.pick("+ 준비 명령어 추가", "+ Add Prep Command")) {
            app.prepCmds.append(StreamAppPrepCmd())
          }
        }

        Section(l10n.pick("분리 실행 명령어 (Detached Commands)", "Detached Commands")) {
          ForEach(detachedRows) { row in
            let rowID = row.id
            HStack {
              TextField(
                "",
                text: Binding(
                  get: { detachedRows.first(where: { $0.id == rowID })?.cmd ?? "" },
                  set: { nextVal in
                    if let idx = detachedRows.firstIndex(where: { $0.id == rowID }) {
                      detachedRows[idx].cmd = nextVal
                      app.detached = detachedRows.map(\.cmd)
                    }
                  }
                ),
                prompt: Text("open ...")
              )
              .font(.system(size: 12, design: .monospaced))

              Button(role: .destructive) {
                detachedRows.removeAll(where: { $0.id == rowID })
                app.detached = detachedRows.map(\.cmd)
              } label: {
                Image(systemName: "minus.circle.fill")
              }
              .buttonStyle(.borderless)
            }
          }

          Button(l10n.pick("+ 분리 실행 명령어 추가", "+ Add Detached Command")) {
            detachedRows.append(DetachedCmdDraftRow(cmd: ""))
            app.detached = detachedRows.map(\.cmd)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("고급 앱 실행 정책", "Advanced Launch Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            app.detached = detachedRows.map(\.cmd)
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 480, height: 460)
    .onAppear {
      detachedRows = app.detached.map { DetachedCmdDraftRow(cmd: $0) }
    }
    .onDisappear {
      app.detached = detachedRows.map(\.cmd)
    }
  }
}

// MARK: - 공통 설정 덮어쓰기 편집 시트 (Per-Device & Per-App Config Overrides Editor)

private struct OverrideRowEntry: Identifiable, Equatable {
  var id: UUID = UUID()
  var key: String
  var value: String
}

struct ConfigOverridesSheet: View {
  let title: String
  let l10n: L10n
  let onSave: ([String: String]) -> Void
  @Environment(\.dismiss) private var dismiss

  @ViewState private var rows: [OverrideRowEntry]
  @ViewState private var selectedPresetKey: String = "max_bitrate"

  init(
    title: String,
    l10n: L10n,
    initialOverrides: [String: String],
    onSave: @escaping ([String: String]) -> Void
  ) {
    self.title = title
    self.l10n = l10n
    self.onSave = onSave
    let sorted = initialOverrides.keys.sorted().map { k in
      OverrideRowEntry(key: k, value: initialOverrides[k] ?? "")
    }
    self._rows = ViewState(wrappedValue: sorted)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 10) {
            Picker(l10n.pick("항목 선택", "Setting Key"), selection: $selectedPresetKey) {
              ForEach(OverrideableSettingCatalog.keys, id: \.self) { k in
                Text(k).tag(k)
              }
            }
            .frame(maxWidth: .infinity)

            Button(l10n.pick("추가", "Add")) {
              if !rows.contains(where: { $0.key == selectedPresetKey }) {
                rows.append(OverrideRowEntry(key: selectedPresetKey, value: ""))
              }
            }
          }
        }

        Section(l10n.pick("적용 중인 덮어쓰기 항목", "Active Overrides")) {
          if rows.isEmpty {
            Text(l10n.pick("등록된 개별 설정이 없습니다. 호스트 전역 설정을 그대로 따릅니다.", "No overrides set. Follows global host settings."))
              .foregroundStyle(.secondary)
          } else {
            ForEach(rows) { row in
              let rowID = row.id
              HStack(spacing: 8) {
                TextField(
                  "",
                  text: Binding(
                    get: { rows.first(where: { $0.id == rowID })?.key ?? "" },
                    set: { nextVal in
                      if let idx = rows.firstIndex(where: { $0.id == rowID }) {
                        rows[idx].key = nextVal
                      }
                    }
                  ),
                  prompt: Text("key")
                )
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 195)

                TextField(
                  "",
                  text: Binding(
                    get: { rows.first(where: { $0.id == rowID })?.value ?? "" },
                    set: { nextVal in
                      if let idx = rows.firstIndex(where: { $0.id == rowID }) {
                        rows[idx].value = nextVal
                      }
                    }
                  ),
                  prompt: Text(l10n.pick("값 입력", "Value"))
                )
                .font(.system(size: 12, design: .monospaced))

                Button(role: .destructive) {
                  rows.removeAll(where: { $0.id == rowID })
                } label: {
                  Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
              }
            }
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(title)
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
            var map: [String: String] = [:]
            for r in rows {
              let k = r.key.trimmingCharacters(in: .whitespacesAndNewlines)
              let v = r.value.trimmingCharacters(in: .whitespacesAndNewlines)
              if !k.isEmpty && !v.isEmpty {
                map[k] = v
              }
            }
            onSave(map)
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 490, height: 360)
  }
}
