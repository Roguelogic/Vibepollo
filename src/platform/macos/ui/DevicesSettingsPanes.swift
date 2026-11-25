import AppKit
import SwiftUI

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

struct DevicesPane: View {
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

struct DeviceDetailSubView: View {
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

struct PinPairingSheet: View {
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
