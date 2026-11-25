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

// MARK: - Visible-Only Telemetry Store (Zero Polling When Popover Is Closed)

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  @Published var dashboard: DashboardSnapshot = .empty
  @Published var cpuHistory: [Double] = []
  @Published var gpuHistory: [Double] = []

  private static let maxSamples = 40
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
    cpuHistory.removeAll()
    gpuHistory.removeAll()
  }

  func refresh() {
    let raw = VibepolloHostBridge.shared().fetchDashboardSnapshotJSON(includeHostStats: true)
    guard let data = raw.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    else { return }

    if dashboard != decoded {
      dashboard = decoded
    }

    let hs = decoded.hostStats
    if hs.cpuPercent >= 0 {
      Self.append(min(max(hs.cpuPercent, 0), 100), to: &cpuHistory)
    }
    if hs.gpuPercent >= 0 {
      Self.append(min(max(hs.gpuPercent, 0), 100), to: &gpuHistory)
    }
  }

  private static func append(_ value: Double, to buffer: inout [Double]) {
    buffer.append(value)
    if buffer.count > maxSamples {
      buffer.removeFirst(buffer.count - maxSamples)
    }
  }
}

// MARK: - Native AppKit NSPopover Manager (Native macOS Tahoe Liquid Glass, Zero Custom Window Chrome)

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
    // Ensure clicking in another app always dismisses the popover even while Vibepollo is an accessory app.
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

// MARK: - RunCat-Inspired Minimalist Monochrome Graphs (Single System Accent)

private struct MinimalAreaGraph: View {
  let values: [Double]
  let maxValue: Double

  var body: some View {
    Path { path in
      let w: CGFloat = 156
      let h: CGFloat = 16
      guard !values.isEmpty else { return }
      let ceiling = max(maxValue, 1.0)
      path.move(to: CGPoint(x: 0, y: h))
      if values.count == 1 {
        let norm = min(1.0, max(0.08, values[0] / ceiling))
        let y = h - h * CGFloat(norm)
        path.addLine(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: w, y: y))
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return
      }
      let step = w / CGFloat(values.count - 1)
      for (idx, raw) in values.enumerated() {
        let norm = min(1.0, max(0.06, raw / ceiling))
        let x = CGFloat(idx) * step
        let y = h - h * CGFloat(norm)
        path.addLine(to: CGPoint(x: x, y: y))
      }
      path.addLine(to: CGPoint(x: w, y: h))
      path.closeSubpath()
    }
    .fill(Color.accentColor.opacity(0.88))
    .frame(width: 156, height: 16)
    .padding(.top, 2)
  }
}

private struct MinimalBarGraph: View {
  let fraction: Double

  var body: some View {
    let clamped = min(max(fraction, 0), 1)
    Rectangle()
      .fill(Color.clear)
      .frame(width: 156, height: 7)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(Color.accentColor.opacity(0.88))
          .frame(width: 156 * CGFloat(clamped), height: 7)
      }
      .overlay(
        Rectangle()
          .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 0.6)
      )
      .padding(.top, 3)
  }
}

// MARK: - Minimalist Metric Row (RunCat Neo Anatomy)

private struct MinimalMetricRow<Accessory: View>: View {
  let symbol: String
  let summary: String
  let details: [String]
  @ViewBuilder let accessory: () -> Accessory

  init(
    symbol: String,
    summary: String,
    details: [String],
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
  ) {
    self.symbol = symbol
    self.summary = summary
    self.details = details
    self.accessory = accessory
  }

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
          accessory()
        }
        .padding(.leading, 8)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
  }
}

// MARK: - Main Minimalist Popover View

struct MenuBarMinimalPopoverView: View {
  @ObservedObject var store: MenuBarPopoverStore
  let onOpenSettings: (String?) -> Void
  let onDismiss: () -> Void

  private var l10n: L10n { store.l10n }
  private var hs: HostStatsSnapshot { store.dashboard.hostStats }
  private var activeSession: ActiveStreamSession? { store.dashboard.sessions.first }

  var body: some View {
    VStack(spacing: 8) {
      headerRow

      VStack(alignment: .leading, spacing: 8) {
        streamRow
        Divider()
        cpuRow
        Divider()
        gpuRow
        Divider()
        memoryRow
        Divider()
        networkRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .padding(8)
    .frame(width: 256)
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

  // MARK: 5 Minimalist Rows

  private var streamRow: some View {
    if let s = activeSession {
      let liveFps = (s.actualFps ?? 0) > 0 ? (s.actualFps ?? 0) : Double(s.fps)
      let liveMbps = (s.actualBitrateKbps ?? 0) > 0
        ? ((s.actualBitrateKbps ?? 0) / 1000.0)
        : (Double(s.bitrateKbps) / 1000.0)
      let encMs = s.encodeP95Ms ?? s.encodeLatencyMs
      let codecLine: String = {
        let base = "\(s.codec) \(s.bitDepth)-bit\(s.yuv444 ? " 4:4:4" : "")"
        if encMs > 0 {
          return String(format: "%@ · %.1f ms", base, encMs)
        }
        return base
      }()
      return MinimalMetricRow(
        symbol: "airplayvideo",
        summary: l10n.pick(
          String(format: "스트리밍: %.1f fps", liveFps),
          String(format: "Stream: %.1f fps", liveFps)
        ),
        details: [
          String(format: "%@ · %.1f Mbps", s.deviceName, liveMbps),
          codecLine,
        ]
      )
    } else {
      let chip = hs.cpuModel.isEmpty ? "Apple Silicon" : hs.cpuModel
      let detail: String = {
        if let mpx = store.dashboard.encoderSpec?.hevcMaxMpxPerSec, mpx > 0 {
          return String(format: "%@ · HEVC %.0f Mpx/s", chip, mpx)
        }
        return "\(chip) · VideoToolbox"
      }()
      return MinimalMetricRow(
        symbol: "airplayvideo",
        summary: l10n.pick("스트리밍: 대기 중", "Stream: Ready"),
        details: [detail]
      )
    }
  }

  private var cpuRow: some View {
    let summary = hs.cpuPercent >= 0
      ? String(format: "CPU: %.1f%%", hs.cpuPercent)
      : "CPU: —"
    var details: [String] = []
    if let u = hs.cpuUserPercent, let s = hs.cpuSystemPercent, u >= 0, s >= 0 {
      details.append(String(format: "User: %.1f%% · System: %.1f%%", u, s))
    } else if !hs.cpuModel.isEmpty {
      details.append(hs.cpuModel)
    }
    let ceiling = min(100.0, max(50.0, (store.cpuHistory.max() ?? 0) * 1.25))
    return MinimalMetricRow(symbol: "cpu", summary: summary, details: details) {
      MinimalAreaGraph(values: store.cpuHistory, maxValue: ceiling)
    }
  }

  private var gpuRow: some View {
    let summary = hs.gpuPercent >= 0
      ? String(format: "GPU: %.0f%%", hs.gpuPercent)
      : "GPU: —"
    var parts: [String] = []
    if !hs.gpuModel.isEmpty {
      if let cores = hs.gpuCoreCount, cores > 0 {
        parts.append(l10n.pick("\(hs.gpuModel) (\(cores)코어)", "\(hs.gpuModel) (\(cores)-core)"))
      } else {
        parts.append(hs.gpuModel)
      }
    }
    if let mb = hs.gpuMemInUseMB, mb > 0 {
      parts.append(mb >= 1024 ? String(format: "%.1f GB", mb / 1024.0) : String(format: "%.0f MB", mb))
    }
    let ceiling = min(100.0, max(50.0, (store.gpuHistory.max() ?? 0) * 1.25))
    return MinimalMetricRow(
      symbol: "square.3.layers.3d",
      summary: summary,
      details: parts.isEmpty ? [] : [parts.joined(separator: " · ")]
    ) {
      MinimalAreaGraph(values: store.gpuHistory, maxValue: ceiling)
    }
  }

  private var memoryRow: some View {
    let frac: Double = (hs.ramUsedGB > 0 && hs.ramTotalGB > 0)
      ? min(max(hs.ramUsedGB / hs.ramTotalGB, 0), 1)
      : 0
    let summary = (hs.ramUsedGB > 0 && hs.ramTotalGB > 0)
      ? l10n.pick(String(format: "메모리: %.1f%%", frac * 100), String(format: "Memory: %.1f%%", frac * 100))
      : l10n.pick("메모리: —", "Memory: —")
    var details: [String] = []
    if hs.ramUsedGB > 0 && hs.ramTotalGB > 0 {
      var line = String(format: "%.1f / %.0f GB", hs.ramUsedGB, hs.ramTotalGB)
      if let appMB = hs.processFootprintMB, appMB > 0 {
        line += String(format: " · %@ %.0f MB", l10n.pick("앱", "App"), appMB)
      }
      details.append(line)
    }
    return MinimalMetricRow(symbol: "memorychip", summary: summary, details: details) {
      MinimalBarGraph(fraction: frac)
    }
  }

  private var networkRow: some View {
    let iface = (hs.netInterface ?? "").isEmpty ? "—" : (hs.netInterface ?? "—")
    let summary = l10n.pick("네트워크: \(iface)", "Network: \(iface)")
    var details: [String] = []
    if let tx = hs.netTxMbps, tx >= 0 {
      details.append(l10n.pick(String(format: "송신: %.1f Mbps", tx), String(format: "Upload: %.1f Mbps", tx)))
    }
    if let rx = hs.netRxMbps, rx >= 0 {
      details.append(l10n.pick(String(format: "수신: %.1f Mbps", rx), String(format: "Download: %.1f Mbps", rx)))
    }
    if details.isEmpty {
      details.append("—")
    }
    return MinimalMetricRow(symbol: "globe", summary: summary, details: details)
  }
}
