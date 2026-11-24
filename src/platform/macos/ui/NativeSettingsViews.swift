import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// ObservableObject-backed local state wrapper that triggers SwiftUI ViewGraph updates reliably
/// without requiring the `SwiftUIMacros.StateMacro` compiler plugin in CommandLineTools-only SDKs.
final class LocalStateBox<Value>: ObservableObject {
  @Published var value: Value
  init(_ value: Value) {
    self.value = value
  }
}

@propertyWrapper
struct ViewState<Value>: DynamicProperty {
  @StateObject private var box: LocalStateBox<Value>

  init(wrappedValue: Value) {
    self._box = StateObject(wrappedValue: LocalStateBox(wrappedValue))
  }

  var wrappedValue: Value {
    get { box.value }
    nonmutating set { box.value = newValue }
  }

  var projectedValue: Binding<Value> {
    Binding(
      get: { box.value },
      set: { box.value = $0 }
    )
  }
}

// MARK: - Shared Form Spacing & Apple System Settings Components

extension View {
  func vibepolloSettingsForm() -> some View {
    self
      .formStyle(.grouped)
  }

  func vibepolloSheetForm() -> some View {
    self
      .formStyle(.grouped)
      .background(PassiveSheetFocusAnchor().frame(width: 0, height: 0))
  }
}

struct SidebarIconBadge: View {
  let symbol: String
  let tint: Color
  var size: CGFloat = 20
  var symbolSize: CGFloat = 11

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        .fill(
          LinearGradient(
            colors: [tint.opacity(0.90), tint],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: size, height: size)
        .overlay(
          RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
      Image(systemName: symbol)
        .font(.system(size: symbolSize, weight: .semibold))
        .foregroundStyle(.white)
    }
  }
}

struct SettingsNotificationBadge: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, count > 9 ? 5.5 : 0)
      .frame(minWidth: 18, minHeight: 18)
      .background(Circle().fill(Color.red))
  }
}

private struct SidebarCategoryRow: View {
  let section: SidebarSection
  let title: String
  var badgeCount: Int = 0

  var body: some View {
    HStack(spacing: 9) {
      SidebarIconBadge(symbol: section.symbolName, tint: section.badgeTint)
      Text(title)
        .font(.system(size: 13))
        .lineLimit(1)
      Spacer(minLength: 4)
      if badgeCount > 0 {
        SettingsNotificationBadge(count: badgeCount)
      }
    }
    .padding(.vertical, 1.5)
  }
}

struct SettingsRowLabel: View {
  let title: String
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 2.5) {
      Text(title)
        .font(.system(size: 13))
      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 2)
  }
}

struct SettingsDrillInRow: View {
  let title: String
  var subtitle: String? = nil
  var badgeText: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        SettingsRowLabel(title: title, subtitle: subtitle)
        Spacer()
        if let badgeText, !badgeText.isEmpty {
          Text(badgeText)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct RestartRequiredSection: View {
  @ObservedObject var store: HostStore
  private var l10n: L10n { store.l10n }

  var body: some View {
    Section {
      HStack(spacing: 12) {
        Image(systemName: "arrow.trianglehead.2.clockwise")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(
          l10n.pick(
            "변경한 설정을 적용하려면 Vibepollo 재시작이 필요합니다.",
            "Restart Vibepollo to apply the updated settings."
          )
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        Spacer()
        Button(l10n.pick("지금 재시작", "Restart Now")) {
          VibepolloHostBridge.shared().restartHost()
        }
        .controlSize(.small)
      }
    }
  }
}

// MARK: - Root NavigationSplitView (Matches Apple's SettingsNavigationSplitView.swift 1:1)

struct VibepolloRootView: View {
  @ObservedObject var store: HostStore

  private var l10n: L10n { store.l10n }

  private var selectionBinding: Binding<SidebarSection?> {
    Binding(
      get: { store.selectedSection },
      set: { next in
        if let next {
          store.selectSidebar(next)
        }
      }
    )
  }

  private func matchesSearch(_ section: SidebarSection) -> Bool {
    let q = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return true }
    if l10n.sectionTitle(section).lowercased().contains(q) { return true }
    return l10n.sectionKeywords(section).contains { $0.lowercased().contains(q) }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: selectionBinding) {
        let visibleSettings = SidebarSection.settingsGroup.filter(matchesSearch)
        if !visibleSettings.isEmpty {
          Section {
            ForEach(visibleSettings) { sec in
              SidebarCategoryRow(
                section: sec,
                title: l10n.sectionTitle(sec),
                badgeCount: (sec == .general && store.dashboard.updateAvailable) ? 1 : 0
              )
              .tag(sec)
            }
          }
        }

        let visibleClients = SidebarSection.clientGroup.filter(matchesSearch)
        if !visibleClients.isEmpty {
          Section {
            ForEach(visibleClients) { sec in
              SidebarCategoryRow(
                section: sec,
                title: l10n.sectionTitle(sec)
              )
              .tag(sec)
            }
          }
        }
      }
      .listStyle(.sidebar)
      .searchable(
        text: $store.searchQuery,
        placement: .sidebar,
        prompt: Text(l10n.pick("검색", "Search"))
      )
      .toolbar(removing: .sidebarToggle)
      .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
    } detail: {
      Group {
        switch store.currentRoute {
        case .section(let section):
          switch section {
          case .general:
            GeneralSettingsPane(store: store)
          case .display:
            DisplaySettingsPane(store: store)
          case .video:
            VideoSettingsPane(store: store)
          case .inputAudio:
            InputAudioSettingsPane(store: store)
          case .networkSystem:
            NetworkSystemPane(store: store)
          case .devices:
            DevicesPane(store: store)
          case .apps:
            AppsPane(store: store)
          }
        case .softwareUpdate:
          SoftwareUpdateSubView(store: store)
        case .hostAutomation:
          HostAutomationSubView(store: store)
        case .deviceDetail(let uuid):
          DeviceDetailSubView(store: store, clientUUID: uuid)
        case .logs:
          LogViewerSubView(store: store)
        case .telemetry:
          TelemetryDetailView(store: store)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(store.currentWindowTitle)
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigation) {
          ControlGroup {
            Button {
              store.goBack()
            } label: {
              Image(systemName: "chevron.backward")
            }
            .disabled(!store.canGoBack)

            Button {
              store.goForward()
            } label: {
              Image(systemName: "chevron.forward")
            }
            .disabled(!store.canGoForward)
          }
          .controlGroupStyle(.navigation)
        }
      }
    }
    .frame(minWidth: 715, idealWidth: 745, maxWidth: 880, minHeight: 520, idealHeight: 640)
    .sheet(isPresented: $store.showPinSheet) {
      PinPairingSheet(store: store)
    }
  }
}

// MARK: - 1. 일반 (General Settings Pane)

private struct GeneralSettingsPane: View {
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

// MARK: - 2. 디스플레이 (Displays Settings Pane)

private struct DisplaySettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showAdvancedSheet = false
  private var l10n: L10n { store.l10n }

  private static let scaleChoices: [Int] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]

  var body: some View {
    Form {
      Section {
        Picker(
          selection: Binding(
            get: { store.settings.virtualDisplayMode },
            set: { v in
              store.settings.virtualDisplayMode = v
              store.patchSettings(["virtual_display_mode": v])
            }
          )
        ) {
          Text(l10n.pick("클라이언트별 전용 모니터", "Per-Client Virtual Display")).tag("per_client")
          Text(l10n.pick("공유 가상 모니터", "Shared Virtual Display")).tag("shared")
          Text(l10n.pick("물리 모니터 직접 캡처", "Physical Display")).tag("disabled")
        } label: {
          SettingsRowLabel(
            title: l10n.pick("디스플레이 방식", "Display Mode"),
            subtitle: l10n.pick("클라이언트 해상도와 주사율에 맞춘 독립 가상 화면을 생성합니다.", "Create native CGVirtualDisplay screens matching client resolution and refresh rate.")
          )
        }

        Picker(
          l10n.pick("레티나(HiDPI) 배율", "Retina HiDPI Scale"),
          selection: Binding(
            get: { store.settings.virtualDisplayScale },
            set: { v in
              store.settings.virtualDisplayScale = v
              store.patchSettings(["dd_virtual_display_scale": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (권장)", "Automatic (Recommended)")).tag(-1)
          Text(l10n.pick("기존 배율 유지", "Preserve Current")).tag(0)
          ForEach(Self.scaleChoices, id: \.self) { pct in
            Text(pct == 200 ? "200% (2x Retina)" : "\(pct)%").tag(pct)
          }
          if store.settings.virtualDisplayScale != -1
            && store.settings.virtualDisplayScale != 0
            && !Self.scaleChoices.contains(store.settings.virtualDisplayScale)
          {
            Text("\(store.settings.virtualDisplayScale)%").tag(store.settings.virtualDisplayScale)
          }
        }

        Picker(
          l10n.pick("HDR 요청 처리", "HDR Request Policy"),
          selection: Binding(
            get: { store.settings.hdrRequestOverride },
            set: { v in
              store.settings.hdrRequestOverride = v
              store.patchSettings(["dd_hdr_request_override": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (클라이언트 요청 따름)", "Automatic (Follow Client)")).tag("auto")
          Text(l10n.pick("항상 HDR 활성화 강제", "Force HDR On")).tag("force_on")
          Text(l10n.pick("항상 SDR 유지 (HDR 끔)", "Force HDR Off (SDR)")).tag("force_off")
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.keepDisplayWhilePaused },
            set: { v in
              store.settings.keepDisplayWhilePaused = v
              store.patchSettings(["virtual_display_keep_while_paused": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("일시정지 중 가상 모니터 유지", "Keep Virtual Display While Paused"),
            subtitle: l10n.pick("스트림이 잠시 중단되어도 열려 있는 창 배치를 그대로 보존합니다.", "Preserve window positions while a client temporarily pauses.")
          )
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.lidCloseEndsStreams },
            set: { v in
              store.settings.lidCloseEndsStreams = v
              store.patchSettings(["lid_close_ends_streams": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("MacBook 덮개를 닫을 때 스트림 종료", "End Stream When Lid Closes"),
            subtitle: l10n.pick("비활성화하면 깨어 있는 MacBook의 덮개를 닫은 상태에서도 스트리밍을 유지합니다.", "Turn off to continue streaming in clamshell mode while your Mac stays awake.")
          )
        }
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("고급...", "Advanced...")) {
            showAdvancedSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("모니터 배치 · 타겟 출력 및 원격 모니터", "Arrangement, Target Output & Remote Monitor"),
            subtitle: l10n.pick("배치 정책, 일시정지 해제 시간, 캡처 모니터 ID, 대체 해상도 및 원격 모니터 동작을 설정합니다.", "Configure layout policy, paused timeout, target display ID, fallback mode, and Remote Monitor options.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showAdvancedSheet) {
      DisplayAdvancedSheet(store: store)
    }
  }
}

// MARK: - 3. 화질 및 인코더 (Video & Encoder Pane)

private struct VideoSettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showAdvancedSheet = false
  private var l10n: L10n { store.l10n }

  private static let presetBitrates: [Int] = [0, 20000, 50000, 80000, 100000, 150000, 250000, 500000]

  var body: some View {
    Form {
      Section(l10n.pick("현재 스트리밍 화질", "Current Stream")) {
        if store.dashboard.sessions.isEmpty {
          LabeledContent(l10n.pick("상태", "Status")) {
            Text(l10n.pick("스트리밍 시작 시 클라이언트 설정이 반영됩니다", "Follows client app once streaming starts"))
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(store.dashboard.sessions) { s in
            LabeledContent {
              VStack(alignment: .trailing, spacing: 2) {
                Text("\(s.codec) · \(s.bitDepth)-bit \(s.hdr ? "HDR" : "SDR") · \(s.yuv444 ? "4:4:4" : "4:2:0")")
                  .font(.system(size: 12.5, weight: .medium))
                Text(
                  String(
                    format: "%d×%d @ %dHz · %.1f Mbps",
                    s.width,
                    s.height,
                    s.fps,
                    Double(s.bitrateKbps) / 1000.0
                  )
                )
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
              }
            } label: {
              SettingsRowLabel(
                title: s.deviceName,
                subtitle: s.directUsb
                  ? l10n.pick("USB 유선 연결 중", "Connected via USB")
                  : l10n.pick("네트워크 연결 중", "Connected via Network")
              )
            }
          }
        }
      }

      Section {
        Picker(
          l10n.pick("비디오 인코더", "Video Encoder"),
          selection: Binding(
            get: { store.settings.encoder },
            set: { v in
              store.settings.encoder = v
              store.patchSettings(["encoder": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (권장)", "Automatic (Recommended)")).tag("")
          Text(l10n.pick("Apple VideoToolbox (하드웨어)", "Apple VideoToolbox (Hardware)")).tag("videotoolbox")
          Text(l10n.pick("소프트웨어 (CPU 인코딩)", "Software (CPU)")).tag("software")
          if !["", "videotoolbox", "software"].contains(store.settings.encoder) {
            Text(store.settings.encoder).tag(store.settings.encoder)
          }
        }

        Picker(
          l10n.pick("최대 비트레이트 상한", "Max Bitrate Ceiling"),
          selection: Binding(
            get: { store.settings.maxBitrateKbps },
            set: { v in
              store.settings.maxBitrateKbps = v
              store.patchSettings(["max_bitrate": v])
            }
          )
        ) {
          Text(l10n.pick("제한 없음 (클라이언트 설정 따름)", "Uncapped (Follow Client)")).tag(0)
          Text("20 Mbps").tag(20000)
          Text("50 Mbps").tag(50000)
          Text("80 Mbps").tag(80000)
          Text("100 Mbps").tag(100000)
          Text("150 Mbps").tag(150000)
          Text("250 Mbps").tag(250000)
          Text("500 Mbps").tag(500000)
          if !Self.presetBitrates.contains(store.settings.maxBitrateKbps) {
            Text(l10n.pick("사용자 지정 (\(store.settings.maxBitrateKbps) kbps)", "Custom (\(store.settings.maxBitrateKbps) kbps)"))
              .tag(store.settings.maxBitrateKbps)
          }
        }

        Picker(
          l10n.pick("HEVC 허용 범위", "Allow HEVC"),
          selection: Binding(
            get: { store.settings.hevcMode },
            set: { v in
              store.settings.hevcMode = v
              store.patchSettings(["hevc_mode": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (클라이언트 설정 따름)", "Automatic (Follow Client)")).tag(0)
          Text(l10n.pick("사용 안 함 (H.264로 제한)", "Disabled (H.264 Only)")).tag(1)
          Text(l10n.pick("8-bit SDR까지만 허용", "Up to 8-bit SDR")).tag(2)
          Text(l10n.pick("10-bit HDR까지 허용", "Up to 10-bit HDR")).tag(3)
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.vtRealtime },
            set: { v in
              store.settings.vtRealtime = v
              store.patchSettings(["vt_realtime": v ? "enabled" : "disabled"])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("VideoToolbox 실시간 저지연 인코딩", "VideoToolbox Realtime Priority"),
            subtitle: l10n.pick("Apple Silicon 미디어 엔진의 프레임 인코딩 지연을 최소화합니다.", "Minimize frame encoding latency on Apple Silicon Media Engine.")
          )
        }
      } header: {
        Text(l10n.pick("인코더 및 코덱 허용 범위", "Encoder & Allowed Formats"))
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("고급...", "Advanced...")) {
            showAdvancedSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("인코더 튜닝 · 비트레이트 직접 입력 및 패킷 복구", "Encoder Tuning, Custom Bitrate & FEC"),
            subtitle: l10n.pick("세부 비트레이트(kbps), VideoToolbox 코더, SW 프리셋/QP, 유휴 FPS, FEC 및 페이싱을 설정합니다.", "Configure exact kbps bitrate, VideoToolbox coder, SW preset/QP, idle FPS, FEC, and pacing.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showAdvancedSheet) {
      VideoAdvancedSheet(store: store)
    }
  }
}

// MARK: - 4. 입력 및 오디오 (Input & Audio Pane)

private struct InputAudioSettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showInputAdvanced = false
  @ViewState private var showAudioAdvanced = false
  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      Section(l10n.pick("트랙패드 및 Apple Pencil", "Trackpad & Apple Pencil")) {
        Picker(
          l10n.pick("스크롤 관성 방식", "Scroll Inertia"),
          selection: Binding(
            get: { store.settings.scrollInertia },
            set: { v in
              store.settings.scrollInertia = v
              store.patchSettings(["macos_scroll_inertia": v])
            }
          )
        ) {
          Text(l10n.pick("MacBook 트랙패드 네이티브", "MacBook Trackpad")).tag("macos")
          Text(l10n.pick("iPad 모멘텀 관성", "iPad Momentum")).tag("ipados")
          Text(l10n.pick("관성 없음", "Disabled")).tag("disabled")
        }

        Picker(
          l10n.pick("Apple Pencil 동작", "Apple Pencil Mode"),
          selection: Binding(
            get: { store.settings.pencilMode },
            set: { v in
              store.settings.pencilMode = v
              store.patchSettings(["macos_pencil_mode": v])
            }
          )
        ) {
          Text(l10n.pick("클라이언트 설정 따름 (VoidLink)", "Follow Client")).tag("auto")
          Text(l10n.pick("스크롤 및 탭 (iPad 조작 방식)", "Scroll & Tap")).tag("scroll")
          Text(l10n.pick("드로잉 태블릿 (필압 펜 입력)", "Drawing Tablet")).tag("draw")
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.palmRejection },
            set: { v in
              store.settings.palmRejection = v
              store.patchSettings(["macos_palm_rejection": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("펜 사용 중 손바닥 터치 차단", "Reject Touch While Using Pencil"),
            subtitle: l10n.pick("Apple Pencil이 호버 중이거나 그리는 동안 손바닥·손가락 터치 오작동을 자동으로 막습니다.", "Ignore stray finger and palm touches while Apple Pencil is hovering or drawing.")
          )
        }

        Toggle(
          l10n.pick("고해상도 부드러운 스크롤", "High-Resolution Scrolling"),
          isOn: Binding(
            get: { store.settings.highResScrolling },
            set: { v in
              store.settings.highResScrolling = v
              store.patchSettings(["high_resolution_scrolling": v])
            }
          )
        )

        Toggle(
          isOn: Binding(
            get: { store.settings.nativePenTouch },
            set: { v in
              store.settings.nativePenTouch = v
              store.patchSettings(["native_pen_touch": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("Apple Pencil 및 보조 터치 전달", "Apple Pencil & Auxiliary Touch"),
            subtitle: l10n.pick("Apple Pencil 필압 · 호버 · 배럴 롤을 전달합니다. 손가락 조작은 클라이언트 앱의 트랙패드/마우스 모드를 권장합니다.", "Forwards Apple Pencil pressure, hover, and barrel roll. Use the client app's Trackpad or Mouse mode for finger navigation.")
          )
        }
      }

      Section(l10n.pick("입력 장치", "Input Devices")) {
        Toggle(
          l10n.pick("키보드 입력 허용", "Enable Keyboard Input"),
          isOn: Binding(
            get: { store.settings.keyboard },
            set: { v in
              store.settings.keyboard = v
              store.patchSettings(["keyboard": v])
            }
          )
        )

        Toggle(
          l10n.pick("마우스 입력 허용", "Enable Mouse Input"),
          isOn: Binding(
            get: { store.settings.mouse },
            set: { v in
              store.settings.mouse = v
              store.patchSettings(["mouse": v])
            }
          )
        )
      }

      Section(l10n.pick("오디오", "Audio")) {
        Toggle(
          isOn: Binding(
            get: { store.settings.streamAudio },
            set: { v in
              store.settings.streamAudio = v
              store.patchSettings(["stream_audio": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("Mac 시스템 오디오 전송", "Stream System Audio"),
            subtitle: l10n.pick("스트리밍 중 클라이언트로 Mac의 오디오 출력을 함께 전달합니다.", "Capture and stream macOS system audio to connected clients.")
          )
        }

        Picker(
          l10n.pick("오디오 코덱 포맷", "Audio Codec"),
          selection: Binding(
            get: { store.settings.audioFormat },
            set: { v in
              store.settings.audioFormat = v
              store.patchSettings(["audio_format": v])
            }
          )
        ) {
          Text(l10n.pick("Opus (초저지연 기본)", "Opus (Low-Latency Default)")).tag("opus")
          Text("Dolby Digital (AC-3)").tag("ac3")
          Text("Dolby Digital Plus (E-AC-3)").tag("eac3")
        }
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("입력 고급...", "Input Options...")) {
            showInputAdvanced = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("입력 세션 · 키 반복 및 키 바인딩", "Input Session, Key Repeat & Keybindings"),
            subtitle: l10n.pick("입력 전용 모드, 우측 Option 매핑, 키 반복 속도 및 커스텀 키 바인딩을 설정합니다.", "Configure input-only mode, Right Option mapping, key repeat, and custom keybindings.")
          )
        }

        LabeledContent {
          Button(l10n.pick("오디오 고급...", "Audio Options...")) {
            showAudioAdvanced = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("오디오 출력 장치 및 서라운드 옵션", "Audio Routing & Surround"),
            subtitle: l10n.pick("CoreAudio 출력 싱크 장치 지정 및 Dolby 고음질 서라운드를 설정합니다.", "Configure CoreAudio sink override and high-quality Dolby surround.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showInputAdvanced) {
      InputAdvancedSheet(store: store)
    }
    .sheet(isPresented: $showAudioAdvanced) {
      AudioAdvancedSheet(store: store)
    }
  }
}

// MARK: - 5. 네트워크 및 로그 (Network & Logs Pane)

private struct NetworkSystemPane: View {
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
          title: l10n.pick("리소스 및 세션 기록", "Resources & Session History"),
          subtitle: l10n.pick("실시간 CPU · GPU 점유율, 활성 스트림 지표 및 과거 세션 기록을 확인합니다.", "Inspect real-time CPU/GPU usage, active streams, and past session history.")
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

// MARK: - 6. 연결된 기기 (Devices Pane & Detail)

private struct InlineRenameTextField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let onCommit: () -> Void
  let onCancel: () -> Void

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: InlineRenameTextField
    var didFocus = false
    var finished = false

    init(_ parent: InlineRenameTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ obj: Notification) {
      if let tf = obj.object as? NSTextField {
        parent.text = tf.stringValue
      }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      guard !finished else { return }
      finished = true
      parent.onCommit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        guard !finished else { return true }
        finished = true
        parent.onCommit()
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        guard !finished else { return true }
        finished = true
        parent.onCancel()
        return true
      }
      return false
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSTextField {
    let tf = NSTextField(string: text)
    tf.placeholderString = placeholder
    tf.font = .systemFont(ofSize: 13, weight: .medium)
    tf.isBordered = true
    tf.bezelStyle = .roundedBezel
    tf.focusRingType = .exterior
    tf.delegate = context.coordinator
    DispatchQueue.main.async {
      guard !context.coordinator.didFocus, let win = tf.window else { return }
      context.coordinator.didFocus = true
      win.makeFirstResponder(tf)
      tf.currentEditor()?.selectAll(nil)
    }
    return tf
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    context.coordinator.parent = self
    if nsView.currentEditor() == nil && nsView.stringValue != text {
      nsView.stringValue = text
    }
  }
}

private struct DevicesPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var editingUUID: String? = nil
  @ViewState private var editingName: String = ""
  @ViewState private var unpairingClient: PairedClientItem? = nil
  private var l10n: L10n { store.l10n }

  private var sortedClients: [PairedClientItem] {
    store.clients.sorted { lhs, rhs in
      if lhs.connected != rhs.connected {
        return lhs.connected && !rhs.connected
      }
      return false
    }
  }

  private func activeSession(for client: PairedClientItem) -> ActiveStreamSession? {
    if let byUUID = store.dashboard.sessions.first(where: { !$0.uuid.isEmpty && $0.uuid == client.uuid }) {
      return byUUID
    }
    if client.connected {
      return store.dashboard.sessions.first(where: { $0.deviceName.caseInsensitiveCompare(client.name) == .orderedSame })
        ?? (store.dashboard.sessions.count == 1 ? store.dashboard.sessions.first : nil)
    }
    return nil
  }

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          SettingsRowLabel(
            title: l10n.pick("새 클라이언트 페어링", "Pair a New Client"),
            subtitle: l10n.pick("클라이언트 화면에 표시된 4자리 PIN으로 기기를 등록합니다.", "Register a Moonlight or VoidLink device using its 4-digit PIN.")
          )
          Spacer()
          Button(l10n.pick("기기 페어링...", "Pair Device...")) {
            store.showPinSheet = true
          }
        }
      }

      Section(l10n.pick("나의 기기", "My Devices")) {
        if sortedClients.isEmpty {
          Text(l10n.pick("페어링된 기기가 없습니다.", "No paired devices yet."))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        } else {
          ForEach(sortedClients) { client in
            HStack(spacing: 12) {
              if editingUUID == client.uuid {
                HStack(spacing: 12) {
                  Image(systemName: symbolForDevice(editingName.isEmpty ? client.name : editingName))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(client.connected ? Color.primary : Color.secondary)
                    .frame(width: 26, height: 26)

                  VStack(alignment: .leading, spacing: 2) {
                    InlineRenameTextField(
                      text: $editingName,
                      placeholder: client.name,
                      onCommit: {
                        commitInlineRename(for: client)
                      },
                      onCancel: {
                        editingUUID = nil
                      }
                    )
                    .frame(maxWidth: 220, minHeight: 20)

                    Text(subtitle(for: client))
                      .font(.system(size: 11.5).monospacedDigit())
                      .foregroundStyle(.secondary)
                  }

                  Spacer(minLength: 8)
                }
              } else {
                Button {
                  store.navigate(to: .deviceDetail(client.uuid))
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: symbolForDevice(client.name))
                      .font(.system(size: 16, weight: .regular))
                      .foregroundStyle(client.connected ? Color.primary : Color.secondary)
                      .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 2) {
                      Text(client.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                      Text(subtitle(for: client))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }

              if client.connected {
                Button(l10n.pick("연결 해제", "Disconnect")) {
                  store.disconnectClient(uuid: client.uuid)
                }
                .controlSize(.small)
              }

              Button {
                store.navigate(to: .deviceDetail(client.uuid))
              } label: {
                Image(systemName: "chevron.right")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(.tertiary)
                  .frame(width: 16, height: 24)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
            .padding(.vertical, 2.5)
            .contextMenu {
              Button(l10n.pick("이름 변경", "Rename")) {
                editingName = client.name
                editingUUID = client.uuid
              }
              if client.connected {
                Button(l10n.pick("연결 해제", "Disconnect")) {
                  store.disconnectClient(uuid: client.uuid)
                }
              }
              Divider()
              Button(l10n.pick("이 기기 페어링 해제...", "Forget This Device..."), role: .destructive) {
                unpairingClient = client
              }
            }
          }
        }
      }
    }
    .vibepolloSettingsForm()
    .confirmationDialog(
      l10n.pick("이 기기의 페어링을 해제하시겠습니까?", "Unpair this device?"),
      isPresented: Binding(
        get: { unpairingClient != nil },
        set: { if !$0 { unpairingClient = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(l10n.pick("페어링 해제", "Unpair"), role: .destructive) {
        if let target = unpairingClient {
          store.unpairClient(uuid: target.uuid)
        }
        unpairingClient = nil
      }
      Button(l10n.pick("취소", "Cancel"), role: .cancel) {
        unpairingClient = nil
      }
    }
  }

  private func symbolForDevice(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("ipad") { return "ipad.landscape" }
    if lower.contains("iphone") || lower.contains("phone") { return "iphone" }
    if lower.contains("tv") { return "appletv" }
    if lower.contains("mac") || lower.contains("book") { return "laptopcomputer" }
    return "display"
  }

  private func subtitle(for client: PairedClientItem) -> String {
    if !client.enabled {
      return l10n.pick("연결 차단됨", "Blocked")
    }
    if client.connected {
      if let s = activeSession(for: client) {
        let transport = s.directUsb
          ? l10n.pick("USB 유선", "USB")
          : l10n.pick("네트워크", "Network")
        return l10n.pick(
          "연결됨 · \(transport) · \(s.width)×\(s.height) \(s.fps)Hz · \(s.codec)\(s.hdr ? " HDR" : "")",
          "Connected · \(transport) · \(s.width)×\(s.height) \(s.fps)Hz · \(s.codec)\(s.hdr ? " HDR" : "")"
        )
      }
      return l10n.pick("연결됨", "Connected")
    }
    if client.lastSeen > 0 {
      let date = Date(timeIntervalSince1970: TimeInterval(client.lastSeen))
      let formatter = l10n.isKo ? Self.relativeLastSeenKoFormatter : Self.relativeLastSeenEnFormatter
      let rel = formatter.localizedString(for: date, relativeTo: Date())
      return l10n.pick("연결 안 됨 · 마지막 접속 \(rel)", "Not Connected · Last seen \(rel)")
    }
    return l10n.pick("연결 안 됨", "Not Connected")
  }

  private static let relativeLastSeenKoFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.unitsStyle = .full
    return formatter
  }()

  private static let relativeLastSeenEnFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = .full
    return formatter
  }()

  private func commitInlineRename(for client: PairedClientItem) {
    let target = String(editingName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    editingUUID = nil
    guard !target.isEmpty, target.lowercased() != "self", target != client.name else {
      return
    }
    _ = store.renameClient(uuid: client.uuid, newName: target)
  }
}

private struct DeviceDetailSubView: View {
  @ObservedObject var store: HostStore
  let clientUUID: String

  @ViewState private var draft: PairedClientItem? = nil
  @ViewState private var nameDraft: String = ""
  @ViewState private var isEditingName = false
  @ViewState private var confirmUnpair = false
  @ViewState private var showGranularSheet = false
  @ViewState private var showCommandsSheet = false
  @ViewState private var showOverridesSheet = false

  private var l10n: L10n { store.l10n }

  var body: some View {
    Group {
      if let binding = Binding($draft) {
        Form {
          Section {
            LabeledContent(l10n.pick("기기 이름", "Device Name")) {
              TextField(
                "",
                text: $nameDraft,
                onEditingChanged: { editing in
                  isEditingName = editing
                  if !editing {
                    commitNameDraftIfNeeded()
                  }
                }
              )
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 220)
              .onSubmit {
                commitNameDraftIfNeeded()
              }
            }

            Toggle(
              isOn: Binding(
                get: { binding.wrappedValue.enabled },
                set: { v in
                  var next = binding.wrappedValue
                  next.enabled = v
                  commit(next)
                }
              )
            ) {
              SettingsRowLabel(
                title: l10n.pick("스트리밍 연결 허용", "Allow Streaming"),
                subtitle: l10n.pick("비활성화하면 페어링을 유지한 채 이 기기의 접속만 차단합니다.", "Temporarily block connections without unpairing.")
              )
            }

            if binding.wrappedValue.connected {
              HStack {
                Text(l10n.pick("현재 세션", "Active Session"))
                Spacer()
                Button(l10n.pick("연결 해제", "Disconnect")) {
                  store.disconnectClient(uuid: clientUUID)
                }
              }
            }
          }

          Section(l10n.pick("디스플레이", "Display")) {
            Toggle(
              l10n.pick("항상 가상 디스플레이 사용", "Always Use Virtual Display"),
              isOn: Binding(
                get: { binding.wrappedValue.alwaysUseVirtualDisplay },
                set: { v in
                  var next = binding.wrappedValue
                  next.alwaysUseVirtualDisplay = v
                  commit(next)
                }
              )
            )

            Picker(
              l10n.pick("디스플레이 방식", "Virtual Display Mode"),
              selection: Binding(
                get: { binding.wrappedValue.virtualDisplayMode },
                set: { v in
                  var next = binding.wrappedValue
                  next.virtualDisplayMode = v
                  commit(next)
                }
              )
            ) {
              Text(l10n.pick("호스트 기본값 따름", "Follow Host Default")).tag("")
              Text(l10n.pick("클라이언트별 전용 모니터", "Per-Client Display")).tag("per_client")
              Text(l10n.pick("공유 가상 모니터", "Shared Display")).tag("shared")
              Text(l10n.pick("물리 모니터", "Physical Display")).tag("disabled")
            }

            Picker(
              l10n.pick("모니터 배치 정책", "Layout Policy"),
              selection: Binding(
                get: { binding.wrappedValue.virtualDisplayLayout },
                set: { v in
                  var next = binding.wrappedValue
                  next.virtualDisplayLayout = v
                  commit(next)
                }
              )
            ) {
              Text(l10n.pick("호스트 기본값 따름", "Follow Host Default")).tag("")
              Text(l10n.pick("단독 표시 (물리 화면 숨김)", "Exclusive")).tag("exclusive")
              Text(l10n.pick("데스크톱 확장", "Extended")).tag("extended")
              Text(l10n.pick("확장 + 주 모니터 지정", "Extended Primary")).tag("extended_primary")
              Text(l10n.pick("확장 + 커서 격리 배치", "Extended Isolated")).tag("extended_isolated")
              Text(l10n.pick("확장 + 주 모니터 및 커서 격리", "Extended Primary & Isolated")).tag("extended_primary_isolated")
            }

            LabeledContent(l10n.pick("해상도 강제 지정", "Mode Override")) {
              TextField(
                "",
                text: binding.displayMode,
                prompt: Text("2752x2064x120")
              )
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 170)
              .onSubmit { commit(binding.wrappedValue) }
            }

            LabeledContent(l10n.pick("캡처 모니터 ID 덮어쓰기", "Target Display ID")) {
              TextField(
                "",
                text: binding.outputNameOverride,
                prompt: Text(l10n.pick("기본값", "Default"))
              )
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 170)
              .onSubmit { commit(binding.wrappedValue) }
            }

            Toggle(
              l10n.pick("HDR 요청 시 10-bit SDR로 전송", "Prefer 10-bit SDR over HDR"),
              isOn: Binding(
                get: { binding.wrappedValue.prefer10BitSdr },
                set: { v in
                  var next = binding.wrappedValue
                  next.prefer10BitSdr = v
                  commit(next)
                }
              )
            )
          }

          Section(l10n.pick("권한", "Permissions")) {
            Toggle(
              l10n.pick("화면 보기 및 앱 목록 조회", "View Stream & App List"),
              isOn: permBinding(binding, mask: PairedClientItem.maskView | PairedClientItem.maskList)
            )
            Toggle(
              l10n.pick("애플리케이션 실행", "Launch Applications"),
              isOn: permBinding(binding, mask: PairedClientItem.maskLaunch)
            )
            Toggle(
              l10n.pick("입력 제어 (키보드 · 마우스 · 터치 · 펜)", "Input Control"),
              isOn: permBinding(binding, mask: PairedClientItem.maskAllInputs)
            )
            Toggle(
              l10n.pick("클립보드 동기화", "Clipboard Sync"),
              isOn: permBinding(binding, mask: PairedClientItem.maskAllClipboard)
            )
            Toggle(
              l10n.pick("서버 메뉴 명령어 실행", "Run Server Commands"),
              isOn: permBinding(binding, mask: PairedClientItem.maskServerCmd)
            )
            Toggle(
              isOn: Binding(
                get: { binding.wrappedValue.allowSleep },
                set: { v in
                  var next = binding.wrappedValue
                  next.allowSleep = v
                  commit(next)
                }
              )
            ) {
              SettingsRowLabel(
                title: l10n.pick("원격 Mac 절전 요청 허용", "Allow Remote Sleep"),
                subtitle: l10n.pick("클라이언트에서 세션 종료 시 이 Mac을 잠자기 상태로 전환할 수 있습니다.", "Allow this device to put your Mac to sleep when ending a session.")
              )
            }

            LabeledContent {
              Button(l10n.pick("세부 권한...", "Input Options...")) {
                showGranularSheet = true
              }
            } label: {
              SettingsRowLabel(
                title: l10n.pick("개별 입력 및 클립보드 권한", "Granular Input & Clipboard Permissions"),
                subtitle: l10n.pick("키보드, 마우스, 터치, 펜 및 클립보드 읽기/쓰기 허용 여부를 개별 지정합니다.", "Toggle keyboard, mouse, touch, pen, and clipboard read/write individually.")
              )
            }
          }

          Section(l10n.pick("자동화 · 덮어쓰기 및 정보", "Automation, Overrides & Info")) {
            LabeledContent {
              Button(l10n.pick("명령어 설정...", "Commands...")) {
                showCommandsSheet = true
              }
            } label: {
              SettingsRowLabel(
                title: l10n.pick("연결 / 해제 시 셸 명령어", "Connect & Disconnect Commands"),
                subtitle: l10n.pick("이 기기가 연결되거나 종료될 때 실행할 스크립트를 관리합니다.", "Configure shell scripts triggered on session start and end.")
              )
            }

            LabeledContent {
              Button(l10n.pick("설정 덮어쓰기...", "Overrides...")) {
                showOverridesSheet = true
              }
            } label: {
              SettingsRowLabel(
                title: l10n.pick("기기별 호스트 설정 덮어쓰기", "Per-Device Config Overrides"),
                subtitle: binding.wrappedValue.configOverrides.isEmpty
                  ? l10n.pick("이 기기로 접속할 때만 다른 비트레이트·코덱·입력 설정을 적용합니다.", "Apply custom bitrate, codec, or input settings only when this device connects.")
                  : l10n.pick("\(binding.wrappedValue.configOverrides.count)개 항목 적용 중", "\(binding.wrappedValue.configOverrides.count) override(s) active")
              )
            }

            Toggle(
              l10n.pick("레거시 앱 목록 순서 사용", "Legacy App Ordering"),
              isOn: Binding(
                get: { binding.wrappedValue.enableLegacyOrdering },
                set: { v in
                  var next = binding.wrappedValue
                  next.enableLegacyOrdering = v
                  commit(next)
                }
              )
            )

            LabeledContent("UUID") {
              HStack(spacing: 6) {
                Text(binding.wrappedValue.uuid)
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Button {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(binding.wrappedValue.uuid, forType: .string)
                } label: {
                  Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
              }
            }

            HStack {
              Spacer()
              Button(role: .destructive) {
                confirmUnpair = true
              } label: {
                Text(l10n.pick("이 기기 페어링 해제...", "Forget This Device..."))
              }
            }
          }
        }
        .vibepolloSettingsForm()
        .sheet(isPresented: $showGranularSheet) {
          DeviceGranularPermSheet(client: binding, l10n: l10n, onCommit: commit)
        }
        .sheet(isPresented: $showCommandsSheet) {
          DeviceCommandsSheet(client: binding, l10n: l10n, onCommit: commit)
        }
        .sheet(isPresented: $showOverridesSheet) {
          ConfigOverridesSheet(
            title: l10n.pick("기기별 설정 덮어쓰기", "Device Config Overrides"),
            l10n: l10n,
            initialOverrides: binding.wrappedValue.configOverrides
          ) { updated in
            var next = binding.wrappedValue
            next.configOverrides = updated
            commit(next)
          }
        }
        .confirmationDialog(
          l10n.pick("이 기기의 페어링을 해제하시겠습니까?", "Unpair this device?"),
          isPresented: $confirmUnpair,
          titleVisibility: .visible
        ) {
          Button(l10n.pick("페어링 해제", "Unpair"), role: .destructive) {
            store.unpairClient(uuid: clientUUID)
            store.popToSectionRoot(.devices)
          }
          Button(l10n.pick("취소", "Cancel"), role: .cancel) {}
        }
      } else {
        ContentUnavailableView(
          l10n.pick("기기를 찾을 수 없습니다", "Device Not Found"),
          systemImage: "ipad.slash"
        )
      }
    }
    .onAppear(perform: syncFromStore)
    .onDisappear {
      commitNameDraftIfNeeded()
      commitPendingDraftIfNeeded()
    }
    .onChange(of: store.clients) { _, _ in
      syncFromStore()
    }
  }

  private func commitPendingDraftIfNeeded() {
    guard let current = draft,
          let saved = store.clients.first(where: { $0.uuid == clientUUID }) else {
      return
    }
    if current.displayMode != saved.displayMode || current.outputNameOverride != saved.outputNameOverride {
      store.saveClient(current)
    }
  }

  private func syncFromStore() {
    if let found = store.clients.first(where: { $0.uuid == clientUUID }) {
      draft = found
      if !isEditingName {
        nameDraft = found.name
      }
    }
  }

  private func commitNameDraftIfNeeded() {
    guard let current = draft else { return }
    let trimmed = String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    guard !trimmed.isEmpty, trimmed.lowercased() != "self" else {
      nameDraft = current.name
      return
    }
    guard trimmed != current.name else {
      if nameDraft != trimmed {
        nameDraft = trimmed
      }
      return
    }
    if store.renameClient(uuid: clientUUID, newName: trimmed) {
      draft?.name = trimmed
      nameDraft = trimmed
    } else {
      nameDraft = current.name
    }
  }

  private func commit(_ updated: PairedClientItem) {
    draft = updated
    store.saveClient(updated)
  }

  private func permBinding(_ client: Binding<PairedClientItem>, mask: UInt32) -> Binding<Bool> {
    Binding(
      get: { client.wrappedValue.hasPerm(mask) },
      set: { enabled in
        var next = client.wrappedValue
        next.setPerm(mask, enabled: enabled)
        commit(next)
      }
    )
  }
}

private struct DeviceGranularPermSheet: View {
  var client: Binding<PairedClientItem>
  let l10n: L10n
  let onCommit: (PairedClientItem) -> Void
  @Environment(\.dismiss) private var dismiss

  private func perm(_ mask: UInt32) -> Binding<Bool> {
    Binding(
      get: { client.wrappedValue.hasPerm(mask) },
      set: { v in
        var next = client.wrappedValue
        next.setPerm(mask, enabled: v)
        onCommit(next)
      }
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(l10n.pick("키보드 입력", "Keyboard"), isOn: perm(PairedClientItem.maskInputKeyboard))
          Toggle(l10n.pick("마우스 및 트랙패드", "Mouse & Trackpad"), isOn: perm(PairedClientItem.maskInputMouse))
          Toggle(l10n.pick("멀티터치 화면", "Touch"), isOn: perm(PairedClientItem.maskInputTouch))
          Toggle(l10n.pick("펜 및 Apple Pencil", "Pen & Apple Pencil"), isOn: perm(PairedClientItem.maskInputPen))
          Toggle(l10n.pick("호스트 클립보드 읽기", "Read Host Clipboard"), isOn: perm(PairedClientItem.maskClipboardRead))
          Toggle(l10n.pick("호스트 클립보드 쓰기", "Write Host Clipboard"), isOn: perm(PairedClientItem.maskClipboardSet))
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("개별 입력 및 클립보드 권한", "Granular Permissions"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) { dismiss() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 430, height: 350)
  }
}

private struct DeviceCommandsSheet: View {
  var client: Binding<PairedClientItem>
  let l10n: L10n
  let onCommit: (PairedClientItem) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(
            l10n.pick("클라이언트 명령어 실행 허용", "Allow Client Commands"),
            isOn: Binding(
              get: { client.wrappedValue.allowClientCommands },
              set: { v in
                var next = client.wrappedValue
                next.allowClientCommands = v
                onCommit(next)
              }
            )
          )
        }

        if client.wrappedValue.allowClientCommands {
          Section(l10n.pick("연결 시 실행", "On Connect")) {
            ForEach(client.wrappedValue.doCommands) { item in
              let itemID = item.id
              HStack {
                TextField(
                  "",
                  text: Binding(
                    get: { client.wrappedValue.doCommands.first(where: { $0.id == itemID })?.cmd ?? "" },
                    set: { nextVal in
                      if let idx = client.wrappedValue.doCommands.firstIndex(where: { $0.id == itemID }) {
                        client.wrappedValue.doCommands[idx].cmd = nextVal
                      }
                    }
                  ),
                  prompt: Text("sh -c ...")
                )
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { onCommit(client.wrappedValue) }

                Button(role: .destructive) {
                  var next = client.wrappedValue
                  next.doCommands.removeAll(where: { $0.id == itemID })
                  onCommit(next)
                } label: {
                  Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
              }
            }

            Button(l10n.pick("+ 연결 시 명령어 추가", "+ Add Connect Command")) {
              var next = client.wrappedValue
              next.doCommands.append(ClientCommandEntry(cmd: ""))
              client.wrappedValue = next
            }
          }

          Section(l10n.pick("연결 해제 시 실행", "On Disconnect")) {
            ForEach(client.wrappedValue.undoCommands) { item in
              let itemID = item.id
              HStack {
                TextField(
                  "",
                  text: Binding(
                    get: { client.wrappedValue.undoCommands.first(where: { $0.id == itemID })?.cmd ?? "" },
                    set: { nextVal in
                      if let idx = client.wrappedValue.undoCommands.firstIndex(where: { $0.id == itemID }) {
                        client.wrappedValue.undoCommands[idx].cmd = nextVal
                      }
                    }
                  ),
                  prompt: Text("sh -c ...")
                )
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { onCommit(client.wrappedValue) }

                Button(role: .destructive) {
                  var next = client.wrappedValue
                  next.undoCommands.removeAll(where: { $0.id == itemID })
                  onCommit(next)
                } label: {
                  Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
              }
            }

            Button(l10n.pick("+ 연결 해제 시 명령어 추가", "+ Add Disconnect Command")) {
              var next = client.wrappedValue
              next.undoCommands.append(ClientCommandEntry(cmd: ""))
              client.wrappedValue = next
            }
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("연결 명령어 설정", "Client Commands"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            onCommit(client.wrappedValue)
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 460, height: 390)
    .onDisappear {
      onCommit(client.wrappedValue)
    }
  }
}

// MARK: - 새 기기 페어링 시트 (macOS Tahoe Native Liquid Glass Sheet)

private struct PinPairingSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss

  @ViewState private var pin: String = ""
  @ViewState private var deviceName: String = ""
  @ViewState private var isSubmitting = false
  @ViewState private var errorText: String? = nil

  private var l10n: L10n { store.l10n }
  private var isValidPin: Bool {
    let digits = pin.trimmingCharacters(in: .whitespacesAndNewlines)
    return digits.count == 4 && digits.allSatisfy(\.isNumber)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 14) {
            SidebarIconBadge(symbol: "ipad.and.iphone", tint: .blue, size: 40, symbolSize: 18)
            VStack(alignment: .leading, spacing: 2.5) {
              Text(l10n.pick("클라이언트 PIN 인증", "Client PIN Verification"))
                .font(.system(size: 13, weight: .semibold))
              Text(
                l10n.pick(
                  "Moonlight 또는 VoidLink 화면에 표시된 4자리 숫자를 입력하세요.",
                  "Enter the 4-digit code shown on your Moonlight or VoidLink screen."
                )
              )
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }

        Section {
          LabeledContent(l10n.pick("PIN 번호", "4-Digit PIN")) {
            TextField(
              "",
              text: Binding(
                get: { pin },
                set: { next in
                  pin = String(next.filter(\.isNumber).prefix(4))
                }
              ),
              prompt: Text("0000")
            )
            .labelsHidden()
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
            .onSubmit {
              if isValidPin && !isSubmitting { submit() }
            }
          }

          LabeledContent(l10n.pick("기기 이름", "Device Name")) {
            TextField(
              "",
              text: $deviceName,
              prompt: Text(l10n.pick("예: iPad Pro", "e.g. iPad Pro"))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 210)
            .onSubmit {
              if isValidPin && !isSubmitting { submit() }
            }
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
      .navigationTitle(l10n.pick("새 기기 페어링", "Pair New Device"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(l10n.pick("취소", "Cancel")) {
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("페어링", "Pair")) {
            submit()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!isValidPin || isSubmitting)
        }
      }
    }
    .frame(width: 430, height: errorText == nil ? 255 : 305)
  }

  private func submit() {
    isSubmitting = true
    errorText = nil
    let finalName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Moonlight Client"
      : deviceName
    Task {
      let ok = await store.pairDevice(pin: pin, name: finalName)
      isSubmitting = false
      if ok {
        dismiss()
      } else {
        errorText = l10n.pick(
          "페어링에 실패했습니다. 클라이언트가 대기 중인지와 PIN 번호를 확인하세요.",
          "Pairing failed. Verify the client is waiting and the PIN is correct."
        )
      }
    }
  }
}

// MARK: - 7. 스트리밍 앱 (Apps Pane & Native Liquid Glass Editor Sheet)

private struct AppsPane: View {
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

// MARK: - 시스템 로그 & 리소스 / 세션 기록 (Diagnostics Sub-Pages)

private struct LogViewerSubView: View {
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

private struct TelemetryDetailView: View {
  @ObservedObject var store: HostStore
  @ViewState private var showTelemetrySettings = false
  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      Section {
        if !store.dashboard.hostStats.cpuModel.isEmpty {
          LabeledContent("CPU") {
            Text(
              store.dashboard.hostStats.cpuPercent >= 0
                ? String(format: "%.1f%% · %@", store.dashboard.hostStats.cpuPercent, store.dashboard.hostStats.cpuModel)
                : store.dashboard.hostStats.cpuModel
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
          }
        }
        if store.dashboard.hostStats.gpuPercent >= 0 || !store.dashboard.hostStats.gpuModel.isEmpty {
          LabeledContent("GPU") {
            Text(
              store.dashboard.hostStats.gpuPercent >= 0
                ? String(format: "%.1f%%", store.dashboard.hostStats.gpuPercent)
                : store.dashboard.hostStats.gpuModel
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
          }
        }
        if store.dashboard.hostStats.ramUsedGB > 0 && store.dashboard.hostStats.ramTotalGB > 0 {
          LabeledContent(l10n.pick("메모리", "Memory")) {
            Text(
              String(
                format: "%.1f / %.0f GB",
                store.dashboard.hostStats.ramUsedGB,
                store.dashboard.hostStats.ramTotalGB
              )
            )
            .monospacedDigit()
            .foregroundStyle(.secondary)
          }
        }

        LabeledContent {
          Button(l10n.pick("통계 설정...", "Telemetry Options...")) {
            showTelemetrySettings = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("통계 샘플링 및 세션 기록 보관", "Sampling & History Retention"),
            subtitle: l10n.pick("실시간 하드웨어 지표 주기와 SQLite 세션 이력 보관 기간을 설정합니다.", "Configure hardware metrics sampling and SQLite session history retention.")
          )
        }
      }

      if store.dashboard.sessions.isEmpty {
        Section(l10n.pick("활성 세션", "Active Sessions")) {
          Text(l10n.pick("현재 진행 중인 스트리밍 세션이 없습니다.", "No active streaming sessions."))
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(store.dashboard.sessions) { s in
          Section(s.deviceName) {
            LabeledContent(l10n.pick("전송 경로", "Transport")) {
              Text(s.directUsb ? "USB Direct (usbmuxd)" : "Network (UDP/RTSP)")
                .foregroundStyle(.secondary)
            }
            LabeledContent(l10n.pick("해상도 및 주사율", "Resolution")) {
              Text("\(s.width)×\(s.height) @ \(s.fps) Hz")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            LabeledContent(l10n.pick("인코더 포맷", "Format")) {
              Text("\(s.codec) · \(s.bitDepth)-bit · \(s.yuv444 ? "4:4:4" : "4:2:0")\(s.hdr ? " · HDR" : "")")
                .foregroundStyle(.secondary)
            }
            LabeledContent(l10n.pick("비트레이트", "Bitrate")) {
              Text(String(format: "%.1f Mbps", Double(s.bitrateKbps) / 1000.0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            LabeledContent(l10n.pick("최근 호스트 처리 시간", "Last Host Processing Time")) {
              Text(s.encodeLatencyMs > 0 ? String(format: "%.2f ms", s.encodeLatencyMs) : "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            if let capture = s.captureToSubmitP95Ms, let encode = s.encodeP95Ms, let send = s.completeToSendP95Ms {
              LabeledContent(l10n.pick("캡처 → 인코더 제출 (P95)", "Capture to Submit (P95)"), value: String(format: "%.2f ms", capture))
              LabeledContent(l10n.pick("인코딩 (P95)", "Encoding (P95)"), value: String(format: "%.2f ms", encode))
              LabeledContent(l10n.pick("인코딩 완료 → 호스트 전송 (P95)", "Completion to Host Send (P95)"), value: String(format: "%.2f ms", send))
            }
            LabeledContent(l10n.pick("전송 프레임 / 손실", "Frames / Losses")) {
              Text("\(s.framesSent) / \(max(0, s.losses))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
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
    let spec = "\(item.width)×\(item.height) \(item.targetFps)Hz · \(item.codec)\(item.hdr ? " HDR" : "") · \(mins)\(l10n.pick("분", "m"))"
    return dateStr.isEmpty ? spec : "\(dateStr) · \(spec)"
  }
}
