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
