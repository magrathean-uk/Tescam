import Foundation

/// Pure helpers extracted from `AppState` for telemetry-derived computation.
/// Kept as a value-namespace so it has no instance state and is trivially testable.
nonisolated enum TelemetryProcessor {
  /// Builds a deduplicated route from a parsed telemetry timeline. Skips frames
  /// inside the same whole second and frames whose coordinate did not move.
  static func routePoints(from timeline: TelemetryTimeline) -> [TelemetryRoutePoint] {
    var points: [TelemetryRoutePoint] = []
    points.reserveCapacity(min(240, timeline.frames.count))
    var lastWholeSecond = -1
    var lastCoordinate: TelemetryCoordinate?
    for frame in timeline.frames {
      let seconds = Int((frame.timestampMs / 1000.0).rounded(.down))
      guard seconds != lastWholeSecond else { continue }
      lastWholeSecond = seconds
      let coordinate = TelemetryCoordinate(
        latitude: frame.sei.latitudeDeg,
        longitude: frame.sei.longitudeDeg
      )
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

  /// Compact one-line telemetry overlay text. Returns empty when no SEI frame is available.
  static func formatTelemetryCompact(_ sei: SeiMetadata?, unit: TelemetrySpeedUnit = .kilometersPerHour) -> String {
    guard let sei else { return "" }
    return TelemetryDisplayModel(sei: sei).compactText(unit: unit)
  }

  static func formatTelemetryDetailed(_ sei: SeiMetadata?, unit: TelemetrySpeedUnit = .kilometersPerHour) -> String {
    guard let sei else { return "" }
    let model = TelemetryDisplayModel(sei: sei)
    return [
      "Speed: \(model.speedText(unit: unit))",
      "Pedal: \(model.acceleratorText)",
      "Steer: \(model.steeringText)",
      "Gear: \(model.gear)",
      "Assist: \(model.autopilot)",
      "Brake: \(model.brakeApplied ? "On" : "Off")",
      "Signal: \(model.signalText)",
      "Heading: \(model.headingText)",
      "GPS: \(model.locationText)",
      "G: \(model.gForceText)"
    ].joined(separator: "  ")
  }

  /// Produces a human-readable duration label like "1h 12m total" or "5m total".
  static func durationString(seconds: Double) -> String {
    let totalMinutes = max(0, Int((seconds / 60).rounded()))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
      return "\(minutes)m total"
    }
    return "\(hours)h \(minutes)m total"
  }

  /// Cameras that should be present for a clip set based on which side cameras
  /// were captured (HW3 repeaters vs HW4 wide/pillar). When the set is fully
  /// mixed or empty, falls back to the supplied profile.
  static func expectedCoverageCameras(for set: ClipSet, layoutProfile: CameraLayoutProfile) -> Set<Camera> {
    let present = Set(set.files.keys)
    let containsClassicSides = !present.intersection([.left_repeater, .right_repeater]).isEmpty
    let containsSixCamMarkers = !present.intersection([.left, .right, .left_pillar, .right_pillar]).isEmpty

    if containsClassicSides && !containsSixCamMarkers {
      return Set(Camera.hw3ClassicOrder)
    }
    if containsSixCamMarkers && !containsClassicSides {
      return Set(Camera.hw4SixCamOrder)
    }
    if containsClassicSides && containsSixCamMarkers {
      return present
    }

    switch layoutProfile {
    case .hw3FourCam:
      return Set(Camera.hw3ClassicOrder)
    case .hw4SixCam:
      return Set(Camera.hw4SixCamOrder)
    case .mixedUnknown:
      return present
    }
  }

  /// Builds the summary surfaced on the loaded screen (timeline minutes, gap
  /// count, partial-set count, HW3 vs HW4 counts, per-camera missing counts).
  /// Pure given the supplied layout profile; the profile only matters for
  /// clip sets that are ambiguous (no side cameras detected at all).
  static func buildHealthSummary(
    from sets: [ClipSet],
    layoutProfile: CameraLayoutProfile
  ) -> ExportHealthSummary {
    var gapCount = 0
    var partialSetCount = 0
    var four = 0
    var six = 0
    var missingCameraCounts: [Camera: Int] = [:]

    for (index, set) in sets.enumerated() {
      let expected = expectedCoverageCameras(for: set, layoutProfile: layoutProfile)
      let present = Set(set.files.keys)

      if expected == Set(Camera.hw3ClassicOrder) {
        four += 1
      } else if expected == Set(Camera.hw4SixCamOrder) {
        six += 1
      }

      if !expected.isEmpty {
        let missing = expected.subtracting(present)
        if !missing.isEmpty {
          partialSetCount += 1
          for camera in missing {
            missingCameraCounts[camera, default: 0] += 1
          }
        }
      }

      if let next = sets[safe: index + 1] {
        let delta = next.date.timeIntervalSince(set.endDate)
        if delta > 1 {
          gapCount += 1
        }
      }
    }

    let timelineMinutes: Int
    if let minStart = sets.map(\.date).min(), let maxEnd = sets.map(\.endDate).max() {
      timelineMinutes = max(1, Int((maxEnd.timeIntervalSince(minStart) / 60).rounded(.up)))
    } else {
      timelineMinutes = max(1, Int((sets.reduce(0) { $0 + $1.duration } / 60).rounded(.up)))
    }

    return ExportHealthSummary(
      totalMinutes: timelineMinutes,
      gapCount: gapCount,
      partialSetCount: partialSetCount,
      fourCameraSetCount: four,
      sixCameraSetCount: six,
      missingCameraCounts: missingCameraCounts
    )
  }

  /// Builds high-level facts about a clip set (file count, total duration,
  /// most common resolution, missing-camera count) for the iPad health panel.
  static func buildClipHealthFacts(
    from sets: [ClipSet],
    layoutProfile: CameraLayoutProfile
  ) -> [ClipHealthFact] {
    let totalDuration = sets.reduce(0) { $0 + $1.duration }
    let fileCount = sets.reduce(0) { $0 + $1.files.count }
    let expectedMissing = sets.reduce(0) { partials, set in
      let expected = expectedCoverageCameras(for: set, layoutProfile: layoutProfile)
      return partials + max(0, expected.subtracting(Set(set.files.keys)).count)
    }
    let resolutions = sets.flatMap { set in
      set.naturalSizes.values.map { size in
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
      }
    }
    let mostCommonResolution = Dictionary(grouping: resolutions, by: { $0 })
      .max { lhs, rhs in lhs.value.count < rhs.value.count }?
      .key ?? "Unknown"

    return [
      ClipHealthFact(title: "Files", value: "\(fileCount)", severity: .info),
      ClipHealthFact(title: "Duration", value: durationString(seconds: totalDuration), severity: .info),
      ClipHealthFact(title: "Main Size", value: mostCommonResolution, severity: .info),
      ClipHealthFact(
        title: "Missing",
        value: "\(expectedMissing)",
        severity: expectedMissing == 0 ? .info : .warning
      )
    ]
  }

  /// Walks distinct clip-set folders and reads `event.json` + `thumb.png`
  /// to produce one summary per recorded event for the iPad event rail.
  static func buildEventSummaries(from sets: [ClipSet]) -> [TeslaCamEventSummary] {
    var seenFolders = Set<String>()
    var events: [TeslaCamEventSummary] = []
    for (index, set) in sets.enumerated() {
      guard let folder = set.files.values.first?.deletingLastPathComponent() else { continue }
      let folderKey = folder.standardizedFileURL.path
      guard seenFolders.insert(folderKey).inserted else { continue }
      events.append(loadEventSummary(folder: folder, fallbackDate: set.date, clipIndex: index))
    }
    return events.sorted { $0.timestamp < $1.timestamp }
  }

  /// Reads a single `event.json` payload alongside the clip folder, falling back
  /// to the clip's own timestamp and skipping a missing thumbnail.
  static func loadEventSummary(folder: URL, fallbackDate: Date, clipIndex: Int) -> TeslaCamEventSummary {
    let eventURL = folder.appendingPathComponent("event.json")
    let thumbnailURL = folder.appendingPathComponent("thumb.png")
    var payload: EventJSON?
    if let data = try? Data(contentsOf: eventURL) {
      payload = try? JSONDecoder().decode(EventJSON.self, from: data)
    }
    let date = payload?.parsedTimestamp ?? fallbackDate
    let coordinate = TelemetryCoordinate(
      latitude: Double(payload?.estLat ?? "") ?? 0,
      longitude: Double(payload?.estLon ?? "") ?? 0
    )
    return TeslaCamEventSummary(
      id: folder.standardizedFileURL.path,
      clipIndex: clipIndex,
      timestamp: date,
      folderURL: folder,
      thumbnailURL: FileManager.default.fileExists(atPath: thumbnailURL.path) ? thumbnailURL : nil,
      city: payload?.city ?? "",
      street: payload?.street ?? "",
      reason: payload?.reason ?? "recording",
      camera: payload?.camera ?? "",
      coordinate: coordinate.isUsable ? coordinate : nil
    )
  }
}

nonisolated struct TelemetryRouteFrame: Equatable, Hashable {
  let seconds: Double
  let coordinate: TelemetryCoordinate
  let speedKmh: Double
  let headingDeg: Double
  let progress: Double
}

nonisolated struct TelemetryRouteReplay {
  let route: [TelemetryRoutePoint]

  init(route: [TelemetryRoutePoint]) {
    self.route = route.sorted { $0.seconds < $1.seconds }
  }

  func frame(at seconds: Double) -> TelemetryRouteFrame {
    guard let first = route.first else {
      return TelemetryRouteFrame(
        seconds: 0,
        coordinate: TelemetryCoordinate(latitude: 0, longitude: 0),
        speedKmh: 0,
        headingDeg: 0,
        progress: 0
      )
    }
    guard let last = route.last, last != first else {
      return Self.frame(from: first, progress: 0)
    }

    if seconds <= first.seconds {
      return Self.frame(from: first, progress: 0)
    }
    if seconds >= last.seconds {
      return Self.frame(from: last, progress: 1)
    }

    let upperIndex = upperBound(for: seconds)
    let lower = route[max(0, upperIndex - 1)]
    let upper = route[min(upperIndex, route.count - 1)]
    let span = max(upper.seconds - lower.seconds, 0.0001)
    let ratio = min(max((seconds - lower.seconds) / span, 0), 1)
    let duration = max(last.seconds - first.seconds, 0.0001)

    return TelemetryRouteFrame(
      seconds: seconds,
      coordinate: TelemetryCoordinate(
        latitude: Self.interpolate(lower.coordinate.latitude, upper.coordinate.latitude, ratio),
        longitude: Self.interpolate(lower.coordinate.longitude, upper.coordinate.longitude, ratio)
      ),
      speedKmh: Self.interpolate(lower.speedKmh, upper.speedKmh, ratio),
      headingDeg: Self.interpolateHeading(from: lower.headingDeg, to: upper.headingDeg, ratio: ratio),
      progress: min(max((seconds - first.seconds) / duration, 0), 1)
    )
  }

  static func displaySamples(from route: [TelemetryRoutePoint], maxPoints: Int = 8_000) -> [TelemetryRoutePoint] {
    guard route.count > maxPoints, maxPoints > 2 else { return route }

    struct ScoredPoint {
      let index: Int
      let score: Double
    }

    var scored: [ScoredPoint] = []
    scored.reserveCapacity(route.count - 2)
    for index in 1..<(route.count - 1) {
      let previous = route[index - 1]
      let current = route[index]
      let next = route[index + 1]
      let headingDelta = Self.headingDelta(from: previous.headingDeg, to: next.headingDeg)
      let distance = Self.distanceMeters(from: previous.coordinate, to: next.coordinate)
      let speedBoost = min(max(current.speedKmh, 0), 140) * 2
      scored.append(ScoredPoint(index: index, score: abs(headingDelta) * 30 + distance + speedBoost))
    }

    let keepCount = maxPoints - 2
    let kept = Set(scored.sorted { $0.score > $1.score }.prefix(keepCount).map(\.index))
    var result = [route[0]]
    result.reserveCapacity(maxPoints)
    for index in 1..<(route.count - 1) where kept.contains(index) {
      result.append(route[index])
    }
    result.append(route[route.count - 1])
    return result
  }

  private static func frame(from point: TelemetryRoutePoint, progress: Double) -> TelemetryRouteFrame {
    TelemetryRouteFrame(
      seconds: point.seconds,
      coordinate: point.coordinate,
      speedKmh: point.speedKmh,
      headingDeg: point.headingDeg,
      progress: progress
    )
  }

  private func upperBound(for seconds: Double) -> Int {
    var low = 0
    var high = route.count
    while low < high {
      let mid = (low + high) / 2
      if route[mid].seconds <= seconds {
        low = mid + 1
      } else {
        high = mid
      }
    }
    return low
  }

  private static func interpolate(_ left: Double, _ right: Double, _ ratio: Double) -> Double {
    left + ((right - left) * ratio)
  }

  private static func interpolateHeading(from left: Double, to right: Double, ratio: Double) -> Double {
    let delta = headingDelta(from: left, to: right)
    let value = left + (delta * ratio)
    if value < 0 {
      return value + 360
    }
    if value >= 360 {
      return value - 360
    }
    return value
  }

  private static func headingDelta(from left: Double, to right: Double) -> Double {
    var delta = right - left
    if delta > 180 {
      delta -= 360
    } else if delta < -180 {
      delta += 360
    }
    return delta
  }

  private static func distanceMeters(from left: TelemetryCoordinate, to right: TelemetryCoordinate) -> Double {
    let earthRadius = 6_371_000.0
    let lat1 = left.latitude * .pi / 180
    let lat2 = right.latitude * .pi / 180
    let dLat = (right.latitude - left.latitude) * .pi / 180
    let dLon = (right.longitude - left.longitude) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
      + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
  }
}

nonisolated enum TelemetryRouteStyle {
  static func lineWidth(latitudeDelta: Double, longitudeDelta: Double) -> Double {
    let delta = max(latitudeDelta, longitudeDelta)
    switch delta {
    case let value where value > 8.0:
      return 2.0
    case let value where value > 4.0:
      return 2.6
    case let value where value > 1.5:
      return 3.1
    case let value where value > 0.7:
      return 3.6
    default:
      return 4.0
    }
  }
}

nonisolated enum TelemetryRouteSignature {
  static func route(_ route: [TelemetryRoutePoint]) -> String {
    route.map { point in
      "\(roundedString(point.seconds)):\(roundedString(point.coordinate.latitude)),\(roundedString(point.coordinate.longitude))"
    }.joined(separator: "|")
  }

  private static func roundedString(_ value: Double) -> String {
    let rounded = (value * 1000).rounded() / 1000
    if rounded.rounded() == rounded {
      return "\(Int(rounded))"
    }
    return "\(rounded)"
  }
}

nonisolated private struct EventJSON: Decodable {
  let timestamp: String?
  let city: String?
  let street: String?
  let estLat: String?
  let estLon: String?
  let reason: String?
  let camera: String?

  enum CodingKeys: String, CodingKey {
    case timestamp
    case city
    case street
    case estLat = "est_lat"
    case estLon = "est_lon"
    case reason
    case camera
  }

  var parsedTimestamp: Date? {
    guard let timestamp else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.date(from: timestamp)
  }
}
