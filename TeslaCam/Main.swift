#if os(macOS)
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var window: NSWindow?
  private var mainContentController: NSViewController?
  private var logWindow: NSWindow?
  private let state = AppState()
  private var didLaunch = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    launchIfNeeded()
  }

  fileprivate func launchIfNeeded() {
    guard !didLaunch else { return }
    didLaunch = true
    installMainMenu()

    let content = ContentView().environmentObject(state)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.center()
    window.title = "Tescam"
    window.identifier = NSUserInterfaceItemIdentifier("TeslaCam.MainWindow")
    window.isRestorable = false
    window.isReleasedWhenClosed = false
    let hostingController = NSHostingController(rootView: content)
    window.contentViewController = hostingController
    window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
    window.center()

    NSApp.setActivationPolicy(.regular)

    self.window = window
    self.mainContentController = hostingController
    showMainWindow()
    DispatchQueue.main.async { [weak self] in
      self?.showMainWindow()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.showMainWindow()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if state.exporter.isExporting {
      state.cancelExport()
      window?.makeKeyAndOrderFront(nil)
      return .terminateCancel
    }
    state.shutdownForTermination()
    if sender.modalWindow != nil {
      sender.abortModal()
    }
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    state.shutdownForTermination()
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let urls = filenames.map { URL(fileURLWithPath: $0) }
    if !urls.isEmpty {
      state.ingestDroppedURLs(urls)
      NSApp.activate(ignoringOtherApps: true)
      window?.makeKeyAndOrderFront(nil)
    }
    sender.reply(toOpenOrPrint: .success)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  private func showMainWindow() {
    guard let window else { return }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  private func installMainMenu() {
    let appName = ProcessInfo.processInfo.processName
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "File")
    let openItem = fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder), keyEquivalent: "o")
    openItem.target = self
    let reloadItem = fileMenu.addItem(withTitle: "Reload", action: #selector(reloadSources), keyEquivalent: "r")
    reloadItem.target = self
    fileMenu.addItem(NSMenuItem.separator())
    let exportItem = fileMenu.addItem(withTitle: "Export Range…", action: #selector(exportRange), keyEquivalent: "e")
    exportItem.target = self
    let cancelItem = fileMenu.addItem(withTitle: "Cancel Export", action: #selector(cancelExport), keyEquivalent: ".")
    cancelItem.target = self
    let revealItem = fileMenu.addItem(withTitle: "Reveal Last Export", action: #selector(revealLastExport), keyEquivalent: "R")
    revealItem.target = self
    fileMenuItem.submenu = fileMenu

    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    let logItem = viewMenu.addItem(withTitle: "Application Logs", action: #selector(showLogWindow), keyEquivalent: "l")
    logItem.target = self
    viewMenuItem.submenu = viewMenu

    // Playback menu — the macOS app previously had no keyboard transport at all.
    let playbackMenuItem = NSMenuItem()
    mainMenu.addItem(playbackMenuItem)
    let playbackMenu = NSMenu(title: "Playback")
    let leftArrow = String(utf16CodeUnits: [unichar(NSLeftArrowFunctionKey)], count: 1)
    let rightArrow = String(utf16CodeUnits: [unichar(NSRightArrowFunctionKey)], count: 1)

    let playItem = playbackMenu.addItem(withTitle: "Play/Pause", action: #selector(togglePlay), keyEquivalent: " ")
    playItem.keyEquivalentModifierMask = []
    playItem.target = self
    let backItem = playbackMenu.addItem(withTitle: "Back 5s", action: #selector(stepBack), keyEquivalent: leftArrow)
    backItem.keyEquivalentModifierMask = [.command]
    backItem.target = self
    let fwdItem = playbackMenu.addItem(withTitle: "Forward 5s", action: #selector(stepForward), keyEquivalent: rightArrow)
    fwdItem.keyEquivalentModifierMask = [.command]
    fwdItem.target = self
    playbackMenu.addItem(NSMenuItem.separator())
    let prevEventItem = playbackMenu.addItem(withTitle: "Previous Event", action: #selector(previousEvent), keyEquivalent: leftArrow)
    prevEventItem.keyEquivalentModifierMask = [.command, .shift]
    prevEventItem.target = self
    let nextEventItem = playbackMenu.addItem(withTitle: "Next Event", action: #selector(nextEvent), keyEquivalent: rightArrow)
    nextEventItem.keyEquivalentModifierMask = [.command, .shift]
    nextEventItem.target = self
    let restartItem = playbackMenu.addItem(withTitle: "Restart", action: #selector(restartPlayback), keyEquivalent: "0")
    restartItem.keyEquivalentModifierMask = [.command]
    restartItem.target = self
    playbackMenuItem.submenu = playbackMenu

    NSApp.mainMenu = mainMenu
  }

  @objc private func openFolder() {
    state.chooseFolder()
  }

  @objc private func reloadSources() {
    state.reloadSources()
  }

  @objc private func exportRange() {
    state.exportRange()
  }

  @objc private func cancelExport() {
    state.cancelExport()
  }

  @objc private func revealLastExport() {
    state.revealLastExport()
  }

  @objc private func togglePlay() {
    state.togglePlay()
  }

  @objc private func stepBack() {
    state.stepPlayback(by: -5)
  }

  @objc private func stepForward() {
    state.stepPlayback(by: 5)
  }

  @objc private func previousEvent() {
    state.jumpToNextEvent(direction: -1)
  }

  @objc private func nextEvent() {
    state.jumpToNextEvent(direction: 1)
  }

  @objc private func restartPlayback() {
    state.restart()
  }

  @objc private func showLogWindow() {
    if logWindow == nil {
      let logView = ApplicationLogView(logSink: state.debugLog, exporter: state.exporter)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      window.title = "Application Logs"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: logView)
      logWindow = window
    }

    logWindow?.center()
    logWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    canPerform(action: menuItem.action)
  }

  private func canPerform(action: Selector?) -> Bool {
    switch action {
    case #selector(openFolder):
      return !state.exporter.isExporting
    case #selector(reloadSources):
      return state.canReloadSources
    case #selector(exportRange):
      return state.canExport
    case #selector(cancelExport):
      return state.exporter.isExporting
    case #selector(revealLastExport):
      return !state.exporter.exportHistory.isEmpty
    case #selector(togglePlay), #selector(stepBack), #selector(stepForward), #selector(restartPlayback):
      return !state.clipSets.isEmpty
    case #selector(previousEvent), #selector(nextEvent):
      return !state.eventSummaries.isEmpty
    default:
      return true
    }
  }
}

@main
struct MainApp {
  private static var delegate: AppDelegate?

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    Self.delegate = delegate
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      app.run()
    }
  }
}

private struct ApplicationLogView: View {
  @ObservedObject var logSink: DebugLogSink
  @ObservedObject var exporter: NativeExportController

  var body: some View {
    ZStack {
      TeslaCamSceneBackground()

      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.cardGap) {
        Text("Application Logs")
          .font(TeslaCamTheme.Typography.panelTitle)
          .foregroundStyle(TeslaCamTheme.Colors.textPrimary)

        ScrollView {
          Text(logText)
            .font(TeslaCamTheme.Typography.monoSmall)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(TeslaCamTheme.Metrics.cardPaddingCompact)
        }
        .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)

        HStack {
          Button("Reveal Export Log") {
            exporter.revealLog()
          }
          .buttonStyle(.bordered)

          Spacer()
        }
      }
      .padding(TeslaCamTheme.Spacing.screen)
    }
    .frame(minWidth: 720, minHeight: 520)
  }

  private var logText: String {
    var sections: [String] = []
    let appEvents = logSink.events.map { event in
      "\(TeslaCamFormatters.fullDateTime.string(from: event.timestamp)) [\(event.category)] \(event.message)"
    }
    sections.append(appEvents.isEmpty ? "Application log\nNo events yet." : "Application log\n" + appEvents.joined(separator: "\n"))
    sections.append(exporter.log.isEmpty ? "Export log\nNo export log yet." : "Export log\n" + exporter.log)
    return sections.joined(separator: "\n\n")
  }
}
#endif
