import AppKit
import Combine
import SwiftUI

@_cdecl("vibepollo_macos_open_native_ui")
public func vibepollo_macos_open_native_ui(_ routePtr: UnsafePointer<CChar>?) {
  let route = routePtr.map { String(cString: $0) }
  DispatchQueue.main.async {
    MainActor.assumeIsolated {
      SettingsWindowManager.shared.openWindow(route: route)
    }
  }
}

/// Invisible responder that absorbs NSWindow's initial key-view selection so opening or switching
/// panes or sheets never auto-highlights the first TextField in blue.
final class PassiveFocusTargetView: NSView {
  private var suppressedForCurrentWindow = false

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let win = window else {
      suppressedForCurrentWindow = false
      return
    }
    win.initialFirstResponder = self
    if !suppressedForCurrentWindow {
      suppressedForCurrentWindow = true
      suppressAutomaticTextFocus(in: win)
      DispatchQueue.main.async { [weak self, weak win] in
        guard let self, let win else { return }
        self.suppressAutomaticTextFocus(in: win)
      }
    }
  }

  func suppressAutomaticTextFocus(in win: NSWindow) {
    if win.firstResponder == nil
      || win.firstResponder === win
      || win.firstResponder is NSTextView
      || win.firstResponder is NSTextField
    {
      win.makeFirstResponder(self)
    }
  }
}

struct PassiveSheetFocusAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> PassiveFocusTargetView {
    PassiveFocusTargetView(frame: .zero)
  }

  func updateNSView(_ nsView: PassiveFocusTargetView, context: Context) {}
}

@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowManager()

  private var window: NSWindow?
  private var focusSink: PassiveFocusTargetView?
  private var lastObservedRoute: NavigationRoute?
  private var storeCancellable: AnyCancellable?
  private var sheetObserversInstalled = false
  private var handledSheetWindows = Set<ObjectIdentifier>()
  private var mainMenuLocaleIsKo: Bool? = nil

  func openWindow(route: String?) {
    // Security guard: never open a settings window on the pre-login macOS LoginWindow screen.
    if VibepolloHostBridge.shared().isLoginWindowSession() {
      return
    }

    syncStandardMainMenu()
    installSheetFocusObserversIfNeeded()

    // Raycast / OrbStack behavior: show in Dock & Cmd+Tab while the Settings window is open.
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
    }

    let wasVisible = window?.isVisible == true

    if window == nil {
      let store = HostStore.shared
      let rootView = VibepolloRootView(store: store)
      let hostingController = NSHostingController(rootView: rootView)
      hostingController.sizingOptions = [.minSize, .maxSize]

      let sink = PassiveFocusTargetView(frame: .zero)
      hostingController.view.addSubview(sink)
      self.focusSink = sink

      let win = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 745, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      win.contentViewController = hostingController
      win.initialFirstResponder = sink
      win.toolbarStyle = .automatic
      win.titlebarSeparatorStyle = .automatic
      win.titleVisibility = .visible
      win.title = store.currentWindowTitle
      win.setContentSize(NSSize(width: 745, height: 640))
      win.minSize = NSSize(width: 715, height: 520)
      win.maxSize = NSSize(width: 880, height: 1400)
      win.center()
      win.isReleasedWhenClosed = false
      win.delegate = self
      self.window = win

      storeCancellable = store.objectWillChange.sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.syncWindowChrome()
        }
      }
    }

    HostStore.shared.startWindowSession(initialRoute: route)
    lastObservedRoute = HostStore.shared.currentRoute
    vibepollo_set_macos_native_ui_visible(true)
    window?.makeKeyAndOrderFront(nil)
    syncWindowChrome()
    NSApp.activate(ignoringOtherApps: true)

    if !wasVisible {
      clearAutomaticTextFieldFocus()
      DispatchQueue.main.async { [weak self] in
        self?.clearAutomaticTextFieldFocus()
      }
    }
  }

  private func installSheetFocusObserversIfNeeded() {
    guard !sheetObserversInstalled else { return }
    sheetObserversInstalled = true

    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let sheetWin = note.object as? NSWindow, sheetWin.sheetParent != nil else { return }
      MainActor.assumeIsolated {
        self?.suppressInitialFocusOnSheet(sheetWin)
      }
    }

    NotificationCenter.default.addObserver(
      forName: NSWindow.didEndSheetNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.pruneClosedSheetIdentifiers()
      }
    }
  }

  private func suppressInitialFocusOnSheet(_ sheetWin: NSWindow) {
    let id = ObjectIdentifier(sheetWin)
    guard !handledSheetWindows.contains(id) else { return }
    handledSheetWindows.insert(id)

    let sink: PassiveFocusTargetView
    if let existing = sheetWin.contentView?.subviews.compactMap({ $0 as? PassiveFocusTargetView }).first {
      sink = existing
    } else {
      let created = PassiveFocusTargetView(frame: .zero)
      sheetWin.contentView?.addSubview(created)
      sink = created
    }
    sheetWin.initialFirstResponder = sink
    sink.suppressAutomaticTextFocus(in: sheetWin)
    DispatchQueue.main.async { [weak sheetWin, weak sink] in
      guard let sheetWin, let sink else { return }
      sink.suppressAutomaticTextFocus(in: sheetWin)
    }
  }

  private func pruneClosedSheetIdentifiers() {
    let liveSheetIDs = Set(
      NSApp.windows.filter { $0.sheetParent != nil && $0.isVisible }.map { ObjectIdentifier($0) }
    )
    handledSheetWindows.formIntersection(liveSheetIDs)
  }

  private func clearAutomaticTextFieldFocus() {
    guard let win = window, let focusSink else { return }
    focusSink.suppressAutomaticTextFocus(in: win)
  }

  private func syncWindowChrome() {
    guard let win = window else { return }
    let currentRoute = HostStore.shared.currentRoute
    win.title = HostStore.shared.currentWindowTitle
    win.toolbar?.allowsUserCustomization = false
    syncStandardMainMenu()

    if currentRoute != lastObservedRoute {
      lastObservedRoute = currentRoute
      clearAutomaticTextFieldFocus()
      DispatchQueue.main.async { [weak self] in
        self?.clearAutomaticTextFieldFocus()
      }
    }

    if let rootView = win.contentView {
      enforceSidebarWidth(in: rootView)
    }
  }

  private func enforceSidebarWidth(in view: NSView) {
    if let splitView = view as? NSSplitView {
      if let splitVC = splitView.delegate as? NSSplitViewController,
         let sidebarItem = splitVC.splitViewItems.first {
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 215
      }
      return
    }
    for sub in view.subviews {
      enforceSidebarWidth(in: sub)
    }
  }

  @objc private func goBackAction(_ sender: Any?) {
    HostStore.shared.goBack()
  }

  @objc private func goForwardAction(_ sender: Any?) {
    HostStore.shared.goForward()
  }

  // MARK: - NSWindowDelegate

  func windowDidResize(_ notification: Notification) {
    syncWindowChrome()
  }

  func windowWillClose(_ notification: Notification) {
    vibepollo_set_macos_native_ui_visible(false)
    window?.makeFirstResponder(focusSink)
    HostStore.shared.stopWindowSession()

    // Return cleanly to menu-bar-only mode once the Settings window closes.
    DispatchQueue.main.async {
      let hasVisibleStandardWindow = NSApp.windows.contains { w in
        w !== self.window && w.isVisible && w.canBecomeMain
      }
      if !hasVisibleStandardWindow {
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  private func syncStandardMainMenu() {
    let l10n = HostStore.shared.l10n
    guard mainMenuLocaleIsKo != l10n.isKo else { return }
    mainMenuLocaleIsKo = l10n.isKo

    let mainMenu = NSMenu()

    // App Menu
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: l10n.pick("창 닫기", "Close Window"),
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: l10n.pick("종료", "Quit"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // Edit Menu (enables Cmd+C / Cmd+V / Cmd+X / Cmd+A / Cmd+Z in all SwiftUI text fields)
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: l10n.pick("편집", "Edit"))
    editMenu.addItem(withTitle: l10n.pick("실행 취소", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: l10n.pick("다시 실행", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: l10n.pick("오려두기", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: l10n.pick("복사하기", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: l10n.pick("붙여넣기", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: l10n.pick("전체 선택", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // Window & History Menu
    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: l10n.pick("윈도우", "Window"))
    let backMenu = NSMenuItem(title: l10n.pick("뒤로", "Back"), action: #selector(goBackAction(_:)), keyEquivalent: "[")
    backMenu.target = self
    windowMenu.addItem(backMenu)
    let forwardMenu = NSMenuItem(title: l10n.pick("앞으로", "Forward"), action: #selector(goForwardAction(_:)), keyEquivalent: "]")
    forwardMenu.target = self
    windowMenu.addItem(forwardMenu)
    windowMenu.addItem(NSMenuItem.separator())
    windowMenu.addItem(
      withTitle: l10n.pick("최소화", "Minimize"),
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    NSApp.mainMenu = mainMenu
  }
}
