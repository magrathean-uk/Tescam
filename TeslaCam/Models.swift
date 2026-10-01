import Foundation
import CoreGraphics
import Combine
import OSLog
import AVFoundation

nonisolated enum Camera: String, CaseIterable, Hashable, Codable {
  case front
  case back
  case left_repeater
  case right_repeater
  case left
  case right
  case left_pillar
  case right_pillar

  static let hw3ClassicOrder: [Camera] = [
    .front,
    .back,
    .left_repeater,
    .right_repeater
  ]

  static let hw4SixCamOrder: [Camera] = [
    .front,
    .back,
    .left,
    .right,
    .left_pillar,
    .right_pillar
  ]

  static let mixedOrder: [Camera] = [
    .front,
    .back,
    .left_repeater,
    .right_repeater,
    .left,
    .right,
    .left_pillar,
    .right_pillar
  ]

  var displayName: String {
    switch self {
    case .front: return "Front"
    case .back: return "Back"
    case .left_repeater: return "Left Repeater"
    case .right_repeater: return "Right Repeater"
    case .left: return "Left"
    case .right: return "Right"
    case .left_pillar: return "Left Pillar"
    case .right_pillar: return "Right Pillar"
    }
  }

  /// Compact label for inline camera toggle buttons.
  var shortName: String {
    switch self {
    case .front: return "Front"
    case .back: return "Back"
    case .left_repeater: return "L Rep"
    case .right_repeater: return "R Rep"
    case .left: return "Left"
    case .right: return "Right"
    case .left_pillar: return "L Pil"
    case .right_pillar: return "R Pil"
    }
  }
}

nonisolated enum CameraLayoutProfile: String, CaseIterable, Identifiable {
  case hw3FourCam
  case hw4SixCam
  case mixedUnknown

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .hw3FourCam:
      return "HW3 4-Camera"
    case .hw4SixCam:
      return "HW4 6-Camera"
    case .mixedUnknown:
      return "Mixed / Unknown"
    }
  }

  var orderedCameras: [Camera] {
    switch self {
    case .hw3FourCam:
      return Camera.hw3ClassicOrder
    case .hw4SixCam:
      return Camera.hw4SixCamOrder
    case .mixedUnknown:
      return Camera.mixedOrder
    }
  }
}

nonisolated enum CameraLayoutRequest: String, CaseIterable, Codable {
  case auto
  case legacy4
  case sixcam

  var displayName: String {
    switch self {
    case .auto:
      return "Auto"
    case .legacy4:
      return "4-Cam"
    case .sixcam:
      return "6-Cam"
    }
  }
}

extension CameraLayoutRequest: Identifiable {
  var id: String { rawValue }
}

enum PreviewLayoutMode: String, CaseIterable, Identifiable, Codable {
  case grid
  case focus
  case frontRear
  case horizontal
  case pictureInPicture

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .grid:
      return "Grid"
    case .focus:
      return "Focus"
    case .frontRear:
      return "Front/Rear"
    case .horizontal:
      return "Strip"
    case .pictureInPicture:
      return "PiP"
    }
  }
}

nonisolated enum CameraLayoutKind: String {
  case fourUp = "4up"
  case sixUp = "6up"
}

struct CameraLayoutCell: Codable, Equatable {
  let width: Int
  let height: Int
  let x: Int
  let y: Int
}

struct DomainLayoutCanvas: Codable, Equatable {
  let width: Int
  let height: Int
}

struct DomainLayoutManifest: Codable, Equatable {
  let profile: String
  let kind: String
  let expectedCameras: [String]
  let renderOrder: [String]
  let hiddenCameras: [String]
  let canvas: DomainLayoutCanvas
  let cells: [String: CameraLayoutCell]

  enum CodingKeys: String, CodingKey {
    case profile
    case kind
    case expectedCameras = "expected_cameras"
    case renderOrder = "render_order"
    case hiddenCameras = "hidden_cameras"
    case canvas
    case cells
  }
}

nonisolated struct CameraLayoutPlan {
  let requestedProfile: CameraLayoutRequest
  let kind: CameraLayoutKind
  let expectedCameras: [Camera]
  let renderOrder: [Camera]
  let hiddenCameras: [Camera]
  let canvasSize: CGSize
  let cellByCamera: [Camera: CGRect]

  static func build(
    requestedProfile: CameraLayoutRequest,
    detectedCameras: Set<Camera>,
    enabledCameras: Set<Camera>,
    naturalSizes: [Camera: CGSize]
  ) -> CameraLayoutPlan {
    let available = detectedCameras.union(enabledCameras)
    let kind = layoutKind(requestedProfile: requestedProfile, cameras: available)
    let expected = expectedCameras(for: kind)
    let sizes = filledSizes(for: expected, naturalSizes: naturalSizes)
    let cells = buildCells(kind: kind, sizes: sizes)
    let maxX = cells.values.map(\.maxX).max() ?? 1280
    let maxY = cells.values.map(\.maxY).max() ?? 960
    let hidden = available.subtracting(expected).sortedByContractOrder()
    return CameraLayoutPlan(
      requestedProfile: requestedProfile,
      kind: kind,
      expectedCameras: expected,
      renderOrder: expected,
      hiddenCameras: hidden,
      canvasSize: CGSize(width: maxX, height: maxY),
      cellByCamera: cells
    )
  }

  static func detectedProfile(for cameras: Set<Camera>) -> CameraLayoutProfile {
    guard !cameras.isEmpty else { return .mixedUnknown }
    return layoutKind(requestedProfile: .auto, cameras: cameras) == .sixUp ? .hw4SixCam : .hw3FourCam
  }

  var domainLayoutManifest: DomainLayoutManifest {
    var cells: [String: CameraLayoutCell] = [:]
    for camera in renderOrder {
      guard let rect = cellByCamera[camera] else { continue }
      cells[camera.rawValue] = CameraLayoutCell(
        width: Int(rect.width.rounded()),
        height: Int(rect.height.rounded()),
        x: Int(rect.minX.rounded()),
        y: Int(rect.minY.rounded())
      )
    }
    return DomainLayoutManifest(
      profile: requestedProfile.rawValue,
      kind: kind.rawValue,
      expectedCameras: expectedCameras.map(\.rawValue),
      renderOrder: renderOrder.map(\.rawValue),
      hiddenCameras: hiddenCameras.map(\.rawValue),
      canvas: DomainLayoutCanvas(
        width: Int(canvasSize.width.rounded()),
        height: Int(canvasSize.height.rounded())
      ),
      cells: cells
    )
  }

  private static func layoutKind(
    requestedProfile: CameraLayoutRequest,
    cameras: Set<Camera>
  ) -> CameraLayoutKind {
    switch requestedProfile {
    case .legacy4:
      return .fourUp
    case .sixcam:
      return .sixUp
    case .auto:
      let hw4Markers: Set<Camera> = [.left, .right, .left_pillar, .right_pillar]
      return cameras.isDisjoint(with: hw4Markers) ? .fourUp : .sixUp
    }
  }

  private static func expectedCameras(for kind: CameraLayoutKind) -> [Camera] {
    switch kind {
    case .fourUp:
      return Camera.hw3ClassicOrder
    case .sixUp:
      return Camera.hw4SixCamOrder
    }
  }

  private static func filledSizes(
    for cameras: [Camera],
    naturalSizes: [Camera: CGSize]
  ) -> [Camera: CGSize] {
    let known = naturalSizes.values.filter { $0.width > 0 && $0.height > 0 }
    let fallback = CGSize(
      width: known.map(\.width).max() ?? 1280,
      height: known.map(\.height).max() ?? 960
    )
    return Dictionary(uniqueKeysWithValues: cameras.map { camera in
      (camera, naturalSizes[camera] ?? fallback)
    })
  }

  private static func buildCells(
    kind: CameraLayoutKind,
    sizes: [Camera: CGSize]
  ) -> [Camera: CGRect] {
    switch kind {
    case .sixUp:
      let tileWidth = sizes.values.map(\.width).max() ?? 1280
      let tileHeight = sizes.values.map(\.height).max() ?? 960
      let grid: [Camera: (row: Int, col: Int)] = [
        .front: (0, 0),
        .back: (0, 1),
        .left: (0, 2),
        .right: (1, 0),
        .left_pillar: (1, 1),
        .right_pillar: (1, 2)
      ]
      return grid.mapValues { position in
        CGRect(
          x: CGFloat(position.col) * tileWidth,
          y: CGFloat(position.row) * tileHeight,
          width: tileWidth,
          height: tileHeight
        )
      }
    case .fourUp:
      let grid: [Camera: (row: Int, col: Int)] = [
        .front: (0, 0),
        .back: (0, 1),
        .left_repeater: (1, 0),
        .right_repeater: (1, 1)
      ]
      var rowHeights = [CGFloat](repeating: 0, count: 2)
      var colWidths = [CGFloat](repeating: 0, count: 2)
      for (camera, position) in grid {
        let size = sizes[camera] ?? CGSize(width: 1280, height: 960)
        rowHeights[position.row] = max(rowHeights[position.row], size.height)
        colWidths[position.col] = max(colWidths[position.col], size.width)
      }
      let xOffsets: [CGFloat] = [0, colWidths[0]]
      let yOffsets: [CGFloat] = [0, rowHeights[0]]
      return grid.mapValues { position in
        CGRect(
          x: xOffsets[position.col],
          y: yOffsets[position.row],
          width: colWidths[position.col],
          height: rowHeights[position.row]
        )
      }
    }
  }
}

nonisolated private extension Sequence where Element == Camera {
  func sortedByContractOrder() -> [Camera] {
    let order = Dictionary(uniqueKeysWithValues: Camera.mixedOrder.enumerated().map { ($0.element, $0.offset) })
    return sorted { lhs, rhs in
      let lhsIndex = order[lhs] ?? Int.max
      let rhsIndex = order[rhs] ?? Int.max
      if lhsIndex == rhsIndex { return lhs.rawValue < rhs.rawValue }
      return lhsIndex < rhsIndex
    }
  }
}

/// Source video codec detected from a clip's video track. Tesla hardware
/// generations differ: older cars (HW2/2.5/3) record H.264, HW4 records HEVC
/// (H.265). The export pipeline adopts this codec so H.264 footage is never
/// needlessly transcoded to HEVC.
nonisolated enum VideoCodec: String, Hashable, Codable {
  case hevc
  case h264
  case other

  /// Maps a CoreMedia media sub-type (`CMFormatDescriptionGetMediaSubType`).
  init(mediaSubType: CMVideoCodecType) {
    switch mediaSubType {
    case kCMVideoCodecType_HEVC:
      self = .hevc
    case kCMVideoCodecType_H264:
      self = .h264
    default:
      self = .other
    }
  }

  var displayName: String {
    switch self {
    case .hevc: return "H.265"
    case .h264: return "H.264"
    case .other: return "Source"
    }
  }
}

enum ExportPreset: String, CaseIterable, Identifiable {
  case originalTracksMOV
  case maxQualityHEVC
  case maxQualityH264
  case fastHEVC
  case socialShareHEVC
  case proxyHEVC
  case editFriendlyProRes

  private static let referenceCanvasPixels = 1_920.0 * 1_080.0
  private static let defaultFrameRate = 30.0

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .originalTracksMOV:
      return "Original"
    case .maxQualityHEVC:
      return "Evidence HEVC"
    case .maxQualityH264:
      return "Evidence H.264"
    case .fastHEVC:
      return "Fast Review HEVC"
    case .socialShareHEVC:
      return "Social 25 MB HEVC"
    case .proxyHEVC:
      return "Proxy HEVC"
    case .editFriendlyProRes:
      return "Master ProRes"
    }
  }

  var scriptPreset: String {
    switch self {
    case .originalTracksMOV:
      return "PASSTHROUGH_MOV"
    case .maxQualityHEVC:
      return "HEVC_CPU_MAX"
    case .maxQualityH264:
      return "H264_CPU_MAX"
    case .fastHEVC:
      return "HEVC_MAX"
    case .socialShareHEVC:
      return "HEVC_SOCIAL"
    case .proxyHEVC:
      return "HEVC_PROXY"
    case .editFriendlyProRes:
      return "PRORES_HQ"
    }
  }

  var defaultExtension: String {
    switch self {
    case .originalTracksMOV, .editFriendlyProRes:
      return "mov"
    case .maxQualityHEVC, .maxQualityH264, .fastHEVC, .socialShareHEVC, .proxyHEVC:
      return "mp4"
    }
  }

  var outputLabel: String {
    switch self {
    case .originalTracksMOV:
      return "original_tracks"
    case .maxQualityHEVC:
      return "evidence_hevc"
    case .maxQualityH264:
      return "evidence_h264"
    case .fastHEVC:
      return "fast_review_hevc"
    case .socialShareHEVC:
      return "social_25mb_hevc"
    case .proxyHEVC:
      return "proxy_hevc"
    case .editFriendlyProRes:
      return "master_prores"
    }
  }

  func nativeCompressionProperties(for canvasSize: CGSize, frameRate: Double = Self.defaultFrameRate) -> [String: Any] {
    let sourceFrameRate = Int(max(1, min(120, frameRate.rounded())))
    switch self {
    case .originalTracksMOV, .editFriendlyProRes:
      return [:]
    case .maxQualityHEVC:
      return [
        AVVideoAverageBitRateKey: scaledHEVCBitRate(
          for: canvasSize,
          referenceBitRate: 45_000_000,
          scalingExponent: 0.8,
          maximumBitRate: 240_000_000
        ),
        AVVideoExpectedSourceFrameRateKey: sourceFrameRate,
        AVVideoMaxKeyFrameIntervalKey: sourceFrameRate
      ]
    case .maxQualityH264:
      // H.264 is ~1.4× the bits of HEVC for equivalent quality, so the
      // reference/ceiling are scaled up accordingly. Same max-quality intent
      // as the HEVC evidence preset, just on the faster/wider-compatible codec.
      return [
        AVVideoAverageBitRateKey: scaledHEVCBitRate(
          for: canvasSize,
          referenceBitRate: 63_000_000,
          scalingExponent: 0.8,
          maximumBitRate: 320_000_000
        ),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: sourceFrameRate,
        AVVideoMaxKeyFrameIntervalKey: sourceFrameRate
      ]
    case .fastHEVC:
      return [
        AVVideoAverageBitRateKey: scaledHEVCBitRate(
          for: canvasSize,
          referenceBitRate: 20_000_000,
          scalingExponent: 0.78,
          maximumBitRate: 120_000_000
        ),
        AVVideoExpectedSourceFrameRateKey: sourceFrameRate,
        AVVideoMaxKeyFrameIntervalKey: sourceFrameRate
      ]
    case .socialShareHEVC:
      return [
        AVVideoAverageBitRateKey: scaledHEVCBitRate(
          for: canvasSize,
          referenceBitRate: 8_000_000,
          scalingExponent: 0.72,
          maximumBitRate: 35_000_000
        ),
        AVVideoExpectedSourceFrameRateKey: sourceFrameRate,
        AVVideoMaxKeyFrameIntervalKey: sourceFrameRate
      ]
    case .proxyHEVC:
      return [
        AVVideoAverageBitRateKey: scaledHEVCBitRate(
          for: canvasSize,
          referenceBitRate: 4_000_000,
          scalingExponent: 0.70,
          maximumBitRate: 18_000_000
        ),
        AVVideoExpectedSourceFrameRateKey: sourceFrameRate,
        AVVideoMaxKeyFrameIntervalKey: sourceFrameRate
      ]
    }
  }

  private func scaledHEVCBitRate(
    for canvasSize: CGSize,
    referenceBitRate: Double,
    scalingExponent: Double,
    maximumBitRate: Double
  ) -> Int {
    let width = max(1, Double(canvasSize.width.rounded(.up)))
    let height = max(1, Double(canvasSize.height.rounded(.up)))
    let pixelScale = max(1, (width * height) / Self.referenceCanvasPixels)
    let scaled = referenceBitRate * pow(pixelScale, scalingExponent)
    return Int(min(maximumBitRate, max(referenceBitRate, scaled)).rounded())
  }
}

enum ExportJobPhase: String {
  case idle
  case preparing
  case renderingParts
  case concatenating
  case finishing
  case failed
  case cancelled
  case completed

  var displayName: String {
    switch self {
    case .idle: return "Idle"
    case .preparing: return "Preparing clips"
    case .renderingParts: return "Rendering"
    case .concatenating: return "Concatenating"
    case .finishing: return "Finalizing movie"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    case .completed: return "Completed"
    }
  }
}

enum ExportFailureCategory: String {
  case missingScript
  case missingTools
  case outputWrite
  case launch
  case preparation
  case partRender
  case concat
  case cancelled
  case unknown

  var displayName: String {
    switch self {
    case .missingScript: return "Missing Script"
    case .missingTools: return "Missing Tools"
    case .outputWrite: return "Output Write Failure"
    case .launch: return "Launch Failure"
    case .preparation: return "Preparation Failure"
    case .partRender: return "Part Render Failure"
    case .concat: return "Concat Failure"
    case .cancelled: return "Cancelled"
    case .unknown: return "Unknown Failure"
    }
  }
}

struct ExportRequest: Identifiable {
  let id = UUID()
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

  init(
    sets: [ClipSet],
    outputURL: URL,
    useSixCam: Bool,
    preset: ExportPreset,
    enabledCameras: Set<Camera>,
    layoutRequest: CameraLayoutRequest = .auto,
    overlayOptions: ExportOverlayOptions = ExportOverlayOptions(),
    trimStartSeconds: Double,
    trimEndSeconds: Double,
    trimStartDate: Date,
    trimEndDate: Date,
    selectedRangeText: String,
    partialClipCount: Int,
    cameraTrack: CameraTrack = .empty,
    isPreviewSample: Bool = false
  ) {
    self.sets = sets
    self.outputURL = outputURL
    self.useSixCam = useSixCam
    self.preset = preset
    self.enabledCameras = enabledCameras
    self.layoutRequest = layoutRequest
    self.overlayOptions = overlayOptions
    self.trimStartSeconds = trimStartSeconds
    self.trimEndSeconds = trimEndSeconds
    self.trimStartDate = trimStartDate
    self.trimEndDate = trimEndDate
    self.selectedRangeText = selectedRangeText
    self.partialClipCount = partialClipCount
    self.cameraTrack = cameraTrack.normalized
    self.isPreviewSample = isPreviewSample
  }

  var totalParts: Int {
    sets.count
  }

  var totalDuration: Double {
    let dateSpan = trimEndDate.timeIntervalSince(trimStartDate)
    if dateSpan > 0 {
      return dateSpan
    }
    return max(0, trimEndSeconds - trimStartSeconds)
  }
}

struct ExportIssue: Identifiable {
  let id = UUID()
  let message: String
  let isBlocking: Bool
}

struct ExportPreflightSummary {
  let blockingIssues: [ExportIssue]
  let warnings: [ExportIssue]
  let hasWriteAccess: Bool
  let resolvedOutputURL: URL
  let requiresUserSavePanel: Bool

  var canExport: Bool {
    blockingIssues.isEmpty
  }
}

struct TimelineTrimSelection: Equatable {
  var startSeconds: Double
  var endSeconds: Double
  var isDragging: Bool
}

nonisolated enum ExportTelemetryHUDMode: String, Codable, CaseIterable, Identifiable {
  case minimal
  case detailed

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .minimal:
      return "Minimal"
    case .detailed:
      return "Detailed"
    }
  }
}

nonisolated enum TelemetrySpeedUnit: String, Codable, CaseIterable, Identifiable {
  case kilometersPerHour
  case milesPerHour

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .kilometersPerHour:
      return "km/h"
    case .milesPerHour:
      return "mph"
    }
  }

  func speed(fromKmh speedKmh: Double) -> Double {
    switch self {
    case .kilometersPerHour:
      return speedKmh
    case .milesPerHour:
      return speedKmh * 0.621371
    }
  }
}

nonisolated struct ExportOverlayOptions: Codable, Equatable, Hashable {
  var telemetryHUD: Bool = false
  var routeMap: Bool = false
  var privacyMask: Bool = false
  var includeReport: Bool = false
  var includeScreenshot: Bool = false
  var telemetryHUDMode: ExportTelemetryHUDMode = .detailed
  var speedUnit: TelemetrySpeedUnit = .kilometersPerHour

  init(
    telemetryHUD: Bool = false,
    routeMap: Bool = false,
    privacyMask: Bool = false,
    includeReport: Bool = false,
    includeScreenshot: Bool = false,
    telemetryHUDMode: ExportTelemetryHUDMode = .detailed,
    speedUnit: TelemetrySpeedUnit = .kilometersPerHour
  ) {
    self.telemetryHUD = telemetryHUD
    self.routeMap = routeMap
    self.privacyMask = privacyMask
    self.includeReport = includeReport
    self.includeScreenshot = includeScreenshot
    self.telemetryHUDMode = telemetryHUDMode
    self.speedUnit = speedUnit
  }

  enum CodingKeys: String, CodingKey {
    case telemetryHUD
    case routeMap
    case privacyMask
    case includeReport
    case includeScreenshot
    case telemetryHUDMode
    case speedUnit
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    telemetryHUD = try container.decodeIfPresent(Bool.self, forKey: .telemetryHUD) ?? false
    routeMap = try container.decodeIfPresent(Bool.self, forKey: .routeMap) ?? false
    privacyMask = try container.decodeIfPresent(Bool.self, forKey: .privacyMask) ?? false
    includeReport = try container.decodeIfPresent(Bool.self, forKey: .includeReport) ?? false
    includeScreenshot = try container.decodeIfPresent(Bool.self, forKey: .includeScreenshot) ?? false
    telemetryHUDMode = try container.decodeIfPresent(ExportTelemetryHUDMode.self, forKey: .telemetryHUDMode) ?? .detailed
    speedUnit = try container.decodeIfPresent(TelemetrySpeedUnit.self, forKey: .speedUnit) ?? .kilometersPerHour
  }

  var needsTelemetry: Bool {
    telemetryHUD || routeMap || includeReport
  }

  var needsSidecars: Bool {
    includeReport || includeScreenshot
  }
}

struct CameraTrackKeyframe: Codable, Equatable, Hashable, Identifiable {
  let seconds: Double
  let camera: Camera

  var id: String {
    "\(seconds)-\(camera.rawValue)"
  }
}

struct CameraTrack: Codable, Equatable, Hashable {
  static let empty = CameraTrack(keyframes: [])

  let keyframes: [CameraTrackKeyframe]

  var normalized: CameraTrack {
    CameraTrack(
      keyframes: keyframes.sorted {
        if abs($0.seconds - $1.seconds) < 0.001 {
          return $0.camera.rawValue < $1.camera.rawValue
        }
        return $0.seconds < $1.seconds
      }
    )
  }

  var isEmpty: Bool {
    keyframes.isEmpty
  }

  func camera(at seconds: Double) -> Camera? {
    var active: Camera?
    for keyframe in normalized.keyframes {
      guard keyframe.seconds <= seconds + 0.001 else { break }
      active = keyframe.camera
    }
    return active
  }

  func addingCut(seconds: Double, camera: Camera) -> CameraTrack {
    let rounded = (max(0, seconds) * 10).rounded() / 10
    let filtered = keyframes.filter { abs($0.seconds - rounded) >= 0.25 }
    return CameraTrack(keyframes: filtered + [CameraTrackKeyframe(seconds: rounded, camera: camera)]).normalized
  }
}

enum TelemetryEventKind: String, Codable, CaseIterable, Identifiable {
  case brake
  case accelerator
  case leftBlinker
  case rightBlinker
  case steering
  case autopilot
  case gForce

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .brake: return "Brake"
    case .accelerator: return "Gas"
    case .leftBlinker: return "Left"
    case .rightBlinker: return "Right"
    case .steering: return "Steer"
    case .autopilot: return "Assist"
    case .gForce: return "G"
    }
  }
}

struct TelemetryEventMarker: Equatable, Hashable, Identifiable {
  let seconds: Double
  let kind: TelemetryEventKind
  let intensity: Double

  var id: String {
    "\(Int(seconds * 10))-\(kind.rawValue)"
  }

  static func markers(from timeline: TelemetryTimeline) -> [TelemetryEventMarker] {
    var markers: [TelemetryEventMarker] = []
    var seen = Set<String>()

    func append(second: Double, kind: TelemetryEventKind, intensity: Double) {
      let wholeSecond = floor(max(0, second))
      let key = "\(Int(wholeSecond))-\(kind.rawValue)"
      guard seen.insert(key).inserted else { return }
      markers.append(
        TelemetryEventMarker(
          seconds: wholeSecond,
          kind: kind,
          intensity: min(1, max(0, intensity))
        )
      )
    }

    for frame in timeline.frames {
      let seconds = frame.timestampMs / 1000.0
      let sei = frame.sei
      if sei.brakeApplied {
        append(second: seconds, kind: .brake, intensity: 1)
      }
      if sei.blinkerLeft {
        append(second: seconds, kind: .leftBlinker, intensity: 1)
      }
      if sei.blinkerRight {
        append(second: seconds, kind: .rightBlinker, intensity: 1)
      }
      let pedal = Double(sei.acceleratorPedalPosition)
      if pedal >= 35 {
        append(second: seconds, kind: .accelerator, intensity: pedal / 100.0)
      }
      let steering = abs(Double(sei.steeringWheelAngle))
      if steering >= 35 {
        append(second: seconds, kind: .steering, intensity: min(1, steering / 90.0))
      }
      if sei.autopilotState != .none {
        append(second: seconds, kind: .autopilot, intensity: 1)
      }
      let g = sqrt(
        (sei.linearAccelX * sei.linearAccelX)
        + (sei.linearAccelY * sei.linearAccelY)
        + (sei.linearAccelZ * sei.linearAccelZ)
      )
      if g >= 0.7 {
        append(second: seconds, kind: .gForce, intensity: min(1, g / 2.0))
      }
    }

    return markers.sorted {
      if abs($0.seconds - $1.seconds) < 0.001 {
        return $0.kind.rawValue < $1.kind.rawValue
      }
      return $0.seconds < $1.seconds
    }
  }
}

struct CustomLayoutPreset: Codable, Equatable, Hashable {
  let name: String
  let layoutRequest: CameraLayoutRequest
  let previewLayoutMode: PreviewLayoutMode
  let focusedCamera: Camera?
  let overlayOptions: ExportOverlayOptions
  let cameraTrack: CameraTrack
}

enum CustomLayoutPresetCodec {
  static func encode(_ preset: CustomLayoutPreset) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(preset)
  }

  static func decode(_ data: Data) throws -> CustomLayoutPreset {
    try JSONDecoder().decode(CustomLayoutPreset.self, from: data)
  }
}

nonisolated struct TelemetryCoordinate: Equatable, Hashable {
  let latitude: Double
  let longitude: Double

  /// A coordinate is usable only when both components are finite, within valid
  /// geographic bounds, and not the null-island origin. Corrupt SEI telemetry
  /// can decode raw bit patterns into NaN/Inf or absurd magnitudes; feeding
  /// those to MapKit or the export HUD is a crash/garbage risk, so they are
  /// rejected here — the single gate every telemetry consumer goes through.
  var isUsable: Bool {
    latitude.isFinite && longitude.isFinite
      && abs(latitude) <= 90.0 && abs(longitude) <= 180.0
      && (abs(latitude) > 0.0001 || abs(longitude) > 0.0001)
  }
}

nonisolated struct TelemetryRoutePoint: Equatable, Hashable, Identifiable {
  let id: Int
  let seconds: Double
  let coordinate: TelemetryCoordinate
  let speedKmh: Double
  let headingDeg: Double
}

enum ClipHealthSeverity: String, Codable, Equatable, Hashable {
  case info
  case warning
}

struct ClipHealthFact: Codable, Equatable, Hashable, Identifiable {
  let title: String
  let value: String
  let severity: ClipHealthSeverity

  var id: String {
    "\(title)-\(value)"
  }
}

nonisolated struct TelemetryDisplayModel: Equatable, Hashable {
  let speedKmh: Double
  let acceleratorPercent: Double
  let steeringAngleDeg: Double
  let gear: String
  let autopilot: String
  let brakeApplied: Bool
  let blinkerLeft: Bool
  let blinkerRight: Bool
  let headingDeg: Double
  let coordinate: TelemetryCoordinate?
  let accelX: Double
  let accelY: Double
  let accelZ: Double

  /// Non-finite (NaN/Inf) guard. Corrupt SEI decodes raw bit patterns into
  /// Float/Double, so a garbage clip could otherwise put "nan km/h" in the HUD.
  private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

  init(sei: SeiMetadata) {
    speedKmh = Self.finite(Double(sei.vehicleSpeedMps)) * 3.6
    acceleratorPercent = max(0, Self.finite(Double(sei.acceleratorPedalPosition)))
    steeringAngleDeg = Self.finite(Double(sei.steeringWheelAngle))
    switch sei.gearState {
    case .park: gear = "P"
    case .drive: gear = "D"
    case .reverse: gear = "R"
    case .neutral: gear = "N"
    }
    switch sei.autopilotState {
    case .none: autopilot = "Off"
    case .selfDriving: autopilot = "Self-driving"
    case .autosteer: autopilot = "Steering"
    case .tacc: autopilot = "Cruise"
    }
    brakeApplied = sei.brakeApplied
    blinkerLeft = sei.blinkerLeft
    blinkerRight = sei.blinkerRight
    headingDeg = Self.finite(sei.headingDeg)
    let coordinate = TelemetryCoordinate(latitude: sei.latitudeDeg, longitude: sei.longitudeDeg)
    self.coordinate = coordinate.isUsable ? coordinate : nil
    accelX = Self.finite(sei.linearAccelX)
    accelY = Self.finite(sei.linearAccelY)
    accelZ = Self.finite(sei.linearAccelZ)
  }

  var speedText: String {
    speedText(unit: .kilometersPerHour)
  }

  func speedText(unit: TelemetrySpeedUnit) -> String {
    let speed = unit.speed(fromKmh: speedKmh)
    return String(format: "%.1f %@", speed, unit.displayName)
  }

  var acceleratorText: String {
    String(format: "%.0f%%", acceleratorPercent)
  }

  var steeringText: String {
    String(format: "%.0f deg", steeringAngleDeg)
  }

  var headingText: String {
    String(format: "%.0f deg", headingDeg)
  }

  var locationText: String {
    guard let coordinate else { return "No GPS" }
    return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
  }

  var signalText: String {
    switch (blinkerLeft, blinkerRight) {
    case (true, true):
      return "Hazard"
    case (true, false):
      return "Left"
    case (false, true):
      return "Right"
    case (false, false):
      return "Off"
    }
  }

  var gForceText: String {
    String(format: "%.2f/%.2f/%.2f", accelX, accelY, accelZ)
  }

  var compactText: String {
    compactText(unit: .kilometersPerHour)
  }

  func compactText(unit: TelemetrySpeedUnit) -> String {
    "Speed: \(speedText(unit: unit))  Pedal: \(acceleratorText)  Steer: \(steeringText)  Gear: \(gear)  Assist: \(autopilot)  Brake: \(brakeApplied ? "On" : "Off")"
  }
}

struct TeslaCamEventSummary: Identifiable, Hashable {
  let id: String
  let clipIndex: Int
  let timestamp: Date
  let folderURL: URL?
  let thumbnailURL: URL?
  let city: String
  let street: String
  let reason: String
  let camera: String
  let coordinate: TelemetryCoordinate?

  var locationTitle: String {
    let trimmedStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedStreet.isEmpty, !trimmedCity.isEmpty {
      return "\(trimmedStreet), \(trimmedCity)"
    }
    if !trimmedCity.isEmpty {
      return trimmedCity
    }
    return coordinate?.isUsable == true ? "GPS Event" : "Event"
  }

  var reasonTitle: String {
    reason
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }
}

/// Whether the loaded clip carries usable per-frame telemetry. Drives an
/// explicit "no telemetry" UI state instead of a silently empty map/HUD.
/// Telemetry presence is per-clip, not per-car: on a typical HW3 dump the
/// SavedClips carry it (all cameras) while SentryClips/RecentClips do not.
enum TelemetryAvailability {
  case unknown      // nothing loaded yet
  case available    // usable route/telemetry present
  case unavailable  // clip loaded but carries no telemetry
}

enum TeslaCamEventSortMode: String, CaseIterable, Identifiable {
  case oldestFirst
  case newestFirst
  case location

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .oldestFirst:
      return "Oldest"
    case .newestFirst:
      return "Newest"
    case .location:
      return "Place"
    }
  }
}

struct PreviewTimelineState: Equatable {
  var currentGlobalSeconds: Double
  var activeClipSetIndex: Int
  var playing: Bool
}

@MainActor
final class PlaybackUIState: ObservableObject {
  @Published var currentSeconds: Double = 0
  @Published var overlayText: String = ""
  @Published var telemetryText: String = ""
}

struct DebugEvent: Identifiable, Hashable {
  let id = UUID()
  let timestamp: Date
  let category: String
  let message: String
}

final class DebugLogSink: ObservableObject {
  @Published private(set) var events: [DebugEvent] = []

  private let logger = Logger(subsystem: "com.magrathean.TeslaCam", category: "debug")
  private let maxEventCount = 250

  func record(_ message: String, category: String) {
    // Categories are fixed identifiers (e.g. "export", "import") so they
    // stay .public for filtering. Message content is dynamic and may
    // contain user-facing file paths (export destinations, source-folder
    // URLs). Mark it .private so it's redacted in Console.app /
    // sysdiagnose without a debugger attached. The in-app `Show Log`
    // surface still receives the full string via the in-memory `events`
    // array below — that's the canonical user-facing diagnostic.
    logger.log("[\(category, privacy: .public)] \(message, privacy: .private)")
    events.append(DebugEvent(timestamp: Date(), category: category, message: message))
    if events.count > maxEventCount {
      events.removeFirst(events.count - maxEventCount)
    }
  }
}

struct TimelinePlaybackSegment: Equatable {
  let clipIndex: Int?
  let startSeconds: Double
  let duration: Double

  func matchesLoadedSegment(
    clipIndex: Int?,
    startSeconds: Double,
    duration: Double,
    tolerance: Double = 0.001
  ) -> Bool {
    self.clipIndex == clipIndex
      && abs(self.startSeconds - startSeconds) <= tolerance
      && abs(self.duration - duration) <= tolerance
  }
}

struct TimelineCoverageMap {
  enum Scale: Equatable {
    case wallClock
    case recordedClips
  }

  let anchorDate: Date?
  let totalDuration: Double

  private let sortedOriginalIndices: [Int]
  private let originalToSortedIndices: [Int]
  private let startOffsets: [Double]
  private let endOffsets: [Double]
  private let prefixMaxEndOffsets: [Double]
  private let sortedEndOffsets: [Double]
  private let sourceStartDates: [Date]
  private let sourceEndDates: [Date]
  private let scale: Scale

  init(sets: [ClipSet], scale: Scale = .wallClock) {
    guard !sets.isEmpty else {
      anchorDate = nil
      totalDuration = 0
      sortedOriginalIndices = []
      originalToSortedIndices = []
      startOffsets = []
      endOffsets = []
      prefixMaxEndOffsets = []
      sortedEndOffsets = []
      sourceStartDates = []
      sourceEndDates = []
      self.scale = scale
      return
    }

    let ordered = sets.enumerated().sorted { lhs, rhs in
      if lhs.element.date == rhs.element.date {
        if lhs.element.timestamp == rhs.element.timestamp {
          return lhs.element.id < rhs.element.id
        }
        return lhs.element.timestamp < rhs.element.timestamp
      }
      return lhs.element.date < rhs.element.date
    }

    let anchor = ordered[0].element.date
    anchorDate = anchor

    var sortedOriginalIndices: [Int] = []
    var originalToSortedIndices = Array(repeating: -1, count: sets.count)
    var startOffsets: [Double] = []
    var endOffsets: [Double] = []
    var sortedEndOffsets: [Double] = []
    var sourceStartDates: [Date] = []
    var sourceEndDates: [Date] = []
    var recordedOffset = 0.0
    sortedOriginalIndices.reserveCapacity(ordered.count)
    startOffsets.reserveCapacity(ordered.count)
    endOffsets.reserveCapacity(ordered.count)
    sortedEndOffsets.reserveCapacity(ordered.count)
    sourceStartDates.reserveCapacity(ordered.count)
    sourceEndDates.reserveCapacity(ordered.count)

    for (sortedIndex, item) in ordered.enumerated() {
      let originalIndex = item.offset
      let set = item.element
      let duration = max(1.0 / 30.0, set.duration)
      let start: Double
      switch scale {
      case .wallClock:
        start = max(0, set.date.timeIntervalSince(anchor))
      case .recordedClips:
        start = recordedOffset
        recordedOffset += duration
      }
      let end = start + duration

      sortedOriginalIndices.append(originalIndex)
      originalToSortedIndices[originalIndex] = sortedIndex
      startOffsets.append(start)
      endOffsets.append(end)
      sortedEndOffsets.append(end)
      sourceStartDates.append(set.date)
      sourceEndDates.append(set.date.addingTimeInterval(duration))
    }

    var prefixMaxEndOffsets: [Double] = []
    prefixMaxEndOffsets.reserveCapacity(endOffsets.count)
    var coveredEnd = 0.0
    for endOffset in endOffsets {
      coveredEnd = max(coveredEnd, endOffset)
      prefixMaxEndOffsets.append(coveredEnd)
    }

    self.sortedOriginalIndices = sortedOriginalIndices
    self.originalToSortedIndices = originalToSortedIndices
    self.startOffsets = startOffsets
    self.endOffsets = endOffsets
    self.prefixMaxEndOffsets = prefixMaxEndOffsets
    self.sortedEndOffsets = sortedEndOffsets.sorted()
    self.sourceStartDates = sourceStartDates
    self.sourceEndDates = sourceEndDates
    self.scale = scale
    self.totalDuration = max(1.0 / 30.0, endOffsets.max() ?? 0)
  }

  func date(forGlobalSeconds seconds: Double) -> Date? {
    guard let anchorDate else { return nil }
    let clamped = max(0, min(seconds, totalDuration))
    if scale == .recordedClips {
      guard !startOffsets.isEmpty else { return anchorDate }
      if clamped >= totalDuration, let last = sourceEndDates.last {
        return last
      }
      let index = max(0, min(startOffsets.count - 1, upperBound(in: startOffsets, for: clamped) - 1))
      let local = max(0, min(clamped - startOffsets[index], endOffsets[index] - startOffsets[index]))
      return sourceStartDates[index].addingTimeInterval(local)
    }
    return anchorDate.addingTimeInterval(clamped)
  }

  func globalSeconds(for date: Date) -> Double {
    guard let anchorDate else { return 0 }
    if scale == .recordedClips {
      guard !sourceStartDates.isEmpty else { return 0 }
      if date <= sourceStartDates[0] {
        return 0
      }
      for index in sourceStartDates.indices {
        if date >= sourceStartDates[index], date <= sourceEndDates[index] {
          return max(0, min(totalDuration, startOffsets[index] + date.timeIntervalSince(sourceStartDates[index])))
        }
        if index + 1 < sourceStartDates.count,
           date > sourceEndDates[index],
           date < sourceStartDates[index + 1] {
          return startOffsets[index + 1]
        }
      }
      return totalDuration
    }
    let seconds = date.timeIntervalSince(anchorDate)
    return max(0, min(seconds, totalDuration))
  }

  func clipStartOffset(at index: Int) -> Double {
    guard index >= 0, index < originalToSortedIndices.count else { return 0 }
    let sortedIndex = originalToSortedIndices[index]
    guard sortedIndex >= 0 else { return 0 }
    return startOffsets[sortedIndex]
  }

  func activeClipIndex(at globalSeconds: Double, tolerance: Double = 0.001) -> Int? {
    guard !startOffsets.isEmpty else { return nil }
    let clamped = max(0, min(globalSeconds, totalDuration))
    var candidate = upperBound(in: startOffsets, for: clamped) - 1

    while candidate >= 0 {
      if prefixMaxEndOffsets[candidate] + tolerance < clamped {
        break
      }
      if endOffsets[candidate] + tolerance >= clamped {
        return sortedOriginalIndices[candidate]
      }
      candidate -= 1
    }

    return nil
  }

  func nearestClipIndex(to globalSeconds: Double) -> Int {
    if let active = activeClipIndex(at: globalSeconds) {
      return active
    }
    guard !startOffsets.isEmpty else { return 0 }
    let candidate = max(0, upperBound(in: startOffsets, for: globalSeconds) - 1)
    return sortedOriginalIndices[candidate]
  }

  func playbackSegment(
    at globalSeconds: Double,
    tolerance: Double = 0.001,
    minimumDuration: Double = 1.0 / 30.0
  ) -> TimelinePlaybackSegment {
    guard !startOffsets.isEmpty else {
      return TimelinePlaybackSegment(
        clipIndex: nil,
        startSeconds: 0,
        duration: max(minimumDuration, totalDuration)
      )
    }

    let clamped = max(0, min(globalSeconds, totalDuration))
    if let clipIndex = activeClipIndex(at: clamped, tolerance: tolerance) {
      let sortedIndex = originalToSortedIndices[clipIndex]
      let start = startOffsets[sortedIndex]
      let end = endOffsets[sortedIndex]
      return TimelinePlaybackSegment(
        clipIndex: clipIndex,
        startSeconds: start,
        duration: max(minimumDuration, end - start)
      )
    }

    let insertion = upperBound(in: startOffsets, for: clamped)
    let previousCoveredEnd = insertion > 0 ? prefixMaxEndOffsets[insertion - 1] : 0
    let nextStart = insertion < startOffsets.count ? startOffsets[insertion] : totalDuration
    let startSeconds = min(max(previousCoveredEnd, 0), totalDuration)
    let endSeconds = max(startSeconds + minimumDuration, min(nextStart, totalDuration))
    return TimelinePlaybackSegment(
      clipIndex: nil,
      startSeconds: startSeconds,
      duration: endSeconds - startSeconds
    )
  }

  func completedClipCount(at globalSeconds: Double) -> Int {
    guard !sortedEndOffsets.isEmpty else { return 0 }
    let clamped = max(0, min(globalSeconds, totalDuration))
    return upperBound(in: sortedEndOffsets, for: clamped)
  }

  func gapRanges(minimumDuration: Double = 1) -> [TimelineGapRange] {
    guard scale == .wallClock else { return [] }
    guard !startOffsets.isEmpty else { return [] }

    var gaps: [TimelineGapRange] = []
    var coveredEnd = endOffsets[0]

    for index in 1..<startOffsets.count {
      let nextStart = startOffsets[index]
      let uncovered = nextStart - coveredEnd
      if uncovered > minimumDuration {
        gaps.append(
          TimelineGapRange(
            startSeconds: max(0, coveredEnd),
            endSeconds: max(0, nextStart)
          )
        )
      }
      coveredEnd = max(coveredEnd, endOffsets[index])
    }

    return gaps
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

struct TimelineGapRange: Equatable, Hashable {
  let startSeconds: Double
  let endSeconds: Double

  var duration: Double {
    max(0, endSeconds - startSeconds)
  }

  func contains(_ seconds: Double) -> Bool {
    seconds >= startSeconds && seconds < endSeconds
  }

  static func ranges(for sets: [ClipSet], minimumDuration: Double = 1) -> [TimelineGapRange] {
    TimelineCoverageMap(sets: sets).gapRanges(minimumDuration: minimumDuration)
  }
}

struct ExportJobSnapshot: Identifiable {
  let id: UUID
  let request: ExportRequest
  var phase: ExportJobPhase
  var progress: Double
  var phaseLabel: String
  var startedAt: Date
  var finishedAt: Date?
  var outputURL: URL
  var logFileURL: URL
  var workingDirectoryURL: URL?
  var failureCategory: ExportFailureCategory?
  var failureReason: String?
  var completedParts: Int
  var totalParts: Int
  var completedDuration: Double
  var totalDuration: Double
  var isIndeterminate: Bool
  var isTerminal: Bool
  var canRevealOutput: Bool
  var canRevealWorkingFiles: Bool
  var canRetry: Bool
  var isCancelled: Bool

  var elapsedTime: TimeInterval {
    (finishedAt ?? Date()).timeIntervalSince(startedAt)
  }

  var progressPercentText: String {
    "\(Int((progress * 100).rounded()))%"
  }

  var detailText: String {
    if totalDuration > 0 {
      return "\(formatPlaybackDuration(completedDuration)) / \(formatPlaybackDuration(totalDuration))"
    }
    if totalParts > 0 {
      return "\(completedParts) / \(totalParts) clips"
    }
    return request.selectedRangeText
  }
}

struct MutableExportSession {
  let id: UUID
  let request: ExportRequest
  var phase: ExportJobPhase
  var progress: Double
  var phaseLabel: String
  var startedAt: Date
  var finishedAt: Date?
  var outputURL: URL
  var logFileURL: URL
  var tempRootURL: URL?
  var failureCategory: ExportFailureCategory?
  var failureReason: String?
  var completedParts: Int
  var totalParts: Int
  var completedDuration: Double
  var totalDuration: Double
  var isIndeterminate: Bool
  var isTerminal: Bool
  var canRevealOutput: Bool
  var canRevealWorkingFiles: Bool
  var canRetry: Bool
  var isCancelled: Bool

  func snapshot(fileManager: FileManager) -> ExportJobSnapshot {
    ExportJobSnapshot(
      id: id,
      request: request,
      phase: phase,
      progress: progress,
      phaseLabel: phaseLabel,
      startedAt: startedAt,
      finishedAt: finishedAt,
      outputURL: outputURL,
      logFileURL: logFileURL,
      workingDirectoryURL: tempRootURL,
      failureCategory: failureCategory,
      failureReason: failureReason,
      completedParts: completedParts,
      totalParts: totalParts,
      completedDuration: completedDuration,
      totalDuration: totalDuration,
      isIndeterminate: isIndeterminate,
      isTerminal: isTerminal,
      canRevealOutput: canRevealOutput && fileManager.fileExists(atPath: outputURL.path),
      canRevealWorkingFiles: canRevealWorkingFiles && tempRootURL != nil,
      canRetry: canRetry,
      isCancelled: isCancelled
    )
  }
}

enum DuplicateClipPolicy: String, CaseIterable, Identifiable {
  case mergeByTime
  case keepAll
  case preferNewest

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mergeByTime:
      return "Merge by Time"
    case .keepAll:
      return "Keep All"
    case .preferNewest:
      return "Prefer Newest"
    }
  }
}

enum ScanStage: Int, CaseIterable, Identifiable {
  case scanningNestedFolders
  case parsingTimestamps
  case mergingClips
  case preparingTimeline

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .scanningNestedFolders:
      return "Scanning nested folders"
    case .parsingTimestamps:
      return "Parsing timestamps"
    case .mergingClips:
      return "Merging clips by time"
    case .preparingTimeline:
      return "Preparing timeline"
    }
  }
}

nonisolated struct ClipSet: Identifiable, Hashable {
  let id: String
  let timestamp: String
  let date: Date
  let duration: Double
  var files: [Camera: URL]
  var cameraDurations: [Camera: Double]
  var naturalSizes: [Camera: CGSize]
  var cameraFrameRates: [Camera: Double]
  var cameraCodecs: [Camera: VideoCodec]
  /// Cameras in this set whose clip failed to probe (corrupt/truncated media).
  /// Empty for a healthy set. The clip still occupies its grid cell (rendered
  /// black) so the timeline is unbroken, but the UI can flag it.
  var unreadableCameras: Set<Camera>

  init(
    id: String? = nil,
    timestamp: String,
    date: Date,
    duration: Double,
    files: [Camera: URL],
    cameraDurations: [Camera: Double] = [:],
    naturalSizes: [Camera: CGSize] = [:],
    cameraFrameRates: [Camera: Double] = [:],
    cameraCodecs: [Camera: VideoCodec] = [:],
    unreadableCameras: Set<Camera> = []
  ) {
    self.id = id ?? timestamp
    self.timestamp = timestamp
    self.date = date
    self.duration = duration
    self.files = files
    self.cameraDurations = cameraDurations
    self.naturalSizes = naturalSizes
    self.cameraFrameRates = cameraFrameRates
    self.cameraCodecs = cameraCodecs
    self.unreadableCameras = unreadableCameras
  }

  init(
    timestamp: String,
    date: Date,
    duration: Double,
    files: [Camera: URL],
    cameraDurations: [Camera: Double] = [:],
    naturalSizes: [Camera: CGSize] = [:],
    cameraFrameRates: [Camera: Double] = [:],
    cameraCodecs: [Camera: VideoCodec] = [:],
    unreadableCameras: Set<Camera> = []
  ) {
    self.init(
      id: nil,
      timestamp: timestamp,
      date: date,
      duration: duration,
      files: files,
      cameraDurations: cameraDurations,
      naturalSizes: naturalSizes,
      cameraFrameRates: cameraFrameRates,
      cameraCodecs: cameraCodecs,
      unreadableCameras: unreadableCameras
    )
  }

  /// Whether any camera in this set is corrupt/unreadable.
  var hasUnreadableCameras: Bool { !unreadableCameras.isEmpty }

  func file(for camera: Camera) -> URL? {
    files[camera]
  }

  func duration(for camera: Camera) -> Double? {
    cameraDurations[camera]
  }

  func naturalSize(for camera: Camera) -> CGSize? {
    naturalSizes[camera]
  }

  func frameRate(for camera: Camera) -> Double? {
    cameraFrameRates[camera]
  }

  func codec(for camera: Camera) -> VideoCodec? {
    cameraCodecs[camera]
  }

  /// The codec the export pipeline should adopt for this set: the first
  /// readable camera's codec, preferring concrete H.264/HEVC over `.other`.
  var dominantCodec: VideoCodec? {
    let codecs = cameraCodecs.values
    if let concrete = codecs.first(where: { $0 == .hevc || $0 == .h264 }) {
      return concrete
    }
    return codecs.first
  }

  var endDate: Date {
    date.addingTimeInterval(duration)
  }
}

nonisolated struct DuplicateResolutionSummary: Hashable {
  let duplicateFileCount: Int
  let duplicateTimestampCount: Int
  let overlapMinuteCount: Int

  var hasConflicts: Bool {
    duplicateFileCount > 0 || overlapMinuteCount > 0
  }
}

nonisolated struct ClipIndex {
  let sets: [ClipSet]
  let minDate: Date
  let maxDate: Date
  let totalDuration: Double
  let camerasFound: Set<Camera>
  let layoutProfile: CameraLayoutProfile
  let duplicateSummary: DuplicateResolutionSummary

  var duplicateFileCount: Int {
    duplicateSummary.duplicateFileCount
  }
}

struct DomainClipSetManifest: Codable, Equatable {
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

struct DomainScanManifest: Codable, Equatable {
  let schemaVersion: Int
  let type: String
  let clipSetCount: Int
  let duplicateFileCount: Int
  let duplicateTimestampCount: Int
  let cameras: [String]
  let clipSets: [DomainClipSetManifest]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case type
    case clipSetCount = "clip_set_count"
    case duplicateFileCount = "duplicate_file_count"
    case duplicateTimestampCount = "duplicate_timestamp_count"
    case cameras
    case clipSets = "clip_sets"
  }
}

extension ClipIndex {
  func domainScanManifest(relativeTo rootURL: URL) -> DomainScanManifest {
    let cameraOrder = Dictionary(uniqueKeysWithValues: Camera.mixedOrder.enumerated().map { ($0.element, $0.offset) })
    let orderedCameras = camerasFound.sorted { lhs, rhs in
      let lhsIndex = cameraOrder[lhs] ?? Int.max
      let rhsIndex = cameraOrder[rhs] ?? Int.max
      if lhsIndex == rhsIndex { return lhs.rawValue < rhs.rawValue }
      return lhsIndex < rhsIndex
    }
    let clipSetManifests = sets.map { set -> DomainClipSetManifest in
      let cameras = set.files.keys.sorted { lhs, rhs in
        let lhsIndex = cameraOrder[lhs] ?? Int.max
        let rhsIndex = cameraOrder[rhs] ?? Int.max
        if lhsIndex == rhsIndex { return lhs.rawValue < rhs.rawValue }
        return lhsIndex < rhsIndex
      }
      var files: [String: String] = [:]
      for camera in cameras {
        if let url = set.files[camera] {
          files[camera.rawValue] = Self.contractPath(url, relativeTo: rootURL)
        }
      }
      return DomainClipSetManifest(
        timestamp: set.timestamp,
        startTime: Self.contractTimestamp(set.date),
        cameras: cameras.map(\.rawValue),
        files: files
      )
    }

    return DomainScanManifest(
      schemaVersion: 1,
      type: "teslacam.scan",
      clipSetCount: sets.count,
      duplicateFileCount: duplicateSummary.duplicateFileCount,
      duplicateTimestampCount: duplicateSummary.duplicateTimestampCount,
      cameras: orderedCameras.map(\.rawValue),
      clipSets: clipSetManifests
    )
  }

  private static func contractTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: date)
  }

  private static func contractPath(_ url: URL, relativeTo rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    if path.hasPrefix(prefix) {
      return String(path.dropFirst(prefix.count))
    }
    return path
  }
}

// Domain contract types live in `TeslaCam/DomainContract.swift`:
//   DomainSelectedClipSetManifest, DomainSelectionManifest,
//   [ClipSet].domainSelectionManifest(...)
//   OutputConflictPolicy, OutputAlreadyExistsError,
//   DomainOutputContract, DomainOutputErrorEntry, DomainOutputManifest,
//   DomainContractPath
//
// Kept separate so this file stays focused on the core domain model
// (Camera, ClipSet, layouts, scan manifest, ExportRequest, etc.).

struct ExportHealthSummary {
  let totalMinutes: Int
  let gapCount: Int
  let partialSetCount: Int
  let fourCameraSetCount: Int
  let sixCameraSetCount: Int
  let missingCameraCounts: [Camera: Int]

  var hasMixedCoverage: Bool {
    fourCameraSetCount > 0 && sixCameraSetCount > 0
  }

  var missingCoverageSummary: String {
    let ordered = Camera.mixedOrder.compactMap { camera -> String? in
      guard let count = missingCameraCounts[camera], count > 0 else { return nil }
      return "\(camera.displayName): \(count)"
    }
    return ordered.joined(separator: "  ")
  }
}

private func formatPlaybackDuration(_ seconds: Double) -> String {
  let wholeSeconds = max(0, Int(seconds.rounded(.down)))
  let hours = wholeSeconds / 3600
  let minutes = (wholeSeconds % 3600) / 60
  let secs = wholeSeconds % 60
  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, secs)
  }
  return String(format: "%d:%02d", minutes, secs)
}
