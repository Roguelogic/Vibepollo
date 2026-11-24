import AppKit
import SwiftUI

// MARK: - 1. 소프트웨어 업데이트 하위 페이지 (Apple macOS Software Update 1:1)

private enum SoftwareUpdateTextHelper {
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter
  }()

  private static let lastCheckedKoFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  private static let lastCheckedEnFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  static func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "" }
    return byteFormatter.string(fromByteCount: bytes)
  }

  static func formatLastChecked(_ unix: Int64, isKo: Bool) -> String? {
    guard unix > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(unix))
    let formatter = isKo ? lastCheckedKoFormatter : lastCheckedEnFormatter
    return formatter.string(from: date)
  }

  static func cleanReleaseNotes(_ raw: String, preferKorean: Bool) -> [String] {
    guard !raw.isEmpty else { return [] }
    // Strip HTML comments (such as <!-- nightly-identity: ... -->)
    var cleaned = raw
    while let start = cleaned.range(of: "<!--"),
          let end = cleaned.range(of: "-->", range: start.upperBound..<cleaned.endIndex) {
      cleaned.removeSubrange(start.lowerBound..<end.upperBound)
    }

    let rawLines = cleaned.components(separatedBy: .newlines)
    var koLines: [String] = []
    var enLines: [String] = []
    var neutralLines: [String] = []

    enum LangSection {
      case neutral, ko, en, skip
    }
    var currentSection: LangSection = .neutral
    var insideCodeFence = false

    for rawLine in rawLines {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        insideCodeFence.toggle()
        continue
      }
      if insideCodeFence {
        continue
      }
      if trimmed == "---" || trimmed == "***" {
        continue
      }
      if trimmed.hasPrefix("#") {
        let heading = trimmed.drop(while: { $0 == "#" || $0 == " " })
        let lower = heading.lowercased()
        if lower.contains("sha-256") || lower.contains("sha256") || lower.contains("checksum") {
          currentSection = .skip
          continue
        }
        if heading.contains("한국어") || lower == "korean" {
          currentSection = .ko
          continue
        }
        if lower == "english" || heading.contains("영어") {
          currentSection = .en
          continue
        }
        if lower.hasPrefix("what's new") {
          continue
        }
      }

      guard currentSection != .skip, !trimmed.isEmpty else { continue }
      let formatted = stripInlineMarkdown(trimmed)
      guard !formatted.isEmpty else { continue }

      switch currentSection {
      case .ko:
        koLines.append(formatted)
      case .en:
        enLines.append(formatted)
      case .neutral:
        neutralLines.append(formatted)
      case .skip:
        break
      }
    }

    if preferKorean && !koLines.isEmpty {
      return koLines
    }
    if !preferKorean && !enLines.isEmpty {
      return enLines
    }
    if !koLines.isEmpty || !enLines.isEmpty {
      return preferKorean ? (koLines + enLines) : (enLines + koLines)
    }
    return neutralLines
  }

  private static func stripInlineMarkdown(_ line: String) -> String {
    var out = line
    if out.hasPrefix("- ") || out.hasPrefix("* ") {
      out = "• " + out.dropFirst(2)
    } else if out.hasPrefix("#") {
      out = String(out.drop(while: { $0 == "#" || $0 == " " }))
    }
    out = out.replacingOccurrences(of: "**", with: "")
    out = out.replacingOccurrences(of: "`", with: "")
    return out.trimmingCharacters(in: .whitespaces)
  }
}

struct SoftwareUpdateSubView: View {
  @ObservedObject var store: HostStore
  @ViewState private var showAutoUpdateSheet = false
  @ViewState private var showBetaSheet = false
  @ViewState private var showMoreInfoSheet = false
  @ViewState private var showActiveStreamConfirm = false

  private var l10n: L10n { store.l10n }
  private var u: SoftwareUpdateSnapshot { store.softwareUpdate }

  private var currentVersionDisplay: String {
    if !u.currentVersion.isEmpty {
      return u.currentVersion
    }
    return store.dashboard.version.isEmpty ? VibepolloHostBridge.shared().appVersion() : store.dashboard.version
  }

  private var appIconImage: NSImage {
    NSApp.applicationIconImage ?? NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: nil) ?? NSImage()
  }

  private var automaticUpdateSummaryText: String {
    let checkOn = store.settings.updateCheckInterval > 0
    if !checkOn {
      return l10n.pick("끔", "Off")
    }
    if store.settings.autoDownloadUpdates && store.settings.autoInstallUpdates {
      return l10n.pick("켬", "On")
    }
    if store.settings.autoDownloadUpdates {
      return l10n.pick("다운로드만", "Only Download")
    }
    return l10n.pick("확인만", "Check Only")
  }

  private var betaUpdateSummaryText: String {
    store.settings.notifyPreReleases
      ? l10n.pick("Vibepollo 베타", "Vibepollo Beta")
      : l10n.pick("끔", "Off")
  }

  var body: some View {
    Form {
      Section {
        switch u.phase {
        case "idle", "checking":
          checkingView
        case "up_to_date":
          upToDateView
        case "available", "downloaded":
          availableUpdateView
        case "downloading", "verifying", "installing", "restarting":
          installingProgressView
        case "error":
          errorStateView
        default:
          upToDateView
        }
      }

      Section {
        LabeledContent(l10n.pick("자동 업데이트", "Automatic Updates")) {
          HStack(spacing: 6) {
            Text(automaticUpdateSummaryText)
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            Button {
              showAutoUpdateSheet = true
            } label: {
              Image(systemName: "info.circle")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(l10n.pick("자동 업데이트 옵션", "Automatic Updates Options"))
          }
        }

        LabeledContent(l10n.pick("베타 업데이트", "Beta Updates")) {
          HStack(spacing: 6) {
            Text(betaUpdateSummaryText)
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
            Button {
              showBetaSheet = true
            } label: {
              Image(systemName: "info.circle")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(l10n.pick("베타 업데이트 설정", "Beta Updates Settings"))
          }
        }
      }
    }
    .vibepolloSettingsForm()
    .onAppear {
      store.refreshSoftwareUpdate()
      let now = Int64(Date().timeIntervalSince1970)
      let stale = (now - store.softwareUpdate.lastCheckedUnix) > 60
      if store.softwareUpdate.phase == "idle" || (store.softwareUpdate.phase == "up_to_date" && stale && !store.softwareUpdate.isBusy) {
        store.checkForUpdatesNow()
      }
    }
    .sheet(isPresented: $showAutoUpdateSheet) {
      SoftwareUpdateAutomaticSheet(store: store)
    }
    .sheet(isPresented: $showBetaSheet) {
      SoftwareUpdateBetaSheet(store: store)
    }
    .sheet(isPresented: $showMoreInfoSheet) {
      SoftwareUpdateMoreInfoSheet(store: store) {
        triggerInstallWithSessionCheck()
      }
    }
    .alert(
      l10n.pick("현재 스트리밍 세션이 연결되어 있습니다", "Active Streaming Session Connected"),
      isPresented: $showActiveStreamConfirm
    ) {
      Button(l10n.pick("지금 업데이트 및 재시작", "Update & Restart Now"), role: .destructive) {
        store.installUpdateNow()
      }
      Button(l10n.pick("스트리밍 종료 후 자동 설치", "Update After Stream Ends")) {
        store.setUpdateScheduledOnIdle(true)
      }
      Button(l10n.pick("취소", "Cancel"), role: .cancel) {}
    } message: {
      Text(
        l10n.pick(
          "지금 업데이트하면 연결된 클라이언트의 스트리밍이 잠시 끊어지고 새 버전으로 재시작됩니다.",
          "Updating now will briefly disconnect active clients while Vibepollo restarts into the new version."
        )
      )
    }
  }

  private func triggerInstallWithSessionCheck() {
    if !store.dashboard.sessions.isEmpty {
      showActiveStreamConfirm = true
    } else {
      store.installUpdateNow()
    }
  }

  @ViewBuilder
  private var checkingView: some View {
    HStack(spacing: 14) {
      Image(nsImage: appIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 46, height: 46)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(l10n.pick("업데이트 확인 중…", "Checking for updates…"))
            .font(.system(size: 13.5, weight: .semibold))
        }
        Text("Vibepollo \(currentVersionDisplay)")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var upToDateView: some View {
    HStack(spacing: 14) {
      Image(nsImage: appIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 46, height: 46)
      VStack(alignment: .leading, spacing: 3) {
        Text(l10n.pick("Vibepollo가 최신 버전입니다.", "Vibepollo is up to date."))
          .font(.system(size: 13.5, weight: .semibold))
        Text("Vibepollo \(currentVersionDisplay)")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        if let lastStr = SoftwareUpdateTextHelper.formatLastChecked(u.lastCheckedUnix, isKo: l10n.isKo) {
          Text(l10n.pick("마지막 확인: \(lastStr)", "Last checked: \(lastStr)"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
      Spacer()
      Button(l10n.pick("다시 확인", "Check Again")) {
        store.checkForUpdatesNow()
      }
      .disabled(u.isBusy)
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var availableUpdateView: some View {
    let notesPreview = Array(SoftwareUpdateTextHelper.cleanReleaseNotes(u.availableBody, preferKorean: l10n.isKo).prefix(3))
    let sizeText = SoftwareUpdateTextHelper.formatBytes(u.assetSize)
    let isDownloaded = (u.phase == "downloaded")

    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .center, spacing: 13) {
        Image(nsImage: appIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text("Vibepollo \(u.availableVersion)")
              .font(.system(size: 13.5, weight: .semibold))
            if u.isPrerelease {
              Text(l10n.pick("베타", "Beta"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
          }

          HStack(spacing: 4) {
            Text(u.availableVersion)
            if !sizeText.isEmpty {
              Text("• \(sizeText)")
            }
            if isDownloaded {
              Text(l10n.pick("— 다운로드됨", "— Downloaded"))
                .foregroundStyle(.primary.opacity(0.75))
            }
          }
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        if !u.canSelfUpdate {
          Button(l10n.pick("다운로드 페이지 열기…", "Open Release Page…")) {
            if !u.availableUrl.isEmpty {
              store.openExternalURL(u.availableUrl)
            }
          }
          .buttonStyle(.borderedProminent)
        } else if u.scheduledOnIdle {
          HStack(spacing: 8) {
            Button(l10n.pick("예정된 업데이트 취소", "Cancel Scheduled Update")) {
              store.setUpdateScheduledOnIdle(false)
            }
            Button(isDownloaded ? l10n.pick("지금 재시작", "Restart Now") : l10n.pick("지금 업데이트", "Update Now")) {
              triggerInstallWithSessionCheck()
            }
            .buttonStyle(.borderedProminent)
          }
        } else {
          HStack(spacing: 8) {
            if !store.dashboard.sessions.isEmpty {
              Button(l10n.pick("유휴 시 업데이트", "Update When Idle")) {
                store.setUpdateScheduledOnIdle(true)
              }
            }
            Button(isDownloaded ? l10n.pick("지금 재시작", "Restart Now") : l10n.pick("지금 업데이트", "Update Now")) {
              triggerInstallWithSessionCheck()
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }

      if !notesPreview.isEmpty {
        VStack(alignment: .leading, spacing: 3.5) {
          ForEach(Array(notesPreview.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .padding(.leading, 57)
      }

      HStack {
        Button {
          showMoreInfoSheet = true
        } label: {
          Text(l10n.pick("자세한 정보…", "More Info…"))
            .font(.system(size: 12))
        }
        .buttonStyle(.link)

        Spacer()
      }
      .padding(.leading, 57)

      if u.scheduledOnIdle {
        HStack(spacing: 6) {
          Image(systemName: "clock.badge.checkmark")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
          Text(
            l10n.pick(
              "연결된 스트리밍 세션이 종료되면 자동으로 설치하고 Vibepollo를 재시작합니다.",
              "Vibepollo will automatically install this update and restart once active streams end."
            )
          )
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        }
        .padding(.leading, 57)
      } else if !u.canSelfUpdate {
        HStack(spacing: 6) {
          Image(systemName: "info.circle")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
          Text(nonUpdatableBundleHint)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 57)
      }
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var installingProgressView: some View {
    let total = max(u.totalBytes, u.assetSize)
    let downloaded = max(0, min(u.downloadedBytes, total > 0 ? total : u.downloadedBytes))

    HStack(alignment: .center, spacing: 13) {
      Image(nsImage: appIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 6) {
        Text(u.availableVersion.isEmpty ? "Vibepollo" : "Vibepollo \(u.availableVersion)")
          .font(.system(size: 13.5, weight: .semibold))

        if u.phase == "downloading" && total > 0 {
          ProgressView(value: Double(downloaded), total: Double(total))
            .progressViewStyle(.linear)
          Text(
            l10n.pick(
              "업데이트 다운로드 중… — \(SoftwareUpdateTextHelper.formatBytes(downloaded)) / \(SoftwareUpdateTextHelper.formatBytes(total))",
              "Downloading update… — \(SoftwareUpdateTextHelper.formatBytes(downloaded)) of \(SoftwareUpdateTextHelper.formatBytes(total))"
            )
          )
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        } else {
          ProgressView()
            .progressViewStyle(.linear)
          Text(progressPhaseCaption)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
      }

      if u.phase == "downloading" {
        Spacer(minLength: 8)
        Button(l10n.pick("취소", "Cancel")) {
          store.cancelUpdateDownload()
        }
      }
    }
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var errorStateView: some View {
    HStack(alignment: .center, spacing: 13) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 26))
        .foregroundStyle(.orange)
        .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 3) {
        Text(errorTitleText)
          .font(.system(size: 13.5, weight: .semibold))
        Text(errorDescriptionText)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        if !u.availableUrl.isEmpty && (u.errorCode == "read_only_bundle" || u.errorCode == "not_app_bundle" || u.errorCode == "install_failed") {
          Button(l10n.pick("릴리스 열기…", "Open Release…")) {
            store.openExternalURL(u.availableUrl)
          }
        }
        Button(l10n.pick("다시 시도", "Try Again")) {
          if !u.availableVersion.isEmpty && u.errorCode != "scan_failed" && u.canSelfUpdate {
            triggerInstallWithSessionCheck()
          } else {
            store.checkForUpdatesNow()
          }
        }
      }
    }
    .padding(.vertical, 6)
  }

  private var progressPhaseCaption: String {
    switch u.phase {
    case "downloading":
      return l10n.pick("업데이트 다운로드 중…", "Downloading update…")
    case "verifying":
      return l10n.pick("업데이트 무결성 및 코드 서명 검증 중…", "Verifying update integrity and signature…")
    case "installing":
      return l10n.pick("업데이트 준비 및 설치 중…", "Preparing and installing update…")
    case "restarting":
      return l10n.pick("Vibepollo 재시작 중…", "Restarting Vibepollo…")
    default:
      return l10n.pick("처리 중…", "Working…")
    }
  }

  private var nonUpdatableBundleHint: String {
    if u.bundleReason == "read_only_bundle" {
      return l10n.pick(
        "읽기 전용 디스크 이미지(DMG)에서 실행 중입니다. Vibepollo.app을 응용 프로그램(/Applications) 폴더로 옮긴 후 업데이트하십시오.",
        "Vibepollo is running from a read-only disk image. Move Vibepollo.app to /Applications to install updates automatically."
      )
    }
    return l10n.pick(
      "앱 번들(.app) 외부에서 실행 중이므로 인앱 자동 교체 대신 GitHub 릴리스 페이지로 안내합니다.",
      "Running outside a standard .app bundle; updates can be downloaded from GitHub Releases."
    )
  }

  private var errorTitleText: String {
    switch u.errorCode {
    case "download_failed", "checksum_mismatch":
      return l10n.pick("소프트웨어 업데이트를 다운로드할 수 없음", "Unable to download software update")
    case "signature_invalid", "read_only_bundle", "not_app_bundle", "install_failed":
      return l10n.pick("소프트웨어를 설치할 수 없습니다.", "Can’t install the software.")
    default:
      return l10n.pick("업데이트를 확인할 수 없음", "Unable to check for updates")
    }
  }

  private var errorDescriptionText: String {
    switch u.errorCode {
    case "checksum_mismatch":
      return l10n.pick(
        "다운로드한 업데이트 파일의 무결성(SHA-256) 검증에 실패했습니다. 다시 시도해 주십시오.",
        "The downloaded update package failed SHA-256 integrity verification. Please try again."
      )
    case "signature_invalid":
      return l10n.pick(
        "업데이트 패키지의 Apple 개발자 서명이 유효하지 않거나 현재 설치된 앱과 일치하지 않습니다.",
        "The update bundle’s code signature or Developer Team ID did not match the installed app."
      )
    case "read_only_bundle":
      return nonUpdatableBundleHint
    case "not_app_bundle":
      return nonUpdatableBundleHint
    case "download_failed":
      return l10n.pick(
        "네트워크 문제 때문에 소프트웨어를 다운로드할 수 없습니다. 인터넷 연결을 확인하고 다시 시도하십시오.",
        "Can’t download the software because of a network problem. Check your internet connection and try again."
      )
    case "install_failed":
      return u.errorDetail.isEmpty
        ? l10n.pick("업데이트 적용 중 오류가 발생했습니다. 다시 시도하십시오.", "An error occurred while installing the update. Please try again.")
        : u.errorDetail
    default:
      return l10n.pick(
        "인터넷 연결을 확인하고 다시 시도하십시오.",
        "Please check your internet connection and try again."
      )
    }
  }
}

// MARK: - 1.1 자동 업데이트 옵션 시트 (Apple Automatic Updates Sheet)

struct SoftwareUpdateAutomaticSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  private var checkEnabled: Bool {
    store.settings.updateCheckInterval > 0
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(
            l10n.pick("업데이트 확인", "Check for updates"),
            isOn: Binding(
              get: { checkEnabled },
              set: { store.setAutomaticCheckEnabled($0) }
            )
          )

          if checkEnabled {
            Picker(
              l10n.pick("자동 확인 주기", "Check Frequency"),
              selection: Binding(
                get: { store.settings.updateCheckInterval },
                set: { v in
                  store.settings.updateCheckInterval = v
                  store.patchSettings(["update_check_interval": v])
                }
              )
            ) {
              Text(l10n.pick("매시간", "Hourly")).tag(3600)
              Text(l10n.pick("매일 (기본)", "Daily (Default)")).tag(86400)
              Text(l10n.pick("매주", "Weekly")).tag(604800)
              if ![3600, 86400, 604800].contains(store.settings.updateCheckInterval) {
                Text("\(store.settings.updateCheckInterval)s").tag(store.settings.updateCheckInterval)
              }
            }
          }

          Toggle(
            l10n.pick("사용 가능할 때 새로운 업데이트 다운로드", "Download new updates when available"),
            isOn: Binding(
              get: { checkEnabled && store.settings.autoDownloadUpdates },
              set: { store.setAutomaticDownloadEnabled($0) }
            )
          )
          .disabled(!checkEnabled)

          Toggle(
            l10n.pick("Vibepollo 업데이트 설치", "Install Vibepollo updates"),
            isOn: Binding(
              get: { checkEnabled && store.settings.autoDownloadUpdates && store.settings.autoInstallUpdates },
              set: { store.setAutomaticInstallEnabled($0) }
            )
          )
          .disabled(!checkEnabled || !store.settings.autoDownloadUpdates)
        } footer: {
          Text(
            l10n.pick(
              "원격 스트리밍 중에는 연결이 끊기지 않도록 대기하며, 스트리밍 세션이 없는 유휴 상태일 때만 자동으로 업데이트를 설치하고 재시작합니다.",
              "Vibepollo waits while remote streams are active and installs updates automatically only when idle."
            )
          )
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("자동 업데이트", "Automatic Updates"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 460, height: checkEnabled ? 305 : 265)
  }
}

// MARK: - 1.2 베타 업데이트 시트 (Apple Beta Updates Sheet)

struct SoftwareUpdateBetaSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker(
            l10n.pick("베타 업데이트", "Beta Updates"),
            selection: Binding(
              get: { store.settings.notifyPreReleases },
              set: { store.setBetaUpdatesEnabled($0) }
            )
          ) {
            Text(l10n.pick("끔", "Off")).tag(false)
            Text(l10n.pick("Vibepollo 베타 업데이트", "Vibepollo Beta Updates")).tag(true)
          }
        } footer: {
          Text(
            l10n.pick(
              "이 Mac에서 Vibepollo 사전 공개(프리릴리스 · 나이틀리) 빌드를 받아 최신 기능을 먼저 사용해 볼 수 있습니다. 끄면 정식 안정화 릴리스만 확인합니다.",
              "Receive pre-release and nightly builds on this Mac to try new features early. Turn off to receive stable releases only."
            )
          )
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("베타 업데이트", "Beta Updates"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 450, height: 220)
  }
}

// MARK: - 1.3 업데이트 자세한 정보 시트 (Apple More Info… Sheet)

struct SoftwareUpdateMoreInfoSheet: View {
  @ObservedObject var store: HostStore
  let onInstallNow: () -> Void
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }
  private var u: SoftwareUpdateSnapshot { store.softwareUpdate }

  private var appIconImage: NSImage {
    NSApp.applicationIconImage ?? NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: nil) ?? NSImage()
  }

  var body: some View {
    let lines = SoftwareUpdateTextHelper.cleanReleaseNotes(u.availableBody, preferKorean: l10n.isKo)
    let sizeText = SoftwareUpdateTextHelper.formatBytes(u.assetSize)
    let isDownloaded = (u.phase == "downloaded")

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 13) {
        Image(nsImage: appIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 3) {
          Text(u.availableName.isEmpty ? "Vibepollo \(u.availableVersion)" : u.availableName)
            .font(.system(size: 15, weight: .semibold))
          HStack(spacing: 4) {
            Text(l10n.pick("버전 \(u.availableVersion)", "Version \(u.availableVersion)"))
            if !sizeText.isEmpty {
              Text("• \(sizeText)")
            }
            Text(l10n.pick("— 재시작이 필요함", "— Restart Required"))
          }
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if lines.isEmpty {
            Text(l10n.pick("이 업데이트에는 성능 및 안정성 개선 사항이 포함되어 있습니다.", "This update includes stability and performance improvements."))
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
          } else {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }
      .background(Color(nsColor: .textBackgroundColor))

      Divider()

      HStack(spacing: 10) {
        if !u.availableUrl.isEmpty {
          Button(l10n.pick("GitHub에서 릴리스 보기…", "View on GitHub…")) {
            store.openExternalURL(u.availableUrl)
          }
          .buttonStyle(.link)
        }

        Spacer()

        Button(l10n.pick("닫기", "Close")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        if u.canSelfUpdate {
          Button(isDownloaded ? l10n.pick("지금 재시작", "Restart Now") : l10n.pick("지금 업데이트", "Update Now")) {
            dismiss()
            onInstallNow()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
    }
    .frame(width: 540, height: 430)
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
            Text(l10n.pick("단독 표시 (물리 화면 숨김, 기본)", "Exclusive (Default)")).tag("exclusive")
            Text(l10n.pick("데스크톱 확장", "Extended")).tag("extended")
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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

  @ViewState private var repeatDelayDraft: Int = 500
  @ViewState private var repeatFreqDraft: Double = 24.9
  @ViewState private var keybindingsDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("입력 세션", "Input Session")) {
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
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 480, height: 340)
    .onAppear {
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
        }

        Section(l10n.pick("CoreAudio 출력 장치 지정 (비워 두면 시스템 전체 오디오)", "CoreAudio Sink Override")) {
          LabeledContent(l10n.pick("오디오 싱크 (audio_sink)", "Audio Sink")) {
            TextField("", text: $audioSinkDraft, prompt: Text(l10n.pick("시스템 기본", "System Default")))
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
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 470, height: 240)
    .onAppear {
      audioSinkDraft = store.settings.audioSink
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    let s1 = audioSinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if s1 != store.settings.audioSink {
      store.settings.audioSink = s1
      store.patchSettings(["audio_sink": s1])
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
            NSApp.keyWindow?.makeFirstResponder(nil)
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
