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

// MARK: - Lightweight Popover Snapshot (Zero JSON Overhead, Rounded Tenths Prevent Redundant Redraws)

struct MenuBarPopoverSnapshot: Equatable {
  var locale: String = "ko"
  var appRunning: Bool = false
  var streaming: Bool = false

  // Streaming state
  var deviceName: String = ""
  var width: Int = 0
  var height: Int = 0
  var liveFpsTenths: Int = 0
  var liveBitrateTenthsMbps: Int = 0
  var encodeMsTenths: Int = 0
  var codec: String = ""
  var bitDepth: Int = 8
  var yuv444: Bool = false
  var hdr: Bool = false
  var directUsb: Bool = false
  var pipelineActive: Bool = false
  var zeroCopy: Bool = false
  var captureFormat: String = ""
  var encoderFormat: String = ""

  // Idle state
  var hostName: String = ""
  var pairedCount: Int = 0
  var backend: String = "videotoolbox"
  var hevc10BitHdr: Bool = false
  var hevc8Bit: Bool = false
  var hevc444: Bool = false

  static let empty = MenuBarPopoverSnapshot()

  init() {}

  init(dictionary dict: [String: Any]) {
    self.locale = (dict["locale"] as? String) ?? "ko"
    self.appRunning = (dict["appRunning"] as? NSNumber)?.boolValue ?? false
    self.streaming = (dict["streaming"] as? NSNumber)?.boolValue ?? false

    if self.streaming {
      self.deviceName = (dict["deviceName"] as? String) ?? "Client"
      self.width = (dict["width"] as? NSNumber)?.intValue ?? 0
      self.height = (dict["height"] as? NSNumber)?.intValue ?? 0
      self.liveFpsTenths = (dict["liveFpsTenths"] as? NSNumber)?.intValue ?? 0
      self.liveBitrateTenthsMbps = (dict["liveBitrateTenthsMbps"] as? NSNumber)?.intValue ?? 0
      self.encodeMsTenths = (dict["encodeMsTenths"] as? NSNumber)?.intValue ?? 0
      self.codec = (dict["codec"] as? String) ?? ""
      self.bitDepth = (dict["bitDepth"] as? NSNumber)?.intValue ?? 8
      self.yuv444 = (dict["yuv444"] as? NSNumber)?.boolValue ?? false
      self.hdr = (dict["hdr"] as? NSNumber)?.boolValue ?? false
      self.directUsb = (dict["directUsb"] as? NSNumber)?.boolValue ?? false
      self.pipelineActive = (dict["pipelineActive"] as? NSNumber)?.boolValue ?? false
      self.zeroCopy = (dict["zeroCopy"] as? NSNumber)?.boolValue ?? false
      self.captureFormat = (dict["captureFormat"] as? String) ?? ""
      self.encoderFormat = (dict["encoderFormat"] as? String) ?? ""
    } else {
      self.hostName = (dict["hostName"] as? String) ?? ""
      self.pairedCount = (dict["pairedCount"] as? NSNumber)?.intValue ?? 0
      self.backend = (dict["backend"] as? String) ?? "videotoolbox"
      self.hevc10BitHdr = (dict["hevc10BitHdr"] as? NSNumber)?.boolValue ?? false
      self.hevc8Bit = (dict["hevc8Bit"] as? NSNumber)?.boolValue ?? false
      self.hevc444 = (dict["hevc444"] as? NSNumber)?.boolValue ?? false
    }
  }
}

// MARK: - Visible-Only Adaptive Store (0 Hz Closed · 1.5s Idle · 4 Hz Streaming)

@MainActor
final class MenuBarPopoverStore: ObservableObject {
  @Published var snapshot: MenuBarPopoverSnapshot = .empty

  private var pollTimer: Timer?
  private var currentInterval: TimeInterval = 0
  private var active = false

  private static let streamingPollInterval: TimeInterval = 0.25
  private static let idlePollInterval: TimeInterval = 1.5

  var l10n: L10n {
    let locale = HostStore.shared.settings.locale.isEmpty
      ? snapshot.locale
      : HostStore.shared.settings.locale
    return L10n(locale: locale)
  }

  func start() {
    active = true
    refresh()
    rescheduleTimerIfNeeded()
  }

  func stop() {
    active = false
    pollTimer?.invalidate()
    pollTimer = nil
    currentInterval = 0
  }

  func refresh() {
    let dict = VibepolloHostBridge.shared().fetchMenuBarPopoverSnapshot()
    let next = MenuBarPopoverSnapshot(dictionary: dict)
    if snapshot != next {
      snapshot = next
    }
    if active {
      rescheduleTimerIfNeeded()
    }
  }

  private func rescheduleTimerIfNeeded() {
    let targetInterval = snapshot.streaming ? Self.streamingPollInterval : Self.idlePollInterval
    guard pollTimer == nil || currentInterval != targetInterval else { return }
    pollTimer?.invalidate()
    currentInterval = targetInterval
    let timer = Timer(timeInterval: targetInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refresh()
      }
    }
    timer.tolerance = snapshot.streaming ? 0.03 : 0.25
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
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
  private var snap: MenuBarPopoverSnapshot { store.snapshot }

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

        if snap.appRunning {
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
    if snap.streaming {
      let liveFps = Double(snap.liveFpsTenths) / 10.0
      let liveMbps = Double(snap.liveBitrateTenthsMbps) / 10.0
      let encMs = Double(snap.encodeMsTenths) / 10.0
      let secondLine: String = {
        let res = String(format: "%d×%d", snap.width, snap.height)
        var parts = [res]
        if snap.encodeMsTenths > 0 {
          parts.append(String(format: "%.1f ms", encMs))
        }
        if snap.directUsb {
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
          String(format: "%@ · %.1f Mbps", snap.deviceName, liveMbps),
          secondLine,
        ]
      )
    } else {
      let host = snap.hostName.isEmpty ? "Mac" : snap.hostName
      let detail = snap.pairedCount > 0
        ? l10n.pick("\(host) · 기기 \(snap.pairedCount)대", "\(host) · \(snap.pairedCount) paired")
        : host
      return MinimalMetricRow(
        symbol: "airplayvideo",
        summary: l10n.pick("대기 중", "Ready"),
        details: [detail]
      )
    }
  }

  private var encoderRow: some View {
    if snap.streaming {
      let summary = l10n.pick(
        "인코더: \(snap.codec) \(snap.bitDepth)-bit",
        "Encoder: \(snap.codec) \(snap.bitDepth)-bit"
      )
      var tags: [String] = []
      if snap.pipelineActive {
        tags.append(snap.zeroCopy ? "Zero-Copy" : "\(snap.captureFormat)→\(snap.encoderFormat)")
      }
      tags.append(snap.yuv444 ? "4:4:4" : "4:2:0")
      if snap.hdr {
        tags.append("HDR")
      }
      return MinimalMetricRow(
        symbol: "film",
        summary: summary,
        details: [tags.joined(separator: " · ")]
      )
    } else {
      let backend = snap.backend == "videotoolbox"
        ? "VideoToolbox"
        : (snap.backend == "software" ? l10n.pick("소프트웨어", "Software") : snap.backend)
      var codecs: [String] = []
      if snap.hevc10BitHdr {
        codecs.append("HEVC 10-bit")
      } else if snap.hevc8Bit {
        codecs.append("HEVC")
      }
      if snap.hevc444 {
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
