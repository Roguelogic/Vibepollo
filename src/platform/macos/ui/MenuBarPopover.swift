import AppKit
import Combine
import SwiftUI

// MARK: - C Entrypoints from tray.mm / settings_bridge.mm

@_cdecl("vibepollo_macos_toggle_menubar_popover")
public func vibepollo_macos_toggle_menubar_popover(
  _ x: Double,
  _ y: Double,
  _ width: Double,
  _ height: Double
) {
  let anchor = NSRect(x: x, y: y, width: width, height: height)
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      MenuBarPopoverManager.shared.toggle(anchorRect: anchor)
    }
  }
}

@_cdecl("vibepollo_macos_close_menubar_popover")
public func vibepollo_macos_close_menubar_popover() {
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      MenuBarPopoverManager.shared.close()
    }
  }
}

// MARK: - Lightweight Visible-Only Store (Zero Polling When Popover Is Closed)

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  enum Tab: String, CaseIterable, Identifiable {
    case live
    case encoder
    var id: String { rawValue }
  }

  @Published var selectedTab: Tab = .live
  @Published var dashboard: DashboardSnapshot = .empty
  @Published var cpuHistory: [Double] = []
  @Published var gpuHistory: [Double] = []
  @Published var ramHistory: [Double] = []
  @Published var netTxHistory: [Double] = []

  private static let maxSamples = 30
  private var pollTimer: Timer?
  var onContentSizeChange: (() -> Void)?

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
    ramHistory.removeAll()
    netTxHistory.removeAll()
  }

  func selectTab(_ tab: Tab) {
    guard selectedTab != tab else { return }
    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
      selectedTab = tab
    }
    DispatchQueue.main.async { [weak self] in
      self?.onContentSizeChange?()
    }
  }

  func refresh() {
    let raw = VibepolloHostBridge.shared().fetchDashboardSnapshotJSON(includeHostStats: true)
    guard let data = raw.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    else { return }

    let layoutChanged = decoded.sessions.count != dashboard.sessions.count
      || decoded.appRunning != dashboard.appRunning
      || (decoded.encoderSpec?.activePipeline?.active ?? false) != (dashboard.encoderSpec?.activePipeline?.active ?? false)
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
    if hs.ramUsedGB > 0 && hs.ramTotalGB > 0 {
      Self.append(min(max((hs.ramUsedGB / hs.ramTotalGB) * 100.0, 0), 100), to: &ramHistory)
    }
    if let tx = hs.netTxMbps, tx >= 0 {
      Self.append(tx, to: &netTxHistory)
    }

    if layoutChanged {
      DispatchQueue.main.async { [weak self] in
        self?.onContentSizeChange?()
      }
    }
  }

  private static func append(_ value: Double, to buffer: inout [Double]) {
    buffer.append(value)
    if buffer.count > maxSamples {
      buffer.removeFirst(buffer.count - maxSamples)
    }
  }
}

// MARK: - Floating macOS Tahoe Liquid Glass Panel Controller

private final class MenuBarGlassPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarPopoverManager: NSObject, NSWindowDelegate {
  static let shared = MenuBarPopoverManager()

  static let panelWidth: CGFloat = 356
  private let cornerRadius: CGFloat = 24

  let store = MenuBarPopoverStore()
  private var panel: MenuBarGlassPanel?
  private var hostingView: NSHostingView<MenuBarGlassPopoverView>?
  private var lastAnchorRect: NSRect = .zero
  private var globalClickMonitor: Any?
  private var localKeyMonitor: Any?
  private var lastCloseTimestamp: CFAbsoluteTime = 0

  override private init() {
    super.init()
    store.onContentSizeChange = { [weak self] in
      self?.relayoutPanel(animated: true)
    }
  }

  var isVisible: Bool {
    panel?.isVisible == true
  }

  func toggle(anchorRect: NSRect) {
    if VibepolloHostBridge.shared().isLoginWindowSession() {
      return
    }
    if isVisible {
      close()
      return
    }
    // Avoid immediate reopen if clicking the status item just dismissed the panel via resignKey/global monitor.
    if CFAbsoluteTimeGetCurrent() - lastCloseTimestamp < 0.22 {
      return
    }
    show(anchorRect: anchorRect)
  }

  func show(anchorRect: NSRect) {
    lastAnchorRect = anchorRect
    ensurePanel()
    store.start()
    relayoutPanel(animated: false)

    guard let panel else { return }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()
    installDismissMonitors()

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.14
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  func close() {
    removeDismissMonitors()
    store.stop()
    guard let panel, panel.isVisible else { return }
    lastCloseTimestamp = CFAbsoluteTimeGetCurrent()
    panel.orderOut(nil)
  }

  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  private func ensurePanel() {
    if panel != nil {
      return
    }

    let rootView = MenuBarGlassPopoverView(
      store: store,
      onOpenSettings: { [weak self] route in
        self?.close()
        SettingsWindowManager.shared.openWindow(route: route)
      },
      onDismiss: { [weak self] in
        self?.close()
      }
    )

    let hosting = NSHostingView(rootView: rootView)
    // Keep .intrinsicContentSize so fittingSize reports exact SwiftUI height across all states.
    hosting.sizingOptions = [.intrinsicContentSize]
    hosting.translatesAutoresizingMaskIntoConstraints = false
    self.hostingView = hosting

    let initialHeight = max(hosting.fittingSize.height, 440)
    let initialBounds = NSRect(x: 0, y: 0, width: Self.panelWidth, height: initialHeight)

    let p = MenuBarGlassPanel(
      contentRect: initialBounds,
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .statusBar
    p.isMovable = false
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    p.delegate = self

    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView(frame: initialBounds)
      glass.style = .regular
      glass.cornerRadius = cornerRadius
      glass.contentView = hosting
      p.contentView = glass
      NSLayoutConstraint.activate([
        hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
        hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        hosting.topAnchor.constraint(equalTo: glass.topAnchor),
        hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
      ])
    } else {
      let vfx = NSVisualEffectView(frame: initialBounds)
      vfx.material = .hudWindow
      vfx.blendingMode = .behindWindow
      vfx.state = .active
      vfx.wantsLayer = true
      vfx.layer?.cornerRadius = cornerRadius
      vfx.layer?.masksToBounds = true
      vfx.addSubview(hosting)
      p.contentView = vfx
      NSLayoutConstraint.activate([
        hosting.leadingAnchor.constraint(equalTo: vfx.leadingAnchor),
        hosting.trailingAnchor.constraint(equalTo: vfx.trailingAnchor),
        hosting.topAnchor.constraint(equalTo: vfx.topAnchor),
        hosting.bottomAnchor.constraint(equalTo: vfx.bottomAnchor),
      ])
    }

    self.panel = p
  }

  private func relayoutPanel(animated: Bool) {
    guard let panel, let hosting = hostingView else { return }
    hosting.invalidateIntrinsicContentSize()
    hosting.layoutSubtreeIfNeeded()
    let measured = hosting.fittingSize.height
    let targetHeight = min(max(ceil(measured), 280), 660)
    let frame = computeFrame(width: Self.panelWidth, height: targetHeight, anchor: lastAnchorRect)
    if animated && panel.isVisible {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
  }

  private func computeFrame(width: CGFloat, height: CGFloat, anchor: NSRect) -> NSRect {
    let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
    let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(anchorCenter) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    let visible = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let screenFrame = targetScreen?.frame ?? visible

    let margin: CGFloat = 10
    let gapBelowMenuBar: CGFloat = 6

    var x: CGFloat
    var y: CGFloat
    if anchor.width > 0 && anchor.height > 0 {
      x = anchor.midX - (width / 2.0)
      y = anchor.minY - height - gapBelowMenuBar
    } else {
      x = visible.maxX - width - margin
      y = visible.maxY - height - gapBelowMenuBar
    }

    x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
    y = min(max(y, visible.minY + margin), screenFrame.maxY - height - 28)
    return NSRect(x: round(x), y: round(y), width: width, height: round(height))
  }

  private func installDismissMonitors() {
    removeDismissMonitors()
    globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      let clickPoint = NSEvent.mouseLocation
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Let the status bar button action handle clicks on the status item itself cleanly.
        if self.lastAnchorRect.width > 0, self.lastAnchorRect.insetBy(dx: -4, dy: -4).contains(clickPoint) {
          return
        }
        self.close()
      }
    }
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {  // Escape
        Task { @MainActor [weak self] in
          self?.close()
        }
        return nil
      }
      return event
    }
  }

  private func removeDismissMonitors() {
    if let monitor = globalClickMonitor {
      NSEvent.removeMonitor(monitor)
      globalClickMonitor = nil
    }
    if let monitor = localKeyMonitor {
      NSEvent.removeMonitor(monitor)
      localKeyMonitor = nil
    }
  }
}

// MARK: - Liquid Glass Inner Surface & Control Primitives
// Note: The outer NSPanel uses native macOS 26+ NSGlassEffectView. Inner bento tiles and buttons
// use luminous translucent glass plates (never double-stacking glass-on-glass, per Apple HIG).

private struct GlassBentoTile<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let cornerRadius: CGFloat
  let padding: CGFloat
  @ViewBuilder let content: () -> Content

  init(cornerRadius: CGFloat = 16, padding: CGFloat = 11, @ViewBuilder content: @escaping () -> Content) {
    self.cornerRadius = cornerRadius
    self.padding = padding
    self.content = content
  }

  var body: some View {
    let isDark = colorScheme == .dark
    content()
      .padding(padding)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(isDark ? Color.white.opacity(0.068) : Color.white.opacity(0.54))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: isDark
                ? [Color.white.opacity(0.22), Color.white.opacity(0.04)]
                : [Color.white.opacity(0.88), Color.black.opacity(0.06)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 0.65
          )
      )
      .shadow(color: Color.black.opacity(isDark ? 0.0 : 0.035), radius: 4, x: 0, y: 1.5)
  }
}

private struct GlassPillButton<Label: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @ViewState private var hovered = false
  let tint: Color?
  let isCircle: Bool
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  init(tint: Color? = nil, isCircle: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
    self.tint = tint
    self.isCircle = isCircle
    self.action = action
    self.label = label
  }

  var body: some View {
    let isDark = colorScheme == .dark
    let fillColor: Color = {
      if let tint {
        return tint.opacity(hovered ? (isDark ? 0.28 : 0.20) : (isDark ? 0.18 : 0.13))
      }
      if isDark {
        return Color.white.opacity(hovered ? 0.17 : 0.095)
      } else {
        return Color.white.opacity(hovered ? 0.82 : 0.60)
      }
    }()
    let strokeTop = tint?.opacity(isDark ? 0.45 : 0.35) ?? Color.white.opacity(isDark ? 0.28 : 0.90)
    let strokeBottom = tint?.opacity(0.10) ?? (isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.08))

    Button(action: action) {
      label()
        .background {
          if isCircle {
            Circle().fill(fillColor)
          } else {
            Capsule(style: .continuous).fill(fillColor)
          }
        }
        .overlay {
          if isCircle {
            Circle().strokeBorder(
              LinearGradient(colors: [strokeTop, strokeBottom], startPoint: .top, endPoint: .bottom),
              lineWidth: 0.65
            )
          } else {
            Capsule(style: .continuous).strokeBorder(
              LinearGradient(colors: [strokeTop, strokeBottom], startPoint: .top, endPoint: .bottom),
              lineWidth: 0.65
            )
          }
        }
        .contentShape(isCircle ? AnyShape(Circle()) : AnyShape(Capsule(style: .continuous)))
    }
    .buttonStyle(.plain)
    .onHover { isOver in
      withAnimation(.easeOut(duration: 0.12)) {
        hovered = isOver
      }
    }
  }
}

private struct CircularGaugeRing: View {
  @Environment(\.colorScheme) private var colorScheme
  let progress: Double
  let tint: Color
  let symbol: String
  var size: CGFloat = 34

  var body: some View {
    let clamped = min(max(progress, 0), 1)
    let isDark = colorScheme == .dark
    ZStack {
      Circle()
        .stroke(isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.08), lineWidth: 3.3)
      Circle()
        .trim(from: 0, to: clamped > 0 ? max(0.04, clamped) : 0)
        .stroke(
          AngularGradient(
            colors: [tint.opacity(0.68), tint],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360 * max(0.06, clamped))
          ),
          style: StrokeStyle(lineWidth: 3.3, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: 0.35), value: clamped)
      Image(systemName: symbol)
        .font(.system(size: size * 0.34, weight: .semibold))
        .foregroundStyle(tint)
    }
    .frame(width: size, height: size)
  }
}

private struct MiniGlassSparkline: View {
  @Environment(\.colorScheme) private var colorScheme
  let values: [Double]
  let maxValue: Double
  let tint: Color

  var body: some View {
    let isDark = colorScheme == .dark
    ZStack {
      // Subtle baseline track so even low values look anchored
      VStack {
        Spacer()
        Rectangle()
          .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
          .frame(height: 0.5)
      }
      if !values.isEmpty {
        PopoverSparkArea(values: values, maxValue: maxValue)
          .fill(
            LinearGradient(
              colors: [tint.opacity(isDark ? 0.30 : 0.24), tint.opacity(0.01)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
        PopoverSparkLine(values: values, maxValue: maxValue)
          .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
      }
    }
    .frame(height: 24)
    .clipped()
  }
}

private struct PopoverSparkLine: Shape {
  let values: [Double]
  let maxValue: Double

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard !values.isEmpty, rect.width > 1, rect.height > 1 else { return path }
    let ceiling = max(maxValue, 0.001)
    let pad: CGFloat = 2.0
    let usableH = max(1, rect.height - pad * 2)
    if values.count == 1 {
      let y = rect.height - pad - CGFloat(min(max(values[0] / ceiling, 0), 1)) * usableH
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: rect.width, y: y))
      return path
    }
    let step = rect.width / CGFloat(values.count - 1)
    let pts: [CGPoint] = values.enumerated().map { idx, v in
      let norm = CGFloat(min(max(v / ceiling, 0), 1))
      return CGPoint(x: CGFloat(idx) * step, y: rect.height - pad - norm * usableH)
    }
    path.move(to: pts[0])
    for i in 1..<pts.count {
      let prev = pts[i - 1]
      let curr = pts[i]
      let midX = (prev.x + curr.x) * 0.5
      path.addCurve(
        to: curr,
        control1: CGPoint(x: midX, y: prev.y),
        control2: CGPoint(x: midX, y: curr.y)
      )
    }
    return path
  }
}

private struct PopoverSparkArea: Shape {
  let values: [Double]
  let maxValue: Double

  func path(in rect: CGRect) -> Path {
    var path = PopoverSparkLine(values: values, maxValue: maxValue).path(in: rect)
    guard !values.isEmpty, rect.width > 1, rect.height > 1 else { return path }
    path.addLine(to: CGPoint(x: rect.width, y: rect.height))
    path.addLine(to: CGPoint(x: 0, y: rect.height))
    path.closeSubpath()
    return path
  }
}

// MARK: - Main Liquid Glass Popover View

struct MenuBarGlassPopoverView: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var store: MenuBarPopoverStore
  let onOpenSettings: (String?) -> Void
  let onDismiss: () -> Void

  private var l10n: L10n { store.l10n }
  private var hs: HostStatsSnapshot { store.dashboard.hostStats }
  private var activeSession: ActiveStreamSession? { store.dashboard.sessions.first }
  private var isDark: Bool { colorScheme == .dark }

  var body: some View {
    VStack(spacing: 10) {
      headerBar
      tabSwitcher

      if store.selectedTab == .live {
        liveContent
      } else {
        encoderContent
      }

      footerBar
    }
    .padding(14)
    .frame(width: MenuBarPopoverManager.panelWidth)
  }

  // MARK: Header

  private var headerBar: some View {
    HStack(spacing: 10) {
      ZStack {
        if activeSession != nil {
          Circle()
            .fill(Color.green.opacity(0.28))
            .frame(width: 22, height: 22)
        } else {
          Circle()
            .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            .frame(width: 22, height: 22)
        }
        Circle()
          .fill(activeSession != nil ? Color.green : Color.secondary.opacity(0.55))
          .frame(width: 9, height: 9)
      }

      VStack(alignment: .leading, spacing: 1.5) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("Vibepollo")
            .font(.system(size: 14, weight: .semibold))
          if !store.dashboard.version.isEmpty {
            Text(store.dashboard.version)
              .font(.system(size: 10.5, weight: .medium).monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        Text(headerSubtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      if activeSession != nil {
        HStack(spacing: 4) {
          Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
          Text("LIVE")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(isDark ? Color.green : Color(red: 0.08, green: 0.52, blue: 0.22))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.green.opacity(isDark ? 0.18 : 0.14)))
        .overlay(
          Capsule().strokeBorder(Color.green.opacity(0.32), lineWidth: 0.6)
        )
      } else {
        GlassPillButton(tint: .accentColor) {
          onOpenSettings("/pin")
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "key.horizontal.fill")
              .font(.system(size: 10, weight: .semibold))
            Text(l10n.pick("PIN 연결", "Pair PIN"))
              .font(.system(size: 11, weight: .semibold))
          }
          .foregroundStyle(Color.accentColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
        }
      }
    }
    .padding(.horizontal, 2)
  }

  private var headerSubtitle: String {
    if let s = activeSession {
      return l10n.pick(
        "\(s.deviceName) 스트리밍 중 · \(formatUptime(s.uptimeSeconds))",
        "Streaming to \(s.deviceName) · \(formatUptime(s.uptimeSeconds))"
      )
    }
    let host = store.dashboard.hostName.isEmpty ? "Mac" : store.dashboard.hostName
    return l10n.pick("\(host) · 연결 대기 중", "\(host) · Ready to stream")
  }

  // MARK: Segmented Switcher

  private var tabSwitcher: some View {
    HStack(spacing: 4) {
      tabPill(.live, title: l10n.pick("실시간 현황", "Live Monitor"), symbol: "waveform.path.ecg")
      tabPill(.encoder, title: l10n.pick("인코딩 스펙", "Encoder Specs"), symbol: "cpu")
    }
    .padding(3)
    .background(
      Capsule(style: .continuous)
        .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.055))
    )
    .overlay(
      Capsule(style: .continuous)
        .strokeBorder(isDark ? Color.white.opacity(0.14) : Color.white.opacity(0.65), lineWidth: 0.55)
    )
  }

  private func tabPill(_ tab: MenuBarPopoverStore.Tab, title: String, symbol: String) -> some View {
    let selected = store.selectedTab == tab
    return Button {
      store.selectTab(tab)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: symbol)
          .font(.system(size: 10.5, weight: .semibold))
        Text(title)
          .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
      }
      .foregroundStyle(selected ? .primary : .secondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 5.5)
      .background {
        if selected {
          Capsule(style: .continuous)
            .fill(isDark ? Color.white.opacity(0.15) : Color.white.opacity(0.86))
            .overlay(
              Capsule(style: .continuous)
                .strokeBorder(
                  isDark ? Color.white.opacity(0.28) : Color.white.opacity(0.95),
                  lineWidth: 0.6
                )
            )
            .shadow(color: Color.black.opacity(isDark ? 0.12 : 0.06), radius: 3, x: 0, y: 1)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: Tab 1 — Live Monitor

  @ViewBuilder
  private var liveContent: some View {
    if let s = activeSession {
      activeStreamHeroTile(s)
    } else {
      standbyHeroTile
    }

    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
      ],
      spacing: 8
    ) {
      cpuBentoTile
      gpuBentoTile
      memoryBentoTile
      networkBentoTile
    }
  }

  private func activeStreamHeroTile(_ s: ActiveStreamSession) -> some View {
    let liveFps = (s.actualFps ?? 0) > 0 ? (s.actualFps ?? 0) : Double(s.fps)
    let liveMbps = (s.actualBitrateKbps ?? 0) > 0 ? ((s.actualBitrateKbps ?? 0) / 1000.0) : (Double(s.bitrateKbps) / 1000.0)
    let encMs = s.encodeP95Ms ?? s.encodeLatencyMs
    let isVfrIdle = (s.actualFps ?? 0) > 0 && (s.actualFps ?? 0) < 20 && (s.repeatedFrames ?? 0) > 0

    return GlassBentoTile(cornerRadius: 18, padding: 12) {
      VStack(alignment: .leading, spacing: 10) {
        // Badges row
        HStack(spacing: 6) {
          tinyBadge(
            s.directUsb ? "USB Direct" : l10n.pick("네트워크", "Network"),
            tint: s.directUsb ? .blue : .teal
          )
          tinyBadge(
            "\(s.codec) \(s.bitDepth)-bit\(s.yuv444 ? " 4:4:4" : "")\(s.hdr ? " HDR" : "")",
            tint: .purple
          )
          if isVfrIdle {
            tinyBadge(l10n.pick("VFR 절전", "VFR Idle"), tint: .secondary)
          }
          Spacer(minLength: 2)
          Text(String(format: "%d×%d", s.width, s.height))
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }

        // Hero KPI Trio
        HStack(spacing: 0) {
          heroMetric(
            value: String(format: "%.1f", liveFps),
            unit: "fps",
            caption: l10n.pick("목표 \(s.fps)Hz", "Target \(s.fps)Hz")
          )
          Divider().frame(height: 28).opacity(0.32)
          heroMetric(
            value: String(format: "%.1f", liveMbps),
            unit: "Mbps",
            caption: String(format: "%@ %.0fM", l10n.pick("상한", "Cap"), Double(s.bitrateKbps) / 1000.0)
          )
          Divider().frame(height: 28).opacity(0.32)
          heroMetric(
            value: encMs > 0 ? String(format: "%.1f", encMs) : "—",
            unit: "ms",
            caption: s.jitterMs != nil
              ? String(format: "%@ %.1fms", l10n.pick("지터", "Jit"), s.jitterMs ?? 0)
              : l10n.pick("호스트 지연", "Host Lat")
          )
        }

        // 3-Stage Latency Bar
        if let cap = s.captureToSubmitP95Ms, let enc = s.encodeP95Ms, let snd = s.completeToSendP95Ms {
          let total = max(0.01, cap + enc + snd)
          VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
              let w = geo.size.width
              HStack(spacing: 1.5) {
                Rectangle().fill(Color.blue).frame(width: max(cap > 0 ? 4 : 0, w * CGFloat(cap / total)))
                Rectangle().fill(Color.purple).frame(width: max(enc > 0 ? 6 : 0, w * CGFloat(enc / total)))
                Rectangle().fill(Color.green).frame(width: max(snd > 0 ? 4 : 0, w * CGFloat(snd / total)))
              }
              .clipShape(Capsule())
            }
            .frame(height: 5.5)

            HStack(spacing: 7) {
              miniDot(.blue, l10n.pick(String(format: "캡처 %.2f", cap), String(format: "Cap %.2f", cap)))
              miniDot(.purple, l10n.pick(String(format: "인코드 %.1f", enc), String(format: "Enc %.1f", enc)))
              miniDot(.green, l10n.pick(String(format: "전송 %.2fms", snd), String(format: "Snd %.2fms", snd)))
              Spacer(minLength: 2)
              Text(
                l10n.pick(
                  "손실 \(max(0, s.losses)) · IDR \(s.idrRequests ?? 0)",
                  "Loss \(max(0, s.losses)) · IDR \(s.idrRequests ?? 0)"
                )
              )
              .font(.system(size: 9.5).monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
        }

        // Compact Pipeline Summary Line (guaranteed single line without truncation)
        if let pipe = store.dashboard.encoderSpec?.activePipeline, pipe.active {
          HStack(spacing: 5) {
            Image(systemName: pipe.zeroCopy ? "bolt.fill" : "arrow.triangle.2.circlepath")
              .font(.system(size: 9.5, weight: .semibold))
              .foregroundStyle(pipe.zeroCopy ? .green : .orange)
            Text(pipelineInlineSummary(pipe))
              .font(.system(size: 10.5, weight: .medium).monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.9)
          }
        }
      }
    }
  }

  private var standbyHeroTile: some View {
    GlassBentoTile(cornerRadius: 18, padding: 12) {
      HStack(spacing: 11) {
        ZStack {
          Circle()
            .fill(Color.accentColor.opacity(isDark ? 0.18 : 0.14))
            .frame(width: 36, height: 36)
          Image(systemName: "airplayvideo")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }

        VStack(alignment: .leading, spacing: 2.5) {
          Text(l10n.pick("스트리밍 대기 중", "Ready to Stream"))
            .font(.system(size: 13, weight: .semibold))
          Text(standbySiliconLine)
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 4)

        if store.dashboard.pairedCount > 0 {
          Text(l10n.pick("기기 \(store.dashboard.pairedCount)대", "\(store.dashboard.pairedCount) paired"))
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
        }
      }
    }
  }

  private var standbySiliconLine: String {
    let chip = hs.cpuModel.isEmpty ? "Apple Silicon" : hs.cpuModel
    if let mpx = store.dashboard.encoderSpec?.hevcMaxMpxPerSec, mpx > 0 {
      return String(format: "%@ · HEVC Turbo %.0f Mpx/s", chip, mpx)
    }
    return l10n.pick("\(chip) · VideoToolbox 준비됨", "\(chip) · VideoToolbox Ready")
  }

  // MARK: 2x2 Bento Resource Tiles

  private var cpuBentoTile: some View {
    let pct = hs.cpuPercent >= 0 ? hs.cpuPercent : 0
    let sparkCeiling = min(100.0, max(40.0, (store.cpuHistory.max() ?? 0) * 1.35))
    let sub1: String = {
      if let p = hs.cpuPerfCores, let e = hs.cpuEffCores, p > 0, e > 0 {
        return "\(hs.cpuModel.isEmpty ? "CPU" : hs.cpuModel) · \(p)P+\(e)E"
      }
      return hs.cpuModel.isEmpty ? "CPU" : hs.cpuModel
    }()
    let sub2: String = {
      if let u = hs.cpuUserPercent, let s = hs.cpuSystemPercent, u >= 0, s >= 0 {
        return String(format: "Usr %.0f%% · Sys %.0f%%", u, s)
      }
      return ""
    }()

    return GlassBentoTile(cornerRadius: 16, padding: 10.5) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8.5) {
          CircularGaugeRing(progress: pct / 100.0, tint: .blue, symbol: "cpu", size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text("CPU")
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(.secondary)
            Text(hs.cpuPercent >= 0 ? String(format: "%.1f%%", hs.cpuPercent) : "—")
              .font(.system(size: 15.5, weight: .semibold, design: .rounded))
              .monospacedDigit()
          }
          Spacer(minLength: 0)
        }
        MiniGlassSparkline(values: store.cpuHistory, maxValue: sparkCeiling, tint: .blue)
        VStack(alignment: .leading, spacing: 1.5) {
          Text(sub1)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if !sub2.isEmpty {
            Text(sub2)
              .font(.system(size: 9.5).monospacedDigit())
              .foregroundStyle(.secondary.opacity(0.82))
              .lineLimit(1)
          }
        }
      }
    }
  }

  private var gpuBentoTile: some View {
    let pct = hs.gpuPercent >= 0 ? hs.gpuPercent : 0
    let sparkCeiling = min(100.0, max(45.0, (store.gpuHistory.max() ?? 0) * 1.35))
    let sub1: String = {
      let base = hs.gpuModel.isEmpty ? "Apple GPU" : hs.gpuModel
      if let c = hs.gpuCoreCount, c > 0 {
        return l10n.pick("\(base) · \(c)코어", "\(base) · \(c)-core")
      }
      return base
    }()
    let sub2: String = {
      var parts: [String] = []
      if let r = hs.gpuRendererPercent, r >= 0 {
        parts.append(l10n.pick(String(format: "렌더 %.0f%%", r), String(format: "R %.0f%%", r)))
      }
      if let mb = hs.gpuMemInUseMB, mb > 0 {
        parts.append(mb >= 1024 ? String(format: "%.1fGB", mb / 1024.0) : String(format: "%.0fMB", mb))
      }
      return parts.joined(separator: " · ")
    }()

    return GlassBentoTile(cornerRadius: 16, padding: 10.5) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8.5) {
          CircularGaugeRing(progress: pct / 100.0, tint: .purple, symbol: "sparkles", size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text("GPU")
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(.secondary)
            Text(hs.gpuPercent >= 0 ? String(format: "%.0f%%", hs.gpuPercent) : "—")
              .font(.system(size: 15.5, weight: .semibold, design: .rounded))
              .monospacedDigit()
          }
          Spacer(minLength: 0)
        }
        MiniGlassSparkline(values: store.gpuHistory, maxValue: sparkCeiling, tint: .purple)
        VStack(alignment: .leading, spacing: 1.5) {
          Text(sub1)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if !sub2.isEmpty {
            Text(sub2)
              .font(.system(size: 9.5).monospacedDigit())
              .foregroundStyle(.secondary.opacity(0.82))
              .lineLimit(1)
          }
        }
      }
    }
  }

  private var memoryBentoTile: some View {
    let frac: Double = (hs.ramUsedGB > 0 && hs.ramTotalGB > 0) ? min(max(hs.ramUsedGB / hs.ramTotalGB, 0), 1) : 0
    let tint: Color = frac >= 0.90 ? .red : (frac >= 0.80 ? .orange : .green)
    let valueStr = (hs.ramUsedGB > 0 && hs.ramTotalGB > 0)
      ? String(format: "%.1f GB", hs.ramUsedGB)
      : "—"
    let sub1 = (hs.ramTotalGB > 0)
      ? l10n.pick(String(format: "%.0f GB 중 %.0f%%", hs.ramTotalGB, frac * 100), String(format: "%.0f%% of %.0f GB", frac * 100, hs.ramTotalGB))
      : l10n.pick("통합 메모리", "Unified")
    let sub2 = (hs.processFootprintMB ?? 0) > 0
      ? String(format: "Vibepollo %.0f MB", hs.processFootprintMB ?? 0)
      : ""

    return GlassBentoTile(cornerRadius: 16, padding: 10.5) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8.5) {
          CircularGaugeRing(progress: frac, tint: tint, symbol: "memorychip", size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text(l10n.pick("메모리", "Memory"))
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(.secondary)
            Text(valueStr)
              .font(.system(size: 15.5, weight: .semibold, design: .rounded))
              .monospacedDigit()
          }
          Spacer(minLength: 0)
        }
        MiniGlassSparkline(values: store.ramHistory, maxValue: 100, tint: tint)
        VStack(alignment: .leading, spacing: 1.5) {
          Text(sub1)
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if !sub2.isEmpty {
            Text(sub2)
              .font(.system(size: 9.5).monospacedDigit())
              .foregroundStyle(.secondary.opacity(0.82))
              .lineLimit(1)
          }
        }
      }
    }
  }

  private var networkBentoTile: some View {
    let tx = hs.netTxMbps ?? -1
    let rx = hs.netRxMbps ?? -1
    let ceiling = max(10.0, (store.netTxHistory.max() ?? 0) * 1.25)
    let progress = tx >= 0 ? min(max(tx / ceiling, 0), 1) : 0
    let iface = hs.netInterface ?? ""
    let sub1: String = {
      if iface.isEmpty { return l10n.pick("네트워크", "Network") }
      if let link = hs.netLinkSpeedMbps, link > 0 {
        let s = link >= 1000 ? String(format: "%.0fG", Double(link) / 1000.0) : "\(link)M"
        return "\(iface) · \(s)"
      }
      return iface
    }()
    let sub2 = rx >= 0 ? String(format: "↓ %.1f Mbps", rx) : ""

    return GlassBentoTile(cornerRadius: 16, padding: 10.5) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 8.5) {
          CircularGaugeRing(progress: progress, tint: .teal, symbol: "arrow.up.arrow.down", size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text(l10n.pick("송신", "Tx Rate"))
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(.secondary)
            Text(tx >= 0 ? String(format: "%.1fM", tx) : "—")
              .font(.system(size: 15.5, weight: .semibold, design: .rounded))
              .monospacedDigit()
          }
          Spacer(minLength: 0)
        }
        MiniGlassSparkline(values: store.netTxHistory, maxValue: ceiling, tint: .teal)
        VStack(alignment: .leading, spacing: 1.5) {
          Text(sub1)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if !sub2.isEmpty {
            Text(sub2)
              .font(.system(size: 9.5).monospacedDigit())
              .foregroundStyle(.secondary.opacity(0.82))
              .lineLimit(1)
          }
        }
      }
    }
  }

  // MARK: Tab 2 — Hardware Encoder Specs

  @ViewBuilder
  private var encoderContent: some View {
    let spec = store.dashboard.encoderSpec ?? .empty

    GlassBentoTile(cornerRadius: 18, padding: 12) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 9) {
          ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.purple.opacity(isDark ? 0.22 : 0.14))
              .frame(width: 32, height: 32)
            Image(systemName: "film.stack.fill")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.purple)
          }
          VStack(alignment: .leading, spacing: 1.5) {
            Text(spec.backend == "videotoolbox"
              ? l10n.pick("Apple VideoToolbox (하드웨어)", "Apple VideoToolbox (Hardware)")
              : spec.backend)
              .font(.system(size: 12.5, weight: .semibold))
            Text(hs.cpuModel.isEmpty ? "Apple Silicon Media Engine" : "\(hs.cpuModel) · AppleAVE")
              .font(.system(size: 10.5))
              .foregroundStyle(.secondary)
          }
          Spacer()
        }

        if spec.hevcMaxMpxPerSec > 0 || spec.h264MaxMpxPerSec > 0 {
          Divider().opacity(0.32)
          HStack(spacing: 10) {
            if spec.hevcMaxMpxPerSec > 0 {
              VStack(alignment: .leading, spacing: 1.5) {
                Text("HEVC \(spec.hevcMaxTier.capitalized)")
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                Text(String(format: "%.1f Mpx/s", spec.hevcMaxMpxPerSec))
                  .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                  .monospacedDigit()
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            if spec.h264MaxMpxPerSec > 0 {
              Divider().frame(height: 24).opacity(0.32)
              VStack(alignment: .leading, spacing: 1.5) {
                Text("H.264 \(spec.h264MaxTier.capitalized)")
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                Text(String(format: "%.1f Mpx/s", spec.h264MaxMpxPerSec))
                  .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                  .monospacedDigit()
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }

    if let pipe = spec.activePipeline, pipe.active {
      GlassBentoTile(cornerRadius: 16, padding: 11) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(l10n.pick("현재 활성 파이프라인", "Active Session Pipeline"))
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer()
            tinyBadge(
              pipe.zeroCopy ? "Zero-Copy" : l10n.pick("포맷 변환", "Transfer"),
              tint: pipe.zeroCopy ? .green : .orange
            )
          }
          specRow(l10n.pick("프로파일", "Profile"), "\(pipe.codec) \(pipe.profile)")
          specRow(
            l10n.pick("픽셀 경로", "Pixel Path"),
            pipe.captureFormat.isEmpty
              ? pipe.encoderFormat
              : (pipe.zeroCopy
                ? l10n.pick("\(pipe.captureFormat) 직결", "\(pipe.captureFormat) Direct")
                : "\(pipe.captureFormat) → \(pipe.encoderFormat)")
          )
          specRow(
            l10n.pick("파이프라인", "Pipeline"),
            "\(pipe.maxInFlight)-Stage · \(pipe.slicesPerFrame) Slices · ME \(pipe.motionSearch)"
          )
          specRow(l10n.pick("레이트 컨트롤", "Rate Control"), pipe.rateControl)
        }
      }
    }

    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
      ],
      spacing: 7
    ) {
      codecGlassCell("H.264", ok: spec.h264, sub: "8-bit 4:2:0")
      codecGlassCell("HEVC 8-bit", ok: spec.hevc8Bit, sub: "SDR 4:2:0")
      codecGlassCell("HEVC 10-bit", ok: spec.hevc10BitHdr, sub: "HDR10 PQ")
      codecGlassCell("HEVC 4:4:4", ok: spec.hevc444_8Bit, sub: l10n.pick("8-bit 고선명", "8-bit Chroma"))
      codecGlassCell("HEVC 4:4:4 10", ok: spec.hevc444_10Bit, sub: "10-bit HDR")
      codecGlassCell("AV1 HW", ok: spec.av1Hw, sub: spec.av1Hw ? "Hardware" : l10n.pick("디코드 전용", "Decode Only"))
    }
  }

  private func specRow(_ key: String, _ value: String) -> some View {
    HStack {
      Text(key)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
  }

  private func codecGlassCell(_ name: String, ok: Bool, sub: String) -> some View {
    GlassBentoTile(cornerRadius: 13, padding: 8.5) {
      HStack(spacing: 7) {
        Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle.fill")
          .font(.system(size: 12))
          .foregroundStyle(ok ? Color.green : Color.secondary.opacity(0.55))
        VStack(alignment: .leading, spacing: 1) {
          Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ok ? .primary : .secondary)
            .lineLimit(1)
          Text(sub)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
    }
  }

  // MARK: Footer Quick Actions

  private var footerBar: some View {
    HStack(spacing: 6) {
      GlassPillButton {
        onOpenSettings(nil)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "gearshape.fill")
            .font(.system(size: 11, weight: .semibold))
          Text(l10n.pick("설정", "Settings"))
            .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
      }

      if store.dashboard.appRunning {
        GlassPillButton(tint: .red) {
          VibepolloHostBridge.shared().terminateRunningApp()
          store.refresh()
        } label: {
          HStack(spacing: 4.5) {
            Image(systemName: "stop.fill")
              .font(.system(size: 9.5, weight: .semibold))
            Text(l10n.pick("앱 종료", "Stop App"))
              .font(.system(size: 11.5, weight: .medium))
          }
          .foregroundStyle(isDark ? Color(red: 1.0, green: 0.45, blue: 0.42) : Color(red: 0.80, green: 0.14, blue: 0.14))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
      } else if activeSession != nil {
        GlassPillButton {
          onOpenSettings("/pin")
        } label: {
          HStack(spacing: 4.5) {
            Image(systemName: "key.horizontal.fill")
              .font(.system(size: 10, weight: .semibold))
            Text(l10n.pick("PIN", "PIN"))
              .font(.system(size: 11.5, weight: .medium))
          }
          .foregroundStyle(.primary)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
      }

      Spacer(minLength: 4)

      GlassPillButton(isCircle: true) {
        onDismiss()
        VibepolloHostBridge.shared().restartHost()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 28, height: 28)
      }
      .help(l10n.pick("Vibepollo 재시작", "Restart Vibepollo"))

      GlassPillButton(isCircle: true) {
        onDismiss()
        VibepolloHostBridge.shared().quitHost()
      } label: {
        Image(systemName: "power")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
      }
      .help(l10n.pick("Vibepollo 종료", "Quit Vibepollo"))
    }
    .padding(.top, 2)
  }

  // MARK: Helpers

  private func heroMetric(value: String, unit: String, caption: String) -> some View {
    VStack(spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2.5) {
        Text(value)
          .font(.system(size: 18, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
        Text(unit)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      Text(caption)
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }

  private func tinyBadge(_ text: String, tint: Color) -> some View {
    let fg: Color = {
      if !isDark {
        if tint == .teal { return Color(red: 0.04, green: 0.45, blue: 0.50) }
        if tint == .green { return Color(red: 0.07, green: 0.48, blue: 0.20) }
      }
      return tint
    }()
    return Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(fg)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 7.5)
      .padding(.vertical, 2.5)
      .background(Capsule().fill(tint.opacity(isDark ? 0.18 : 0.14)))
  }

  private func miniDot(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 3) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(text)
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private func pipelineInlineSummary(_ pipe: EncoderRuntimePipeline) -> String {
    var parts: [String] = []
    if !pipe.throughputTier.isEmpty {
      let tier = pipe.throughputTier.capitalized
      parts.append(pipe.maxMpxPerSec > 0 ? String(format: "AppleAVE %@ %.0f Mpx/s", tier, pipe.maxMpxPerSec) : "AppleAVE \(tier)")
    }
    if !pipe.captureFormat.isEmpty {
      parts.append(pipe.zeroCopy ? "Zero-Copy \(pipe.captureFormat)" : "\(pipe.captureFormat)→\(pipe.encoderFormat)")
    }
    if pipe.slicesPerFrame > 1 {
      parts.append("\(pipe.maxInFlight)-Stage · \(pipe.slicesPerFrame)S")
    } else {
      parts.append("\(pipe.maxInFlight)-Stage")
    }
    return parts.joined(separator: " · ")
  }

  private func formatUptime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let sec = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
  }
}
