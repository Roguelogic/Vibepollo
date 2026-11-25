import AppKit
import Combine
import SwiftUI

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
  var showLiveDot: Bool = false

  var body: some View {
    HStack(spacing: 9) {
      SidebarIconBadge(symbol: section.symbolName, tint: section.badgeTint)
      Text(title)
        .font(.system(size: 13))
        .lineLimit(1)
      Spacer(minLength: 4)
      if showLiveDot {
        Circle()
          .fill(Color.green)
          .frame(width: 7, height: 7)
      }
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
          SessionHistorySubView(store: store)
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
