import AppKit
import SwiftUI

// MARK: - 7. 스트리밍 앱 (Apps Pane & Native Liquid Glass Editor Sheet)

struct AppsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var editingApp: StreamAppItem? = nil
  @ViewState private var showSteamSheet = false

  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          SettingsRowLabel(
            title: l10n.pick("스트리밍 애플리케이션 등록", "Published Applications"),
            subtitle: l10n.pick("클라이언트 앱 목록에 표시할 Mac 앱이나 실행 명령어를 관리합니다.", "Choose which macOS apps or commands appear in Moonlight.")
          )
          Spacer()
          Button(l10n.pick("앱 추가...", "Add App...")) {
            editingApp = StreamAppItem()
          }
        }

        LabeledContent {
          Button(l10n.pick("Steam 연동...", "Steam Sync...")) {
            showSteamSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("Steam 게임 라이브러리 자동 연동", "Steam Library Integration"),
            subtitle: store.steamInstalled
              ? l10n.pick("이 Mac에 설치된 Steam 게임을 앱 목록과 자동으로 동기화합니다.", "Automatically sync installed macOS Steam games into your app list.")
              : l10n.pick("Steam 동기화 정책을 구성합니다 (현재 Steam 미감지).", "Configure Steam sync policy (Steam not currently detected).")
          )
        }
      }

      if store.dashboard.appRunning {
        Section(l10n.pick("실행 중", "Currently Running")) {
          HStack {
            Label(
              store.dashboard.runningAppName.isEmpty ? "App" : store.dashboard.runningAppName,
              systemImage: "play.circle.fill"
            )
            Spacer()
            Button(l10n.pick("강제 종료", "Force Stop"), role: .destructive) {
              store.terminateRunningApp()
            }
            .controlSize(.small)
          }
        }
      }

      Section(l10n.pick("애플리케이션 목록", "Application List")) {
        ForEach(store.apps) { app in
          HStack(spacing: 12) {
            Image(systemName: app.isSystem ? "desktopcomputer" : "app.badge.checkmark")
              .font(.system(size: 15, weight: .regular))
              .foregroundStyle(.secondary)
              .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(app.name)
                  .font(.system(size: 13, weight: .medium))
                if app.isSystem {
                  Text(l10n.pick("기본 제공", "Built-in"))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
                } else if !app.configOverrides.isEmpty {
                  Text(l10n.pick("개별 설정 \(app.configOverrides.count)", "\(app.configOverrides.count) override(s)"))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
                }
              }
              if !app.cmd.isEmpty {
                Text(app.cmd)
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              } else if app.isSystem {
                Text(l10n.pick("전체 macOS 데스크톱 화면 스트리밍", "Full macOS desktop session"))
                  .font(.system(size: 11.5))
                  .foregroundStyle(.secondary)
              }
            }

            Spacer()

            if !app.isSystem {
              Button(l10n.pick("편집...", "Edit...")) {
                editingApp = app
              }
              .controlSize(.small)
            }
          }
          .padding(.vertical, 2)
        }
      }

      Section(l10n.pick("정렬 옵션", "Ordering")) {
        Toggle(
          l10n.pick("클라이언트에 레거시 앱 정렬 순서 제공", "Use Legacy App Ordering"),
          isOn: Binding(
            get: { store.settings.legacyOrdering },
            set: { v in
              store.settings.legacyOrdering = v
              store.patchSettings(["legacy_ordering": v])
            }
          )
        )
      }
    }
    .vibepolloSettingsForm()
    .sheet(item: $editingApp) { item in
      AppEditorSheet(store: store, app: item)
    }
    .sheet(isPresented: $showSteamSheet) {
      SteamIntegrationSheet(store: store)
    }
  }
}

private struct AppEditorSheet: View {
  @ObservedObject var store: HostStore
  @ViewState var app: StreamAppItem
  @Environment(\.dismiss) private var dismiss
  @ViewState private var errorMsg: String? = nil
  @ViewState private var showAdvancedSheet = false
  @ViewState private var showOverridesSheet = false

  private var l10n: L10n { store.l10n }
  private var isNew: Bool { app.uuid.isEmpty }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            SettingsRowLabel(
              title: l10n.pick("Mac 앱에서 불러오기", "Choose from Applications"),
              subtitle: l10n.pick("응용 프로그램 폴더에서 .app을 선택하면 이름과 실행 명령어가 자동 입력됩니다.", "Pick a macOS .app bundle to fill in its name and launch command automatically.")
            )
            Spacer()
            Button(l10n.pick("앱 선택...", "Choose App...")) {
              pickApplicationBundle()
            }
          }
        }

        Section {
          LabeledContent(l10n.pick("이름", "Name")) {
            TextField("", text: $app.name, prompt: Text(l10n.pick("예: Steam", "e.g. Steam")))
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 240)
          }
          LabeledContent(l10n.pick("실행 명령어", "Command")) {
            TextField("", text: $app.cmd, prompt: Text("open -a \"/Applications/Steam.app\""))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 240)
          }
          LabeledContent(l10n.pick("작업 폴더", "Working Directory")) {
            TextField("", text: $app.workingDir, prompt: Text(l10n.pick("선택 사항", "Optional")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 240)
          }
          Toggle(l10n.pick("백그라운드 분리 실행 허용", "Auto-detach process"), isOn: $app.autoDetach)
        }

        Section(l10n.pick("자동화 및 앱별 설정", "Automation & Overrides")) {
          LabeledContent {
            Button(l10n.pick("실행 옵션...", "Launch Options...")) {
              showAdvancedSheet = true
            }
          } label: {
            SettingsRowLabel(
              title: l10n.pick("준비 명령어 및 고급 실행 정책", "Prep Commands & Launch Policy"),
              subtitle: l10n.pick("실행 전/후 스크립트, 종료 대기 시간, 가상 화면 강제 여부를 설정합니다.", "Configure pre/post commands, exit timeout, and virtual display options.")
            )
          }

          LabeledContent {
            Button(l10n.pick("설정 덮어쓰기...", "Overrides...")) {
              showOverridesSheet = true
            }
          } label: {
            SettingsRowLabel(
              title: l10n.pick("앱별 호스트 설정 덮어쓰기", "Per-App Config Overrides"),
              subtitle: app.configOverrides.isEmpty
                ? l10n.pick("이 앱을 스트리밍할 때만 다른 화질·입력·오디오 설정을 적용합니다.", "Override video, input, or audio settings while streaming this app.")
                : l10n.pick("\(app.configOverrides.count)개 항목 설정됨", "\(app.configOverrides.count) override(s) configured")
            )
          }
        }

        if !isNew {
          Section {
            HStack {
              Spacer()
              Button(l10n.pick("애플리케이션 삭제", "Delete Application"), role: .destructive) {
                store.deleteApp(uuid: app.uuid)
                dismiss()
              }
            }
          }
        }

        if let errorMsg {
          Section {
            Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 11.5))
              .foregroundStyle(.red)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(isNew ? l10n.pick("애플리케이션 추가", "Add Application") : l10n.pick("애플리케이션 편집", "Edit Application"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(l10n.pick("취소", "Cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("저장", "Save")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            if let err = store.saveApp(app) {
              errorMsg = err
            } else {
              dismiss()
            }
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .sheet(isPresented: $showAdvancedSheet) {
        AppAdvancedOptionsSheet(app: $app, l10n: l10n)
      }
      .sheet(isPresented: $showOverridesSheet) {
        ConfigOverridesSheet(
          title: l10n.pick("앱별 설정 덮어쓰기", "App Config Overrides"),
          l10n: l10n,
          initialOverrides: app.configOverrides
        ) { updated in
          app.configOverrides = updated
        }
      }
    }
    .frame(width: 480, height: isNew ? 430 : 485)
  }

  private func pickApplicationBundle() {
    let panel = NSOpenPanel()
    panel.title = l10n.pick("스트리밍할 애플리케이션 선택", "Choose Application")
    panel.prompt = l10n.pick("선택", "Choose")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    if panel.runModal() == .OK, let url = panel.url {
      let bundle = Bundle(url: url)
      let displayName =
        (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String) ??
        (bundle?.infoDictionary?["CFBundleDisplayName"] as? String) ??
        (bundle?.localizedInfoDictionary?["CFBundleName"] as? String) ??
        (bundle?.infoDictionary?["CFBundleName"] as? String) ??
        url.deletingPathExtension().lastPathComponent

      let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleanName.isEmpty {
        app.name = cleanName
      }
      let escapedPath = url.path.replacingOccurrences(of: "\"", with: "\\\"")
      app.cmd = "open -a \"\(escapedPath)\""
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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
