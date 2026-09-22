import Foundation
import Combine
import AVFoundation
import CoreVideo
import CoreGraphics
import CoreText
import CoreImage
import ImageIO
@preconcurrency import Metal
import Synchronization
import UniformTypeIdentifiers
import VideoToolbox

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

struct ExportPlan {
  enum ValidationError: LocalizedError, Equatable {
    case noClips
    case emptyTrimRange
    case noEnabledCameras
    case invalidCanvas

    var errorDescription: String? {
      switch self {
      case .noClips:
        return "There are no clips in the selected export range."
      case .emptyTrimRange:
        return "Selected trim range is empty."
      case .noEnabledCameras:
        return "Select at least one camera to export."
      case .invalidCanvas:
        return "Export canvas could not be prepared."
      }
    }
  }

  let sets: [ClipSet]
  let outputURL: URL
  let useSixCam: Bool
  let preset: ExportPreset
  let enabledCameras: Set<Camera>
  let layoutRequest: CameraLayoutRequest
  let overlayOptions: ExportOverlayOptions
  let trimStartSeconds: Double
  let trimEndSeconds: Double
  let trimStartDate: Date
  let trimEndDate: Date
  let selectedRangeText: String
  let partialClipCount: Int
  let cameraTrack: CameraTrack
  let isPreviewSample: Bool
  fileprivate let layout: TimelineFrameLayout

  var totalParts: Int { sets.count }
  var totalDuration: Double { trimEndDate.timeIntervalSince(trimStartDate) }
  var renderDuration: Double {
    TimelineFrameProvider.renderDuration(
      sets: sets,
      trimStartDate: trimStartDate,
      trimEndDate: trimEndDate
    )
  }
  var canvasSize: CGSize { layout.canvasSize }
  var tileSize: CGSize { layout.tileSize }
  var cameraOrder: [Camera] { layout.cameraOrder }
  var boundsByCamera: [Camera: CGRect] { layout.boundsByCamera }

  init(request: ExportRequest) throws {
    guard !request.sets.isEmpty else {
      throw ValidationError.noClips
    }
    guard request.trimEndDate > request.trimStartDate, request.totalDuration > 0 else {
      throw ValidationError.emptyTrimRange
    }
    guard !request.enabledCameras.isEmpty else {
      throw ValidationError.noEnabledCameras
    }

    let layout = try TimelineFrameLayout.build(
      sets: request.sets,
      enabledCameras: request.enabledCameras,
      useSixCam: request.useSixCam,
      layoutRequest: request.layoutRequest
    )
    guard layout.canvasSize.width.isFinite,
          layout.canvasSize.height.isFinite,
          layout.canvasSize.width > 0,
          layout.canvasSize.height > 0 else {
      throw ValidationError.invalidCanvas
    }

    self.sets = request.sets
    self.outputURL = request.outputURL
    self.useSixCam = request.useSixCam
    self.preset = request.preset
    self.enabledCameras = request.enabledCameras
    self.layoutRequest = request.layoutRequest
    self.overlayOptions = request.overlayOptions
    self.trimStartSeconds = request.trimStartSeconds
    self.trimEndSeconds = request.trimEndSeconds
    self.trimStartDate = request.trimStartDate
    self.trimEndDate = request.trimEndDate
    self.selectedRangeText = request.selectedRangeText
    self.partialClipCount = request.partialClipCount
    self.cameraTrack = request.cameraTrack
    self.isPreviewSample = request.isPreviewSample
    self.layout = layout
  }
}

protocol ExportPreflightFileAccess {
  func canWrite(to outputURL: URL) -> Bool
  func availableCapacity(forWritingTo outputURL: URL) -> Int64?
}

struct FileManagerExportPreflightFileAccess: ExportPreflightFileAccess {
  var fileManager: FileManager = .default

  func canWrite(to outputURL: URL) -> Bool {
    let targetDirectory = outputURL.deletingLastPathComponent()
    let scopeURL = beginSecurityScope(outputURL: outputURL, targetDirectory: targetDirectory)
    let outputExists = fileManager.fileExists(atPath: outputURL.path)

    defer {
      if !outputExists, fileManager.fileExists(atPath: outputURL.path) {
        try? fileManager.removeItem(at: outputURL)
      }
      scopeURL?.stopAccessingSecurityScopedResource()
    }

    do {
      let values = try targetDirectory.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else { return false }
      if outputExists {
        return fileManager.isWritableFile(atPath: outputURL.path)
      }
      return fileManager.createFile(
        atPath: outputURL.path,
        contents: Data(),
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
      )
    } catch {
      return false
    }
  }

  func availableCapacity(forWritingTo outputURL: URL) -> Int64? {
    let targetDirectory = outputURL.deletingLastPathComponent()
    do {
      let values = try targetDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      if let important = values.volumeAvailableCapacityForImportantUsage {
        return important
      }
      let fallback = try fileManager.attributesOfFileSystem(forPath: targetDirectory.path)
      if let number = fallback[.systemFreeSize] as? NSNumber {
        return number.int64Value
      }
      return fallback[.systemFreeSize] as? Int64
    } catch {
      return nil
    }
  }

  private func beginSecurityScope(outputURL: URL, targetDirectory: URL) -> URL? {
    if outputURL.startAccessingSecurityScopedResource() {
      return outputURL
    }
    if targetDirectory.startAccessingSecurityScopedResource() {
      return targetDirectory
    }
    return nil
  }
}

struct ExportPreflight {
  private static let minimumDiskHeadroomBytes: Int64 = 256 * 1024 * 1024
  private static let hevcEncoderMaxSidePixels: CGFloat = 8192

  var fileAccess: ExportPreflightFileAccess = FileManagerExportPreflightFileAccess()

  func summary(for plan: ExportPlan) -> ExportPreflightSummary {
    var blocking: [ExportIssue] = []
    var warnings: [ExportIssue] = []

    if plan.partialClipCount > 0 {
      warnings.append(ExportIssue(message: "\(plan.partialClipCount) selected clip span(s) are missing one or more cameras and will export with black placeholders.", isBlocking: false))
    }

    let visibleCameras = Set(plan.sets.flatMap { $0.files.keys }).union(plan.enabledCameras)
    let hiddenCameras = Camera.mixedOrder.filter { visibleCameras.contains($0) && !plan.enabledCameras.contains($0) }
    if !hiddenCameras.isEmpty {
      warnings.append(ExportIssue(message: "Hidden cameras will export as black tiles: \(hiddenCameras.map(\.displayName).joined(separator: ", ")).", isBlocking: false))
    }

    if plan.preset == .originalTracksMOV {
      if plan.overlayOptions.telemetryHUD
          || plan.overlayOptions.routeMap
          || plan.overlayOptions.privacyMask
          || plan.overlayOptions.needsSidecars
          || !plan.cameraTrack.isEmpty {
        blocking.append(
          ExportIssue(
            message: "Original Tracks MOV preserves source video streams and cannot include overlays, reports, privacy masking, or camera cuts. Switch to an HEVC or ProRes preset for rendered output.",
            isBlocking: true
          )
        )
      }
    }

    if plan.preset != .originalTracksMOV,
       plan.preset != .editFriendlyProRes,
       plan.canvasSize.width > Self.hevcEncoderMaxSidePixels || plan.canvasSize.height > Self.hevcEncoderMaxSidePixels {
      blocking.append(
        ExportIssue(
          message: "Composite canvas \(Int(plan.canvasSize.width.rounded(.up)))×\(Int(plan.canvasSize.height.rounded(.up))) exceeds the hardware HEVC encoder ceiling (8192 px per side). Reduce enabled cameras or switch to ProRes preset.",
          isBlocking: true
        )
      )
    }

    let hasWriteAccess = fileAccess.canWrite(to: plan.outputURL)
    if !hasWriteAccess {
      blocking.append(ExportIssue(message: "The selected export location is not writable.", isBlocking: true))
    }

    let requiredBytes = estimatedRequiredDiskBytes(for: plan)
    if let availableBytes = fileAccess.availableCapacity(forWritingTo: plan.outputURL) {
      if availableBytes < requiredBytes {
        blocking.append(
          ExportIssue(
            message: "The selected export location has only \(Self.formatBytes(availableBytes)) free. Export preflight requires at least \(Self.formatBytes(requiredBytes)).",
            isBlocking: true
          )
        )
      }
    } else {
      warnings.append(ExportIssue(message: "Free disk space could not be checked for the selected export location.", isBlocking: false))
    }

    return ExportPreflightSummary(
      blockingIssues: blocking,
      warnings: warnings,
      hasWriteAccess: hasWriteAccess,
      resolvedOutputURL: plan.outputURL,
      requiresUserSavePanel: false
    )
  }

  private func estimatedRequiredDiskBytes(for plan: ExportPlan) -> Int64 {
    let seconds = max(1, plan.renderDuration)
    let bytesPerSecond: Double
    switch plan.preset {
    case .originalTracksMOV:
      bytesPerSecond = 6 * 1024 * 1024
    case .editFriendlyProRes:
      bytesPerSecond = 32 * 1024 * 1024
    case .maxQualityHEVC:
      bytesPerSecond = 8 * 1024 * 1024
    case .maxQualityH264:
      bytesPerSecond = 11 * 1024 * 1024
    case .fastHEVC:
      bytesPerSecond = 4 * 1024 * 1024
    case .socialShareHEVC:
      bytesPerSecond = 2 * 1024 * 1024
    case .proxyHEVC:
      bytesPerSecond = 1 * 1024 * 1024
    }
    let estimatedOutput = Int64((seconds * bytesPerSecond).rounded(.up))
    return max(Self.minimumDiskHeadroomBytes, estimatedOutput + Self.minimumDiskHeadroomBytes)
  }

  private static func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB, .useTB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

final class NativeExportController: ObservableObject {
  private static let staleWorkdirAge: TimeInterval = 24 * 60 * 60

  @Published var log: String = ""
  @Published var lastError: String = ""
  @Published var currentJob: ExportJobSnapshot?
  @Published var exportHistory: [ExportJobSnapshot] = []
  @Published var queuedRequests: [ExportRequest] = []
  @Published var isStatusPresented: Bool = false

  weak var debugLog: DebugLogSink?

  var isExporting: Bool {
    guard let currentJob else { return false }
    return !currentJob.isTerminal
  }

  private let fm = FileManager.default
  private var activeSession: MutableExportSession?
  private var cancelRequested = false
  private var activeOutputScopeURL: URL?
  private lazy var logFileURL: URL = {
    let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("TeslaCam", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("native-export.log")
  }()

  private enum ExportError: LocalizedError {
    case preparation(String)
    case encoding(String)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .preparation(let detail), .encoding(let detail):
        return detail
      case .cancelled:
        return "Export cancelled by user."
      }
    }
  }

  func preflightSummary(request: ExportRequest) -> ExportPreflightSummary {
    do {
      return ExportPreflight().summary(for: try ExportPlan(request: request))
    } catch {
      return ExportPreflightSummary(
        blockingIssues: [
          ExportIssue(message: error.localizedDescription, isBlocking: true)
        ],
        warnings: [],
        hasWriteAccess: false,
        resolvedOutputURL: request.outputURL,
        requiresUserSavePanel: false
      )
    }
  }

  func export(request: ExportRequest) {
    guard !isExporting else {
      enqueue(request: request)
      return
    }
    cleanupStaleTempDirectories()
    beginOutputScope(for: request.outputURL)
    debug("start \(request.outputURL.lastPathComponent) preset=\(request.preset.rawValue)", category: "export")

    let preflight = preflightSummary(request: request)
    guard preflight.canExport else {
      publishBlockedPreflight(request: request, preflight: preflight)
      endOutputScope()
      startNextQueuedExportIfIdle()
      return
    }

    let renderDuration = (try? ExportPlan(request: request).renderDuration) ?? request.totalDuration
    let session = MutableExportSession(
      id: UUID(),
      request: request,
      phase: .preparing,
      progress: 0.02,
      phaseLabel: ExportJobPhase.preparing.displayName,
      startedAt: Date(),
      finishedAt: nil,
      outputURL: request.outputURL,
      logFileURL: logFileURL,
      tempRootURL: nil,
      failureCategory: nil,
      failureReason: nil,
      completedParts: 0,
      totalParts: request.totalParts,
      completedDuration: 0,
      totalDuration: renderDuration,
      isIndeterminate: false,
      isTerminal: false,
      canRevealOutput: false,
      canRevealWorkingFiles: false,
      canRetry: false,
      isCancelled: false
    )

    activeSession = session
    cancelRequested = false
    log = ""
    lastError = ""
    resetLogFile()
    appendLog("Log file: \(logFileURL.path)\n")
    appendLog("Export start: \(Date())\n")
    appendLog("Output: \(request.outputURL.path)\n")
    appendLog("Preset: \(request.preset.displayName)\n")
    appendLog("Range: \(request.selectedRangeText)\n")
    appendLog("Selected cameras: \(request.enabledCameras.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).joined(separator: ", "))\n")
    appendStructuredLogEvent(
      "export_started",
      fields: [
        "output": request.outputURL.path,
        "preset": request.preset.rawValue,
        "range": request.selectedRangeText,
        "duration": String(format: "%.3f", request.totalDuration),
        "parts": "\(request.totalParts)"
      ]
    )
    for warning in preflight.warnings {
      appendLog("Warning: \(warning.message)\n")
      appendStructuredLogEvent("preflight_warning", fields: ["message": warning.message])
    }
    publishCurrentSession()
    isStatusPresented = true

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try self.performExport(request: request)
      } catch {
        self.runOnMain {
          self.finishFailure(error: error)
        }
      }
    }
  }

  func enqueue(request: ExportRequest) {
    queuedRequests.append(request)
    appendStructuredLogEvent("export_queued", fields: ["output": request.outputURL.path])
    startNextQueuedExportIfIdle()
  }

  func clearQueue() {
    queuedRequests.removeAll()
  }

  private func publishBlockedPreflight(request: ExportRequest, preflight: ExportPreflightSummary) {
    let message = preflight.blockingIssues.map(\.message).joined(separator: "\n")
    let now = Date()
    let session = MutableExportSession(
      id: UUID(),
      request: request,
      phase: .failed,
      progress: 1,
      phaseLabel: "Export blocked",
      startedAt: now,
      finishedAt: now,
      outputURL: request.outputURL,
      logFileURL: logFileURL,
      tempRootURL: nil,
      failureCategory: .preparation,
      failureReason: message,
      completedParts: 0,
      totalParts: request.totalParts,
      completedDuration: 0,
      totalDuration: request.totalDuration,
      isIndeterminate: false,
      isTerminal: true,
      canRevealOutput: false,
      canRevealWorkingFiles: false,
      canRetry: true,
      isCancelled: false
    )

    activeSession = session
    currentJob = session.snapshot(fileManager: fm)
    lastError = message
    isStatusPresented = true
    appendLog("Export blocked: \(message)\n")
    appendStructuredLogEvent("export_blocked", fields: ["message": message])
    debug("blocked \(request.outputURL.lastPathComponent): \(message)", category: "export")
  }

  func retry(_ snapshot: ExportJobSnapshot) {
    export(request: snapshot.request)
  }

  func dismissStatus() {
    isStatusPresented = false
    if currentJob?.isTerminal == true {
      currentJob = nil
      activeSession = nil
    }
  }

  func cancelExport() {
    cancelRequested = true
    appendLog("\nCancel requested.\n")
    debug("cancel requested", category: "export")
    updateSession {
      $0.phase = .cancelled
      $0.phaseLabel = "Cancelling export"
      $0.failureCategory = .cancelled
      $0.failureReason = "Export cancelled by user."
      $0.isCancelled = true
    }
  }

  func revealLog() {
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    #endif
  }

  func revealOutput(for snapshot: ExportJobSnapshot? = nil) {
    let url = (snapshot ?? currentJob)?.outputURL
    guard let url else { return }
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    #else
    PlatformFileAccess.shareFile(url)
    #endif
  }

  func revealWorkingFiles(for snapshot: ExportJobSnapshot? = nil) {
    guard let url = (snapshot ?? currentJob)?.workingDirectoryURL else { return }
    #if os(macOS)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    #endif
  }

  private func performExport(request: ExportRequest) throws {
    try measure("native_export_full") {
      let plan = try ExportPlan(request: request)
      // Keep the machine awake and out of App Nap for the whole render. Long
      // exports otherwise stall when the Mac idle-sleeps. No-op on iOS.
      let activityToken = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Tescam export"
      )
      defer { ProcessInfo.processInfo.endActivity(activityToken) }
      let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tescam_export_\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      let logRoot = tempRoot.appendingPathComponent("logs", isDirectory: true)
      try fm.createDirectory(at: logRoot, withIntermediateDirectories: true)

      runOnMain {
        self.updateSession {
          $0.tempRootURL = tempRoot
          $0.canRevealWorkingFiles = true
          $0.phase = .preparing
          $0.phaseLabel = "Preparing clips"
          $0.progress = 0.05
          $0.isIndeterminate = false
        }
      }

      if plan.preset == .originalTracksMOV {
        appendLog("Mode: original camera tracks passthrough\n")
        do {
          try PassthroughMovieMuxer.export(
            plan: plan,
            shouldCancel: { self.cancelRequested },
            progress: { progress in
              self.runOnMain {
                self.updateSession {
                  $0.phase = .concatenating
                  $0.phaseLabel = "Muxing original tracks"
                  $0.completedDuration = plan.renderDuration * progress
                  $0.progress = min(0.98, 0.10 + progress * 0.88)
                }
              }
            }
          )
        } catch is PassthroughMovieMuxer.Cancelled {
          throw ExportError.cancelled
        }
        try? fm.removeItem(at: tempRoot)
        runOnMain {
          self.finishCompleted(request: request, outputURL: plan.outputURL, renderDuration: plan.renderDuration)
        }
        return
      }

      let frameProvider = TimelineFrameProvider(
        sets: plan.sets,
        trimStartDate: plan.trimStartDate,
        trimEndDate: plan.trimEndDate
      )
      let renderDuration = frameProvider.totalDuration
      let layout = plan.layout
      appendLog("Canvas: \(Int(layout.canvasSize.width))x\(Int(layout.canvasSize.height))\n")
      appendLog("Graph: \(NativeFilterGraphSummary(plan: plan).description)\n")
      debug("layout cameras=\(layout.cameraOrder.map(\.rawValue).joined(separator: ",")) canvas=\(Int(layout.canvasSize.width))x\(Int(layout.canvasSize.height))", category: "export")

      // Match the render clock to the actual source frame rate instead of a
      // hardcoded 30. Tesla HW3 footage is 24/36 fps depending on firmware; a
      // 30 fps clock duplicates (24->30) or drops (36->30) ~1 frame in 6 and
      // wastes encode on the duplicates.
      let fps = self.sampleSourceFps(for: plan)
      appendLog("Render fps: \(String(format: "%.3f", fps))\n")
      let writer = try NativeMovieWriter(outputURL: plan.outputURL, size: plan.canvasSize, preset: plan.preset, frameRate: fps)
      try writer.start()

      runOnMain {
        self.updateSession {
          $0.phase = .renderingParts
          $0.phaseLabel = "Rendering timeline"
          $0.progress = 0.10
        }
      }

      let composer = TimelineFrameComposer(
        layout: layout,
        enabledCameras: plan.enabledCameras,
        overlayOptions: plan.overlayOptions
      )
      appendLog("Render pipeline: \(composer.pipelineDescription)\n")
      let frameCount = max(1, Int((frameProvider.totalDuration * fps).rounded(.up)))
      var renderedFrames = 0
      var pendingFrame: PendingFrameBuffer?
      var renderMetrics = ExportRenderMetrics()

      for frameIndex in 0..<frameCount {
        if cancelRequested {
          if renderedFrames > 0 {
            // Keep the footage rendered so far as a playable partial rather
            // than discarding a long export the user cancelled near the end.
            try? writer.finishWriting()
            try? fm.removeItem(at: tempRoot)
            runOnMain {
              self.finishCancelled(request: request, outputURL: plan.outputURL, keptPartial: true)
            }
            return
          }
          writer.cancel()
          throw ExportError.cancelled
        }

        let renderSeconds = Double(frameIndex) / fps
        let context = frameProvider.context(for: renderSeconds)
        let cameraOverride = plan.cameraTrack.camera(at: request.trimStartSeconds + context.sourceSecondsFromTrimStart)

        if frameIndex == 0 || frameIndex % Int(max(1, fps / 2)) == 0 {
          let completedParts = min(
            request.totalParts,
            max(frameProvider.completedSetCount(at: renderSeconds), (context.clipIndex.map { $0 + 1 } ?? 0))
          )
          runOnMain {
            self.updateSession {
              $0.completedParts = completedParts
              $0.completedDuration = min(renderSeconds, renderDuration)
              $0.phase = .renderingParts
              $0.phaseLabel = "Rendering timeline"
              $0.progress = self.renderProgress(completed: renderSeconds, total: renderDuration)
            }
          }
        }

        do {
          try autoreleasepool {
            let prepareStarted = ContinuousClock.now
            let nextFrame = try composer.makePendingFrameBuffer(
              at: context.localSeconds,
              set: context.set,
              cameraOverride: cameraOverride,
              presentationTime: CMTime(seconds: renderSeconds, preferredTimescale: 600)
            )
            renderMetrics.recordPrepare(prepareStarted.duration(to: .now))
            if let pendingFrame {
              let compositeStarted = ContinuousClock.now
              pendingFrame.complete()
              renderMetrics.recordComposite(compositeStarted.duration(to: .now))
              let appendStarted = ContinuousClock.now
              let writerWait = try writer.append(buffer: pendingFrame.buffer, at: pendingFrame.presentationTime)
              renderMetrics.recordAppend(appendStarted.duration(to: .now), writerWait: writerWait)
              renderedFrames += 1
              if renderMetrics.shouldLog(frame: renderedFrames, fps: fps) {
                appendLog(renderMetrics.summaryLine(frame: renderedFrames, totalFrames: frameCount, renderSeconds: renderSeconds))
              }
            }
            pendingFrame = nextFrame
          }
        } catch {
          // A compose/encode failure mid-render: tear the writer down cleanly
          // and report it as an encoding failure (not "Unknown Failure").
          writer.cancel()
          throw ExportError.encoding(error.localizedDescription)
        }
      }

      if let pendingFrame {
        let compositeStarted = ContinuousClock.now
        pendingFrame.complete()
        renderMetrics.recordComposite(compositeStarted.duration(to: .now))
        let appendStarted = ContinuousClock.now
        let writerWait = try writer.append(buffer: pendingFrame.buffer, at: pendingFrame.presentationTime)
        renderMetrics.recordAppend(appendStarted.duration(to: .now), writerWait: writerWait)
        renderedFrames += 1
      }
      appendLog(renderMetrics.summaryLine(frame: renderedFrames, totalFrames: frameCount, renderSeconds: renderDuration))

      runOnMain {
        self.updateSession {
          $0.phase = .finishing
          $0.phaseLabel = "Finalizing movie"
          $0.completedParts = request.totalParts
          $0.completedDuration = renderDuration
          $0.progress = 0.98
        }
      }

      try writer.finishWriting()
      if plan.overlayOptions.needsSidecars {
        generateSidecarArtifacts(plan: plan, composer: composer, frameProvider: frameProvider)
      }
      try? fm.removeItem(at: tempRoot)

      runOnMain {
        self.finishCompleted(request: request, outputURL: plan.outputURL, renderDuration: renderDuration)
      }
    }
  }

  private func finishCompleted(request: ExportRequest, outputURL: URL, renderDuration: Double) {
    updateSession {
      $0.phase = .completed
      $0.phaseLabel = "Export complete"
      $0.progress = 1.0
      $0.finishedAt = Date()
      $0.completedParts = request.totalParts
      $0.completedDuration = renderDuration
      $0.isTerminal = true
      $0.canRevealOutput = true
      $0.canRevealWorkingFiles = false
      $0.tempRootURL = nil
      $0.canRetry = true
      $0.isIndeterminate = false
    }
    appendLog("\nDone: \(outputURL.path)\n")
    appendStructuredLogEvent("export_completed", fields: ["output": outputURL.path])
    debug("completed \(outputURL.lastPathComponent)", category: "export")
    endOutputScope()
    publishCurrentSession()
    isStatusPresented = true
    startNextQueuedExportIfIdle()
  }

  private func generateSidecarArtifacts(
    plan: ExportPlan,
    composer: TimelineFrameComposer,
    frameProvider: TimelineFrameProvider
  ) {
    let outputBase = plan.outputURL.deletingPathExtension()
    if plan.overlayOptions.includeScreenshot {
      let screenshotURL = outputBase.appendingPathExtension("poster.png")
      do {
        let context = frameProvider.context(for: 0)
        let buffer = try composer.makeFrameBuffer(
          at: context.localSeconds,
          set: context.set,
          cameraOverride: plan.cameraTrack.camera(at: plan.trimStartSeconds)
        )
        try writePNG(from: buffer, to: screenshotURL)
        appendStructuredLogEvent("export_screenshot_written", fields: ["path": screenshotURL.path])
      } catch {
        appendStructuredLogEvent("export_screenshot_failed", fields: ["message": error.localizedDescription])
      }
    }

    if plan.overlayOptions.includeReport {
      let reportURL = outputBase.appendingPathExtension("report.pdf")
      do {
        try writeReport(plan: plan, to: reportURL)
        appendStructuredLogEvent("export_report_written", fields: ["path": reportURL.path])
      } catch {
        appendStructuredLogEvent("export_report_failed", fields: ["message": error.localizedDescription])
      }
    }
  }

  private func writePNG(from buffer: CVPixelBuffer, to url: URL) throws {
    let image = CIImage(cvPixelBuffer: buffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(image, from: image.extent) else {
      throw NSError(domain: "TeslaCam", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to create export screenshot."])
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw NSError(domain: "TeslaCam", code: 9, userInfo: [NSLocalizedDescriptionKey: "Failed to open screenshot destination."])
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw NSError(domain: "TeslaCam", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to write screenshot."])
    }
  }

  private func writeReport(plan: ExportPlan, to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
      throw NSError(domain: "TeslaCam", code: 11, userInfo: [NSLocalizedDescriptionKey: "Failed to create report."])
    }
    context.beginPDFPage(nil)
    drawReportLine("Tescam Export Report", y: 730, size: 22, context: context, mediaBox: mediaBox)
    drawReportLine("Range: \(plan.selectedRangeText)", y: 690, size: 12, context: context, mediaBox: mediaBox)
    drawReportLine("Duration: \(formatHMS(plan.totalDuration))", y: 670, size: 12, context: context, mediaBox: mediaBox)
    drawReportLine("Cameras: \(plan.enabledCameras.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).joined(separator: ", "))", y: 650, size: 12, context: context, mediaBox: mediaBox)
    drawReportLine("Preset: \(plan.preset.displayName)", y: 630, size: 12, context: context, mediaBox: mediaBox)
    drawReportLine("Output: \(plan.outputURL.lastPathComponent)", y: 610, size: 12, context: context, mediaBox: mediaBox)
    drawReportLine("Clip spans: \(plan.sets.count)", y: 590, size: 12, context: context, mediaBox: mediaBox)
    drawReportLine("Graph: \(NativeFilterGraphSummary(plan: plan).description)", y: 570, size: 10, context: context, mediaBox: mediaBox)
    drawReportLine("HUD: \(plan.overlayOptions.telemetryHUD ? plan.overlayOptions.telemetryHUDMode.displayName : "Off") - Units: \(plan.overlayOptions.speedUnit.displayName)", y: 550, size: 12, context: context, mediaBox: mediaBox)
    if plan.isPreviewSample {
      drawReportLine("Type: Preview sample", y: 530, size: 12, context: context, mediaBox: mediaBox)
    }
    if !plan.cameraTrack.isEmpty {
      drawReportLine("Camera cuts: \(plan.cameraTrack.keyframes.count)", y: plan.isPreviewSample ? 510 : 530, size: 12, context: context, mediaBox: mediaBox)
    }
    if plan.partialClipCount > 0 {
      drawReportLine("Partial spans: \(plan.partialClipCount)", y: 490, size: 12, context: context, mediaBox: mediaBox)
    }
    context.endPDFPage()
    context.closePDF()
  }

  private func drawReportLine(
    _ text: String,
    y: CGFloat,
    size: CGFloat,
    context: CGContext,
    mediaBox: CGRect
  ) {
    let rect = CGRect(x: 54, y: y, width: mediaBox.width - 108, height: 28)
    ExportOverlayDrawing.drawText(
      text,
      in: rect,
      context: context,
      canvasHeight: mediaBox.height,
      size: size,
      color: CGColor(gray: 0.1, alpha: 1)
    )
  }

  private func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
    let start = ContinuousClock.now
    defer {
      let elapsed = start.duration(to: .now)
      NSLog("[perf] %@ took %@", name, String(describing: elapsed))
    }
    return try work()
  }

  private func finishFailure(error: Error) {
    let category: ExportFailureCategory
    if let exportError = error as? ExportError {
      switch exportError {
      case .preparation:
        category = .preparation
      case .encoding:
        category = .partRender
      case .cancelled:
        category = .cancelled
      }
    } else {
      category = .unknown
    }

    let message = error.localizedDescription
    if category == .cancelled {
      appendLog("Export cancelled: \(message)\n")
    } else {
      appendLog("Export failed: \(message)\n")
    }
    appendStructuredLogEvent(
      category == .cancelled ? "export_cancelled" : "export_failed",
      fields: [
        "category": category.rawValue,
        "message": message
      ]
    )
    debug(category == .cancelled ? "cancelled \(message)" : "failed \(message)", category: "export")
    cleanupPartialOutput(at: activeSession?.outputURL)
    updateSession {
      $0.phase = category == .cancelled ? .cancelled : .failed
      $0.phaseLabel = category == .cancelled ? "Export cancelled" : "Export failed"
      $0.finishedAt = Date()
      $0.failureCategory = category
      $0.failureReason = message
      $0.isTerminal = true
      $0.canRetry = true
      $0.canRevealWorkingFiles = true
      $0.isIndeterminate = false
      $0.isCancelled = category == .cancelled
    }
    lastError = category == .cancelled ? "" : message
    endOutputScope()
    publishCurrentSession()
    isStatusPresented = true
    startNextQueuedExportIfIdle()
  }

  private func finishCancelled(request: ExportRequest, outputURL: URL, keptPartial: Bool) {
    appendLog("Export cancelled\(keptPartial ? " — partial saved" : "").\n")
    appendStructuredLogEvent(
      "export_cancelled",
      fields: [
        "category": ExportFailureCategory.cancelled.rawValue,
        "kept_partial": keptPartial ? "1" : "0"
      ]
    )
    debug("cancelled\(keptPartial ? " (partial kept)" : "") \(outputURL.lastPathComponent)", category: "export")
    if !keptPartial {
      cleanupPartialOutput(at: outputURL)
    }
    updateSession {
      $0.phase = .cancelled
      $0.phaseLabel = keptPartial ? "Export cancelled — partial saved" : "Export cancelled"
      $0.finishedAt = Date()
      $0.failureCategory = .cancelled
      $0.failureReason = "Export cancelled by user."
      $0.isTerminal = true
      $0.canRetry = true
      $0.canRevealOutput = keptPartial
      $0.canRevealWorkingFiles = false
      $0.tempRootURL = nil
      $0.isIndeterminate = false
      $0.isCancelled = true
    }
    lastError = ""
    endOutputScope()
    publishCurrentSession()
    isStatusPresented = true
    startNextQueuedExportIfIdle()
  }

  /// Samples the source frame rate from the first readable clip in the plan so
  /// the render clock matches the footage (HW3 is 24 or 36 fps). Falls back to
  /// 30 fps when no clip yields a sane rate.
  private func sampleSourceFps(for plan: ExportPlan) -> Double {
    for set in plan.sets {
      for camera in plan.cameraOrder {
        if let indexedFrameRate = set.frameRate(for: camera), indexedFrameRate >= 12, indexedFrameRate <= 60 {
          return indexedFrameRate
        }
        guard let url = set.files[camera] else { continue }
        if let fps = Self.probeNominalFrameRate(url: url), fps >= 12, fps <= 60 {
          return fps
        }
      }
    }
    return 30.0
  }

  private static func probeNominalFrameRate(url: URL) -> Double? {
    let asset = AVURLAsset(url: url)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Double?
    Task.detached(priority: .userInitiated) {
      defer { semaphore.signal() }
      guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
      if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
        result = Double(rate)
      }
    }
    semaphore.wait()
    return result
  }

  private func startNextQueuedExportIfIdle() {
    guard !isExporting, !queuedRequests.isEmpty else { return }
    let next = queuedRequests.removeFirst()
    export(request: next)
  }

  private func updateSession(_ update: (inout MutableExportSession) -> Void) {
    guard var session = activeSession else { return }
    let previousPhase = session.phase
    update(&session)
    activeSession = session
    if session.phase != previousPhase {
      appendStructuredLogEvent(
        "phase_changed",
        fields: [
          "from": previousPhase.rawValue,
          "to": session.phase.rawValue
        ]
      )
      debug("phase \(previousPhase.rawValue) -> \(session.phase.rawValue)", category: "export")
    }
    publishCurrentSession()
  }

  private func publishCurrentSession() {
    guard let session = activeSession else {
      currentJob = nil
      return
    }
    let snapshot = session.snapshot(fileManager: fm)
    currentJob = snapshot
    if snapshot.isTerminal {
      exportHistory.removeAll { $0.id == snapshot.id }
      exportHistory.insert(snapshot, at: 0)
    }
  }

  private func beginOutputScope(for outputURL: URL) {
    endOutputScope()
    if outputURL.startAccessingSecurityScopedResource() {
      activeOutputScopeURL = outputURL
      return
    }
    let parent = outputURL.deletingLastPathComponent()
    if parent.startAccessingSecurityScopedResource() {
      activeOutputScopeURL = parent
    }
  }

  private func endOutputScope() {
    activeOutputScopeURL?.stopAccessingSecurityScopedResource()
    activeOutputScopeURL = nil
  }

  private func cleanupStaleTempDirectories(now: Date = Date()) {
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    guard let entries = try? fm.contentsOfDirectory(
      at: tempRoot,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
    ) else { return }

    for entry in entries where entry.lastPathComponent.hasPrefix("tescam_export_") {
      let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
      guard values?.isDirectory == true else { continue }
      let modified = values?.contentModificationDate ?? .distantPast
      if now.timeIntervalSince(modified) > Self.staleWorkdirAge {
        try? fm.removeItem(at: entry)
      }
    }
  }

  private func appendStructuredLogEvent(_ name: String, fields: [String: String] = [:]) {
    var payload = fields
    payload["event"] = name
    payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
      appendLog("event: \(line)\n")
    } else {
      appendLog("event: \(name)\n")
    }
  }

  private func appendLog(_ text: String) {
    appendLogToFile(text)
    if Thread.isMainThread {
      appendLogInMemory(text)
    } else {
      runOnMain { self.appendLogInMemory(text) }
    }
  }

  private func appendLogInMemory(_ text: String) {
    let maxLen = 60000
    log.append(text)
    if log.count > maxLen {
      log = String(log.suffix(maxLen))
    }
  }

  private func resetLogFile() {
    if fm.fileExists(atPath: logFileURL.path) {
      try? fm.removeItem(at: logFileURL)
    }
    fm.createFile(atPath: logFileURL.path, contents: nil)
  }

  private func appendLogToFile(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logFileURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      fm.createFile(atPath: logFileURL.path, contents: data)
    }
  }

  private func renderProgress(completed: Double, total: Double) -> Double {
    guard total > 0 else { return 0.10 }
    let clamped = min(max(completed / total, 0), 1)
    return 0.10 + (0.80 * clamped)
  }

  private func cleanupPartialOutput(at url: URL?) {
    guard let url, fm.fileExists(atPath: url.path) else { return }
    try? fm.removeItem(at: url)
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      let runLoop = CFRunLoopGetMain()
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
      CFRunLoopWakeUp(runLoop)
    }
  }

  private func debug(_ message: String, category: String) {
    debugLog?.record(message, category: category)
  }
}

private struct TimelineFrameContext {
  let clipIndex: Int?
  let set: ClipSet?
  let localSeconds: Double
  let sourceSecondsFromTrimStart: Double
}

private struct TimelineFrameSegment {
  let clipIndex: Int
  let set: ClipSet
  let sourceStartSeconds: Double
  let renderStartSeconds: Double
  let duration: Double

  var renderEndSeconds: Double {
    renderStartSeconds + duration
  }
}

private struct NativeFilterGraphSummary {
  let steps: [String]

  init(plan: ExportPlan) {
    if plan.preset == .originalTracksMOV {
      steps = ["read", "mux"]
      return
    }

    var steps = [
      "read",
      "scale",
      plan.cameraTrack.isEmpty ? "stack" : "camera-cut",
      "overlay"
    ]
    if plan.overlayOptions.needsTelemetry {
      steps.append("telemetry")
    }
    steps.append(plan.preset.defaultExtension == "mov" ? "prores" : "hevc")
    self.steps = steps
  }

  var description: String {
    steps.joined(separator: " -> ")
  }
}

private struct ExportRenderMetrics {
  private var prepareSeconds: Double = 0
  private var compositeSeconds: Double = 0
  private var appendSeconds: Double = 0
  private var writerWaitSeconds: Double = 0
  private var preparedFrames: Int = 0
  private var compositedFrames: Int = 0
  private var appendedFrames: Int = 0

  mutating func recordPrepare(_ duration: Duration) {
    prepareSeconds += Self.seconds(duration)
    preparedFrames += 1
  }

  mutating func recordComposite(_ duration: Duration) {
    compositeSeconds += Self.seconds(duration)
    compositedFrames += 1
  }

  mutating func recordAppend(_ duration: Duration, writerWait: TimeInterval) {
    appendSeconds += Self.seconds(duration)
    writerWaitSeconds += writerWait
    appendedFrames += 1
  }

  func shouldLog(frame: Int, fps: Double) -> Bool {
    let cadence = max(24, Int((fps * 5).rounded()))
    return frame > 0 && frame.isMultiple(of: cadence)
  }

  func summaryLine(frame: Int, totalFrames: Int, renderSeconds: Double) -> String {
    "perf render frame=\(frame)/\(totalFrames) seconds=\(String(format: "%.2f", renderSeconds)) prepare_avg_ms=\(Self.ms(prepareSeconds, preparedFrames)) composite_avg_ms=\(Self.ms(compositeSeconds, compositedFrames)) append_avg_ms=\(Self.ms(appendSeconds, appendedFrames)) writer_wait_avg_ms=\(Self.ms(writerWaitSeconds, appendedFrames))\n"
  }

  private static func ms(_ seconds: Double, _ count: Int) -> String {
    guard count > 0 else { return "0.00" }
    return String(format: "%.2f", seconds * 1000.0 / Double(count))
  }

  static func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
  }
}

private struct TimelineFrameProvider {
  let sets: [ClipSet]
  let trimStartDate: Date
  let trimEndDate: Date
  let totalDuration: Double

  private let segments: [TimelineFrameSegment]
  private let segmentStartSeconds: [Double]
  private let segmentEndSeconds: [Double]

  init(sets: [ClipSet], trimStartDate: Date, trimEndDate: Date) {
    self.sets = sets.sorted { lhs, rhs in
      if lhs.date == rhs.date {
        return lhs.timestamp < rhs.timestamp
      }
      return lhs.date < rhs.date
    }
    self.trimStartDate = trimStartDate
    self.trimEndDate = max(trimEndDate, trimStartDate.addingTimeInterval(1.0 / 30.0))
    self.segments = Self.segments(
      for: self.sets,
      trimStartDate: self.trimStartDate,
      trimEndDate: self.trimEndDate
    )
    self.segmentStartSeconds = self.segments.map(\.renderStartSeconds)
    self.segmentEndSeconds = self.segments.map(\.renderEndSeconds)
    self.totalDuration = max(1.0 / 30.0, self.segments.last?.renderEndSeconds ?? 0)
  }

  static func renderDuration(sets: [ClipSet], trimStartDate: Date, trimEndDate: Date) -> Double {
    let orderedSets = sets.sorted { lhs, rhs in
      if lhs.date == rhs.date {
        return lhs.timestamp < rhs.timestamp
      }
      return lhs.date < rhs.date
    }
    let endDate = max(trimEndDate, trimStartDate.addingTimeInterval(1.0 / 30.0))
    let segments = Self.segments(for: orderedSets, trimStartDate: trimStartDate, trimEndDate: endDate)
    return max(1.0 / 30.0, segments.last?.renderEndSeconds ?? 0)
  }

  private static func segments(
    for sets: [ClipSet],
    trimStartDate: Date,
    trimEndDate: Date
  ) -> [TimelineFrameSegment] {
    var renderStartSeconds = 0.0
    var segments: [TimelineFrameSegment] = []
    segments.reserveCapacity(sets.count)

    for (index, set) in sets.enumerated() {
      let clipStartDate = set.date
      let clipEndDate = set.date.addingTimeInterval(max(1.0 / 30.0, set.duration))
      let segmentStartDate = max(clipStartDate, trimStartDate)
      let segmentEndDate = min(clipEndDate, trimEndDate)
      let duration = segmentEndDate.timeIntervalSince(segmentStartDate)
      guard duration > 0 else { continue }

      segments.append(
        TimelineFrameSegment(
          clipIndex: index,
          set: set,
          sourceStartSeconds: segmentStartDate.timeIntervalSince(clipStartDate),
          renderStartSeconds: renderStartSeconds,
          duration: duration
        )
      )
      renderStartSeconds += duration
    }

    return segments
  }

  func context(for renderSeconds: Double) -> TimelineFrameContext {
    guard !segments.isEmpty else {
      return TimelineFrameContext(clipIndex: nil, set: nil, localSeconds: 0, sourceSecondsFromTrimStart: 0)
    }

    let clamped = max(0, min(renderSeconds, totalDuration))
    if clamped >= totalDuration, let segment = segments.last {
      return TimelineFrameContext(
        clipIndex: segment.clipIndex,
        set: segment.set,
        localSeconds: segment.sourceStartSeconds + segment.duration,
        sourceSecondsFromTrimStart: segment.set.date
          .addingTimeInterval(segment.sourceStartSeconds + segment.duration)
          .timeIntervalSince(trimStartDate)
      )
    }

    let index = max(0, min(segments.count - 1, upperBound(in: segmentStartSeconds, for: clamped) - 1))
    let segment = segments[index]
    let localSeconds = segment.sourceStartSeconds + clamped - segment.renderStartSeconds
    return TimelineFrameContext(
      clipIndex: segment.clipIndex,
      set: segment.set,
      localSeconds: localSeconds,
      sourceSecondsFromTrimStart: segment.set.date
        .addingTimeInterval(localSeconds)
        .timeIntervalSince(trimStartDate)
    )

  }

  func completedSetCount(at renderSeconds: Double) -> Int {
    let clamped = max(0, min(renderSeconds, totalDuration))
    return upperBound(in: segmentEndSeconds, for: clamped)
  }

  private func upperBound(in values: [Double], for target: Double) -> Int {
    var low = 0
    var high = values.count
    while low < high {
      let mid = (low + high) / 2
      if values[mid] <= target {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }
}

private struct TimelineFrameLayout {
  let cameraOrder: [Camera]
  let canvasSize: CGSize
  let tileSize: CGSize
  /// Core Graphics coordinates have their origin at the lower left.
  let boundsByCamera: [Camera: CGRect]
  /// Metal viewports have their origin at the upper left.
  let metalBoundsByCamera: [Camera: CGRect]

  static func build(
    sets: [ClipSet],
    enabledCameras: Set<Camera>,
    useSixCam: Bool,
    layoutRequest: CameraLayoutRequest = .auto
  ) throws -> TimelineFrameLayout {
    let present = Set(sets.flatMap { $0.files.keys })
    let probe = TimelineFrameSizeProbe(sets: sets)
    let requestedProfile: CameraLayoutRequest
    if layoutRequest == .auto {
      requestedProfile = useSixCam ? .sixcam : .auto
    } else {
      requestedProfile = layoutRequest
    }
    let plan = CameraLayoutPlan.build(
      requestedProfile: requestedProfile,
      detectedCameras: present,
      enabledCameras: enabledCameras,
      naturalSizes: probe.naturalSizes(for: Camera.mixedOrder)
    )

    var bounds: [Camera: CGRect] = [:]
    var metalBounds: [Camera: CGRect] = [:]
    for camera in plan.renderOrder {
      guard let cell = plan.cellByCamera[camera] else { continue }
      metalBounds[camera] = cell
      bounds[camera] = CGRect(
        x: cell.minX,
        y: plan.canvasSize.height - cell.maxY,
        width: cell.width,
        height: cell.height
      )
    }

    return TimelineFrameLayout(
      cameraOrder: plan.renderOrder,
      canvasSize: plan.canvasSize,
      tileSize: probe.tileSize(for: plan.renderOrder),
      boundsByCamera: bounds,
      metalBoundsByCamera: metalBounds
    )
  }
}

private struct TimelineFrameSizeProbe {
  let sets: [ClipSet]

  func tileSize(for cameras: [Camera]) -> CGSize {
    var maxWidth: CGFloat = 1
    var maxHeight: CGFloat = 1
    var foundVideo = false

    for set in sets {
      for camera in cameras {
        if let naturalSize = set.naturalSize(for: camera), naturalSize.width > 0, naturalSize.height > 0 {
          maxWidth = max(maxWidth, naturalSize.width)
          maxHeight = max(maxHeight, naturalSize.height)
          foundVideo = true
          continue
        }

        guard let url = set.file(for: camera) else { continue }
        let asset = AVURLAsset(
          url: url,
          options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let size = AssetVideoTrackLoader.presentationSize(for: asset) else { continue }
        maxWidth = max(maxWidth, size.width)
        maxHeight = max(maxHeight, size.height)
        foundVideo = true
      }
    }

    if !foundVideo {
      return CGSize(width: 320, height: 240)
    }

    let fallbackWidth = max(maxWidth, 1280)
    let fallbackHeight = max(maxHeight, 960)
    return CGSize(width: fallbackWidth, height: fallbackHeight)
  }

  func naturalSizes(for cameras: [Camera]) -> [Camera: CGSize] {
    var sizes: [Camera: CGSize] = [:]
    for set in sets {
      for camera in cameras where sizes[camera] == nil {
        if let naturalSize = set.naturalSize(for: camera), naturalSize.width > 0, naturalSize.height > 0 {
          sizes[camera] = naturalSize
        }
      }
    }
    return sizes
  }
}

private enum AssetVideoTrackLoader {
  static nonisolated func presentationSize(for asset: AVURLAsset) -> CGSize? {
    let semaphore = DispatchSemaphore(value: 0)
    var loadedSize: CGSize?

    Task.detached(priority: .userInitiated) {
      defer { semaphore.signal() }
      do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
          loadedSize = nil
          return
        }
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        let transformed = try await naturalSize.applying(preferredTransform)
        loadedSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
      } catch {
        loadedSize = nil
      }
    }

    semaphore.wait()
    return loadedSize
  }
}

/// Sequential per-clip frame decoder for export. Decodes BGRA frames in order
/// with a single AVAssetReader instead of the per-frame random-access GOP
/// decode the image-generator path did — that redundant decode was the export
/// throughput ceiling. Synchronous: the export render loop is offline and walks
/// frames in order, so blocking the worker is fine, and decoding each frame
/// exactly once is dramatically cheaper than re-seeking a GOP per frame.
nonisolated private final class SequentialExportDecoder: @unchecked Sendable {
  let url: URL
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var pending: CMSampleBuffer?
  private var lastTime: Double = -1
  private var lastImage: CGImage?

  init(url: URL) { self.url = url }

  /// The frame at/just-before `target` seconds. Advances the reader forward;
  /// only a backward jump recreates it (rare in an offline forward render).
  func image(at target: Double) -> CGImage? {
    if reader == nil || target < lastTime - 0.001 {
      recreate(at: target)
    }
    guard let output, let reader, reader.status == .reading else { return lastImage }
    while true {
      let sample = pending ?? output.copyNextSampleBuffer()
      pending = nil
      guard let sample else { break } // EOF: keep the last decoded frame
      let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard pts.isFinite else { continue }
      if pts <= target + 1.0 / 120.0 {
        lastTime = pts
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
           let image = Self.makeCGImage(from: pixelBuffer) {
          lastImage = image
        }
      } else {
        pending = sample // future frame; consume it on the next call
        break
      }
    }
    return lastImage
  }

  func tearDown() {
    reader?.cancelReading()
    reader = nil; output = nil; pending = nil; lastImage = nil
  }

  private func recreate(at seconds: Double) {
    reader?.cancelReading()
    reader = nil; output = nil; pending = nil; lastTime = -1
    let asset = AVURLAsset(url: url)
    guard let track = Self.loadFirstVideoTrack(asset),
          let newReader = try? AVAssetReader(asset: asset) else { return }
    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    newOutput.alwaysCopiesSampleData = false
    guard newReader.canAdd(newOutput) else { return }
    newReader.add(newOutput)
    if seconds > 0.05 {
      newReader.timeRange = CMTimeRange(
        start: CMTime(seconds: seconds, preferredTimescale: 600),
        duration: .positiveInfinity
      )
    }
    guard newReader.startReading() else { return }
    reader = newReader
    output = newOutput
  }

  private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0,
          let base = CVPixelBufferGetBaseAddress(pixelBuffer),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else { return nil }
    return context.makeImage()
  }

  private static func loadFirstVideoTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: AVAssetTrack?
    Task.detached(priority: .userInitiated) {
      result = try? await asset.loadTracks(withMediaType: .video).first
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }
}

nonisolated private struct FrameImageRequest {
  let camera: Camera
  let url: URL
  let seconds: Double
  let rect: CGRect
}

nonisolated private struct PendingFrameBuffer {
  let buffer: CVPixelBuffer
  let presentationTime: CMTime
  let complete: () -> Void
}

nonisolated private struct DecodedMetalFrame {
  let texture: MTLTexture
  let retainedTexture: CVMetalTexture
}

nonisolated private struct PendingMetalComposite {
  let commandBuffer: MTLCommandBuffer
  let retainedTextures: [CVMetalTexture]

  func complete() {
    _ = retainedTextures
    commandBuffer.waitUntilCompleted()
  }
}

/// Sequential per-clip decoder that yields zero-copy Metal textures for the GPU
/// export compositor. Same sequential-read strategy as SequentialExportDecoder,
/// but wraps each decoded BGRA frame as a CVMetalTextureCache texture instead of
/// copying it into a CGImage — no CPU pixel copy.
nonisolated private final class SequentialMetalDecoder: @unchecked Sendable {
  let url: URL
  private let textureCache: CVMetalTextureCache
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var pending: CMSampleBuffer?
  private var lastTime: Double = -1
  private var current: DecodedMetalFrame?

  init(url: URL, textureCache: CVMetalTextureCache) {
    self.url = url
    self.textureCache = textureCache
  }

  func frame(at target: Double) -> DecodedMetalFrame? {
    if reader == nil || target < lastTime - 0.001 {
      recreate(at: target)
    }
    guard let output, let reader, reader.status == .reading else { return current }
    while true {
      let sample = pending ?? output.copyNextSampleBuffer()
      pending = nil
      guard let sample else { break }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard pts.isFinite else { continue }
      if pts <= target + 1.0 / 120.0 {
        lastTime = pts
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
           let made = makeTexture(from: pixelBuffer) {
          current = made
        }
      } else {
        pending = sample
        break
      }
    }
    return current
  }

  func tearDown() {
    reader?.cancelReading()
    reader = nil; output = nil; pending = nil; current = nil
  }

  private func recreate(at seconds: Double) {
    reader?.cancelReading()
    reader = nil; output = nil; pending = nil; lastTime = -1
    let asset = AVURLAsset(url: url)
    guard let track = Self.loadFirstVideoTrack(asset),
          let newReader = try? AVAssetReader(asset: asset) else { return }
    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    newOutput.alwaysCopiesSampleData = false
    guard newReader.canAdd(newOutput) else { return }
    newReader.add(newOutput)
    if seconds > 0.05 {
      newReader.timeRange = CMTimeRange(
        start: CMTime(seconds: seconds, preferredTimescale: 600),
        duration: .positiveInfinity
      )
    }
    guard newReader.startReading() else { return }
    reader = newReader
    output = newOutput
  }

  private func makeTexture(from pixelBuffer: CVPixelBuffer) -> DecodedMetalFrame? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return nil }
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, pixelBuffer, nil,
      .bgra8Unorm, width, height, 0, &cvTexture
    )
    guard status == kCVReturnSuccess, let cvTexture,
          let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
    return DecodedMetalFrame(texture: texture, retainedTexture: cvTexture)
  }

  private static func loadFirstVideoTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: AVAssetTrack?
    Task.detached(priority: .userInitiated) {
      result = try? await asset.loadTracks(withMediaType: .video).first
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }
}

/// GPU export compositor: decodes each camera to a zero-copy Metal texture and
/// composites the grid into the output pixel buffer with a single Metal render
/// pass — replacing the CoreGraphics per-frame CPU composite. Decode (hardware
/// VideoToolbox), composite (GPU), and encode (hardware HEVC) are all off the
/// CPU; only the small HUD text overlay stays on CoreGraphics.
nonisolated private final class MetalExportCompositor: @unchecked Sendable {
  static var decodeModeDescription: String {
    "serial"
  }

  let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private let vertexBuffer: MTLBuffer
  private let textureCache: CVMetalTextureCache
  private var decoders: [URL: SequentialMetalDecoder] = [:]
  private var activeDecoderURLs = Set<URL>()
  private var compositeCount = 0

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue(),
          let library = Self.loadLibrary(device: device),
          let vertexFunc = library.makeFunction(name: "vertex_main"),
          let fragFunc = library.makeFunction(name: "fragment_main") else { return nil }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunc
    descriptor.fragmentFunction = fragFunc
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

    let samplerDesc = MTLSamplerDescriptor()
    samplerDesc.minFilter = .linear
    samplerDesc.magFilter = .linear
    samplerDesc.sAddressMode = .clampToEdge
    samplerDesc.tAddressMode = .clampToEdge
    guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }

    // Same fullscreen quad + texcoords as the on-screen renderer, so the
    // offscreen orientation matches the preview.
    let quad: [Float] = [
      -1, -1, 0, 1,
       1, -1, 1, 1,
      -1,  1, 0, 0,
       1, -1, 1, 1,
       1,  1, 1, 0,
      -1,  1, 0, 0
    ]
    guard let vertexBuffer = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<Float>.size, options: []) else { return nil }

    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

    self.device = device
    self.commandQueue = queue
    self.pipeline = pipeline
    self.sampler = sampler
    self.vertexBuffer = vertexBuffer
    self.textureCache = cache
  }

  /// Composites the requested cameras into `outputBuffer`. Returns nil if the
  /// buffer can't be wrapped, in which case the caller uses the CPU path.
  func composite(
    requests: [FrameImageRequest],
    canvasSize: CGSize,
    into outputBuffer: CVPixelBuffer
  ) -> PendingMetalComposite? {
    let width = CVPixelBufferGetWidth(outputBuffer)
    let height = CVPixelBufferGetHeight(outputBuffer)
    var cvTarget: CVMetalTexture?
    guard CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, outputBuffer, nil, .bgra8Unorm, width, height, 0, &cvTarget
    ) == kCVReturnSuccess, let cvTarget, let target = CVMetalTextureGetTexture(cvTarget) else {
      return nil
    }

    let active = Set(requests.map(\.url))
    let decoderSetChanged = active != activeDecoderURLs
    activeDecoderURLs = active
    for url in decoders.keys where !active.contains(url) {
      decoders.removeValue(forKey: url)?.tearDown()
    }

    let decoderRequests: [(decoder: SequentialMetalDecoder, request: FrameImageRequest)] = requests.map { request in
      let decoder = decoders[request.url] ?? {
        let d = SequentialMetalDecoder(url: request.url, textureCache: textureCache)
        decoders[request.url] = d
        return d
      }()
      return (decoder, request)
    }

    var draws: [(index: Int, frame: DecodedMetalFrame, viewport: MTLViewport)] = []
    draws.reserveCapacity(decoderRequests.count)

    func makeDraw(index: Int, item: (decoder: SequentialMetalDecoder, request: FrameImageRequest)) -> (index: Int, frame: DecodedMetalFrame, viewport: MTLViewport)? {
      guard let frame = item.decoder.frame(at: item.request.seconds) else { return nil }
      return (
        index: index,
        frame: frame,
        viewport: aspectFitViewport(
          cell: item.request.rect,
          textureWidth: frame.texture.width,
          textureHeight: frame.texture.height
        )
      )
    }

    // A grid frame is complete only when every requested camera has a frame.
    // Serial reads keep VideoToolbox resource use deterministic on macOS and
    // iOS; a failed GPU read falls back to the CPU compositor below instead
    // of silently leaving that camera's cell black.
    for (index, item) in decoderRequests.enumerated() {
      guard let draw = makeDraw(index: index, item: item) else { return nil }
      draws.append(draw)
    }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    pass.colorAttachments[0].storeAction = .store
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      return nil
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)
    for draw in draws {
      encoder.setViewport(draw.viewport)
      encoder.setFragmentTexture(draw.frame.texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    encoder.endEncoding()
    commandBuffer.commit()
    compositeCount += 1
    if decoderSetChanged || compositeCount.isMultiple(of: 120) {
      CVMetalTextureCacheFlush(textureCache, 0)
    }
    return PendingMetalComposite(
      commandBuffer: commandBuffer,
      retainedTextures: draws.map { $0.frame.retainedTexture }
    )
  }

  /// Aspect-fit a source texture into a canvas cell, returning the Metal
  /// viewport (top-left origin, matching the canvas cell coordinates).
  private func aspectFitViewport(cell: CGRect, textureWidth: Int, textureHeight: Int) -> MTLViewport {
    guard textureWidth > 0, textureHeight > 0, cell.width > 0, cell.height > 0 else {
      return MTLViewport(originX: Double(cell.minX), originY: Double(cell.minY), width: Double(cell.width), height: Double(cell.height), znear: 0, zfar: 1)
    }
    let sourceAspect = Double(textureWidth) / Double(textureHeight)
    let cellAspect = Double(cell.width) / Double(cell.height)
    if sourceAspect > cellAspect {
      let fittedHeight = Double(cell.width) / sourceAspect
      let yInset = (Double(cell.height) - fittedHeight) / 2
      return MTLViewport(originX: Double(cell.minX), originY: Double(cell.minY) + yInset, width: Double(cell.width), height: fittedHeight, znear: 0, zfar: 1)
    } else {
      let fittedWidth = Double(cell.height) * sourceAspect
      let xInset = (Double(cell.width) - fittedWidth) / 2
      return MTLViewport(originX: Double(cell.minX) + xInset, originY: Double(cell.minY), width: fittedWidth, height: Double(cell.height), znear: 0, zfar: 1)
    }
  }

  private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
    let bundle = Bundle.main
    guard let url = bundle.url(forResource: "MetalShaders", withExtension: "metal"),
          let source = try? String(contentsOf: url, encoding: .utf8),
          let library = try? device.makeLibrary(source: source, options: nil) else {
      return device.makeDefaultLibrary()
    }
    return library
  }
}

nonisolated private final class TimelineFrameComposer: @unchecked Sendable {
  let layout: TimelineFrameLayout
  let enabledCameras: Set<Camera>
  let overlayOptions: ExportOverlayOptions
  private var exportDecoders: [URL: SequentialExportDecoder] = [:]
  private var lastImages: [URL: CGImage] = [:]
  // GPU compositor — composites the camera grid on the GPU. nil when no Metal
  // device is available, in which case the CoreGraphics CPU path is used.
  private let metalCompositor: MetalExportCompositor?
  private var telemetryCache: [URL: TelemetryTimeline] = [:]
  private var telemetryFailures = Set<URL>()
  private var routeCache: [URL: [TelemetryRoutePoint]] = [:]
  private let pixelBufferPool: CVPixelBufferPool?

  init(layout: TimelineFrameLayout, enabledCameras: Set<Camera>, overlayOptions: ExportOverlayOptions = ExportOverlayOptions()) {
    self.layout = layout
    self.enabledCameras = enabledCameras
    self.overlayOptions = overlayOptions
    self.metalCompositor = MetalExportCompositor()
    let width = Int(layout.canvasSize.width.rounded(.up))
    let height = Int(layout.canvasSize.height.rounded(.up))
    let poolAttributes: [String: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey as String: 8
    ]
    let pixelAttributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      poolAttributes as CFDictionary,
      pixelAttributes as CFDictionary,
      &pool
    )
    pixelBufferPool = pool
  }

  var pipelineDescription: String {
    if metalCompositor != nil {
      return "composite=metal decode=\(MetalExportCompositor.decodeModeDescription)"
    }
    return "composite=coregraphics decode=cpu"
  }

  func makeFrameBuffer(at localSeconds: Double, set: ClipSet?, cameraOverride: Camera? = nil) throws -> CVPixelBuffer {
    let pending = try makePendingFrameBuffer(
      at: localSeconds,
      set: set,
      cameraOverride: cameraOverride,
      presentationTime: .zero
    )
    pending.complete()
    return pending.buffer
  }

  func makePendingFrameBuffer(
    at localSeconds: Double,
    set: ClipSet?,
    cameraOverride: Camera? = nil,
    presentationTime: CMTime
  ) throws -> PendingFrameBuffer {
    let width = Int(layout.canvasSize.width.rounded(.up))
    let height = Int(layout.canvasSize.height.rounded(.up))
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    var buffer: CVPixelBuffer?
    let status: CVReturn
    if let pixelBufferPool {
      status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer)
    } else {
      status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    }
    guard status == kCVReturnSuccess, let buffer else {
      throw NSError(domain: "TeslaCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate frame buffer."])
    }

    let (imageRequests, drawFocusCamera, focusRect) = frameImageRequests(
      set: set, localSeconds: localSeconds, cameraOverride: cameraOverride
    )

    // GPU path: composite the camera grid with Metal (no CPU pixel work), then
    // draw only the overlay (small HUD/timestamp text) with CoreGraphics.
    let metalRequests: [FrameImageRequest]
    if drawFocusCamera == nil {
      metalRequests = imageRequests.map { request in
        FrameImageRequest(
          camera: request.camera,
          url: request.url,
          seconds: request.seconds,
          rect: layout.metalBoundsByCamera[request.camera] ?? request.rect
        )
      }
    } else {
      metalRequests = imageRequests
    }

    if let metalCompositor,
       let composite = metalCompositor.composite(requests: metalRequests, canvasSize: layout.canvasSize, into: buffer) {
      return PendingFrameBuffer(buffer: buffer, presentationTime: presentationTime) { [weak self] in
        composite.complete()
        guard let self else { return }
        if set != nil, overlayOptions.privacyMask || overlayOptions.needsTelemetry {
          withCGContext(for: buffer, width: width, height: height) { context in
            self.drawOverlays(
              in: context,
              set: set,
              localSeconds: localSeconds,
              drawFocusCamera: drawFocusCamera,
              focusRect: focusRect
            )
          }
        }
      }
    }

    // CPU fallback: CoreGraphics composite + overlay.
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
      throw NSError(domain: "TeslaCam", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to access frame buffer."])
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw NSError(domain: "TeslaCam", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create color space."])
    }
    guard let context = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
      throw NSError(domain: "TeslaCam", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create drawing context."])
    }

    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(origin: .zero, size: layout.canvasSize))

    guard set != nil else {
      return PendingFrameBuffer(buffer: buffer, presentationTime: presentationTime) {}
    }

    let images = images(for: imageRequests)
    for request in imageRequests {
      guard let image = images[request.camera] else { continue }
      let fitted = AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height), insideRect: request.rect)
      context.draw(image, in: fitted)
    }
    drawOverlays(in: context, set: set, localSeconds: localSeconds, drawFocusCamera: drawFocusCamera, focusRect: focusRect)
    return PendingFrameBuffer(buffer: buffer, presentationTime: presentationTime) {}
  }

  /// The per-camera frame requests for `set` at `localSeconds`, plus the focus
  /// camera and full-canvas rect used by the overlay. Cameras whose clip has
  /// ended by `localSeconds` are dropped (rendered black).
  private func frameImageRequests(
    set: ClipSet?, localSeconds: Double, cameraOverride: Camera?
  ) -> (requests: [FrameImageRequest], focusCamera: Camera?, focusRect: CGRect) {
    let focusRect = CGRect(origin: .zero, size: layout.canvasSize)
    guard let set else { return ([], nil, focusRect) }
    let drawFocusCamera = cameraOverride.flatMap { camera in
      enabledCameras.contains(camera) && set.file(for: camera) != nil ? camera : nil
    }
    if let camera = drawFocusCamera, let url = set.file(for: camera) {
      if let duration = set.duration(for: camera), localSeconds > duration + (1.0 / 30.0) {
        return ([], drawFocusCamera, focusRect)
      }
      return ([FrameImageRequest(camera: camera, url: url, seconds: localSeconds, rect: focusRect)], drawFocusCamera, focusRect)
    }
    var requests: [FrameImageRequest] = []
    requests.reserveCapacity(layout.cameraOrder.count)
    for camera in layout.cameraOrder {
      guard enabledCameras.contains(camera),
            let rect = layout.boundsByCamera[camera],
            let url = set.file(for: camera) else { continue }
      if let duration = set.duration(for: camera), localSeconds > duration + (1.0 / 30.0) { continue }
      requests.append(FrameImageRequest(camera: camera, url: url, seconds: localSeconds, rect: rect))
    }
    return (requests, nil, focusRect)
  }

  private func drawOverlays(in context: CGContext, set: ClipSet?, localSeconds: Double, drawFocusCamera: Camera?, focusRect: CGRect) {
    guard let set else { return }
    if overlayOptions.privacyMask {
      ExportOverlayDrawing.drawPrivacyMask(
        context: context,
        canvasSize: layout.canvasSize,
        tileRects: drawFocusCamera == nil ? layout.boundsByCamera.values.map { $0 } : [focusRect]
      )
    }
    if overlayOptions.needsTelemetry {
      let telemetryURL = telemetrySourceURL(for: set)
      let timeline = telemetryURL.flatMap { telemetryTimeline(for: $0) }
      let frame = timeline?.closest(to: max(0, localSeconds) * 1000.0)
      let telemetry = frame.map { TelemetryDisplayModel(sei: $0.sei) }
      let route = telemetryURL.flatMap { routePoints(for: $0, timeline: timeline) } ?? []
      ExportOverlayDrawing.drawTelemetryOverlay(
        options: overlayOptions,
        telemetry: telemetry,
        route: route,
        timestamp: set.date.addingTimeInterval(max(0, localSeconds)),
        localSeconds: localSeconds,
        context: context,
        canvasSize: layout.canvasSize
      )
    }
  }

  /// Runs `body` with a CoreGraphics context bound to `buffer` (locked for the
  /// duration), for drawing the overlay on top of the GPU-composited frame.
  private func withCGContext(for buffer: CVPixelBuffer, width: Int, height: Int, _ body: (CGContext) -> Void) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else { return }
    body(context)
  }

  private func telemetrySourceURL(for set: ClipSet) -> URL? {
    set.file(for: .front) ?? set.file(for: .back) ?? set.files.values.sorted { $0.path < $1.path }.first
  }

  private func telemetryTimeline(for url: URL) -> TelemetryTimeline? {
    if let cached = telemetryCache[url] {
      return cached
    }
    if telemetryFailures.contains(url) {
      return nil
    }
    do {
      let timeline = try TelemetryParser.parseTimeline(url: url)
      telemetryCache[url] = timeline
      return timeline
    } catch {
      telemetryFailures.insert(url)
      return nil
    }
  }

  private func routePoints(for url: URL, timeline: TelemetryTimeline?) -> [TelemetryRoutePoint] {
    if let cached = routeCache[url] {
      return cached
    }
    guard let timeline else {
      routeCache[url] = []
      return []
    }
    let points = ExportOverlayDrawing.routePoints(from: timeline)
    routeCache[url] = points
    return points
  }

  private func images(for requests: [FrameImageRequest]) -> [Camera: CGImage] {
    guard !requests.isEmpty else { return [:] }

    // Release decoders for clips the render has advanced past.
    let activeURLs = Set(requests.map(\.url))
    for url in exportDecoders.keys where !activeURLs.contains(url) {
      exportDecoders.removeValue(forKey: url)?.tearDown()
    }

    // Decode each unique clip URL once (cameras in a frame share one time),
    // creating decoders up front so the worker closures never mutate the map.
    var secondsByURL: [URL: Double] = [:]
    var camerasByURL: [URL: [Camera]] = [:]
    for request in requests {
      secondsByURL[request.url] = max(0, request.seconds)
      camerasByURL[request.url, default: []].append(request.camera)
      if exportDecoders[request.url] == nil {
        exportDecoders[request.url] = SequentialExportDecoder(url: request.url)
      }
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var imageByURL: [URL: CGImage] = [:]
    for (url, seconds) in secondsByURL {
      guard let decoder = exportDecoders[url] else { continue }
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        let decoded = decoder.image(at: seconds)
        lock.lock()
        if let decoded {
          imageByURL[url] = decoded
          self.lastImages[url] = decoded
        } else if let fallback = self.lastImages[url] {
          imageByURL[url] = fallback // keep the last good frame on a decode miss
        }
        lock.unlock()
        group.leave()
      }
    }
    group.wait()

    var results: [Camera: CGImage] = [:]
    for (url, cameras) in camerasByURL {
      guard let image = imageByURL[url] else { continue }
      for camera in cameras { results[camera] = image }
    }
    return results
  }
}

nonisolated private enum ExportOverlayDrawing {
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  static func drawTelemetryOverlay(
    options: ExportOverlayOptions,
    telemetry: TelemetryDisplayModel?,
    route: [TelemetryRoutePoint],
    timestamp: Date,
    localSeconds: Double,
    context: CGContext,
    canvasSize: CGSize
  ) {
    if options.routeMap, !route.isEmpty {
      drawRouteMap(route: route, currentSeconds: localSeconds, context: context, canvasSize: canvasSize)
    }

    guard options.telemetryHUD else { return }

    let panelHeight: CGFloat = options.telemetryHUDMode == .minimal ? 118 : 208
    let panel = CGRect(
      x: 26,
      y: max(26, canvasSize.height - 26 - panelHeight),
      width: min(680, canvasSize.width * 0.42),
      height: panelHeight
    )
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.58))
    context.fill(panel)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.stroke(panel, width: 1)

    let timestampText = "\(ExportOverlayDrawing.dateFormatter.string(from: timestamp))  \(ExportOverlayDrawing.timeFormatter.string(from: timestamp))"
    let rows: [(symbol: String, text: String, emphasized: Bool)]
    if let telemetry {
      switch options.telemetryHUDMode {
      case .minimal:
        rows = [
          ("calendar", timestampText, true),
          ("speedometer", "\(telemetry.speedText(unit: options.speedUnit))   Gear \(telemetry.gear)", false),
          ("pedal.brake", "AP \(telemetry.autopilot)   Brake \(telemetry.brakeApplied ? "On" : "Off")", false)
        ]
      case .detailed:
        rows = [
          ("calendar", timestampText, true),
          ("speedometer", "Speed \(telemetry.speedText(unit: options.speedUnit))    Pedal \(telemetry.acceleratorText)", false),
          ("pedal.brake", "Brake \(telemetry.brakeApplied ? "On" : "Off")    Gear \(telemetry.gear)    AP \(telemetry.autopilot)", false),
          ("steeringwheel", "Steer \(telemetry.steeringText)    Heading \(telemetry.headingText)", false),
          ("location", "GPS \(telemetry.locationText)", false),
          ("arrow.triangle.turn.up.right.diamond", "Signal \(telemetry.signalText)    G \(telemetry.gForceText)", false)
        ]
      }
    } else {
      rows = [
        ("calendar", timestampText, true),
        ("speedometer", "No Tesla telemetry", false),
        ("location.slash", "Speed, pedal, GPS and AP unavailable for this clip", false)
      ]
    }
    for (index, row) in rows.enumerated() {
      let y = panel.maxY - 40 - CGFloat(index * 29)
      drawSymbol(
        row.symbol,
        in: CGRect(x: panel.minX + 18, y: y + 2, width: 18, height: 18),
        context: context,
        color: CGColor(red: 1, green: 1, blue: 1, alpha: row.emphasized ? 0.95 : 0.70)
      )
      drawText(
        row.text,
        in: CGRect(x: panel.minX + 44, y: y, width: panel.width - 62, height: 24),
        context: context,
        canvasHeight: canvasSize.height,
        size: row.emphasized ? 19 : 16,
        color: CGColor(red: 1, green: 1, blue: 1, alpha: row.emphasized ? 0.95 : 0.78)
      )
    }
  }

  static func drawPrivacyMask(context: CGContext, canvasSize: CGSize, tileRects: [CGRect]) {
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.76))
    let topBand = CGRect(x: 0, y: canvasSize.height - 96, width: canvasSize.width, height: 96)
    context.fill(topBand)
    for rect in tileRects {
      let bandHeight = max(54, rect.height * 0.16)
      context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandHeight))
    }
  }

  static func routePoints(from timeline: TelemetryTimeline) -> [TelemetryRoutePoint] {
    var points: [TelemetryRoutePoint] = []
    points.reserveCapacity(min(240, timeline.frames.count))
    var lastWholeSecond = -1
    var lastCoordinate: TelemetryCoordinate?
    for frame in timeline.frames {
      let seconds = Int((frame.timestampMs / 1000.0).rounded(.down))
      guard seconds != lastWholeSecond else { continue }
      lastWholeSecond = seconds
      let coordinate = TelemetryCoordinate(latitude: frame.sei.latitudeDeg, longitude: frame.sei.longitudeDeg)
      guard coordinate.isUsable, coordinate != lastCoordinate else { continue }
      lastCoordinate = coordinate
      points.append(
        TelemetryRoutePoint(
          id: points.count,
          seconds: frame.timestampMs / 1000.0,
          coordinate: coordinate,
          speedKmh: Double(frame.sei.vehicleSpeedMps) * 3.6,
          headingDeg: frame.sei.headingDeg
        )
      )
    }
    return points
  }

  private static func drawRouteMap(
    route: [TelemetryRoutePoint],
    currentSeconds: Double,
    context: CGContext,
    canvasSize: CGSize
  ) {
    let displayRoute = TelemetryRouteReplay.displaySamples(from: route, maxPoints: 900)
    let side = min(310, min(canvasSize.width, canvasSize.height) * 0.28)
    let panel = CGRect(x: canvasSize.width - side - 26, y: 26, width: side, height: side)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.58))
    context.fill(panel)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    context.stroke(panel, width: 1)

    let points = displayRoute.map(\.coordinate)
    let latitudes = points.map(\.latitude)
    let longitudes = points.map(\.longitude)
    guard let minLat = latitudes.min(),
          let maxLat = latitudes.max(),
          let minLon = longitudes.min(),
          let maxLon = longitudes.max() else { return }

    let latSpan = max(0.00001, maxLat - minLat)
    let lonSpan = max(0.00001, maxLon - minLon)
    let inset: CGFloat = 22
    let drawRect = panel.insetBy(dx: inset, dy: inset)
    func point(for coordinate: TelemetryCoordinate) -> CGPoint {
      let x = drawRect.minX + CGFloat((coordinate.longitude - minLon) / lonSpan) * drawRect.width
      let y = drawRect.minY + CGFloat((coordinate.latitude - minLat) / latSpan) * drawRect.height
      return CGPoint(x: x, y: y)
    }

    let path = CGMutablePath()
    for (index, item) in displayRoute.enumerated() {
      let p = point(for: item.coordinate)
      if index == 0 {
        path.move(to: p)
      } else {
        path.addLine(to: p)
      }
    }
    context.setStrokeColor(CGColor(red: 0.22, green: 0.58, blue: 1, alpha: 0.95))
    context.setLineWidth(max(3, CGFloat(TelemetryRouteStyle.lineWidth(latitudeDelta: latSpan, longitudeDelta: lonSpan))))
    context.addPath(path)
    context.strokePath()

    let current = TelemetryRouteReplay(route: route).frame(at: currentSeconds)
    let p = point(for: current.coordinate)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    context.fillEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
  }

  static func drawText(
    _ text: String,
    in rect: CGRect,
    context: CGContext,
    canvasHeight: CGFloat,
    size: CGFloat,
    color: CGColor
  ) {
    // Export rendering runs on a background queue. CoreText is safe there;
    // AppKit attributed-string drawing can crash while resolving font attributes.
    // The pixel-buffer context is already y-up, so no coordinate flip is needed.
    context.saveGState()
    context.textMatrix = .identity
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: color
      ]
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: rect, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
    CTFrameDraw(frame, context)
    context.restoreGState()
  }

  private static func drawSymbol(
    _ name: String,
    in rect: CGRect,
    context: CGContext,
    color: CGColor
  ) {
    #if canImport(AppKit)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    image.isTemplate = true
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (NSColor(cgColor: color) ?? .white).set()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.88)
    NSGraphicsContext.restoreGraphicsState()
    #endif
  }
}

nonisolated private enum PassthroughMovieMuxer {
  struct Cancelled: Error {}

  private struct SourceTrack {
    let track: AVAssetTrack
    let preferredTransform: CGAffineTransform
  }

  static func export(
    plan: ExportPlan,
    shouldCancel: @escaping () -> Bool,
    progress: @escaping (Double) -> Void
  ) throws {
    let completionState = Mutex((didFinish: false, result: Optional<Result<Void, Error>>.none))
    let exportTask = Task.detached(priority: .userInitiated) {
      do {
        try await exportAsync(plan: plan, shouldCancel: shouldCancel, progress: progress)
        completionState.withLock {
          $0.result = .success(())
          $0.didFinish = true
        }
      } catch {
        completionState.withLock {
          $0.result = .failure(error)
          $0.didFinish = true
        }
      }
    }

    defer {
      exportTask.cancel()
    }

    while true {
      let finished = completionState.withLock { $0.didFinish }
      if finished {
        break
      }
      if shouldCancel() {
        exportTask.cancel()
        throw Cancelled()
      }
      progress(0.65)
      Thread.sleep(forTimeInterval: 0.05)
    }

    let result = completionState.withLock { $0.result }

    switch result {
    case .success:
      progress(1)
    case .failure(let error):
      if (error as NSError).code == NSUserCancelledError || shouldCancel() {
        throw Cancelled()
      }
      throw error
    case nil:
      throw NSError(domain: "TeslaCam", code: 16, userInfo: [NSLocalizedDescriptionKey: "Passthrough export did not complete."])
    }
  }

  private static func exportAsync(
    plan: ExportPlan,
    shouldCancel: @escaping () -> Bool,
    progress: @escaping (Double) -> Void
  ) async throws {
    if FileManager.default.fileExists(atPath: plan.outputURL.path) {
      try FileManager.default.removeItem(at: plan.outputURL)
    }

    let composition = AVMutableComposition()
    var tracksByCamera: [Camera: AVMutableCompositionTrack] = [:]
    let orderedCameras = Camera.mixedOrder.filter { plan.enabledCameras.contains($0) }
    var renderCursor = CMTime.zero
    var insertedSegmentCount = 0

    for (index, set) in plan.sets.enumerated() {
      if shouldCancel() {
        throw Cancelled()
      }

      let segmentStartDate = max(set.date, plan.trimStartDate)
      let segmentEndDate = min(set.endDate, plan.trimEndDate)
      let segmentDurationSeconds = segmentEndDate.timeIntervalSince(segmentStartDate)
      guard segmentDurationSeconds > 0 else { continue }

      let sourceStartSeconds = max(0, segmentStartDate.timeIntervalSince(set.date))
      for camera in orderedCameras {
        guard let url = set.file(for: camera) else { continue }
        let cameraDuration = set.duration(for: camera) ?? set.duration
        let availableDuration = max(0, cameraDuration - sourceStartSeconds)
        let durationSeconds = min(segmentDurationSeconds, availableDuration)
        guard durationSeconds > 0 else { continue }

        let asset = AVURLAsset(url: url)
        guard let source = await loadFirstVideoTrack(from: asset) else { continue }
        let compositionTrack: AVMutableCompositionTrack
        if let existing = tracksByCamera[camera] {
          compositionTrack = existing
        } else {
          guard let created = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
          ) else {
            throw NSError(domain: "TeslaCam", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to create passthrough video track."])
          }
          created.preferredTransform = source.preferredTransform
          tracksByCamera[camera] = created
          compositionTrack = created
        }

        let timeRange = CMTimeRange(
          start: CMTime(seconds: sourceStartSeconds, preferredTimescale: 600),
          duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )
        try compositionTrack.insertTimeRange(timeRange, of: source.track, at: renderCursor)
        insertedSegmentCount += 1
      }

      renderCursor = renderCursor + CMTime(seconds: segmentDurationSeconds, preferredTimescale: 600)
      progress(Double(index + 1) / Double(max(1, plan.sets.count)) * 0.35)
    }

    guard insertedSegmentCount > 0 else {
      throw NSError(domain: "TeslaCam", code: 13, userInfo: [NSLocalizedDescriptionKey: "No readable source video tracks were available for passthrough export."])
    }

    guard let exportSession = AVAssetExportSession(
      asset: composition,
      presetName: AVAssetExportPresetPassthrough
    ) else {
      throw NSError(domain: "TeslaCam", code: 14, userInfo: [NSLocalizedDescriptionKey: "Passthrough export is not available for this composition."])
    }

    exportSession.shouldOptimizeForNetworkUse = false

    do {
      try await exportSession.export(to: plan.outputURL, as: .mov)
    } catch {
      if (error as NSError).code == NSUserCancelledError || shouldCancel() {
        throw Cancelled()
      }
      throw error
    }
    if shouldCancel() {
      exportSession.cancelExport()
      throw Cancelled()
    }
    progress(1)
  }

  private static func loadFirstVideoTrack(from asset: AVURLAsset) async -> SourceTrack? {
    do {
      guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
      let transform = try await track.load(.preferredTransform)
      return SourceTrack(track: track, preferredTransform: transform)
    } catch {
      return nil
    }
  }
}

private final class NativeMovieWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor

  init(outputURL: URL, size: CGSize, preset: ExportPreset, frameRate: Double = 30.0) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    writer = try AVAssetWriter(outputURL: outputURL, fileType: preset.defaultExtension == "mov" ? .mov : .mp4)

    let codec: AVVideoCodecType
    let compression: [String: Any]
    let requiresHardwareEncoder: Bool
    switch preset {
    case .originalTracksMOV:
      throw NSError(domain: "TeslaCam", code: 17, userInfo: [NSLocalizedDescriptionKey: "Original Tracks MOV uses passthrough export, not the native frame writer."])
    case .editFriendlyProRes:
      codec = .proRes422HQ
      compression = preset.nativeCompressionProperties(for: size, frameRate: frameRate)
      requiresHardwareEncoder = false
    case .maxQualityHEVC, .fastHEVC, .socialShareHEVC, .proxyHEVC:
      codec = .hevc
      compression = preset.nativeCompressionProperties(for: size, frameRate: frameRate)
      requiresHardwareEncoder = true
    case .maxQualityH264:
      codec = .h264
      compression = preset.nativeCompressionProperties(for: size, frameRate: frameRate)
      requiresHardwareEncoder = true
    }

    var settings: [String: Any] = [
      AVVideoCodecKey: codec.rawValue,
      AVVideoWidthKey: Int(size.width.rounded(.up)),
      AVVideoHeightKey: Int(size.height.rounded(.up)),
      // Tag the output as Rec.709 SDR. The composited frames are sRGB-ish BGRA;
      // without explicit color properties the HEVC/ProRes stream is untagged
      // and players guess, producing washed-out or oversaturated playback.
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
      ]
    ]
    if !compression.isEmpty {
      settings[AVVideoCompressionPropertiesKey] = compression
    }
    #if os(macOS)
    if requiresHardwareEncoder {
      settings[AVVideoEncoderSpecificationKey] = Self.hardwareEncoderSpecification()
    }
    #endif

    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferWidthKey as String: Int(size.width.rounded(.up)),
        kCVPixelBufferHeightKey as String: Int(size.height.rounded(.up))
      ]
    )

    guard writer.canAdd(input) else {
      throw NSError(domain: "TeslaCam", code: 5, userInfo: [NSLocalizedDescriptionKey: "Writer cannot accept video input."])
    }
    writer.add(input)
  }

  private static func hardwareEncoderSpecification() -> [String: Any] {
    var specification: [String: Any] = [
      kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
    ]
    #if !targetEnvironment(simulator)
    specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
    #endif
    return specification
  }

  func start() throws {
    guard writer.startWriting() else {
      throw NSError(domain: "TeslaCam", code: 6, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Failed to start writer."])
    }
    writer.startSession(atSourceTime: .zero)
  }

  @discardableResult
  func append(buffer: CVPixelBuffer, at time: CMTime) throws -> TimeInterval {
    let waitStarted = ContinuousClock.now
    var waited = false
    while !input.isReadyForMoreMediaData {
      if writer.status == .failed || writer.status == .cancelled {
        throw NSError(domain: "TeslaCam", code: 7, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Writer stopped before accepting the next frame."])
      }
      waited = true
      Thread.sleep(forTimeInterval: 0.001)
    }
    let waitSeconds = waited ? ExportRenderMetrics.seconds(waitStarted.duration(to: .now)) : 0
    guard adaptor.append(buffer, withPresentationTime: time) else {
      throw NSError(domain: "TeslaCam", code: 7, userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "Failed to append frame."])
    }
    return waitSeconds
  }

  func finishWriting() throws {
    input.markAsFinished()
    let group = DispatchGroup()
    group.enter()
    var finishError: Error?
    writer.finishWriting {
      finishError = self.writer.error
      group.leave()
    }
    group.wait()
    if let finishError {
      throw finishError
    }
  }

  /// Tears the writer down on failure, releasing the encoder session and
  /// discarding the incomplete file. Safe to call from any state.
  func cancel() {
    if writer.status == .writing {
      writer.cancelWriting()
    }
  }
}
