import AppKit
import Combine
import SwiftUI

// MARK: - C Entrypoints from tray.mm / settings_bridge.mm

@_cdecl("vibepollo_macos_toggle_menubar_popover")
public func vibepollo_macos_toggle_menubar_popover(_ statusButtonPtr: UnsafeMutableRawPointer?) {
  guard Thread.isMainThread, let statusButtonPtr else { return }
  let button = Unmanaged<NSStatusBarButton>.fromOpaque(statusButtonPtr).takeUnretainedValue()
  MainActor.assumeIsolated {
    MenuBarPopoverManager.shared.toggle(relativeTo: button)
  }
}

@_cdecl("vibepollo_macos_close_menubar_popover")
public func vibepollo_macos_close_menubar_popover() {
  if Thread.isMainThread {
    MainActor.assumeIsolated {
      MenuBarPopoverManager.shared.close()
    }
    return
  }
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      MenuBarPopoverManager.shared.close()
    }
  }
}

// MARK: - Visible-Only Store (Zero Polling When Popover Is Closed, Zero Host Telemetry Overhead)

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  @Published var dashboard: DashboardSnapshot = .empty

  private var pollTimer: Timer?

  var l10n: L10n {
    let locale = HostStore.shared.settings.locale.isEmpty
      ? dashboard.locale
      : HostStore.shared.settings.locale
    return L10n(locale: locale)
  }

  func start() {
    refresh()
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refresh()
      }
    }
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  func refresh() {
    let raw = VibepolloHostBridge.shared().fetchDashboardSnapshotJSON(includeHostStats: false)
    guard let data = raw.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    else { return }

    if dashboard != decoded {
      dashboard = decoded
    }
  }
}

// MARK: - Native AppKit NSPopover Manager (Native macOS Tahoe Liquid Glass)

@MainActor
final class MenuBarPopoverManager: NSObject, NSPopoverDelegate {
  static let shared = MenuBarPopoverManager()

  let store = MenuBarPopoverStore()
  private var popover: NSPopover?
  private var globalClickMonitor: Any?
  private var lastCloseTimestamp: CFAbsoluteTime = 0
  private weak var anchorButton: NSStatusBarButton?

  override private init() {
    super.init()
  }

  var isShown: Bool {
    popover?.isShown == true
  }

  func toggle(relativeTo button: NSStatusBarButton) {
    if VibepolloHostBridge.shared().isLoginWindowSession() {
      return
    }
    if isShown {
      close()
      return
    }
    // Avoid immediate reopen when clicking the status bar icon just dismissed the transient popover.
    if CFAbsoluteTimeGetCurrent() - lastCloseTimestamp < 0.22 {
      return
    }
    show(relativeTo: button)
  }

  func show(relativeTo button: NSStatusBarButton) {
    anchorButton = button
    ensurePopover()
    store.start()

    guard let popover else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    installGlobalDismissMonitor()
  }

  func close() {
    removeGlobalDismissMonitor()
    store.stop()
    guard let popover, popover.isShown else { return }
    lastCloseTimestamp = CFAbsoluteTimeGetCurrent()
    popover.performClose(nil)
  }

  func popoverDidClose(_ notification: Notification) {
    lastCloseTimestamp = CFAbsoluteTimeGetCurrent()
    removeGlobalDismissMonitor()
    store.stop()
  }

  private func ensurePopover() {
    if popover != nil {
      return
    }

    let rootView = MenuBarMinimalPopoverView(
      store: store,
      onOpenSettings: { [weak self] route in
        self?.close()
        SettingsWindowManager.shared.openWindow(route: route)
      },
      onDismiss: { [weak self] in
        self?.close()
      }
    )

    let hostingController = NSHostingController(rootView: rootView)
    hostingController.sizingOptions = .preferredContentSize

    let pop = NSPopover()
    pop.behavior = .transient
    pop.animates = true
    pop.delegate = self
    pop.contentViewController = hostingController
    self.popover = pop
  }

  private func installGlobalDismissMonitor() {
    removeGlobalDismissMonitor()
    globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      let clickPoint = NSEvent.mouseLocation
      Task { @MainActor [weak self] in
        guard let self, self.isShown else { return }
        if let btn = self.anchorButton, let win = btn.window {
          let rect = win.convertToScreen(btn.convert(btn.bounds, to: nil)).insetBy(dx: -4, dy: -4)
          if rect.contains(clickPoint) {
            return
          }
        }
        self.close()
      }
    }
  }

  private func removeGlobalDismissMonitor() {
    if let monitor = globalClickMonitor {
      NSEvent.removeMonitor(monitor)
      globalClickMonitor = nil
    }
  }
}

// MARK: - Minimalist Monochrome Row (RunCat Neo Anatomy)

private struct MinimalMetricRow: View {
  let symbol: String
  let summary: String
  let details: [String]

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(.primary)
        .frame(width: 24, height: 24, alignment: .center)

      VStack(alignment: .leading, spacing: 2) {
        Text(summary)
          .font(.system(size: 12.5, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(.primary)
          .lineLimit(1)

        VStack(alignment: .leading, spacing: 1.5) {
          ForEach(Array(details.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(size: 11))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.leading, 8)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }
}

// MARK: - Main Minimalist Popover View (Streaming & Encoder Only)

struct MenuBarMinimalPopoverView: View {
  @ObservedObject var store: MenuBarPopoverStore
  let onOpenSettings: (String?) -> Void
  let onDismiss: () -> Void

  private var l10n: L10n { store.l10n }
  private var activeSession: ActiveStreamSession? { store.dashboard.sessions.first }

  var body: some View {
    VStack(spacing: 8) {
      headerRow

      VStack(alignment: .leading, spacing: 9) {
        streamRow
        Divider()
        encoderRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .padding(8)
    .frame(width: 248)
  }

  // MARK: Header (App Name + Native Action Menu)

  private var headerRow: some View {
    HStack {
      Text("Vibepollo")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 6)

      Spacer()

      Menu {
        Button {
          onOpenSettings("/pin")
        } label: {
          Label(l10n.pick("기기 페어링 (PIN)...", "Pair Device (PIN)..."), systemImage: "key.horizontal")
        }

        Button {
          onOpenSettings(nil)
        } label: {
          Label(l10n.pick("설정...", "Settings..."), systemImage: "gear")
        }

        if store.dashboard.appRunning {
          Button {
            VibepolloHostBridge.shared().terminateRunningApp()
            store.refresh()
          } label: {
            Label(l10n.pick("실행 중인 앱 종료", "Stop Running App"), systemImage: "stop.circle")
          }
        }

        Divider()

        Button {
          onDismiss()
          VibepolloHostBridge.shared().restartHost()
        } label: {
          Label(l10n.pick("Vibepollo 재시작", "Restart Vibepollo"), systemImage: "arrow.clockwise")
        }

        Button {
          onDismiss()
          VibepolloHostBridge.shared().quitHost()
        } label: {
          Label(l10n.pick("Vibepollo 종료", "Quit Vibepollo"), systemImage: "power")
        }
      } label: {
        Image(systemName: "list.bullet")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.primary)
          .frame(width: 22, height: 22)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .padding(.trailing, 2)
    }
  }

  // MARK: 2 Essential Rows (Stream + Encoder)

  private var streamRow: some View {
    if let s = activeSession {
      let liveFps = (s.actualFps ?? 0) > 0 ? (s.actualFps ?? 0) : Double(s.fps)
      let liveMbps = (s.actualBitrateKbps ?? 0) > 0
        ? ((s.actualBitrateKbps ?? 0) / 1000.0)
        : (Double(s.bitrateKbps) / 1000.0)
      let encMs = s.encodeP95Ms ?? s.encodeLatencyMs
      let secondLine: String = {
        let res = String(format: "%d×%d", s.width, s.height)
        var parts = [res]
        if encMs > 0 {
          parts.append(String(format: "%.1f ms", encMs))
        }
        if s.directUsb {
          parts.append("USB")
        }
        return parts.joined(separator: " · ")
      }()
      return MinimalMetricRow(
        symbol: "airplayvideo",
        summary: l10n.pick(
          String(format: "스트리밍: %.1f fps", liveFps),
          String(format: "Stream: %.1f fps", liveFps)
        ),
        details: [
          String(format: "%@ · %.1f Mbps", s.deviceName, liveMbps),
          secondLine,
        ]
      )
    } else {
      let host = store.dashboard.hostName.isEmpty ? "Mac" : store.dashboard.hostName
      let detail = store.dashboard.pairedCount > 0
        ? l10n.pick("\(host) · 기기 \(store.dashboard.pairedCount)대", "\(host) · \(store.dashboard.pairedCount) paired")
        : host
      return MinimalMetricRow(
        symbol: "airplayvideo",
        summary: l10n.pick("대기 중", "Ready"),
        details: [detail]
      )
    }
  }

  private var encoderRow: some View {
    let spec = store.dashboard.encoderSpec ?? .empty
    if let s = activeSession {
      let summary = l10n.pick(
        "인코더: \(s.codec) \(s.bitDepth)-bit",
        "Encoder: \(s.codec) \(s.bitDepth)-bit"
      )
      var tags: [String] = []
      if let pipe = spec.activePipeline, pipe.active {
        tags.append(pipe.zeroCopy ? "Zero-Copy" : "\(pipe.captureFormat)→\(pipe.encoderFormat)")
      }
      tags.append(s.yuv444 ? "4:4:4" : "4:2:0")
      if s.hdr {
        tags.append("HDR")
      }
      return MinimalMetricRow(
        symbol: "film",
        summary: summary,
        details: [tags.joined(separator: " · ")]
      )
    } else {
      let backend = spec.backend == "videotoolbox"
        ? "VideoToolbox"
        : (spec.backend == "software" ? l10n.pick("소프트웨어", "Software") : spec.backend)
      var codecs: [String] = []
      if spec.hevc10BitHdr {
        codecs.append("HEVC 10-bit")
      } else if spec.hevc8Bit {
        codecs.append("HEVC")
      }
      if spec.hevc444_10Bit || spec.hevc444_8Bit {
        codecs.append("4:4:4")
      }
      if codecs.isEmpty {
        codecs.append("H.264")
      }
      return MinimalMetricRow(
        symbol: "film",
        summary: l10n.pick("인코더: \(backend)", "Encoder: \(backend)"),
        details: [codecs.joined(separator: " · ")]
      )
    }
  }
}
