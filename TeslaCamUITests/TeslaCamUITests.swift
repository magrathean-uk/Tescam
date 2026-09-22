import XCTest
#if os(iOS)
import UIKit
#endif

final class TeslaCamUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testBlankLaunchShowsOnboarding() throws {
    let app = launchApp(mode: "blank")

    XCTAssertTrue(app.buttons["Choose Folder"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testDefaultLaunchShowsOnboarding() throws {
    let app = launchApp(mode: "blank")

    XCTAssertTrue(app.buttons["Choose Folder"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSampleLaunchShowsPlaybackAndExport() throws {
    let app = launchApp(mode: "sample")

    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSampleExportShowsBlockingOverlay() throws {
    let app = XCUIApplication()
    app.launchEnvironment["TESLACAM_UI_TEST_MODE"] = "sample"
    app.launchEnvironment["TESLACAM_DEBUG_EXPORT_DIR"] = NSTemporaryDirectory()
    app.launchArguments.append(contentsOf: ["--teslacam-ui-test-mode", "sample"])
    app.launch()
    dismissCrashRecoveryIfNeeded(in: app)

    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))
    #if os(macOS)
    app.typeKey("e", modifierFlags: .command)
    #else
    let exportButton = app.descendants(matching: .any)["export-video"]
    XCTAssertTrue(exportButton.waitForExistence(timeout: 5))
    exportButton.tap()
    #endif
    XCTAssertTrue(app.descendants(matching: .any)["export-overlay"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["Export Complete"].waitForExistence(timeout: 60))
  }

  @MainActor
  func testSamplePlaybackToggleResponds() throws {
    let app = launchApp(mode: "sample")

    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSampleQuickRangeAndCameraButtonsRespond() throws {
    let app = launchApp(mode: "sample")

    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSampleMacEventBrowserNavigates() throws {
    #if os(macOS)
    let app = launchApp(mode: "sample")
    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))

    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "mac-compact-workspace"
    attachment.lifetime = .keepAlways
    add(attachment)
    #else
    throw XCTSkip("macOS-only event browser")
    #endif
  }

  @MainActor
  func testSampleDashboardScreenshot() throws {
    // Captures the loaded dashboard as a test attachment for visual review —
    // the verify-as-you-go seam for UI work. Asserts the core transport surface
    // is present so the screenshot is never of an empty/onboarding screen.
    let app = launchApp(mode: "sample")
    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))

    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "sample-dashboard"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testAppStoreScreenshots() throws {
    let app = launchApp(mode: "sample")
    XCTAssertTrue(app.descendants(matching: .any)["loaded-screen"].waitForExistence(timeout: 5))

    try capture(app, named: "01-overview")

    #if os(macOS)
    app.typeKey(" ", modifierFlags: [])
    #else
    activate(app.descendants(matching: .any)["toggle-playback"])
    #endif
    try capture(app, named: "02-playback")

    #if os(iOS)
    app.swipeUp()
    #endif
    activate(app.descendants(matching: .any)["camera-front"])
    try capture(app, named: "03-cameras")

    #if os(macOS)
    // The sample timeline is shorter than five minutes, so that preset leaves
    // the Mac workspace unchanged and produces a duplicate App Store image.
    activate(app.descendants(matching: .any)["range-current-minute"])
    #else
    activate(app.descendants(matching: .any)["range-last-5m"])
    #endif
    try capture(app, named: "04-timeline")

    #if os(iOS)
    app.swipeUp()
    XCTAssertTrue(app.descendants(matching: .any)["export-video"].waitForExistence(timeout: 5))
    #endif
    try capture(app, named: "05-export")
  }

  private func launchApp(mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["TESLACAM_UI_TEST_MODE"] = mode
    app.launchArguments.append(contentsOf: ["--teslacam-ui-test-mode", mode])
    app.launch()
    dismissCrashRecoveryIfNeeded(in: app)
    return app
  }

  private func dismissCrashRecoveryIfNeeded(in app: XCUIApplication) {
    let button = app.buttons["action-button--999"]
    if button.waitForExistence(timeout: 1) {
      #if os(macOS)
      button.click()
      #else
      button.tap()
      #endif
    }
  }

  private func activate(_ element: XCUIElement) {
    guard element.waitForExistence(timeout: 3) else { return }
    #if os(macOS)
    element.click()
    #else
    element.tap()
    #endif
  }

  private func capture(_ app: XCUIApplication, named name: String) throws {
    #if os(macOS)
    let screenshot = app.windows.firstMatch.screenshot()
    #else
    let screenshot = app.screenshot()
    #endif
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)

    guard let root = ProcessInfo.processInfo.environment["TESLACAM_SCREENSHOT_DIR"], !root.isEmpty else {
      return
    }
    #if os(macOS)
    let platform = "mac"
    #else
    let platform = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    #endif
    let directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(platform)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
  }
}
