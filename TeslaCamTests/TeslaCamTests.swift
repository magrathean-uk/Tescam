//
//  TeslaCamTests.swift
//  TeslaCamTests
//
//  Created by Bolyki György on 05/02/2026.
//

import Foundation
import AVFoundation
import CoreVideo
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import TeslaCam

@MainActor
struct TeslaCamTests {

  @Test func exportPresetMappingsRemainStable() async throws {
    #expect(ExportPreset.originalTracksMOV.scriptPreset == "PASSTHROUGH_MOV")
    #expect(ExportPreset.maxQualityHEVC.scriptPreset == "HEVC_CPU_MAX")
    #expect(ExportPreset.maxQualityH264.scriptPreset == "H264_CPU_MAX")
    #expect(ExportPreset.fastHEVC.scriptPreset == "HEVC_MAX")
    #expect(ExportPreset.editFriendlyProRes.scriptPreset == "PRORES_HQ")
    #expect(ExportPreset.originalTracksMOV.defaultExtension == "mov")
    #expect(ExportPreset.maxQualityHEVC.defaultExtension == "mp4")
    #expect(ExportPreset.maxQualityH264.defaultExtension == "mp4")
    #expect(ExportPreset.maxQualityH264.outputLabel == "evidence_h264")
    #expect(ExportPreset.editFriendlyProRes.defaultExtension == "mov")
  }

  @Test func appDefaultsToGridEncodedExport() async throws {
    let state = AppState()
    #expect(state.exportPreset == .maxQualityHEVC)
    #expect(!state.exportOverlayOptions.telemetryHUD)
    #expect(!state.exportOverlayOptions.routeMap)
    #expect(!state.exportOverlayOptions.privacyMask)
    #expect(!state.exportOverlayOptions.needsSidecars)
    #expect(state.effectiveExportPreset == .maxQualityHEVC)
    #expect(state.exportWillReencode)
    #expect(state.exportModeCaption == "Grid export · H.265")
  }

  @Test func defaultGridExportPreflightAcceptsDefaultOptions() async throws {
    let request = exportRequestForPlan(preset: .maxQualityHEVC)
    let plan = try ExportPlan(request: request)
    let preflight = ExportPreflight(fileAccess: StubExportPreflightFileAccess(canWrite: true, availableCapacity: Int64.max))

    let summary = preflight.summary(for: plan)

    #expect(summary.canExport)
  }

  @Test func manualCodecChoiceControlsEffectiveExportPreset() async throws {
    let state = AppState()
    #expect(state.effectiveExportPreset == .maxQualityHEVC)

    state.exportPreset = .maxQualityH264
    #expect(state.effectiveExportPreset == .maxQualityH264)

    state.exportOverlayOptions.telemetryHUD = true
    #expect(state.effectiveExportPreset == .maxQualityH264)

    state.exportPreset = .originalTracksMOV
    #expect(state.effectiveExportPreset == .maxQualityHEVC)

    state.exportOverlayOptions.telemetryHUD = false
    #expect(state.effectiveExportPreset == .originalTracksMOV)
  }

  @Test func renderedPresetResolutionUpdatesOutputExtension() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let state = AppState()
    state.exportOverlayOptions.routeMap = true

    let resolved = state.resolvedExportURL(forTesting: root.url.appendingPathComponent("manual-export.mov"))

    #expect(resolved.lastPathComponent == "manual-export.mp4")
  }

  @Test func videoCodecMapsFromMediaSubType() async throws {
    #expect(VideoCodec(mediaSubType: kCMVideoCodecType_HEVC) == .hevc)
    #expect(VideoCodec(mediaSubType: kCMVideoCodecType_H264) == .h264)
    #expect(VideoCodec(mediaSubType: kCMVideoCodecType_AppleProRes422) == .other)
    #expect(VideoCodec.hevc.displayName == "H.265")
    #expect(VideoCodec.h264.displayName == "H.264")
  }

  @Test func manualTrimClockInputParsesAndClamps() async throws {
    let state = AppState()
    state.clipSets = [
      ClipSet(
        timestamp: "a",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 600,
        files: [.front: URL(fileURLWithPath: "/tmp/front.mov")]
      )
    ]
    state.rebuildTimelineForTesting()

    #expect(state.applyTrimStartInput("00:01:30"))
    #expect(abs(state.trimStartSeconds - 90) < 0.001)

    #expect(state.applyTrimEndInput("00:08:45"))
    #expect(abs(state.trimEndSeconds - 525) < 0.001)

    #expect(state.applyTrimEndInput("99:00:00"))
    #expect(abs(state.trimEndSeconds - 600) < 0.001)

    #expect(!state.applyTrimStartInput("banana"))
  }

  @Test func cameraTrackResolvesLatestCutAtTimelineSecond() async throws {
    let track = CameraTrack(
      keyframes: [
        CameraTrackKeyframe(seconds: 10, camera: .front),
        CameraTrackKeyframe(seconds: 20, camera: .back),
        CameraTrackKeyframe(seconds: 15, camera: .left_repeater)
      ]
    )

    #expect(track.camera(at: 9.99) == nil)
    #expect(track.camera(at: 10) == .front)
    #expect(track.camera(at: 16) == .left_repeater)
    #expect(track.camera(at: 25) == .back)
    #expect(track.normalized.keyframes.map(\.seconds) == [10, 15, 20])
  }

  @Test func exportRequestCarriesCameraTrackAndPreviewFlag() async throws {
    let track = CameraTrack(keyframes: [CameraTrackKeyframe(seconds: 4, camera: .front)])
    let request = exportRequestForPlan(cameraTrack: track, isPreviewSample: true)

    #expect(request.cameraTrack == track.normalized)
    #expect(request.isPreviewSample)
  }

  @Test func telemetryTimelineBuildsEventMarkers() async throws {
    var first = SeiMetadata()
    first.brakeApplied = true
    first.blinkerLeft = true
    var second = SeiMetadata()
    second.acceleratorPedalPosition = 80
    second.steeringWheelAngle = -52
    second.autopilotState = .autosteer
    second.linearAccelX = 0.7
    second.linearAccelY = 0.8
    let timeline = TelemetryTimeline(
      frames: [
        TelemetryFrame(timestampMs: 0, sei: first),
        TelemetryFrame(timestampMs: 1100, sei: second)
      ]
    )

    let kinds = Set(TelemetryEventMarker.markers(from: timeline).map(\.kind))

    #expect(kinds.contains(.brake))
    #expect(kinds.contains(.leftBlinker))
    #expect(kinds.contains(.accelerator))
    #expect(kinds.contains(.steering))
    #expect(kinds.contains(.autopilot))
    #expect(kinds.contains(.gForce))
  }

  @Test func layoutPresetRoundTripsCameraTrackAndOverlayOptions() async throws {
    let preset = CustomLayoutPreset(
      name: "Evidence",
      layoutRequest: .sixcam,
      previewLayoutMode: .focus,
      focusedCamera: .front,
      overlayOptions: ExportOverlayOptions(
        telemetryHUD: true,
        routeMap: true,
        privacyMask: false,
        includeReport: true,
        includeScreenshot: true,
        telemetryHUDMode: .minimal,
        speedUnit: .milesPerHour
      ),
      cameraTrack: CameraTrack(keyframes: [CameraTrackKeyframe(seconds: 12, camera: .back)])
    )

    let data = try CustomLayoutPresetCodec.encode(preset)
    let decoded = try CustomLayoutPresetCodec.decode(data)

    #expect(decoded == preset)
  }

  @Test func exportOverlayOptionsDecodeLegacyPresetDefaults() async throws {
    let json = """
    {
      "telemetryHUD": true,
      "routeMap": true,
      "privacyMask": false,
      "includeReport": true,
      "includeScreenshot": false
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(ExportOverlayOptions.self, from: json)

    #expect(decoded.telemetryHUD)
    #expect(decoded.routeMap)
    #expect(decoded.telemetryHUDMode == .detailed)
    #expect(decoded.speedUnit == .kilometersPerHour)
  }

  @Test func telemetryDisplayModelFormatsSpeedUnits() async throws {
    var metadata = SeiMetadata()
    metadata.vehicleSpeedMps = 10

    let model = TelemetryDisplayModel(sei: metadata)

    #expect(model.speedText(unit: .kilometersPerHour) == "36.0 km/h")
    #expect(model.speedText(unit: .milesPerHour) == "22.4 mph")
  }

  @Test func telemetryProcessorFormatsDetailedDriveData() async throws {
    var metadata = SeiMetadata()
    metadata.vehicleSpeedMps = 13.4
    metadata.acceleratorPedalPosition = 42
    metadata.steeringWheelAngle = -12
    metadata.gearState = .drive
    metadata.autopilotState = .tacc
    metadata.brakeApplied = true
    metadata.blinkerLeft = true
    metadata.headingDeg = 271.5
    metadata.latitudeDeg = 51.5074
    metadata.longitudeDeg = -0.1278
    metadata.linearAccelX = 0.12
    metadata.linearAccelY = -0.34
    metadata.linearAccelZ = 0.98

    let text = TelemetryProcessor.formatTelemetryDetailed(metadata, unit: .milesPerHour)

    #expect(text.contains("Speed: 30.0 mph"))
    #expect(text.contains("Gear: D"))
    #expect(text.contains("AP: TACC"))
    #expect(text.contains("Brake: On"))
    #expect(text.contains("Signal: Left"))
    #expect(text.contains("Heading: 272 deg"))
    #expect(text.contains("GPS: 51.50740, -0.12780"))
    #expect(text.contains("G: 0.12/-0.34/0.98"))
  }

  @Test func compactControlsStayVisuallySmallButKeepTouchTargets() async throws {
    #expect(TeslaCamTheme.Metrics.cardCorner == 10)
    #expect(TeslaCamTheme.Metrics.controlCorner == 7)
    #expect(TeslaCamTheme.Metrics.compactCorner == 7)
    #expect(CompactControlSize.command.visualHeight == TeslaCamTheme.Metrics.compactControlHeight)
    #expect(CompactControlSize.command.maxWidth == 152)
    #expect(CompactControlSize.chip.visualHeight == TeslaCamTheme.Metrics.compactControlHeight)
    #expect(CompactControlSize.icon.visualWidth == TeslaCamTheme.Metrics.compactControlHeight)

    for size in CompactControlSize.allCases {
      #expect(size.hitTargetHeight >= 44)
      #expect(size.hitTargetWidth >= 44)
    }
  }

  @Test @MainActor func demoModeLoadsSampleTimelineWithoutSourceFiles() async throws {
    let state = AppState()

    state.loadDemoTimeline()

    #expect(state.sourceURLs.isEmpty)
    #expect(state.clipSets.count == 3)
    #expect(state.totalDuration > 0)
    #expect(state.camerasDetected.contains(.front))
    #expect(state.eventSummaries.count == state.clipSets.count)
    #expect(state.telemetryModel != nil)
    #expect(state.telemetryRoute.count == state.clipSets.count)
  }

  #if os(macOS)
  @Test @MainActor func rootViewRendersOnboardingOffscreenAtDesktopSize() async throws {
    let state = AppState()

    let snapshot = try renderContentViewSnapshot(state: state, size: CGSize(width: 1100, height: 760))

    #expect(snapshot.pixelsWide >= 1100)
    #expect(snapshot.pixelsHigh >= 760)
    #expect(snapshotHasVisibleContent(snapshot))
  }

  @Test @MainActor func rootViewRendersLoadedDemoWorkspaceOffscreenAtDesktopSize() async throws {
    let state = AppState()
    state.loadDemoTimeline()

    let snapshot = try renderContentViewSnapshot(state: state, size: CGSize(width: 1400, height: 900))

    #expect(snapshot.pixelsWide >= 1400)
    #expect(snapshot.pixelsHigh >= 900)
    #expect(snapshotHasVisibleContent(snapshot))
  }
  #endif

  @Test func nativeHEVCBitrateScalesWithCanvasSize() async throws {
    let hd = CGSize(width: 1920, height: 1080)
    let hw4 = CGSize(width: 5760, height: 2160)

    let hdMax = ExportPreset.maxQualityHEVC.nativeCompressionProperties(for: hd)[AVVideoAverageBitRateKey] as? Int
    let hw4Max = ExportPreset.maxQualityHEVC.nativeCompressionProperties(for: hw4)[AVVideoAverageBitRateKey] as? Int
    let hdFast = ExportPreset.fastHEVC.nativeCompressionProperties(for: hd)[AVVideoAverageBitRateKey] as? Int
    let hw4Fast = ExportPreset.fastHEVC.nativeCompressionProperties(for: hw4)[AVVideoAverageBitRateKey] as? Int

    #expect(hdMax == 45_000_000)
    #expect(hdFast == 20_000_000)
    #expect((hw4Max ?? 0) > (hdMax ?? 0))
    #expect((hw4Fast ?? 0) > (hdFast ?? 0))
  }

  @Test func exportPlanValidatesTrimRangeAndEnabledCameras() async throws {
    let emptyRange = exportRequestForPlan(
      enabledCameras: [.front],
      trimStart: Date(timeIntervalSince1970: 100),
      trimEnd: Date(timeIntervalSince1970: 100)
    )
    #expect(throws: ExportPlan.ValidationError.emptyTrimRange) {
      try ExportPlan(request: emptyRange)
    }

    let noCameras = exportRequestForPlan(enabledCameras: [])
    #expect(throws: ExportPlan.ValidationError.noEnabledCameras) {
      try ExportPlan(request: noCameras)
    }
  }

  @Test func exportPreflightWarnsWhenFreeDiskSpaceCannotBeChecked() async throws {
    // ExportPreflight.summary surfaces a non-blocking warning when the
    // file-access adapter can't determine free disk space (returns
    // nil). Without this safety net, the user might see no disk-space
    // information at all when the OS hides volume capacity (e.g. some
    // network mounts). The other two warning channels are already
    // covered (partial-clip d66432d, hidden-cameras 0c5127b); this
    // closes the third.
    let plan = try ExportPlan(
      request: exportRequestForPlan(enabledCameras: [.front])
    )
    let preflight = ExportPreflight(
      fileAccess: StubExportPreflightFileAccess(canWrite: true, availableCapacity: nil)
    )
    let summary = preflight.summary(for: plan)

    let diskUnknownWarnings = summary.warnings.filter { warning in
      warning.message.lowercased().contains("disk") &&
        warning.message.lowercased().contains("could not be checked")
    }
    #expect(!diskUnknownWarnings.isEmpty, "preflight must surface a 'disk space could not be checked' warning when capacity is nil")
    for warning in diskUnknownWarnings {
      #expect(!warning.isBlocking, "disk-unknown warning is informational; export still proceeds")
    }
    // hasWriteAccess must remain true (the write-access channel is
    // separate from the capacity channel) so we don't accidentally
    // double-fire as a blocking issue here.
    #expect(summary.hasWriteAccess)
  }

  @Test func exportPreflightWarnsAboutHiddenCamerasWhenSomeFilesAreNotEnabled() async throws {
    // ExportPreflight surfaces a non-blocking warning when a clip set
    // contains cameras the user has not enabled — they'll render as
    // black tiles rather than silently dropping out of the layout.
    // Build a request with three cameras present in files but only
    // `.front` enabled; assert the warning message names the hidden
    // cameras using their display names.
    let trimStart = Date(timeIntervalSince1970: 200)
    let trimEnd = Date(timeIntervalSince1970: 260)
    let request = ExportRequest(
      sets: [
        ClipSet(
          timestamp: "sample",
          date: trimStart,
          duration: 60,
          files: [
            .front: URL(fileURLWithPath: "/tmp/front.mov"),
            .back: URL(fileURLWithPath: "/tmp/back.mov"),
            .left_repeater: URL(fileURLWithPath: "/tmp/left.mov"),
          ],
          cameraDurations: [.front: 60, .back: 60, .left_repeater: 60],
          naturalSizes: [
            .front: CGSize(width: 1280, height: 960),
            .back: CGSize(width: 1280, height: 960),
            .left_repeater: CGSize(width: 1280, height: 960),
          ]
        )
      ],
      outputURL: URL(fileURLWithPath: "/tmp/teslacam-hidden.mov"),
      useSixCam: false,
      preset: .maxQualityHEVC,
      enabledCameras: [.front],
      trimStartSeconds: 0,
      trimEndSeconds: 60,
      trimStartDate: trimStart,
      trimEndDate: trimEnd,
      selectedRangeText: "sample",
      partialClipCount: 0,
      cameraTrack: .empty,
      isPreviewSample: false
    )
    let plan = try ExportPlan(request: request)
    let preflight = ExportPreflight(
      fileAccess: StubExportPreflightFileAccess(canWrite: true, availableCapacity: Int64.max)
    )
    let summary = preflight.summary(for: plan)

    let hiddenWarnings = summary.warnings.filter { warning in
      warning.message.contains("Hidden cameras")
    }
    #expect(!hiddenWarnings.isEmpty, "preflight must surface a 'Hidden cameras' warning when present cameras are not enabled")
    for warning in hiddenWarnings {
      #expect(!warning.isBlocking, "hidden-cameras warning is informational; export still ships with black tiles")
      // Display names of the hidden cameras should appear in the message.
      #expect(warning.message.contains(Camera.back.displayName), "warning text must name the hidden Back camera")
      #expect(warning.message.contains(Camera.left_repeater.displayName), "warning text must name the hidden Left repeater camera")
      // The enabled camera must NOT show up as 'hidden'.
      #expect(!warning.message.contains("\(Camera.front.displayName),") && !warning.message.hasSuffix(Camera.front.displayName + "."),
              "warning text must not list Front (the enabled camera) as hidden")
    }
  }

  @Test func exportPreflightWarnsAboutPartialClipsWhenRequestCarriesPartialCount() async throws {
    // ExportPlan carries partialClipCount through from the request;
    // ExportPreflight must surface a non-blocking warning that calls
    // out the count so the export status UI shows the user that some
    // clip spans will render with black placeholders. The current
    // tests cover preflight access + canvas + disk gates but never
    // exercise the partial-clip warning channel.
    let trimStart = Date(timeIntervalSince1970: 100)
    let trimEnd = Date(timeIntervalSince1970: 160)
    let request = ExportRequest(
      sets: [
        ClipSet(
          timestamp: "sample",
          date: trimStart,
          duration: 60,
          files: [.front: URL(fileURLWithPath: "/tmp/front.mov")],
          cameraDurations: [.front: 60],
          naturalSizes: [.front: CGSize(width: 1280, height: 960)]
        )
      ],
      outputURL: URL(fileURLWithPath: "/tmp/teslacam-partial.mov"),
      useSixCam: false,
      preset: .maxQualityHEVC,
      enabledCameras: [.front],
      trimStartSeconds: 0,
      trimEndSeconds: 60,
      trimStartDate: trimStart,
      trimEndDate: trimEnd,
      selectedRangeText: "sample",
      partialClipCount: 2,
      cameraTrack: .empty,
      isPreviewSample: false
    )
    let plan = try ExportPlan(request: request)
    let preflight = ExportPreflight(
      fileAccess: StubExportPreflightFileAccess(canWrite: true, availableCapacity: Int64.max)
    )
    let summary = preflight.summary(for: plan)

    let partialWarnings = summary.warnings.filter { warning in
      warning.message.contains("2") && warning.message.lowercased().contains("missing")
    }
    #expect(!partialWarnings.isEmpty, "preflight should surface a non-blocking warning that mentions the partial-clip count + 'missing'")
    for warning in partialWarnings {
      #expect(!warning.isBlocking, "partial-clip warning must be non-blocking — exports still ship with black placeholders")
    }
  }

  @Test func exportPlanRejectsRequestWithNoClips() async throws {
    // The exportRequestForPlan helper hard-codes a single-clip set so
    // the default path always has clips. Build a no-clip request
    // inline to cover the .noClips ValidationError variant — the only
    // ExportPlan error case the existing combined test does not
    // exercise.
    // Mirror exportRequestForPlan's argument list but with sets: []. Skips
    // the overlayOptions / layoutRequest fields so the helper's defaults
    // apply, exactly as the existing combined test does.
    let noClips = ExportRequest(
      sets: [],
      outputURL: URL(fileURLWithPath: "/tmp/teslacam-noclips.mov"),
      useSixCam: false,
      preset: .maxQualityHEVC,
      enabledCameras: [.front],
      trimStartSeconds: 0,
      trimEndSeconds: 60,
      trimStartDate: Date(timeIntervalSince1970: 0),
      trimEndDate: Date(timeIntervalSince1970: 60),
      selectedRangeText: "sample",
      partialClipCount: 0,
      cameraTrack: .empty,
      isPreviewSample: false
    )
    #expect(throws: ExportPlan.ValidationError.noClips) {
      try ExportPlan(request: noClips)
    }
  }

  @Test func exportPlanValidationErrorsCarryHumanDescription() async throws {
    // Every ValidationError case must carry a non-empty
    // LocalizedError.errorDescription so the surfaced UI / status
    // text is never blank when ExportPlan rejects a request. The
    // strings themselves can change, but they must not be nil or
    // empty.
    let cases: [ExportPlan.ValidationError] = [
      .noClips,
      .emptyTrimRange,
      .noEnabledCameras,
      .invalidCanvas,
    ]
    for variant in cases {
      let description = (variant as LocalizedError).errorDescription
      #expect(description != nil, "ValidationError.\(variant) must carry an errorDescription")
      #expect(!(description ?? "").isEmpty, "ValidationError.\(variant) errorDescription must be non-empty")
    }
  }

  @Test func exportPlanCapturesHw4CanvasWithoutDownscaling() async throws {
    let size = CGSize(width: 1920, height: 1080)
    let cameras = Set(Camera.hw4SixCamOrder)
    let request = exportRequestForPlan(
      useSixCam: true,
      enabledCameras: cameras,
      files: Dictionary(uniqueKeysWithValues: cameras.map { ($0, URL(fileURLWithPath: "/tmp/\($0.rawValue).mov")) }),
      naturalSizes: Dictionary(uniqueKeysWithValues: cameras.map { ($0, size) })
    )

    let plan = try ExportPlan(request: request)

    #expect(plan.canvasSize == CGSize(width: 5760, height: 2160))
    #expect(plan.tileSize == size)
    #expect(plan.cameraOrder == Camera.hw4SixCamOrder)
    #expect(plan.totalDuration == request.totalDuration)
  }

  @Test func exportPreflightReportsAccessAndDiskProblemsThroughAdapter() async throws {
    let request = exportRequestForPlan()
    let plan = try ExportPlan(request: request)
    let preflight = ExportPreflight(
      fileAccess: StubExportPreflightFileAccess(
        canWrite: false,
        availableCapacity: 1
      )
    )

    let summary = preflight.summary(for: plan)

    #expect(!summary.canExport)
    #expect(summary.blockingIssues.contains { $0.message == "The selected export location is not writable." })
    #expect(summary.blockingIssues.contains { $0.message.contains("Export preflight requires at least") })
  }

  @Test func exportPreflightEstimatesRecordedClipDurationForSparseTimeline() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let later = start.addingTimeInterval(15 * 24 * 60 * 60)
    let sets = [
      ClipSet(
        timestamp: "first",
        date: start,
        duration: 60,
        files: [.front: URL(fileURLWithPath: "/tmp/first-front.mov")],
        cameraDurations: [.front: 60],
        naturalSizes: [.front: CGSize(width: 1920, height: 1080)]
      ),
      ClipSet(
        timestamp: "second",
        date: later,
        duration: 60,
        files: [.front: URL(fileURLWithPath: "/tmp/second-front.mov")],
        cameraDurations: [.front: 60],
        naturalSizes: [.front: CGSize(width: 1920, height: 1080)]
      )
    ]
    let request = ExportRequest(
      sets: sets,
      outputURL: URL(fileURLWithPath: "/tmp/sparse.mov"),
      useSixCam: false,
      preset: .editFriendlyProRes,
      enabledCameras: [.front],
      trimStartSeconds: 0,
      trimEndSeconds: later.addingTimeInterval(60).timeIntervalSince(start),
      trimStartDate: start,
      trimEndDate: later.addingTimeInterval(60),
      selectedRangeText: "sparse",
      partialClipCount: 0
    )
    let plan = try ExportPlan(request: request)
    let preflight = ExportPreflight(
      fileAccess: StubExportPreflightFileAccess(
        canWrite: true,
        availableCapacity: 272 * 1024 * 1024 * 1024
      )
    )

    let summary = preflight.summary(for: plan)

    #expect(plan.totalDuration > 15 * 24 * 60 * 60)
    #expect(abs(plan.renderDuration - 120) < 0.001)
    #expect(summary.canExport)
  }

  @Test func exportPreflightBlocksOversizedHevcCanvasButAllowsProRes() async throws {
    let cameras: Set<Camera> = [.front]
    let oversized = CGSize(width: 9000, height: 2400)
    let hevcPlan = try ExportPlan(
      request: exportRequestForPlan(
        preset: .fastHEVC,
        enabledCameras: cameras,
        files: [.front: URL(fileURLWithPath: "/tmp/front.mov")],
        naturalSizes: [.front: oversized]
      )
    )
    let proResPlan = try ExportPlan(
      request: exportRequestForPlan(
        preset: .editFriendlyProRes,
        enabledCameras: cameras,
        files: [.front: URL(fileURLWithPath: "/tmp/front.mov")],
        naturalSizes: [.front: oversized]
      )
    )
    let preflight = ExportPreflight(fileAccess: StubExportPreflightFileAccess(canWrite: true, availableCapacity: Int64.max))

    let hevc = preflight.summary(for: hevcPlan)
    let proRes = preflight.summary(for: proResPlan)

    let width = Int(hevcPlan.canvasSize.width.rounded(.up))
    let height = Int(hevcPlan.canvasSize.height.rounded(.up))
    #expect(hevc.blockingIssues.map(\.message) == [
      "Composite canvas \(width)×\(height) exceeds the hardware HEVC encoder ceiling (8192 px per side). Reduce enabled cameras or switch to ProRes preset."
    ])
    #expect(proRes.canExport)
  }

  @Test func nativeExportPublishesPreflightBlockAsStatus() async throws {
    let controller = NativeExportController()
    let request = exportRequestForPlan(enabledCameras: [])

    controller.export(request: request)

    #expect(controller.currentJob?.phase == .failed)
    #expect(controller.currentJob?.failureReason == "Select at least one camera to export.")
    #expect(controller.isStatusPresented)
  }

  @Test func exportQueueStartsNextRequestWhenIdle() async throws {
    let controller = NativeExportController()
    let request = exportRequestForPlan(enabledCameras: [])

    controller.enqueue(request: request)

    #expect(controller.queuedRequests.isEmpty)
    #expect(controller.currentJob?.phase == .failed)
    #expect(controller.currentJob?.request.id == request.id)
  }

  @Test func preflightWriteCheckDoesNotMutateExistingOutputFile() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let output = root.url.appendingPathComponent("existing.mp4")
    try Data("original".utf8).write(to: output)

    let access = FileManagerExportPreflightFileAccess()
    #expect(access.canWrite(to: output))
    let data = try Data(contentsOf: output)
    #expect(String(data: data, encoding: .utf8) == "original")
  }

  @Test func preflightWriteCheckAllowsChosenNonExistingOutputFile() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let output = root.url.appendingPathComponent("new-export.mp4")

    let access = FileManagerExportPreflightFileAccess()
    #expect(access.canWrite(to: output))
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func healthSummaryMixedCoverageFlagReflectsCounts() async throws {
    let summary = ExportHealthSummary(
      totalMinutes: 12,
      gapCount: 1,
      partialSetCount: 2,
      fourCameraSetCount: 4,
      sixCameraSetCount: 8,
      missingCameraCounts: [.right_pillar: 2]
    )

    #expect(summary.hasMixedCoverage)
    #expect(summary.missingCoverageSummary.contains("Right Pillar: 2"))
  }

  @Test func exportRequestTracksRealTotalDuration() async throws {
    let request = ExportRequest(
      sets: [
        ClipSet(timestamp: "a", date: Date(timeIntervalSince1970: 100), duration: 2, files: [:]),
        ClipSet(timestamp: "b", date: Date(timeIntervalSince1970: 200), duration: 63, files: [:])
      ],
      outputURL: URL(fileURLWithPath: "/tmp/test.mov"),
      useSixCam: false,
      preset: .maxQualityHEVC,
      enabledCameras: [.front],
      trimStartSeconds: 0,
      trimEndSeconds: 65,
      trimStartDate: Date(timeIntervalSince1970: 100),
      trimEndDate: Date(timeIntervalSince1970: 165),
      selectedRangeText: "range",
      partialClipCount: 0
    )

    #expect(request.totalParts == 2)
    #expect(abs(request.totalDuration - 65) < 0.001)
  }

  @Test func exportSnapshotDetailUsesRealDurationProgress() async throws {
    let request = ExportRequest(
      sets: [
        ClipSet(timestamp: "a", date: Date(timeIntervalSince1970: 100), duration: 125, files: [:])
      ],
      outputURL: URL(fileURLWithPath: "/tmp/test.mov"),
      useSixCam: false,
      preset: .maxQualityHEVC,
      enabledCameras: [.front],
      trimStartSeconds: 0,
      trimEndSeconds: 125,
      trimStartDate: Date(timeIntervalSince1970: 100),
      trimEndDate: Date(timeIntervalSince1970: 225),
      selectedRangeText: "range",
      partialClipCount: 0
    )

    let snapshot = ExportJobSnapshot(
      id: UUID(),
      request: request,
      phase: .renderingParts,
      progress: 0.5,
      phaseLabel: "Rendering",
      startedAt: .now,
      finishedAt: nil,
      outputURL: request.outputURL,
      logFileURL: URL(fileURLWithPath: "/tmp/log.txt"),
      workingDirectoryURL: nil,
      failureCategory: nil,
      failureReason: nil,
      completedParts: 0,
      totalParts: request.totalParts,
      completedDuration: 61,
      totalDuration: request.totalDuration,
      isIndeterminate: false,
      isTerminal: false,
      canRevealOutput: false,
      canRevealWorkingFiles: false,
      canRetry: false,
      isCancelled: false
    )

    #expect(snapshot.detailText == "1:01 / 2:05")
  }

  @Test func playbackControllerTracksSharedTimelineWithoutPlayers() async throws {
    let controller = MultiCamPlaybackController()
    let set = ClipSet(
      timestamp: "sample",
      date: Date(timeIntervalSince1970: 100),
      duration: 12,
      files: [:]
    )

    controller.load(set: set, startSeconds: 3.5)
    #expect(abs(controller.currentItemTime().seconds - 3.5) < 0.001)
    let tickAfterLoad = controller.redrawTick

    controller.seek(to: 20)
    #expect(abs(controller.currentItemTime().seconds - 12) < 0.001)
    #expect(controller.redrawTick > tickAfterLoad)
    let tickAfterSeek = controller.redrawTick

    controller.seek(to: 1.25)
    #expect(abs(controller.currentItemTime().seconds - 1.25) < 0.001)
    #expect(controller.redrawTick > tickAfterSeek)
  }

  @Test func playbackControllerProjectsPreviewTimeBetweenUITicks() async throws {
    var hostTime: CFTimeInterval = 100
    let controller = MultiCamPlaybackController(timeProvider: { hostTime })
    let set = ClipSet(
      timestamp: "sample",
      date: Date(timeIntervalSince1970: 100),
      duration: 12,
      files: [:]
    )

    controller.load(set: set)
    controller.play()
    hostTime += 0.05

    #expect(abs(controller.currentItemTime().seconds - 0.05) < 0.005)
    controller.pause()
  }

  @Test func duplicateFilesPreferNewestWhenRequested() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let olderFolder = root.url.appendingPathComponent("folder_a", isDirectory: true)
    let newerFolder = root.url.appendingPathComponent("folder_b", isDirectory: true)
    try FileManager.default.createDirectory(at: olderFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newerFolder, withIntermediateDirectories: true)

    let frontOlder = olderFolder.appendingPathComponent("2026-01-01_00-00-00-front.mp4")
    let frontNewer = newerFolder.appendingPathComponent("2026-01-01_00-00-00-front.mp4")
    let back = olderFolder.appendingPathComponent("2026-01-01_00-00-00-rear.mp4")
    try "older".write(to: frontOlder, atomically: true, encoding: .utf8)
    try "newer".write(to: frontNewer, atomically: true, encoding: .utf8)
    try "back".write(to: back, atomically: true, encoding: .utf8)

    let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newerDate = Date(timeIntervalSince1970: 1_700_000_100)
    try FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: frontOlder.path)
    try FileManager.default.setAttributes([.modificationDate: newerDate], ofItemAtPath: frontNewer.path)

    let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .preferNewest)

    #expect(index.duplicateFileCount == 1)
    #expect(index.sets.count == 1)
    #expect(index.sets[0].file(for: .front)?.lastPathComponent == frontNewer.lastPathComponent)
  }

  @Test func duplicateFilesKeepAllWhenRequested() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let olderFolder = root.url.appendingPathComponent("folder_a", isDirectory: true)
    let newerFolder = root.url.appendingPathComponent("folder_b", isDirectory: true)
    try FileManager.default.createDirectory(at: olderFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newerFolder, withIntermediateDirectories: true)

    let frontOlder = olderFolder.appendingPathComponent("2026-01-01_00-00-00-front.mp4")
    let frontNewer = newerFolder.appendingPathComponent("2026-01-01_00-00-00-front.mp4")
    let back = olderFolder.appendingPathComponent("2026-01-01_00-00-00-rear.mp4")
    try "older".write(to: frontOlder, atomically: true, encoding: .utf8)
    try "newer".write(to: frontNewer, atomically: true, encoding: .utf8)
    try "back".write(to: back, atomically: true, encoding: .utf8)

    let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .keepAll)

    #expect(index.duplicateFileCount == 1)
    #expect(index.sets.count == 2)
    #expect(index.sets.contains { $0.file(for: .front)?.lastPathComponent == frontOlder.lastPathComponent })
    #expect(index.sets.contains { $0.file(for: .front)?.lastPathComponent == frontNewer.lastPathComponent })
  }

  @Test func indexSkipsSymlinkedDirectoriesAndFiles() async throws {
    let root = try TemporaryDirectory.make()
    let external = try TemporaryDirectory.make()
    defer { try? root.remove() }
    defer { try? external.remove() }

    let front = root.url.appendingPathComponent("2026-01-01_00-00-00-front.mp4")
    let externalRear = external.url.appendingPathComponent("2026-01-01_00-00-00-rear.mp4")
    try "front".write(to: front, atomically: true, encoding: .utf8)
    try "rear".write(to: externalRear, atomically: true, encoding: .utf8)

    let linkDir = root.url.appendingPathComponent("linked_dir", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: external.url)
    let linkRear = root.url.appendingPathComponent("2026-01-01_00-00-00-rear.mp4")
    try FileManager.default.createSymbolicLink(at: linkRear, withDestinationURL: externalRear)

    let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .mergeByTime)
    #expect(index.sets.count == 1)
    #expect(index.sets[0].files[.front] != nil)
    #expect(index.sets[0].files[.back] == nil)
  }

  @Test func telemetryParserRejectsMalformedData() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let sample = root.url.appendingPathComponent("bad.mp4")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: sample)

    #expect(throws: Error.self) {
      try TelemetryParser.parseTimeline(url: sample)
    }
  }

  @Test func telemetryParserExtractsTeslaSeiFromMdatWithoutVideoConfig() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let sample = root.url.appendingPathComponent("sei_only.mp4")
    var metadata = SeiMetadata()
    metadata.version = 1
    metadata.gearState = .drive
    metadata.frameSeqNo = 42
    metadata.vehicleSpeedMps = 13.4
    metadata.acceleratorPedalPosition = 18
    metadata.steeringWheelAngle = -2
    metadata.autopilotState = .tacc
    metadata.latitudeDeg = 51.5074
    metadata.longitudeDeg = -0.1278
    metadata.headingDeg = 271.5
    try makeMp4WithTeslaSei(metadata: metadata).write(to: sample)

    let timeline = try TelemetryParser.parseTimeline(url: sample)

    let frame = try #require(timeline.frames.first)
    #expect(timeline.frames.count == 1)
    #expect(frame.sei.version == 1)
    #expect(frame.sei.gearState == .drive)
    #expect(frame.sei.frameSeqNo == 42)
    #expect(abs(frame.sei.vehicleSpeedMps - 13.4) < 0.001)
    #expect(frame.sei.autopilotState == .tacc)
    #expect(abs(frame.sei.latitudeDeg - 51.5074) < 0.000001)
    #expect(abs(frame.sei.longitudeDeg - -0.1278) < 0.000001)
    #expect(abs(frame.sei.headingDeg - 271.5) < 0.000001)
  }

  @Test func telemetryProcessorRoutePointsCollapsesSameSecondAndStationaryFrames() async throws {
    var moving = SeiMetadata()
    moving.latitudeDeg = 51.5
    moving.longitudeDeg = -0.1
    moving.vehicleSpeedMps = 12
    var samePoint = SeiMetadata()
    samePoint.latitudeDeg = 51.5
    samePoint.longitudeDeg = -0.1
    var nextPoint = SeiMetadata()
    nextPoint.latitudeDeg = 51.501
    nextPoint.longitudeDeg = -0.099
    nextPoint.vehicleSpeedMps = 14

    let timeline = TelemetryTimeline(frames: [
      TelemetryFrame(timestampMs: 0, sei: moving),
      TelemetryFrame(timestampMs: 250, sei: moving),     // same whole second → dropped
      TelemetryFrame(timestampMs: 1100, sei: samePoint), // same coordinate → dropped
      TelemetryFrame(timestampMs: 2100, sei: nextPoint)
    ])

    let route = TelemetryProcessor.routePoints(from: timeline)
    #expect(route.count == 2)
    #expect(route[0].coordinate.latitude == 51.5)
    #expect(route[1].coordinate.latitude == 51.501)
  }

  @Test func telemetryRouteReplayInterpolatesFrameBetweenRoutePoints() async throws {
    let route = [
      TelemetryRoutePoint(
        id: 0,
        seconds: 10,
        coordinate: TelemetryCoordinate(latitude: 51.5000, longitude: -0.1000),
        speedKmh: 36,
        headingDeg: 350
      ),
      TelemetryRoutePoint(
        id: 1,
        seconds: 20,
        coordinate: TelemetryCoordinate(latitude: 51.5100, longitude: -0.0900),
        speedKmh: 72,
        headingDeg: 10
      )
    ]

    let frame = TelemetryRouteReplay(route: route).frame(at: 15)

    #expect(abs(frame.coordinate.latitude - 51.5050) < 0.000001)
    #expect(abs(frame.coordinate.longitude - -0.0950) < 0.000001)
    #expect(abs(frame.speedKmh - 54) < 0.000001)
    #expect(abs(frame.headingDeg - 0) < 0.000001)
  }

  @Test func telemetryRouteReplayKeepsEndpointsWhenDecimatingDisplaySamples() async throws {
    let route = (0..<12).map { index in
      TelemetryRoutePoint(
        id: index,
        seconds: Double(index),
        coordinate: TelemetryCoordinate(latitude: 51.5 + Double(index) * 0.001, longitude: -0.1),
        speedKmh: Double(index),
        headingDeg: 0
      )
    }

    let display = TelemetryRouteReplay.displaySamples(from: route, maxPoints: 5)

    #expect(display.count == 5)
    #expect(display.first?.id == 0)
    #expect(display.last?.id == 11)
  }

  @Test func telemetryRouteStyleUsesSpanAwareLineWidthAndStableSignature() async throws {
    #expect(TelemetryRouteStyle.lineWidth(latitudeDelta: 9, longitudeDelta: 1) == 2.0)
    #expect(TelemetryRouteStyle.lineWidth(latitudeDelta: 0.4, longitudeDelta: 0.4) == 4.0)

    let route = [
      TelemetryRoutePoint(
        id: 0,
        seconds: 1.0,
        coordinate: TelemetryCoordinate(latitude: 51.5000001, longitude: -0.1000001),
        speedKmh: 10,
        headingDeg: 90
      ),
      TelemetryRoutePoint(
        id: 1,
        seconds: 2.0,
        coordinate: TelemetryCoordinate(latitude: 51.5000002, longitude: -0.1000002),
        speedKmh: 12,
        headingDeg: 92
      )
    ]

    #expect(TelemetryRouteSignature.route(route) == "1:51.5,-0.1|2:51.5,-0.1")
  }

  @Test func telemetryProcessorDurationStringFormatsHoursAndMinutes() async throws {
    #expect(TelemetryProcessor.durationString(seconds: 0) == "0m total")
    #expect(TelemetryProcessor.durationString(seconds: 540) == "9m total")
    #expect(TelemetryProcessor.durationString(seconds: 3 * 3600 + 7 * 60) == "3h 7m total")
  }

  @Test func telemetryProcessorExpectedCoverageHonorsLayoutProfileWhenAmbiguous() async throws {
    let frontOnly = ClipSet(timestamp: "_", date: Date(), duration: 1, files: [.front: URL(fileURLWithPath: "/x")])
    #expect(TelemetryProcessor.expectedCoverageCameras(for: frontOnly, layoutProfile: .hw3FourCam) == Set(Camera.hw3ClassicOrder))
    #expect(TelemetryProcessor.expectedCoverageCameras(for: frontOnly, layoutProfile: .hw4SixCam) == Set(Camera.hw4SixCamOrder))

    let hw3Set = ClipSet(timestamp: "_", date: Date(), duration: 1, files: [
      .front: URL(fileURLWithPath: "/a"),
      .left_repeater: URL(fileURLWithPath: "/b")
    ])
    #expect(TelemetryProcessor.expectedCoverageCameras(for: hw3Set, layoutProfile: .hw4SixCam) == Set(Camera.hw3ClassicOrder))
  }

  @Test func sourceStoreNormalizeDeduplicatesAndDropsMissingFiles() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let liveOne = root.url.appendingPathComponent("alpha", isDirectory: true)
    let liveTwo = root.url.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: liveOne, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: liveTwo, withIntermediateDirectories: true)
    let phantom = root.url.appendingPathComponent("does-not-exist", isDirectory: true)

    let store = SourceStore()
    let normalized = store.normalize([liveOne, liveTwo, liveOne, phantom])

    #expect(normalized.map(\.path) == [liveOne.standardizedFileURL.path, liveTwo.standardizedFileURL.path])
  }

  @Test func sourceStoreNormalizeProbesExistenceInsideSecurityScope() async throws {
    let folder = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/TeslaCam", isDirectory: true)
    var events: [String] = []

    let store = SourceStore(
      fileExists: { _ in
        events.append("exists")
        return events.contains("start")
      },
      startSecurityScopedAccess: { _ in
        events.append("start")
        return true
      },
      stopSecurityScopedAccess: { _ in
        events.append("stop")
      }
    )

    let normalized = store.normalize([folder])

    #expect(normalized == [folder.standardizedFileURL])
    #expect(events == ["start", "exists", "stop"])
  }

  @Test func sourceStoreBookmarkRoundTripRestoresPreviouslyRememberedURLs() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let folder = root.url.appendingPathComponent("kept", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let suite = "TeslaCamTests.SourceStore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // Plain bookmarks (not security-scoped) so the test runs without app signing.
    let key = "TeslaCam.lastSourceBookmarks.under-test"
    let writeStore = SourceStore(
      bookmarkKey: key,
      userDefaults: defaults,
      bookmarkCreationOptions: [],
      bookmarkResolutionOptions: []
    )
    writeStore.rememberBookmarks(for: [folder])

    let readStore = SourceStore(
      bookmarkKey: key,
      userDefaults: defaults,
      bookmarkCreationOptions: [],
      bookmarkResolutionOptions: []
    )
    let restored = readStore.restoreBookmarkedURLs()

    // macOS bookmark resolution returns the canonical /private/var path; the
    // input was the /var alias. Compare via resolvingSymlinksInPath so the
    // assertion is independent of the temp-directory symlink layout.
    let canonical = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
    #expect(restored.map(canonical) == [canonical(folder)])
  }

  @Test func sourceStoreRestoreReturnsEmptyAndPreservesBlobWhenAllFoldersAreGone() async throws {
    // Sandbox-revoke / drive-ejected / folder-deleted edge case for the
    // SourceStore bookmark layer. When every persisted bookmark resolves
    // to a URL whose underlying file no longer exists, restore() must
    // surface an empty list (no crash, no spurious URLs) and must NOT
    // rewrite the persisted blob — leaving the bookmark data behind so a
    // future re-mount can still resolve it.
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let folder = root.url.appendingPathComponent("vanished", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let suite = "TeslaCamTests.SourceStore.Revoke.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "TeslaCam.lastSourceBookmarks.revoke-under-test"

    let writeStore = SourceStore(
      bookmarkKey: key,
      userDefaults: defaults,
      bookmarkCreationOptions: [],
      bookmarkResolutionOptions: []
    )
    writeStore.rememberBookmarks(for: [folder])
    let blobBeforeRevoke = defaults.array(forKey: key) as? [Data] ?? []
    #expect(blobBeforeRevoke.count == 1)

    // Revoke: the folder disappears between launches.
    try FileManager.default.removeItem(at: folder)

    let readStore = SourceStore(
      bookmarkKey: key,
      userDefaults: defaults,
      bookmarkCreationOptions: [],
      bookmarkResolutionOptions: []
    )
    let restored = readStore.restoreBookmarkedURLs()
    #expect(restored.isEmpty)

    // Blob untouched because zero bookmarks survived — keep the bookmark
    // around so a future remount can still resolve it.
    let blobAfter = defaults.array(forKey: key) as? [Data] ?? []
    #expect(blobAfter == blobBeforeRevoke)
  }

  @Test func sourceStoreRestoreDropsMissingBookmarkAndShrinksBlobToSurvivors() async throws {
    // Partial-survivor scenario: two folders bookmarked, one gets removed.
    // restore() must return only the survivor and rewrite the persisted
    // blob to drop the dead bookmark — otherwise the missing folder lingers
    // forever in the blob, polluting subsequent restores.
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let kept = root.url.appendingPathComponent("kept", isDirectory: true)
    let removed = root.url.appendingPathComponent("removed", isDirectory: true)
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)

    let suite = "TeslaCamTests.SourceStore.Partial.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "TeslaCam.lastSourceBookmarks.partial-under-test"

    let writeStore = SourceStore(
      bookmarkKey: key,
      userDefaults: defaults,
      bookmarkCreationOptions: [],
      bookmarkResolutionOptions: []
    )
    writeStore.rememberBookmarks(for: [kept, removed])
    let blobBefore = defaults.array(forKey: key) as? [Data] ?? []
    #expect(blobBefore.count == 2)

    try FileManager.default.removeItem(at: removed)

    let readStore = SourceStore(
      bookmarkKey: key,
      userDefaults: defaults,
      bookmarkCreationOptions: [],
      bookmarkResolutionOptions: []
    )
    let restored = readStore.restoreBookmarkedURLs()

    // Compare via resolvingSymlinksInPath so the assertion is independent
    // of the temp-directory /var ↔ /private/var aliasing (matches the
    // round-trip test above).
    let canonical = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
    #expect(restored.map(canonical) == [canonical(kept)])

    // Blob shrunk to the survivor only.
    let blobAfter = defaults.array(forKey: key) as? [Data] ?? []
    #expect(blobAfter.count == 1)
  }

  @Test func indexerScansRealFootageWhenSourceIsAvailable() async throws {
    // Opt-in real-footage Swift sibling of the Python real-footage
    // planner test (tests/test_integration.py::RealFootageIntegrationTests).
    // Skipped (vacuous pass) when neither
    // TESLACAM_REAL_FOOTAGE_SOURCE nor the project-owner local
    // fallback ~/Downloads/Teslacam resolves to a directory; CI
    // never has either.
    //
    // When fired, locks the real-footage indexing contract:
    //   - ClipIndexer.index does not throw
    //   - at least one clip set is found
    //   - at least one camera is detected
    //   - layoutProfile resolves to a concrete known camera layout
    //   - totalDuration is positive
    let env = ProcessInfo.processInfo.environment
    let candidates: [URL] = {
      var out: [URL] = []
      if let raw = env["TESLACAM_REAL_FOOTAGE_SOURCE"], !raw.isEmpty {
        out.append(URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath))
      }
      if let home = env["HOME"], !home.isEmpty {
        out.append(URL(fileURLWithPath: home).appendingPathComponent("Downloads").appendingPathComponent("Teslacam"))
      }
      return out
    }()

    var source: URL?
    var isDir: ObjCBool = false
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) && isDir.boolValue {
      source = candidate
      break
    }
    guard let source else {
      // No real source configured. Vacuous pass — the planner-side
      // Python test covers the same surface when configured.
      return
    }

    let index = try await indexClipsOffMain(inputURLs: [source], duplicatePolicy: .mergeByTime)

    #expect(index.sets.count >= 1, "real-footage source must produce at least one clip set")
    #expect(index.totalDuration > 0, "totalDuration must be positive on real footage")
    let cachedFrameRates = index.sets.flatMap { $0.cameraFrameRates.values }
    #expect(!cachedFrameRates.isEmpty, "real-footage scan must cache source frame rates for export")
    #expect(cachedFrameRates.contains { $0 >= 12 && $0 <= 60 }, "real-footage scan must include a supported export frame rate")
    #expect(cachedFrameRates.allSatisfy { $0 >= 12 && $0 <= 120 })

    #expect(!index.camerasFound.isEmpty, "real-footage source must detect at least one camera")
    #expect([.hw3FourCam, .hw4SixCam].contains(index.layoutProfile), "real-footage layout must resolve to a concrete camera profile")
  }

  @Test func indexerSurvivesUnreadableAndCorruptedClipFilesWithFallbackDuration() async throws {
    // Lock the contract for corrupted / unreadable media: ClipIndexer
    // must not crash, must index every well-named clip file (filename
    // pattern is the source of truth), and must fall back to the
    // 60-second default duration when AVAsset cannot decode the bytes.
    // The composer's clip-readability check is a separate downstream
    // gate; the indexer's job is to surface every named clip so the
    // health summary can flag it.
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let savedClips = root.url.appendingPathComponent("SavedClips", isDirectory: true)
    try FileManager.default.createDirectory(at: savedClips, withIntermediateDirectories: true)

    // 1. Empty file — zero bytes. AVAsset returns invalid duration.
    let emptyURL = savedClips.appendingPathComponent("2026-07-01_00-00-00-front.mp4")
    try Data().write(to: emptyURL)

    // 2. Truncated mp4 header — valid 'ftyp' box prefix but no moov
    //    atom, so AVAsset can't establish duration / track metadata.
    let truncatedURL = savedClips.appendingPathComponent("2026-07-01_00-01-00-back.mp4")
    var truncatedHeader = Data()
    // box size = 24 bytes (big-endian)
    truncatedHeader.append(contentsOf: [0x00, 0x00, 0x00, 0x18])
    // box type 'ftyp'
    truncatedHeader.append(contentsOf: [0x66, 0x74, 0x79, 0x70])
    // major brand 'isom'
    truncatedHeader.append(contentsOf: [0x69, 0x73, 0x6F, 0x6D])
    // minor version + compatible brands (just enough to be 24 bytes total)
    truncatedHeader.append(contentsOf: Array(repeating: UInt8(0), count: 12))
    try truncatedHeader.write(to: truncatedURL)

    // 3. Random garbage — guarantees AVAsset failure.
    let garbageURL = savedClips.appendingPathComponent("2026-07-01_00-02-00-left_repeater.mp4")
    var garbage = Data(count: 512)
    for index in 0..<garbage.count {
      garbage[index] = UInt8(index & 0xFF)
    }
    try garbage.write(to: garbageURL)

    // Index — must not throw.
    let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .mergeByTime)

    // All three timestamps survived (filename is the source of truth;
    // AVAsset failure does not drop the clip).
    #expect(index.sets.count == 3)
    let timestamps = Set(index.sets.map(\.timestamp))
    #expect(timestamps == [
      "2026-07-01_00-00-00",
      "2026-07-01_00-01-00",
      "2026-07-01_00-02-00",
    ])

    // Every clip set falls back to the 60.0s default. The indexer's
    // normalizedDuration helper returns 60.0 on invalid CMTime; the
    // builder's max() across cameras propagates that into ClipSet.
    for clipSet in index.sets {
      #expect(clipSet.duration == 60.0, "expected 60s fallback for unreadable clip \(clipSet.timestamp), got \(clipSet.duration)")
    }

    // The fallback duration is no longer silent: each corrupt clip is flagged
    // so the health summary / UI can surface it rather than presenting a
    // healthy-looking 60-second set (#19).
    let byTimestamp = Dictionary(uniqueKeysWithValues: index.sets.map { ($0.timestamp, $0) })
    #expect(byTimestamp["2026-07-01_00-00-00"]?.unreadableCameras == [.front])
    #expect(byTimestamp["2026-07-01_00-01-00"]?.unreadableCameras == [.back])
    #expect(byTimestamp["2026-07-01_00-02-00"]?.unreadableCameras == [.left_repeater])
    for clipSet in index.sets {
      #expect(clipSet.hasUnreadableCameras, "corrupt clip \(clipSet.timestamp) must be flagged unreadable")
    }
  }

  @Test func telemetryCoordinateRejectsNonFiniteAndOutOfRange() async throws {
    // #15: the single gate every telemetry consumer (MapKit, export HUD) uses.
    #expect(TelemetryCoordinate(latitude: 51.5074, longitude: -0.1278).isUsable)
    #expect(!TelemetryCoordinate(latitude: 0, longitude: 0).isUsable)            // null island
    #expect(!TelemetryCoordinate(latitude: .nan, longitude: -0.1).isUsable)      // NaN
    #expect(!TelemetryCoordinate(latitude: 51.5, longitude: .infinity).isUsable) // Inf
    #expect(!TelemetryCoordinate(latitude: 500, longitude: -0.1).isUsable)       // out of range
    #expect(!TelemetryCoordinate(latitude: 51.5, longitude: 240).isUsable)       // out of range
  }

  @Test func telemetryDisplayModelSanitizesCorruptScalars() async throws {
    // A corrupt SEI decodes raw bit patterns into NaN/Inf; the display model
    // must not surface "nan km/h" or a bogus coordinate.
    var sei = SeiMetadata()
    sei.vehicleSpeedMps = .nan
    sei.steeringWheelAngle = .infinity
    sei.headingDeg = .nan
    sei.linearAccelX = .infinity
    sei.latitudeDeg = .nan
    sei.longitudeDeg = 1.0e30
    let model = TelemetryDisplayModel(sei: sei)
    #expect(model.speedKmh.isFinite)
    #expect(model.steeringAngleDeg.isFinite)
    #expect(model.headingDeg.isFinite)
    #expect(model.accelX.isFinite)
    #expect(model.coordinate == nil)
    #expect(!model.speedText(unit: .kilometersPerHour).lowercased().contains("nan"))
  }

  @Test func sharedOutputFixturesMatchNativeOutputContractForEveryPolicy() async throws {
    // Swift parity for the expected_output block emitted by
    // script/regen_fixtures.py. Exercises DomainOutputContract's three
    // helpers (defaultOutputFilename, uniqueOutputPath via
    // applyConflictPolicy(.unique), applyConflictPolicy(.overwrite|.error))
    // against each fixture's natural clip range with
    // clipDurationSeconds = 60 — same stub the regen script uses.
    let fixtureDirectory = repositoryRootForTests()
      .appendingPathComponent("fixtures", isDirectory: true)
      .appendingPathComponent("domain", isDirectory: true)
      .appendingPathComponent("cases", isDirectory: true)
    let fixtureURLs = try FileManager.default.contentsOfDirectory(
      at: fixtureDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    #expect(fixtureURLs.count >= 4)

    let decoder = JSONDecoder()
    var checkedFixtures = 0
    for fixtureURL in fixtureURLs {
      let fixture = try decoder.decode(DomainFixtureCase.self, from: Data(contentsOf: fixtureURL))
      guard let expected = fixture.expectedOutput else { continue }
      checkedFixtures += 1

      let root = try TemporaryDirectory.make()
      defer { try? root.remove() }
      try materializeDomainFixture(fixture, at: root.url)

      let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .mergeByTime)

      // Empty-dataset branch: assert both sides agree there are no clips.
      if expected.emptyDataset == true {
        #expect(index.sets.isEmpty)
        continue
      }

      // Compute the natural range with a 60s clip duration, mirroring
      // Python's dataset_range + StubMediaProbe.
      let sortedSets = index.sets.sorted { lhs, rhs in
        if lhs.date == rhs.date { return lhs.timestamp < rhs.timestamp }
        return lhs.date < rhs.date
      }
      try #require(!sortedSets.isEmpty)
      let earliest = sortedSets.first!.date
      let latest = sortedSets.last!.date.addingTimeInterval(60.0)

      let actualDefaults: [String: String] = [
        "lossless": DomainOutputContract.defaultOutputFilename(mode: "lossless", startTime: earliest, endTime: latest),
        "quality": DomainOutputContract.defaultOutputFilename(mode: "quality", startTime: earliest, endTime: latest),
      ]
      try #require(expected.defaultFilenameByMode != nil)
      #expect(actualDefaults == expected.defaultFilenameByMode!)

      let targetName = actualDefaults["lossless"]!

      // unique-cascade: three calls in a fresh tempdir, write the
      // resolved file each time so the next call hits the next slot.
      let outDirA = try TemporaryDirectory.make()
      defer { try? outDirA.remove() }
      let target = outDirA.url.appendingPathComponent(targetName)
      var actualUnique: [String] = []
      for _ in 0..<3 {
        let resolved = try DomainOutputContract.applyConflictPolicy(path: target, policy: .unique)
        actualUnique.append(resolved.lastPathComponent)
        FileManager.default.createFile(atPath: resolved.path, contents: Data())
      }
      try #require(expected.uniqueResolution != nil)
      #expect(actualUnique == expected.uniqueResolution!)

      // overwrite-with-conflict: returns the input path unchanged.
      let outDirB = try TemporaryDirectory.make()
      defer { try? outDirB.remove() }
      let overwriteTarget = outDirB.url.appendingPathComponent(targetName)
      FileManager.default.createFile(atPath: overwriteTarget.path, contents: Data())
      let overwriteResolved = try DomainOutputContract.applyConflictPolicy(path: overwriteTarget, policy: .overwrite)
      try #require(expected.overwriteWithConflict != nil)
      #expect(overwriteResolved.lastPathComponent == expected.overwriteWithConflict!)

      // error-with-conflict: throws OutputAlreadyExistsError when the
      // path exists. We assert the language-agnostic contract (raises
      // + message contains the fragment); the fixture's
      // exception_type stays Python-side detail.
      let expectedError = try #require(expected.errorWithConflict)
      let outDirC = try TemporaryDirectory.make()
      defer { try? outDirC.remove() }
      let errorTarget = outDirC.url.appendingPathComponent(targetName)
      FileManager.default.createFile(atPath: errorTarget.path, contents: Data())
      if expectedError.raises {
        var caught: Error?
        do {
          _ = try DomainOutputContract.applyConflictPolicy(path: errorTarget, policy: .error)
        } catch {
          caught = error
        }
        let raised = try #require(caught, "error policy must raise on existing path")
        let fragment = expectedError.messageContains ?? DomainOutputContract.errorMessageFragment
        let message = (raised as? LocalizedError)?.errorDescription ?? "\(raised)"
        #expect(
          message.contains(fragment),
          "error message did not contain expected fragment for \(fixture.name): got \(message)"
        )
      } else {
        // No fixture currently flips this branch; the assertion exists so
        // a future fixture that disables raise still has a passable shape.
        let resolved = try DomainOutputContract.applyConflictPolicy(path: errorTarget, policy: .error)
        #expect(resolved == errorTarget)
      }
    }

    #expect(checkedFixtures >= 1)
  }

  @Test func sharedSelectionFixturesMatchNativeSelectionManifestForAllDuplicatePolicies() async throws {
    // Swift parity for the expected_selection.{policy} block emitted by
    // script/regen_fixtures.py. Uses a fixed clipDurationSeconds = 60
    // (matches the StubMediaProbe both the regen script and the Python
    // parity test agree on) so the fixture data does not depend on
    // AVAsset returning realistic durations for empty mp4 placeholders.
    let fixtureDirectory = repositoryRootForTests()
      .appendingPathComponent("fixtures", isDirectory: true)
      .appendingPathComponent("domain", isDirectory: true)
      .appendingPathComponent("cases", isDirectory: true)
    let fixtureURLs = try FileManager.default.contentsOfDirectory(
      at: fixtureDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    #expect(fixtureURLs.count >= 4)

    let decoder = JSONDecoder()
    var checkedFixtures = 0
    for fixtureURL in fixtureURLs {
      let fixture = try decoder.decode(DomainFixtureCase.self, from: Data(contentsOf: fixtureURL))
      guard let expectedSelection = fixture.expectedSelection else { continue }
      checkedFixtures += 1

      let root = try TemporaryDirectory.make()
      defer { try? root.remove() }
      try materializeDomainFixture(fixture, at: root.url)

      for policy in DuplicateClipPolicy.allCases {
        let expected = try #require(expectedSelection[policy.contractValue])
        let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: policy)

        let actual: DomainSelectionManifest
        if index.sets.isEmpty {
          actual = .empty
        } else {
          let sortedSets = index.sets.sorted { lhs, rhs in
            if lhs.date == rhs.date {
              return lhs.timestamp < rhs.timestamp
            }
            return lhs.date < rhs.date
          }
          let earliest = sortedSets.first!.date
          let latest = sortedSets.last!.date.addingTimeInterval(60.0)
          actual = sortedSets.domainSelectionManifest(
            startTime: earliest,
            endTime: latest,
            clipDurationSeconds: 60.0,
            relativeTo: root.url
          )
        }
        #expect(actual == expected, "selection parity differs for \(fixture.name) under policy \(policy.contractValue)")
      }
    }

    #expect(checkedFixtures >= 1)
  }

  @Test func sharedDomainFixturesMatchNativeScanManifestsForAllDuplicatePolicies() async throws {
    let fixtureDirectory = repositoryRootForTests()
      .appendingPathComponent("fixtures", isDirectory: true)
      .appendingPathComponent("domain", isDirectory: true)
      .appendingPathComponent("cases", isDirectory: true)
    let fixtureURLs = try FileManager.default.contentsOfDirectory(
      at: fixtureDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    #expect(fixtureURLs.count >= 4)

    let decoder = JSONDecoder()
    for fixtureURL in fixtureURLs {
      let fixture = try decoder.decode(DomainFixtureCase.self, from: Data(contentsOf: fixtureURL))
      let root = try TemporaryDirectory.make()
      defer { try? root.remove() }
      try materializeDomainFixture(fixture, at: root.url)

      for policy in DuplicateClipPolicy.allCases {
        let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: policy)
        let actual = index.domainScanManifest(relativeTo: root.url).withoutContractHeader
        let expected = try #require(fixture.expectedScan[policy.contractValue])
        #expect(actual == expected)
      }
    }
  }

  @Test func sharedLayoutFixturesMatchNativeLayoutPlan() async throws {
    let fixtureDirectory = repositoryRootForTests()
      .appendingPathComponent("fixtures", isDirectory: true)
      .appendingPathComponent("domain", isDirectory: true)
      .appendingPathComponent("cases", isDirectory: true)
    let fixtureURLs = try FileManager.default.contentsOfDirectory(
      at: fixtureDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

    let decoder = JSONDecoder()
    var checked = 0
    for fixtureURL in fixtureURLs {
      let fixture = try decoder.decode(DomainFixtureCase.self, from: Data(contentsOf: fixtureURL))
      guard let expectedLayout = fixture.expectedLayout else { continue }
      checked += 1
      let detected = Set(fixture.expectedScan.values.flatMap(\.cameras).compactMap(Camera.init(rawValue:)))

      for request in CameraLayoutRequest.allCases {
        let expected = try #require(expectedLayout[request.rawValue])
        let plan = CameraLayoutPlan.build(
          requestedProfile: request,
          detectedCameras: detected,
          enabledCameras: detected,
          naturalSizes: [:]
        )
        #expect(plan.domainLayoutManifest == expected)
      }
    }

    #expect(checked >= 1)
  }

  @Test func currentMinuteRangeUsesCurrentClipBounds() async throws {
    let state = AppState()
    let date = Date(timeIntervalSince1970: 1_700_000_123)
    state.clipSets = [
      ClipSet(timestamp: "2023-11-14_22-15-23", date: date, duration: 43, files: [:])
    ]
    state.minDate = date
    state.maxDate = date.addingTimeInterval(43)
    state.rebuildTimelineForTesting()
    state.currentIndex = 0

    state.setCurrentMinuteRange()

    #expect(abs(state.trimStartSeconds - 0) < 0.001)
    #expect(abs(state.trimEndSeconds - 43) < 0.001)
  }

  @Test func playheadButtonsSetTrimBoundaries() async throws {
    let state = AppState()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    state.clipSets = [
      ClipSet(timestamp: "a", date: date, duration: 120, files: [:])
    ]
    state.minDate = date
    state.maxDate = date.addingTimeInterval(120)
    state.rebuildTimelineForTesting()

    state.currentSeconds = 30
    state.setTrimStartAtPlayhead()
    #expect(abs(state.trimStartSeconds - 30) < 0.001)
    #expect(abs(state.trimEndSeconds - 120) < 0.001)

    state.currentSeconds = 90
    state.setTrimEndAtPlayhead()
    #expect(abs(state.trimStartSeconds - 30) < 0.001)
    #expect(abs(state.trimEndSeconds - 90) < 0.001)
  }

  @Test func testExportRangeClampsAroundCurrentMinute() async throws {
    let state = AppState()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let middle = start.addingTimeInterval(10 * 60 + 19)
    let end = start.addingTimeInterval(20 * 60 + 41)
    state.minDate = start
    state.maxDate = end
    state.currentIndex = 1
    state.clipSets = [
      ClipSet(timestamp: "a", date: start, duration: 60, files: [:]),
      ClipSet(timestamp: "b", date: middle, duration: 60, files: [:]),
      ClipSet(timestamp: "c", date: end, duration: 60, files: [:])
    ]
    state.rebuildTimelineForTesting()
    state.currentSeconds = 60

    state.setTestExportRange(minutes: 3)

    #expect(abs(state.trimStartSeconds - 0) < 0.001)
    #expect(abs(state.trimEndSeconds - 180) < 0.001)
  }

  @Test func timelinePlaybackSegmentMatchesLoadedClipWithinTolerance() async throws {
    let segment = TimelinePlaybackSegment(clipIndex: 2, startSeconds: 120, duration: 59.9996)

    #expect(segment.matchesLoadedSegment(clipIndex: 2, startSeconds: 120.0004, duration: 60.0))
  }

  @Test func timelinePlaybackSegmentDetectsClipBoundaryChanges() async throws {
    let clipSegment = TimelinePlaybackSegment(clipIndex: 2, startSeconds: 120, duration: 60)
    let gapSegment = TimelinePlaybackSegment(clipIndex: nil, startSeconds: 180, duration: 15)

    #expect(!clipSegment.matchesLoadedSegment(clipIndex: 3, startSeconds: 120, duration: 60))
    #expect(!clipSegment.matchesLoadedSegment(clipIndex: nil, startSeconds: 120, duration: 60))
    #expect(!gapSegment.matchesLoadedSegment(clipIndex: nil, startSeconds: 181, duration: 15))
  }

  @Test func timelineGapRangesReflectUnrecordedSpansBetweenCoveredClips() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let sets = [
      ClipSet(timestamp: "a", date: anchor, duration: 50, files: [:]),
      ClipSet(timestamp: "b", date: anchor.addingTimeInterval(80), duration: 60, files: [:]),
      ClipSet(timestamp: "c", date: anchor.addingTimeInterval(170), duration: 30, files: [:])
    ]

    let gaps = TimelineGapRange.ranges(for: sets)

    #expect(gaps.count == 2)
    #expect(abs(gaps[0].startSeconds - 50) < 0.001)
    #expect(abs(gaps[0].endSeconds - 80) < 0.001)
    #expect(abs(gaps[1].startSeconds - 140) < 0.001)
    #expect(abs(gaps[1].endSeconds - 170) < 0.001)
  }

  @Test func timelineGapRangesIgnoreOverlapAndTinyOffsets() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let sets = [
      ClipSet(timestamp: "a", date: anchor, duration: 60, files: [:]),
      ClipSet(timestamp: "b", date: anchor.addingTimeInterval(59), duration: 60, files: [:]),
      ClipSet(timestamp: "c", date: anchor.addingTimeInterval(120.4), duration: 30, files: [:])
    ]

    let gaps = TimelineGapRange.ranges(for: sets, minimumDuration: 2)

    #expect(gaps.isEmpty)
  }

  @Test func timelineCoverageMapReturnsGapSegmentBetweenClips() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let coverage = TimelineCoverageMap(sets: [
      ClipSet(timestamp: "a", date: anchor, duration: 50, files: [:]),
      ClipSet(timestamp: "b", date: anchor.addingTimeInterval(80), duration: 60, files: [:])
    ])

    #expect(coverage.activeClipIndex(at: 10) == 0)
    #expect(coverage.activeClipIndex(at: 60) == nil)

    let gap = coverage.playbackSegment(at: 60)
    #expect(gap.clipIndex == nil)
    #expect(abs(gap.startSeconds - 50) < 0.001)
    #expect(abs(gap.duration - 30) < 0.001)
  }

  @Test func recordedTimelineCoverageSkipsDeadTimeBetweenClips() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let coverage = TimelineCoverageMap(
      sets: [
        ClipSet(timestamp: "a", date: anchor, duration: 50, files: [:]),
        ClipSet(timestamp: "b", date: anchor.addingTimeInterval(80), duration: 60, files: [:])
      ],
      scale: .recordedClips
    )

    #expect(abs(coverage.totalDuration - 110) < 0.001)
    #expect(coverage.gapRanges().isEmpty)
    #expect(coverage.activeClipIndex(at: 55) == 1)
    #expect(coverage.date(forGlobalSeconds: 55) == anchor.addingTimeInterval(85))
    #expect(abs(coverage.globalSeconds(for: anchor.addingTimeInterval(70)) - 50) < 0.001)
  }

  @Test func timelineCoverageMapCountsCompletedClipsByEndTime() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let coverage = TimelineCoverageMap(sets: [
      ClipSet(timestamp: "a", date: anchor, duration: 50, files: [:]),
      ClipSet(timestamp: "b", date: anchor.addingTimeInterval(80), duration: 60, files: [:]),
      ClipSet(timestamp: "c", date: anchor.addingTimeInterval(170), duration: 30, files: [:])
    ])

    #expect(coverage.completedClipCount(at: 49.9) == 0)
    #expect(coverage.completedClipCount(at: 50) == 1)
    #expect(coverage.completedClipCount(at: 139.9) == 1)
    #expect(coverage.completedClipCount(at: 200) == 3)
  }

  @Test func timelineCoverageMapPreservesOriginalIndicesForUnsortedSets() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let sets = [
      ClipSet(timestamp: "late", date: anchor.addingTimeInterval(120), duration: 30, files: [:]),
      ClipSet(timestamp: "early", date: anchor, duration: 30, files: [:])
    ]
    let coverage = TimelineCoverageMap(sets: sets)

    #expect(coverage.activeClipIndex(at: 5) == 1)
    #expect(coverage.nearestClipIndex(to: 60) == 1)
    #expect(coverage.activeClipIndex(at: 125) == 0)
  }

  @Test func timelineStoreOwnsCoverageAndTrimSelection() async throws {
    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let sets = [
      ClipSet(timestamp: "a", date: anchor, duration: 50, files: [:]),
      ClipSet(timestamp: "b", date: anchor.addingTimeInterval(80), duration: 60, files: [:])
    ]
    var store = TimelineStore()

    store.load(sets: sets, minDate: anchor, maxDate: anchor.addingTimeInterval(140))
    store.setTrimRange(startSeconds: 52, endSeconds: 84, snapToMinute: true)

    #expect(abs(store.totalDuration - 110) < 0.001)
    #expect(store.gapRanges.isEmpty)
    #expect(abs(store.trimStartSeconds - 0) < 0.001)
    #expect(abs(store.trimEndSeconds - 110) < 0.001)
    #expect(store.selectedSetsForExport.map(\.timestamp) == ["a", "b"])
    #expect(store.currentGapRange(at: 60) == nil)
  }

  @Test func exportStoreResolvesNamesAndBuildsRequests() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let store = ExportStore(fileManager: .default)
    let first = store.resolvedOutputURL(
      chosenURL: root.url,
      preferredFilename: "manual-export.mov",
      preset: .maxQualityHEVC
    )
    try Data().write(to: first)

    let second = store.resolvedOutputURL(
      chosenURL: root.url,
      preferredFilename: "manual-export.mov",
      preset: .maxQualityHEVC
    )

    let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    let request = store.makeRequest(
      sets: [
        ClipSet(
          timestamp: "a",
          date: anchor,
          duration: 60,
          files: [.front: URL(fileURLWithPath: "/tmp/front.mov"), .left: URL(fileURLWithPath: "/tmp/left.mov")]
        )
      ],
      chosenURL: second,
      preset: .maxQualityHEVC,
      enabledCameras: [.front, .left],
      trimStartSeconds: 0,
      trimEndSeconds: 60,
      trimStartDate: anchor,
      trimEndDate: anchor.addingTimeInterval(60),
      selectedRangeText: "range",
      partialClipCount: 0
    )

    #expect(first.lastPathComponent == "manual-export.mp4")
    #expect(second.lastPathComponent == "manual-export-2.mp4")
    #expect(request?.outputURL.lastPathComponent == "manual-export-2.mp4")
    #expect(request?.useSixCam == true)
  }

  @Test func exportDirectoryNamingAvoidsExistingFiles() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let state = AppState()
    state.clipSets = [
      ClipSet(timestamp: "a", date: Date(timeIntervalSince1970: 1_700_000_000), duration: 60, files: [:])
    ]
    state.selectedExportCameras = [.front]
    state.layoutProfile = .hw3FourCam
    state.rebuildTimelineForTesting()

    let initial = state.resolvedExportURL(forTesting: root.url)
    try Data().write(to: initial)

    let resolved = state.resolvedExportURL(forTesting: root.url)

    #expect(resolved.lastPathComponent == "\(initial.deletingPathExtension().lastPathComponent)-2.mp4")
  }

  @Test func exportFileNamingAvoidsExistingFiles() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let chosen = root.url.appendingPathComponent("manual-export.mp4")
    try Data().write(to: chosen)

    let state = AppState()

    let resolved = state.resolvedExportURL(forTesting: chosen)

    #expect(resolved.lastPathComponent == "manual-export-2.mp4")
  }

  @Test func duplicateResolverNeverInterruptsMergePolicy() async throws {
    let state = AppState()
    let summary = DuplicateResolutionSummary(
      duplicateFileCount: 2,
      duplicateTimestampCount: 1,
      overlapMinuteCount: 1
    )

    state.presentDuplicateResolverIfNeededForTesting(summary: summary)
    #expect(!state.isDuplicateResolverPresented)

    state.chooseDuplicatePolicy(.keepAll)
    state.presentDuplicateResolverIfNeededForTesting(summary: summary)
    #expect(!state.isDuplicateResolverPresented)
    #expect(state.duplicatePolicy == .mergeByTime)

    state.showDuplicateResolverForConflicts = true
    state.presentDuplicateResolverIfNeededForTesting(summary: summary)
    #expect(!state.isDuplicateResolverPresented)
  }

  @Test func indexUsesRealClipDurationAndDetectsFourCamProfile() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let timestamp = "2026-04-08_11-30-00"
    let clipDate = try #require(teslaTimestampDate(timestamp))
    let duration: Double = 2.0

    try await makeVideo(
      at: root.url.appendingPathComponent("\(timestamp)-front.mov"),
      duration: duration,
      size: CGSize(width: 1280, height: 960)
    )
    try await makeVideo(
      at: root.url.appendingPathComponent("\(timestamp)-rear.mov"),
      duration: duration,
      size: CGSize(width: 1280, height: 960)
    )
    try await makeVideo(
      at: root.url.appendingPathComponent("\(timestamp)-left_repeater.mov"),
      duration: duration,
      size: CGSize(width: 1280, height: 960)
    )
    try await makeVideo(
      at: root.url.appendingPathComponent("\(timestamp)-right_repeater.mov"),
      duration: duration,
      size: CGSize(width: 1280, height: 960)
    )

    let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .mergeByTime)

    #expect(index.layoutProfile == .hw3FourCam)
    #expect(index.sets.count == 1)
    #expect(abs(index.sets[0].duration - duration) < 0.25)
    #expect(abs(index.totalDuration - duration) < 0.25)
    #expect(abs(index.minDate.timeIntervalSince(clipDate)) < 1)
    #expect(abs(index.maxDate.timeIntervalSince(clipDate.addingTimeInterval(duration))) < 0.25)
  }

  @Test func indexDetectsSixCamProfileWhenNewSideAndPillarClipsExist() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let timestamp = "2026-04-08_12-00-00"
    let duration: Double = 1.0
    let cameras: [String] = [
      "front",
      "rear",
      "left",
      "right",
      "left_pillar",
      "right_pillar"
    ]

    for camera in cameras {
      try await makeVideo(
        at: root.url.appendingPathComponent("\(timestamp)-\(camera).mov"),
        duration: duration,
        size: CGSize(width: 1920, height: 1080)
      )
    }

    let index = try await indexClipsOffMain(inputURLs: [root.url], duplicatePolicy: .mergeByTime)

    #expect(index.layoutProfile == .hw4SixCam)
    #expect(index.sets.count == 1)
    #expect(index.camerasFound.contains(.left))
    #expect(index.camerasFound.contains(.right))
    #expect(index.camerasFound.contains(.left_pillar))
    #expect(index.camerasFound.contains(.right_pillar))
  }

  @Test func nativeExportWritesMovieForSampleTimeline() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let outputURL = root.url.appendingPathComponent("sample_export.mov")
    let base = Date(timeIntervalSince1970: 1_775_650_200)
    let sets = [
      ClipSet(timestamp: "sample_1", date: base, duration: 1, files: [:]),
      ClipSet(timestamp: "sample_2", date: base.addingTimeInterval(60), duration: 1, files: [:])
    ]
    let request = ExportRequest(
      sets: sets,
      outputURL: outputURL,
      useSixCam: false,
      preset: .editFriendlyProRes,
      enabledCameras: [.front, .back, .left_repeater, .right_repeater],
      trimStartSeconds: 0,
      trimEndSeconds: 2,
      trimStartDate: base,
      trimEndDate: base.addingTimeInterval(2),
      selectedRangeText: "sample",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller)

    #expect(controller.currentJob?.phase == .completed)
    let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(size > 0)
  }

  @Test func nativeExportRendersEveryHW3GridCellInContractOrder() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let timestamp = "2026-07-29_17-00-00"
    let clipDate = try #require(teslaTimestampDate(timestamp))
    let duration: Double = 1.0
    let tileSize = CGSize(width: 320, height: 240)
    let fills: [Camera: UInt8] = [
      .front: 40,
      .back: 90,
      .left_repeater: 150,
      .right_repeater: 210
    ]
    let files = Dictionary(uniqueKeysWithValues: fills.keys.map { camera in
      (camera, root.url.appendingPathComponent("\(timestamp)-\(camera.rawValue).mov"))
    })
    for (camera, url) in files {
      try await makeVideo(at: url, duration: duration, size: tileSize, fill: try #require(fills[camera]))
    }

    let outputURL = root.url.appendingPathComponent("hw3-grid.mov")
    let request = ExportRequest(
      sets: [
        ClipSet(
          timestamp: timestamp,
          date: clipDate,
          duration: duration,
          files: files,
          cameraDurations: Dictionary(uniqueKeysWithValues: fills.keys.map { ($0, duration) }),
          naturalSizes: Dictionary(uniqueKeysWithValues: fills.keys.map { ($0, tileSize) })
        )
      ],
      outputURL: outputURL,
      useSixCam: false,
      preset: .editFriendlyProRes,
      enabledCameras: Set(fills.keys),
      trimStartSeconds: 0,
      trimEndSeconds: duration,
      trimStartDate: clipDate,
      trimEndDate: clipDate.addingTimeInterval(duration),
      selectedRangeText: "hw3 grid",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    controller.export(request: request)
    _ = await waitForTerminalExport(controller)

    #expect(controller.currentJob?.phase == .completed)
    let samples = try await firstFrameLumaByCamera(
      from: outputURL,
      tileSize: tileSize
    )
    for camera in Camera.hw3ClassicOrder {
      let actual = try #require(samples[camera])
      let expected = try #require(fills[camera])
      #expect(abs(Int(actual) - Int(expected)) < 35)
    }
  }

  @Test func nativeExportWritesOverlaySidecars() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let outputURL = root.url.appendingPathComponent("overlay_export.mov")
    let base = Date(timeIntervalSince1970: 1_775_650_200)
    let request = ExportRequest(
      sets: [
        ClipSet(timestamp: "sample_1", date: base, duration: 1, files: [:])
      ],
      outputURL: outputURL,
      useSixCam: false,
      preset: .editFriendlyProRes,
      enabledCameras: [.front, .back, .left_repeater, .right_repeater],
      overlayOptions: ExportOverlayOptions(
        telemetryHUD: true,
        routeMap: true,
        privacyMask: true,
        includeReport: true,
        includeScreenshot: true
      ),
      trimStartSeconds: 0,
      trimEndSeconds: 1,
      trimStartDate: base,
      trimEndDate: base.addingTimeInterval(1),
      selectedRangeText: "overlay",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller)

    #expect(controller.currentJob?.phase == .completed)
    let poster = outputURL.deletingPathExtension().appendingPathExtension("poster.png")
    let report = outputURL.deletingPathExtension().appendingPathExtension("report.pdf")
    #expect(FileManager.default.fileExists(atPath: poster.path))
    #expect(FileManager.default.fileExists(atPath: report.path))
    let posterSize = (try? poster.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    let reportSize = (try? report.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(posterSize > 0)
    #expect(reportSize > 0)
  }

  @Test func nativeExportUsesTwoByThreeCanvasForHw4Composite() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let timestamp = "2026-04-08_12-00-00"
    let clipDate = try #require(teslaTimestampDate(timestamp))
    let duration: Double = 1.0
    let size = CGSize(width: 1920, height: 1080)
    let files: [Camera: URL] = [
      .front: root.url.appendingPathComponent("\(timestamp)-front.mov"),
      .back: root.url.appendingPathComponent("\(timestamp)-rear.mov"),
      .left: root.url.appendingPathComponent("\(timestamp)-left.mov"),
      .right: root.url.appendingPathComponent("\(timestamp)-right.mov"),
      .left_pillar: root.url.appendingPathComponent("\(timestamp)-left_pillar.mov"),
      .right_pillar: root.url.appendingPathComponent("\(timestamp)-right_pillar.mov")
    ]

    for url in files.values {
      try await makeVideo(at: url, duration: duration, size: size)
    }

    let outputURL = root.url.appendingPathComponent("hw4_export.mov")
    let request = ExportRequest(
      sets: [
        ClipSet(
          timestamp: timestamp,
          date: clipDate,
          duration: duration,
          files: files,
          cameraDurations: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, duration) }),
          naturalSizes: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, size) })
        )
      ],
      outputURL: outputURL,
      useSixCam: true,
      preset: .editFriendlyProRes,
      enabledCameras: Set(files.keys),
      trimStartSeconds: 0,
      trimEndSeconds: duration,
      trimStartDate: clipDate,
      trimEndDate: clipDate.addingTimeInterval(duration),
      selectedRangeText: "hw4",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller)

    let asset = AVURLAsset(url: outputURL)
    let track = try #require(await asset.loadTracks(withMediaType: .video).first)
    let naturalSize = try await track.load(.naturalSize)

    #expect(Int(naturalSize.width.rounded()) == 5760)
    #expect(Int(naturalSize.height.rounded()) == 2160)
  }

  @Test func nativePassthroughExportWritesOriginalCameraTracks() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let timestamp = "2026-04-08_12-00-00"
    let clipDate = try #require(teslaTimestampDate(timestamp))
    let duration: Double = 1.0
    let size = CGSize(width: 1920, height: 1080)
    let files: [Camera: URL] = [
      .front: root.url.appendingPathComponent("\(timestamp)-front.mov"),
      .back: root.url.appendingPathComponent("\(timestamp)-rear.mov")
    ]

    for url in files.values {
      try await makeVideo(at: url, duration: duration, size: size)
    }

    let outputURL = root.url.appendingPathComponent("original_tracks.mov")
    let request = ExportRequest(
      sets: [
        ClipSet(
          timestamp: timestamp,
          date: clipDate,
          duration: duration,
          files: files,
          cameraDurations: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, duration) }),
          naturalSizes: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, size) })
        )
      ],
      outputURL: outputURL,
      useSixCam: false,
      preset: .originalTracksMOV,
      enabledCameras: Set(files.keys),
      trimStartSeconds: 0,
      trimEndSeconds: duration,
      trimStartDate: clipDate,
      trimEndDate: clipDate.addingTimeInterval(duration),
      selectedRangeText: "passthrough",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller)

    #expect(controller.currentJob?.phase == .completed)
    let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(outputSize > 0)

    let asset = AVURLAsset(url: outputURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == files.count)
  }

  @Test func nativePassthroughExportsBriefRealFootageWhenOptedIn() async throws {
    guard shouldRunRealFootageExport() else {
      return
    }
    let source = try #require(realFootageSource())
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let indexStarted = Date()
    let index = try await indexClipsOffMain(inputURLs: [source], duplicatePolicy: .mergeByTime)
    let indexElapsed = Date().timeIntervalSince(indexStarted)
    let expected: Set<Camera> = [.front, .back, .left_repeater, .right_repeater]
    let selected = try #require(index.sets.first { expected.isSubset(of: Set($0.files.keys)) })
    let duration = min(10.0, max(1.0, selected.duration))
    let outputURL = root.url.appendingPathComponent("native-real-footage-original-tracks.mov")
    let request = ExportRequest(
      sets: [selected],
      outputURL: outputURL,
      useSixCam: false,
      preset: .originalTracksMOV,
      enabledCameras: expected,
      trimStartSeconds: 0,
      trimEndSeconds: duration,
      trimStartDate: selected.date,
      trimEndDate: selected.date.addingTimeInterval(duration),
      selectedRangeText: "real-footage mux benchmark",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    let exportStarted = Date()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller, timeout: 90)
    let exportElapsed = Date().timeIntervalSince(exportStarted)

    #expect(controller.currentJob?.phase == .completed)
    let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(size > 0)

    let asset = AVURLAsset(url: outputURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == expected.count)
    print(String(format: "NATIVE_REAL_FOOTAGE_MUX index=%.3fs export=%.3fs duration=%.3fs tracks=%d bytes=%d", indexElapsed, exportElapsed, duration, tracks.count, size))
  }

  @Test func nativePassthroughExportsMultipleRealClipSetsWhenOptedIn() async throws {
    guard shouldRunRealFootageExport() else {
      return
    }
    let source = try #require(realFootageSource())
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let indexStarted = Date()
    let index = try await indexClipsOffMain(inputURLs: [source], duplicatePolicy: .mergeByTime)
    let indexElapsed = Date().timeIntervalSince(indexStarted)
    let expected: Set<Camera> = [.front, .back, .left_repeater, .right_repeater]
    let selected = realFootageSets(from: index, expected: expected, limit: 3, maxGapSeconds: 90)

    guard selected.count >= 2 else {
      Issue.record("real-footage source did not contain consecutive complete camera sets")
      return
    }

    let first = try #require(selected.first)
    let last = try #require(selected.last)
    let recordedDuration = selected.reduce(0.0) { $0 + max(0.1, $1.duration) }
    let trimEndDate = last.date.addingTimeInterval(last.duration)
    let outputURL = root.url.appendingPathComponent("native-real-footage-full-folder-slice.mov")
    let request = ExportRequest(
      sets: selected,
      outputURL: outputURL,
      useSixCam: false,
      preset: .originalTracksMOV,
      enabledCameras: expected,
      trimStartSeconds: 0,
      trimEndSeconds: trimEndDate.timeIntervalSince(first.date),
      trimStartDate: first.date,
      trimEndDate: trimEndDate,
      selectedRangeText: "real-footage multi-set mux benchmark",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    let exportStarted = Date()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller, timeout: 120)
    let exportElapsed = Date().timeIntervalSince(exportStarted)

    #expect(controller.currentJob?.phase == .completed)
    let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(size > 0)

    let asset = AVURLAsset(url: outputURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let outputDuration = CMTimeGetSeconds(try await asset.load(.duration))
    #expect(tracks.count == expected.count)
    #expect(outputDuration >= recordedDuration * 0.95)
    #expect(outputDuration <= recordedDuration + 2.0)
    print(String(format: "NATIVE_REAL_FOOTAGE_MULTI_MUX index=%.3fs export=%.3fs sets=%d recorded=%.3fs output=%.3fs tracks=%d bytes=%d", indexElapsed, exportElapsed, selected.count, recordedDuration, outputDuration, tracks.count, size))
  }

  @Test func nativePassthroughExportsLargerRealFootageRangeWhenOptedIn() async throws {
    guard shouldRunRealFootageScaleExport() else {
      return
    }
    let source = try #require(realFootageSource())
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let indexStarted = Date()
    let index = try await indexClipsOffMain(inputURLs: [source], duplicatePolicy: .mergeByTime)
    let indexElapsed = Date().timeIntervalSince(indexStarted)
    let expected: Set<Camera> = [.front, .back, .left_repeater, .right_repeater]
    let requestedSetCount = realFootageScaleSetLimit()
    let selected = realFootageSets(from: index, expected: expected, limit: requestedSetCount)

    guard selected.count >= min(6, requestedSetCount) else {
      Issue.record("real-footage source did not contain enough complete camera sets for scale export")
      return
    }

    let first = try #require(selected.first)
    let last = try #require(selected.last)
    let recordedDuration = selected.reduce(0.0) { $0 + max(0.1, $1.duration) }
    let trimEndDate = last.date.addingTimeInterval(last.duration)
    let outputURL = root.url.appendingPathComponent("native-real-footage-scale-original-tracks.mov")
    let request = ExportRequest(
      sets: selected,
      outputURL: outputURL,
      useSixCam: false,
      preset: .originalTracksMOV,
      enabledCameras: expected,
      trimStartSeconds: 0,
      trimEndSeconds: trimEndDate.timeIntervalSince(first.date),
      trimStartDate: first.date,
      trimEndDate: trimEndDate,
      selectedRangeText: "real-footage scale mux benchmark",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    let exportStarted = Date()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller, timeout: 300)
    let exportElapsed = Date().timeIntervalSince(exportStarted)

    #expect(controller.currentJob?.phase == .completed)
    let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(size > 0)

    let asset = AVURLAsset(url: outputURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let outputDuration = CMTimeGetSeconds(try await asset.load(.duration))
    #expect(tracks.count == expected.count)
    #expect(outputDuration >= recordedDuration * 0.95)
    #expect(outputDuration <= recordedDuration + Double(selected.count))
    print(String(format: "NATIVE_REAL_FOOTAGE_SCALE_MUX index=%.3fs export=%.3fs sets=%d requested=%d recorded=%.3fs output=%.3fs tracks=%d bytes=%d", indexElapsed, exportElapsed, selected.count, requestedSetCount, recordedDuration, outputDuration, tracks.count, size))
  }

  @Test func nativeExportRendersBriefRealFootageHEVCWhenOptedIn() async throws {
    guard shouldRunRealFootageExport() else {
      return
    }
    let source = try #require(realFootageSource())
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }

    let indexStarted = Date()
    let index = try await indexClipsOffMain(inputURLs: [source], duplicatePolicy: .mergeByTime)
    let indexElapsed = Date().timeIntervalSince(indexStarted)
    let expected: Set<Camera> = [.front, .back, .left_repeater, .right_repeater]
    let selected = try #require(index.sets.first { expected.isSubset(of: Set($0.files.keys)) })
    let duration = min(10.0, max(1.0, selected.duration))
    let outputURL = root.url.appendingPathComponent("native-real-footage-hevc.mp4")
    let request = ExportRequest(
      sets: [selected],
      outputURL: outputURL,
      useSixCam: false,
      preset: .fastHEVC,
      enabledCameras: expected,
      trimStartSeconds: 0,
      trimEndSeconds: duration,
      trimStartDate: selected.date,
      trimEndDate: selected.date.addingTimeInterval(duration),
      selectedRangeText: "real-footage benchmark",
      partialClipCount: 0
    )

    let controller = NativeExportController()
    let exportStarted = Date()
    controller.export(request: request)

    _ = await waitForTerminalExport(controller, timeout: 90)
    let exportElapsed = Date().timeIntervalSince(exportStarted)

    #expect(controller.currentJob?.phase == .completed)
    let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    #expect(size > 0)

    let asset = AVURLAsset(url: outputURL)
    let track = try #require(await asset.loadTracks(withMediaType: .video).first)
    let naturalSize = try await track.load(.naturalSize)
    #expect(Int(naturalSize.width.rounded()) == 2560)
    #expect(Int(naturalSize.height.rounded()) == 1920)
    print(String(format: "NATIVE_REAL_FOOTAGE_EXPORT index=%.3fs export=%.3fs duration=%.3fs bytes=%d", indexElapsed, exportElapsed, duration, size))
  }

  private func shouldRunRealFootageExport() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let marker = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(".cache/tmp/run-native-real-footage-export")
    return env["TESLACAM_REAL_FOOTAGE_NATIVE_EXPORT"] == "1"
      || FileManager.default.fileExists(atPath: marker.path)
  }

  private func shouldRunRealFootageScaleExport() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["TESLACAM_REAL_FOOTAGE_SCALE_EXPORT"] == "1"
      || FileManager.default.fileExists(atPath: realFootageScaleMarkerURL().path)
  }

  private func realFootageScaleSetLimit() -> Int {
    let raw = ProcessInfo.processInfo.environment["TESLACAM_REAL_FOOTAGE_SCALE_SET_LIMIT"] ?? ""
    let markerRaw = (try? String(contentsOf: realFootageScaleMarkerURL(), encoding: .utf8))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    let parsed = Int(raw) ?? Int(markerRaw) ?? 12
    return min(max(parsed, 6), 60)
  }

  private func realFootageScaleMarkerURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(".cache/tmp/run-native-real-footage-scale-export")
  }

  private func realFootageSets(
    from index: ClipIndex,
    expected: Set<Camera>,
    limit: Int,
    maxGapSeconds: TimeInterval? = nil
  ) -> [ClipSet] {
    var selected: [ClipSet] = []
    for set in index.sets where expected.isSubset(of: Set(set.files.keys)) {
      if let maxGapSeconds, let previous = selected.last, set.date.timeIntervalSince(previous.date) > maxGapSeconds {
        selected = [set]
      } else {
        selected.append(set)
      }
      if selected.count == limit {
        break
      }
    }
    return selected
  }

  private func realFootageSource() -> URL? {
    let env = ProcessInfo.processInfo.environment
    var candidates: [URL] = []
    if let raw = env["TESLACAM_REAL_FOOTAGE_SOURCE"], !raw.isEmpty {
      candidates.append(URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath))
    }
    if let home = env["HOME"], !home.isEmpty {
      candidates.append(URL(fileURLWithPath: home).appendingPathComponent("Downloads").appendingPathComponent("Teslacam"))
    }

    var isDir: ObjCBool = false
    return candidates.first { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
  }

}

#if os(macOS)
@MainActor
private func renderContentViewSnapshot(state: AppState, size: CGSize) throws -> NSBitmapImageRep {
  let root = ContentView()
    .environmentObject(state)
    .frame(width: size.width, height: size.height)
  let hostingView = NSHostingView(rootView: root)
  hostingView.frame = CGRect(origin: .zero, size: size)
  hostingView.setFrameSize(size)
  hostingView.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  hostingView.layoutSubtreeIfNeeded()

  guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
    throw NSError(
      domain: "TeslaCamTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Could not allocate offscreen root-view bitmap."]
    )
  }
  hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
  return bitmap
}

private func snapshotHasVisibleContent(_ bitmap: NSBitmapImageRep) -> Bool {
  guard let data = bitmap.bitmapData else { return false }
  let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
  guard bytesPerPixel >= 3, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }

  var visibleSamples = 0
  var colors = Set<UInt32>()
  let xStride = max(1, bitmap.pixelsWide / 24)
  let yStride = max(1, bitmap.pixelsHigh / 18)

  for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
      let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
      let first = data[offset]
      let second = data[offset + 1]
      let third = data[offset + 2]
      let alpha = bytesPerPixel >= 4 ? data[offset + 3] : 255
      if alpha > 8, Int(first) + Int(second) + Int(third) > 24 {
        visibleSamples += 1
      }
      colors.insert(UInt32(first) << 16 | UInt32(second) << 8 | UInt32(third))
      if visibleSamples >= 12, colors.count >= 4 {
        return true
      }
    }
  }

  return false
}
#endif

private struct TemporaryDirectory {
  let url: URL

  static func make() throws -> TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("teslacam-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return TemporaryDirectory(url: url)
  }

  func remove() throws {
    try FileManager.default.removeItem(at: url)
  }
}

private struct StubExportPreflightFileAccess: ExportPreflightFileAccess {
  var canWrite: Bool
  var availableCapacity: Int64?

  func canWrite(to outputURL: URL) -> Bool {
    canWrite
  }

  func availableCapacity(forWritingTo outputURL: URL) -> Int64? {
    availableCapacity
  }
}

private func exportRequestForPlan(
  preset: ExportPreset = .maxQualityHEVC,
  useSixCam: Bool = false,
  enabledCameras: Set<Camera> = [.front],
  files: [Camera: URL] = [.front: URL(fileURLWithPath: "/tmp/front.mov")],
  naturalSizes: [Camera: CGSize] = [.front: CGSize(width: 1920, height: 1080)],
  trimStart: Date = Date(timeIntervalSince1970: 100),
  trimEnd: Date = Date(timeIntervalSince1970: 102),
  cameraTrack: CameraTrack = .empty,
  isPreviewSample: Bool = false
) -> ExportRequest {
  ExportRequest(
    sets: [
      ClipSet(
        timestamp: "sample",
        date: trimStart,
        duration: max(0, trimEnd.timeIntervalSince(trimStart)),
        files: files,
        cameraDurations: Dictionary(uniqueKeysWithValues: files.keys.map { ($0, max(0, trimEnd.timeIntervalSince(trimStart))) }),
        naturalSizes: naturalSizes
      )
    ],
    outputURL: URL(fileURLWithPath: "/tmp/export.\(preset.defaultExtension)"),
    useSixCam: useSixCam,
    preset: preset,
    enabledCameras: enabledCameras,
    trimStartSeconds: 0,
    trimEndSeconds: max(0, trimEnd.timeIntervalSince(trimStart)),
    trimStartDate: trimStart,
    trimEndDate: trimEnd,
    selectedRangeText: "sample",
    partialClipCount: 0,
    cameraTrack: cameraTrack,
    isPreviewSample: isPreviewSample
  )
}

private func firstFrameLumaByCamera(
  from url: URL,
  tileSize: CGSize
) async throws -> [Camera: UInt8] {
  let asset = AVURLAsset(url: url)
  guard let track = try await asset.loadTracks(withMediaType: .video).first else {
    throw NSError(domain: "TeslaCamTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export has no video track"])
  }
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
  )
  guard reader.canAdd(output) else {
    throw NSError(domain: "TeslaCamTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot read export pixels"])
  }
  reader.add(output)
  guard reader.startReading(),
        let sample = output.copyNextSampleBuffer(),
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
    throw NSError(domain: "TeslaCamTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot read first export frame"])
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
  guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
    throw NSError(domain: "TeslaCamTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Cannot access first export frame"])
  }

  let width = CVPixelBufferGetWidth(pixelBuffer)
  let height = CVPixelBufferGetHeight(pixelBuffer)
  let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
  let tileWidth = Int(tileSize.width.rounded())
  let tileHeight = Int(tileSize.height.rounded())
  guard width == tileWidth * 2, height == tileHeight * 2 else {
    throw NSError(domain: "TeslaCamTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unexpected HW3 export canvas"])
  }

  let centers: [Camera: (x: Int, y: Int)] = [
    .front: (tileWidth / 2, tileHeight / 2),
    .back: (tileWidth + tileWidth / 2, tileHeight / 2),
    .left_repeater: (tileWidth / 2, tileHeight + tileHeight / 2),
    .right_repeater: (tileWidth + tileWidth / 2, tileHeight + tileHeight / 2)
  ]
  return Dictionary(uniqueKeysWithValues: centers.map { camera, point in
    let offset = point.y * bytesPerRow + point.x * 4
    let blue = Int(baseAddress.load(fromByteOffset: offset, as: UInt8.self))
    let green = Int(baseAddress.load(fromByteOffset: offset + 1, as: UInt8.self))
    let red = Int(baseAddress.load(fromByteOffset: offset + 2, as: UInt8.self))
    return (camera, UInt8((red + green + blue) / 3))
  })
}

private func makeVideo(at url: URL, duration: Double, size: CGSize, fill: UInt8? = nil) async throws {
  try await Task.detached(priority: .userInitiated) {
    try makeVideoImpl(at: url, duration: duration, size: size, fill: fill)
  }.value
}

private func makeVideoImpl(at url: URL, duration: Double, size: CGSize, fill: UInt8? = nil) throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(size.width),
    AVVideoHeightKey: Int(size.height)
  ]
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height)
    ]
  )

  guard writer.canAdd(input) else {
    throw NSError(domain: "TeslaCamTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
  }
  writer.add(input)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)

  let fps = 10
  let frameCount = max(1, Int(duration * Double(fps)))
  for frameIndex in 0..<frameCount {
    while !input.isReadyForMoreMediaData {
      Thread.sleep(forTimeInterval: 0.001)
    }

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(size.width),
      Int(size.height),
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
      ] as CFDictionary,
      &pixelBuffer
    )

    guard let pixelBuffer else {
      throw NSError(domain: "TeslaCamTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate pixel buffer"])
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(base, Int32(fill ?? UInt8(frameIndex % 255)), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
    guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
      throw NSError(domain: "TeslaCamTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot append frame"])
    }
  }

  input.markAsFinished()
  let group = DispatchGroup()
  group.enter()
  writer.finishWriting {
    group.leave()
  }
  group.wait()

  if let error = writer.error {
    throw error
  }
}

private func makeMp4WithTeslaSei(metadata: SeiMetadata) -> Data {
  let nal = makeTeslaSeiNal(metadata: metadata)
  var mdatPayload = Data()
  appendUInt32BE(UInt32(nal.count), to: &mdatPayload)
  mdatPayload.append(nal)

  var data = Data()
  appendUInt32BE(UInt32(8 + mdatPayload.count), to: &data)
  data.append(contentsOf: [0x6D, 0x64, 0x61, 0x74])
  data.append(mdatPayload)
  return data
}

private func makeTeslaSeiNal(metadata: SeiMetadata) -> Data {
  var payload = Data()
  appendProtoVarint(field: 1, value: UInt64(metadata.version), to: &payload)
  appendProtoVarint(field: 2, value: UInt64(metadata.gearState.rawValue), to: &payload)
  appendProtoVarint(field: 3, value: metadata.frameSeqNo, to: &payload)
  appendProtoFixed32(field: 4, value: metadata.vehicleSpeedMps.bitPattern, to: &payload)
  appendProtoFixed32(field: 5, value: metadata.acceleratorPedalPosition.bitPattern, to: &payload)
  appendProtoFixed32(field: 6, value: metadata.steeringWheelAngle.bitPattern, to: &payload)
  appendProtoVarint(field: 7, value: metadata.blinkerLeft ? 1 : 0, to: &payload)
  appendProtoVarint(field: 8, value: metadata.blinkerRight ? 1 : 0, to: &payload)
  appendProtoVarint(field: 9, value: metadata.brakeApplied ? 1 : 0, to: &payload)
  appendProtoVarint(field: 10, value: UInt64(metadata.autopilotState.rawValue), to: &payload)
  appendProtoFixed64(field: 11, value: metadata.latitudeDeg.bitPattern, to: &payload)
  appendProtoFixed64(field: 12, value: metadata.longitudeDeg.bitPattern, to: &payload)
  appendProtoFixed64(field: 13, value: metadata.headingDeg.bitPattern, to: &payload)
  appendProtoFixed64(field: 14, value: metadata.linearAccelX.bitPattern, to: &payload)
  appendProtoFixed64(field: 15, value: metadata.linearAccelY.bitPattern, to: &payload)
  appendProtoFixed64(field: 16, value: metadata.linearAccelZ.bitPattern, to: &payload)

  var nal = Data([0x06, 0x05, 0x00, 0x42, 0x69])
  nal.append(payload)
  nal.append(0x80)
  return nal
}

private func appendProtoVarint(field: Int, value: UInt64, to data: inout Data) {
  appendVarint(UInt64(field << 3), to: &data)
  appendVarint(value, to: &data)
}

private func appendProtoFixed32(field: Int, value: UInt32, to data: inout Data) {
  appendVarint(UInt64((field << 3) | 5), to: &data)
  data.append(UInt8(value & 0xFF))
  data.append(UInt8((value >> 8) & 0xFF))
  data.append(UInt8((value >> 16) & 0xFF))
  data.append(UInt8((value >> 24) & 0xFF))
}

private func appendProtoFixed64(field: Int, value: UInt64, to data: inout Data) {
  appendVarint(UInt64((field << 3) | 1), to: &data)
  for shift in stride(from: 0, through: 56, by: 8) {
    data.append(UInt8((value >> UInt64(shift)) & 0xFF))
  }
}

private func appendVarint(_ value: UInt64, to data: inout Data) {
  var value = value
  while value >= 0x80 {
    data.append(UInt8(value & 0x7F) | 0x80)
    value >>= 7
  }
  data.append(UInt8(value))
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
  data.append(UInt8((value >> 24) & 0xFF))
  data.append(UInt8((value >> 16) & 0xFF))
  data.append(UInt8((value >> 8) & 0xFF))
  data.append(UInt8(value & 0xFF))
}

private func teslaTimestampDate(_ timestamp: String) -> Date? {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone.current
  formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
  return formatter.date(from: timestamp)
}

private struct DomainFixtureCase: Decodable {
  let name: String
  let files: [DomainFixtureFile]
  let expectedScan: [String: DomainScanManifestWithoutHeader]
  let expectedLayout: [String: DomainLayoutManifest]?
  let expectedSelection: [String: DomainSelectionManifest]?
  let expectedOutput: DomainOutputManifest?

  enum CodingKeys: String, CodingKey {
    case name
    case files
    case expectedScan = "expected_scan"
    case expectedLayout = "expected_layout"
    case expectedSelection = "expected_selection"
    case expectedOutput = "expected_output"
  }
}

private struct DomainFixtureFile: Decodable {
  let path: String
  let mtime: TimeInterval?
}

private struct DomainScanManifestWithoutHeader: Codable, Equatable {
  let clipSetCount: Int
  let duplicateFileCount: Int
  let duplicateTimestampCount: Int
  let cameras: [String]
  let clipSets: [DomainClipSetManifestWithoutHeader]

  enum CodingKeys: String, CodingKey {
    case clipSetCount = "clip_set_count"
    case duplicateFileCount = "duplicate_file_count"
    case duplicateTimestampCount = "duplicate_timestamp_count"
    case cameras
    case clipSets = "clip_sets"
  }
}

private struct DomainClipSetManifestWithoutHeader: Codable, Equatable {
  let timestamp: String
  let startTime: String
  let cameras: [String]
  let files: [String: String]

  enum CodingKeys: String, CodingKey {
    case timestamp
    case startTime = "start_time"
    case cameras
    case files
  }
}

private extension DomainScanManifest {
  var withoutContractHeader: DomainScanManifestWithoutHeader {
    DomainScanManifestWithoutHeader(
      clipSetCount: clipSetCount,
      duplicateFileCount: duplicateFileCount,
      duplicateTimestampCount: duplicateTimestampCount,
      cameras: cameras,
      clipSets: clipSets.map(\.withoutContractHeader)
    )
  }
}

private extension DomainClipSetManifest {
  var withoutContractHeader: DomainClipSetManifestWithoutHeader {
    DomainClipSetManifestWithoutHeader(
      timestamp: timestamp,
      startTime: startTime,
      cameras: cameras,
      files: files
    )
  }
}

private extension DuplicateClipPolicy {
  var contractValue: String {
    switch self {
    case .mergeByTime: return "merge-by-time"
    case .keepAll: return "keep-all"
    case .preferNewest: return "prefer-newest"
    }
  }
}

private func repositoryRootForTests() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

@MainActor
private func waitForTerminalExport(
  _ controller: NativeExportController,
  timeout: TimeInterval = 30
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if controller.currentJob?.isTerminal == true {
      return true
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
  }
  return controller.currentJob?.isTerminal == true
}

@MainActor
private func indexClipsOffMain(
  inputURLs: [URL],
  duplicatePolicy: DuplicateClipPolicy = .mergeByTime
) async throws -> ClipIndex {
  try await Task.detached(priority: .userInitiated) {
    try ClipIndexer.index(inputURLs: inputURLs, duplicatePolicy: duplicatePolicy) { _ in }
  }.value
}

private func materializeDomainFixture(_ fixture: DomainFixtureCase, at root: URL) throws {
  for entry in fixture.files {
    let url = root.appendingPathComponent(entry.path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("fixture".utf8).write(to: url)
    if let mtime = entry.mtime {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: mtime)],
        ofItemAtPath: url.path
      )
    }
  }
}
