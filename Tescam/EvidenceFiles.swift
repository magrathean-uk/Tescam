import Foundation
import CryptoKit

// Evidence files written next to an export: a manifest with SHA-256 hashes, a
// telemetry CSV and a GPX track. Formatting is pure; the CSV and GPX are streamed
// row by row to temp files that only move into place once the whole set is done.

nonisolated enum EvidenceError: LocalizedError, Equatable {
  case cancelled
  case unreadable(file: String, detail: String)
  case writeFailed(file: String, detail: String)
  case sourceChanged(file: String)

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return "Evidence files were cancelled."
    case .unreadable(let file, let detail):
      return "Could not read \(file) to hash it: \(detail)"
    case .writeFailed(let file, let detail):
      return "Could not write evidence file \(file): \(detail)"
    case .sourceChanged(let file):
      return "Source clip \(file) changed while the export was running, so evidence files would not match the video."
    }
  }
}

// MARK: - Hashing

nonisolated struct FileFingerprint: Equatable {
  let sha256: String
  let byteCount: Int64
}

nonisolated enum FileHasher {
  static let defaultChunkSize = 1 << 20

  static func sha256Hex(of data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  /// Streams the file through SHA-256 in `chunkSize` pieces so a multi-gigabyte
  /// export never has to fit in memory. `onBytes` receives each chunk's size;
  /// `shouldCancel` is checked between chunks.
  static func fingerprint(
    of url: URL,
    chunkSize: Int = defaultChunkSize,
    onBytes: (Int) -> Void = { _ in },
    shouldCancel: () -> Bool = { false }
  ) throws -> FileFingerprint {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw EvidenceError.unreadable(file: url.lastPathComponent, detail: error.localizedDescription)
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    var total: Int64 = 0
    while true {
      if shouldCancel() { throw EvidenceError.cancelled }
      let chunk: Data?
      do {
        chunk = try autoreleasepool { try handle.read(upToCount: max(1, chunkSize)) }
      } catch {
        throw EvidenceError.unreadable(file: url.lastPathComponent, detail: error.localizedDescription)
      }
      guard let chunk, !chunk.isEmpty else { break }
      hasher.update(data: chunk)
      total += Int64(chunk.count)
      onBytes(chunk.count)
    }
    return FileFingerprint(sha256: hex(hasher.finalize()), byteCount: total)
  }

  static func hex(_ digest: SHA256.Digest) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    out.reserveCapacity(64)
    for byte in digest {
      out.append(digits[Int(byte >> 4)])
      out.append(digits[Int(byte & 0x0F)])
    }
    return out
  }
}


// MARK: - Telemetry samples

nonisolated struct EvidenceTelemetrySample: Equatable {
  var date: Date
  /// True when the parser had no per-sample time and spaced the samples at a
  /// nominal frame interval, so `date` is an estimate.
  var timeEstimated = false
  var speedKmh: Double?
  var autopilotState: String
  var acceleratorPercent: Double?
  var brakeApplied: Bool
  var steeringAngleDeg: Double?
  var headingDeg: Double?
  var latitude: Double?
  var longitude: Double?

  var hasPosition: Bool { latitude != nil && longitude != nil }

  init(sei: SeiMetadata, date: Date, timeEstimated: Bool = false) {
    func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
    self.date = date
    self.timeEstimated = timeEstimated
    speedKmh = finite(Double(sei.vehicleSpeedMps) * 3.6)
    switch sei.autopilotState {
    case .none: autopilotState = "none"
    case .selfDriving: autopilotState = "self_driving"
    case .autosteer: autopilotState = "autosteer"
    case .tacc: autopilotState = "tacc"
    }
    acceleratorPercent = finite(Double(sei.acceleratorPedalPosition))
    brakeApplied = sei.brakeApplied
    steeringAngleDeg = finite(Double(sei.steeringWheelAngle))
    headingDeg = finite(sei.headingDeg)
    let coordinate = TelemetryCoordinate(latitude: sei.latitudeDeg, longitude: sei.longitudeDeg)
    if coordinate.isUsable {
      latitude = coordinate.latitude
      longitude = coordinate.longitude
    }
  }
}

/// Locale-free formatting helpers shared by the writers. Numbers are rendered
/// from integers so the decimal separator is always ".".
nonisolated enum EvidenceFormat {
  static let utc = TimeZone(secondsFromGMT: 0)!

  static func fixed(_ value: Double?, decimals: Int) -> String {
    guard let value, value.isFinite else { return "" }
    var scale: Double = 1
    for _ in 0..<decimals { scale *= 10 }
    let scaled = (abs(value) * scale).rounded(.toNearestOrAwayFromZero)
    guard scaled < 9e18 else { return "" }
    let units = Int64(scaled)
    let divisor = Int64(scale)
    var text = String(units / divisor)
    if decimals > 0 {
      let fraction = String(units % divisor)
      text += "." + String(repeating: "0", count: decimals - fraction.count) + fraction
    }
    return (value < 0 && units != 0) ? "-" + text : text
  }

  static func formatter(timeZone: TimeZone, fractional: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = fractional
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }

  /// UTC (`...Z`) unless a time zone is given, which renders its offset (`...+01:00`).
  static func iso8601(_ date: Date, fractional: Bool, timeZone: TimeZone = utc) -> String {
    formatter(timeZone: timeZone, fractional: fractional).string(from: date)
  }

  static func offsetText(for timeZone: TimeZone, at date: Date) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    let minutes = abs(seconds) / 60
    return (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }
}

// MARK: - Streamed output files

/// A file written in pieces to a hidden temp name next to its final name, hashing
/// as it goes. Nothing replaces the final name until `promote()`, so a failed or
/// cancelled run never touches an earlier run's files.
nonisolated final class EvidenceStreamFile {
  static let flushThreshold = 1 << 16

  let finalURL: URL
  let tempURL: URL
  private var handle: FileHandle?
  private var buffer = Data()
  private var hasher = SHA256()
  private(set) var byteCount: Int64 = 0
  private(set) var sha256 = ""

  init(finalURL: URL) throws {
    self.finalURL = finalURL
    tempURL = finalURL.deletingLastPathComponent()
      .appendingPathComponent(".\(finalURL.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
      throw EvidenceError.writeFailed(file: finalURL.lastPathComponent, detail: "could not create a temporary file")
    }
    do {
      handle = try FileHandle(forWritingTo: tempURL)
    } catch {
      try? FileManager.default.removeItem(at: tempURL)
      throw EvidenceError.writeFailed(file: finalURL.lastPathComponent, detail: error.localizedDescription)
    }
  }

  func append(_ text: String) throws {
    buffer.append(contentsOf: text.utf8)
    if buffer.count >= Self.flushThreshold { try flush() }
  }

  func append(_ data: Data) throws {
    buffer.append(data)
    if buffer.count >= Self.flushThreshold { try flush() }
  }

  private func flush() throws {
    guard !buffer.isEmpty, let handle else { return }
    do {
      try handle.write(contentsOf: buffer)
    } catch {
      throw EvidenceError.writeFailed(file: finalURL.lastPathComponent, detail: error.localizedDescription)
    }
    hasher.update(data: buffer)
    byteCount += Int64(buffer.count)
    buffer.removeAll(keepingCapacity: true)
  }

  /// Flushes and closes; returns the name, size and SHA-256 of what was written.
  func finish() throws -> EvidenceFileRecord {
    try flush()
    try? handle?.close()
    handle = nil
    sha256 = FileHasher.hex(hasher.finalize())
    return EvidenceFileRecord(name: finalURL.lastPathComponent, byteCount: byteCount, sha256: sha256)
  }

  func promote() throws {
    let fm = FileManager.default
    do {
      if fm.fileExists(atPath: finalURL.path) {
        _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
      } else {
        try fm.moveItem(at: tempURL, to: finalURL)
      }
    } catch {
      throw EvidenceError.writeFailed(file: finalURL.lastPathComponent, detail: error.localizedDescription)
    }
  }

  func discard() {
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: tempURL)
  }
}

// MARK: - CSV

nonisolated enum EvidenceCSV {
  /// RFC 4180: quote a field containing a comma, quote, CR or LF; double embedded quotes.
  static func escape(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
      return field
    }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

nonisolated enum TelemetryCSVWriter {
  /// `timestamp_utc` is derived from the clip file name (local wall-clock time in
  /// the assumed zone recorded in the manifest); `timestamp_local` shows the same
  /// instant with that zone's offset. `time_estimated` is 1 when the parser had
  /// no real per-sample time.
  static let header = [
    "timestamp_utc",
    "speed_kmh",
    "autopilot_state",
    "accelerator_pedal_percent",
    "brake_applied",
    "steering_angle_deg",
    "heading_deg",
    "latitude",
    "longitude",
    "timestamp_local",
    "time_estimated"
  ]

  static var headerLine: String { header.map(EvidenceCSV.escape).joined(separator: ",") + "\r\n" }

  struct RowFormatter {
    private let utc = EvidenceFormat.formatter(timeZone: EvidenceFormat.utc, fractional: true)
    private let local: ISO8601DateFormatter

    init(timeZone: TimeZone) {
      local = EvidenceFormat.formatter(timeZone: timeZone, fractional: true)
    }

    func row(_ sample: EvidenceTelemetrySample) -> String {
      let cells = [
        utc.string(from: sample.date),
        EvidenceFormat.fixed(sample.speedKmh, decimals: 2),
        sample.autopilotState,
        EvidenceFormat.fixed(sample.acceleratorPercent, decimals: 1),
        sample.brakeApplied ? "1" : "0",
        EvidenceFormat.fixed(sample.steeringAngleDeg, decimals: 1),
        EvidenceFormat.fixed(sample.headingDeg, decimals: 1),
        EvidenceFormat.fixed(sample.latitude, decimals: 7),
        EvidenceFormat.fixed(sample.longitude, decimals: 7),
        local.string(from: sample.date),
        sample.timeEstimated ? "1" : "0"
      ]
      return cells.map(EvidenceCSV.escape).joined(separator: ",") + "\r\n"
    }
  }

  static func data(samples: [EvidenceTelemetrySample], timeZone: TimeZone = .current) -> Data {
    let formatter = RowFormatter(timeZone: timeZone)
    var out = headerLine
    for sample in samples { out += formatter.row(sample) }
    return Data(out.utf8)
  }
}

// MARK: - GPX

nonisolated enum GPXWriter {
  static let garminNamespace = "http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
  static let garminSchema = "http://www.garmin.com/xmlschemas/TrackPointExtensionv2.xsd"
  static let footer = "    </trkseg>\n  </trk>\n</gpx>\n"

  static func escape(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&apos;"
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  static func latitudeText(_ value: Double) -> String {
    EvidenceFormat.fixed(min(max(value, -90), 90), decimals: 7)
  }

  /// GPX longitude is [-180, 180): 180 is written as -180, the same meridian.
  static func longitudeText(_ value: Double) -> String {
    let text = EvidenceFormat.fixed(min(max(value, -180), 180), decimals: 7)
    return text == "180.0000000" ? "-180.0000000" : text
  }

  /// GPX 1.1 has no speed element, so speed (m/s) and heading go in the Garmin
  /// TrackPointExtension v2 (`gpxtpx:speed`, `gpxtpx:course`); those elements
  /// first appear in v2.
  static func header(name: String, firstDate: Date) -> String {
    var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    out += "<gpx version=\"1.1\" creator=\"Tescam\""
    out += " xmlns=\"http://www.topografix.com/GPX/1/1\""
    out += " xmlns:gpxtpx=\"\(garminNamespace)\""
    out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
    out += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"
    out += " \(garminNamespace) \(garminSchema)\">\n"
    out += "  <metadata>\n    <name>\(escape(name))</name>\n"
    out += "    <time>\(EvidenceFormat.iso8601(firstDate, fractional: true))</time>\n  </metadata>\n"
    out += "  <trk>\n    <name>\(escape(name))</name>\n    <trkseg>\n"
    return out
  }

  /// One `trkpt`, or nil when the sample has no usable position.
  static func point(_ sample: EvidenceTelemetrySample, formatter: ISO8601DateFormatter? = nil) -> String? {
    guard let latitude = sample.latitude, let longitude = sample.longitude else { return nil }
    let time = formatter?.string(from: sample.date) ?? EvidenceFormat.iso8601(sample.date, fractional: true)
    var out = "      <trkpt lat=\"\(latitudeText(latitude))\" lon=\"\(longitudeText(longitude))\">\n"
    out += "        <time>\(time)</time>\n"
    var extensionLines = ""
    if let speed = sample.speedKmh {
      extensionLines += "            <gpxtpx:speed>\(EvidenceFormat.fixed(speed / 3.6, decimals: 2))</gpxtpx:speed>\n"
    }
    if let heading = sample.headingDeg {
      let course = heading.truncatingRemainder(dividingBy: 360)
      extensionLines += "            <gpxtpx:course>\(EvidenceFormat.fixed(course < 0 ? course + 360 : course, decimals: 1))</gpxtpx:course>\n"
    }
    if !extensionLines.isEmpty {
      out += "        <extensions>\n          <gpxtpx:TrackPointExtension>\n\(extensionLines)          </gpxtpx:TrackPointExtension>\n        </extensions>\n"
    }
    out += "      </trkpt>\n"
    return out
  }

  /// Whole-file convenience for small inputs; the export streams `header`,
  /// `point` and `footer` instead. Nil when no sample has a position.
  static func data(samples: [EvidenceTelemetrySample], name: String) -> Data? {
    guard let first = samples.first(where: \.hasPosition) else { return nil }
    var out = header(name: name, firstDate: first.date)
    for sample in samples { if let point = point(sample) { out += point } }
    return Data((out + footer).utf8)
  }
}

// MARK: - Manifest

nonisolated struct EvidenceFileRecord: Equatable {
  var name: String
  var byteCount: Int64
  var sha256: String
}

nonisolated struct EvidenceSourceRecord: Equatable {
  var path: String
  var camera: String
  var clipStart: Date
  var byteCount: Int64
  var sha256: String
}

nonisolated struct EvidenceManifestInput {
  var appName = "Tescam"
  var appVersion = "unknown"
  var appBuild = "unknown"
  var exportedAt: Date
  var rangeStart: Date
  var rangeEnd: Date
  var rangeText: String
  var trimStartSeconds: Double
  var trimEndSeconds: Double
  var cameras: [String]
  var layout: String
  var useSixCam: Bool
  var canvasWidth: Int
  var canvasHeight: Int
  var preset: String
  var presetName: String
  var codec: String
  var cameraCutCount: Int
  var overlays: ExportOverlayOptions
  var sources: [EvidenceSourceRecord]
  var output: EvidenceFileRecord
  var companions: [(kind: String, file: EvidenceFileRecord)]
  /// Clips the telemetry was read from (may be outside the exported cameras).
  var telemetrySources: [EvidenceSourceRecord] = []
  var telemetrySampleCount = 0
  var telemetryEstimatedCount = 0
  /// Dashcam file names carry local wall-clock time; this is the zone assumed to
  /// turn them into UTC.
  var timeZone = TimeZone.current
}

nonisolated enum EvidenceManifest {
  static let formatVersion = 1

  /// Stable bytes: sorted keys, fixed number rounding, sources sorted by path.
  /// Only `exported_at` changes between two exports of the same inputs.
  static func data(_ input: EvidenceManifestInput) throws -> Data {
    func ms(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    func file(_ record: EvidenceFileRecord) -> [String: Any] {
      ["name": record.name, "bytes": record.byteCount, "sha256": record.sha256]
    }
    func clips(_ records: [EvidenceSourceRecord]) -> [[String: Any]] {
      records
        .sorted { ($0.path, $0.camera) < ($1.path, $1.camera) }
        .map { source -> [String: Any] in
          [
            "path": source.path,
            "camera": source.camera,
            "clip_start_utc": EvidenceFormat.iso8601(source.clipStart, fractional: true),
            "clip_start_local": EvidenceFormat.iso8601(source.clipStart, fractional: true, timeZone: input.timeZone),
            "bytes": source.byteCount,
            "sha256": source.sha256
          ]
        }
    }
    let companions = input.companions
      .sorted { $0.file.name < $1.file.name }
      .map { entry -> [String: Any] in
        var item = file(entry.file)
        item["kind"] = entry.kind
        return item
      }
    let timing: String
    if input.telemetrySampleCount == 0 {
      timing = "none"
    } else if input.telemetryEstimatedCount == 0 {
      timing = "exact"
    } else if input.telemetryEstimatedCount == input.telemetrySampleCount {
      timing = "estimated"
    } else {
      timing = "mixed"
    }
    let overlays = input.overlays
    let root: [String: Any] = [
      "manifest_version": formatVersion,
      "app": ["name": input.appName, "version": input.appVersion, "build": input.appBuild],
      "exported_at": EvidenceFormat.iso8601(input.exportedAt, fractional: false),
      "time_basis": [
        "assumed_time_zone": input.timeZone.identifier,
        "utc_offset_at_range_start": EvidenceFormat.offsetText(for: input.timeZone, at: input.rangeStart),
        "source": "Clip file names hold local wall-clock time. UTC values are derived from the assumed time zone, not recorded by the camera."
      ],
      "range": [
        "start_utc": EvidenceFormat.iso8601(input.rangeStart, fractional: true),
        "end_utc": EvidenceFormat.iso8601(input.rangeEnd, fractional: true),
        "start_local": EvidenceFormat.iso8601(input.rangeStart, fractional: true, timeZone: input.timeZone),
        "end_local": EvidenceFormat.iso8601(input.rangeEnd, fractional: true, timeZone: input.timeZone),
        "duration_seconds": ms(input.rangeEnd.timeIntervalSince(input.rangeStart)),
        "trim_start_seconds": ms(input.trimStartSeconds),
        "trim_end_seconds": ms(input.trimEndSeconds),
        "description": input.rangeText
      ] as [String: Any],
      "cameras": input.cameras,
      "export": [
        "preset": input.preset,
        "preset_name": input.presetName,
        "codec": input.codec,
        "layout": input.layout,
        "six_camera_grid": input.useSixCam,
        "canvas": ["width": input.canvasWidth, "height": input.canvasHeight],
        "camera_cuts": input.cameraCutCount,
        "overlays": [
          "telemetry_hud": overlays.telemetryHUD,
          "route_map": overlays.routeMap,
          "privacy_mask": overlays.privacyMask,
          "report": overlays.includeReport,
          "screenshot": overlays.includeScreenshot
        ]
      ] as [String: Any],
      "source_clips": clips(input.sources),
      "telemetry": [
        "samples": input.telemetrySampleCount,
        "estimated_time_samples": input.telemetryEstimatedCount,
        "timing": timing,
        "source_clips": clips(input.telemetrySources)
      ] as [String: Any],
      "output": file(input.output),
      "companion_files": companions
    ]
    var data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
  }
}

// MARK: - Export step

nonisolated struct EvidenceExportInput {
  var outputURL: URL
  var sets: [ClipSet]
  /// Cameras enabled for the export; their clips are the candidates for hashing.
  var cameras: [Camera]
  var sourceRoots: [URL]
  var trimStartDate: Date
  var trimEndDate: Date
  var trimStartSeconds: Double
  var trimEndSeconds: Double
  var rangeText: String
  var layout: String
  var useSixCam: Bool
  var canvasWidth: Int
  var canvasHeight: Int
  var preset: String
  var presetName: String
  var codec: String
  var cameraCutCount: Int
  var overlays: ExportOverlayOptions
  /// False when privacy masking is on: the manifest is still written, but no
  /// telemetry or GPS leaves the app.
  var includeTelemetryFiles: Bool
  var timeZone = TimeZone.current
}

extension ExportPlan {
  var evidenceInput: EvidenceExportInput {
    let codec: String
    switch preset {
    case .originalTracksMOV: codec = "passthrough"
    case .maxQualityHEVC, .fastHEVC, .socialShareHEVC, .proxyHEVC: codec = "hevc"
    case .maxQualityH264: codec = "h264"
    case .editFriendlyProRes: codec = "prores_422_hq"
    }
    return EvidenceExportInput(
      outputURL: outputURL,
      sets: sets,
      cameras: enabledCameras.sorted { $0.rawValue < $1.rawValue },
      sourceRoots: evidenceSourceRoots,
      trimStartDate: trimStartDate,
      trimEndDate: trimEndDate,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      rangeText: selectedRangeText,
      layout: layoutRequest.rawValue,
      useSixCam: useSixCam,
      canvasWidth: Int(canvasSize.width.rounded()),
      canvasHeight: Int(canvasSize.height.rounded()),
      preset: preset.rawValue,
      presetName: preset.displayName,
      codec: codec,
      cameraCutCount: cameraTrack.keyframes.count,
      overlays: overlayOptions,
      includeTelemetryFiles: !overlayOptions.privacyMask
    )
  }
}

/// A source clip as it was before the export started: content hash plus the size
/// and modification date used to notice a swap afterwards.
nonisolated struct EvidenceHashedSource {
  var url: URL
  var fingerprint: FileFingerprint
  var size: Int64
  var modified: Date?
}

nonisolated struct EvidencePreparedSources {
  var sources: [String: EvidenceHashedSource] = [:]
}

/// Records the clips and tracks the export really read or inserted (renderer
/// requests, muxer insertions), so the manifest lists what is in the video.
nonisolated final class EvidenceSourceUsage: @unchecked Sendable {
  struct Entry {
    var url: URL
    var camera: Camera
    var clipStart: Date
  }

  private let lock = NSLock()
  private var recorded: [String: Entry] = [:]

  func record(url: URL, camera: Camera, clipStart: Date) {
    lock.lock()
    defer { lock.unlock() }
    let key = camera.rawValue + "|" + url.path
    if recorded[key] == nil { recorded[key] = Entry(url: url, camera: camera, clipStart: clipStart) }
  }

  var entries: [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return recorded.values.sorted { ($0.url.path, $0.camera.rawValue) < ($1.url.path, $1.camera.rawValue) }
  }
}

nonisolated enum EvidenceExporter {
  struct AppInfo {
    var name = "Tescam"
    var version = "unknown"
    var build = "unknown"

    static var current: AppInfo {
      let info = Bundle.main.infoDictionary
      return AppInfo(
        name: "Tescam",
        version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
        build: info?["CFBundleVersion"] as? String ?? "unknown"
      )
    }
  }

  static func manifestURL(for output: URL) -> URL { companion(output, "manifest.json") }
  static func csvURL(for output: URL) -> URL { companion(output, "telemetry.csv") }
  static func gpxURL(for output: URL) -> URL { companion(output, "gpx") }

  /// Keeps the full video file name (`clip.mov.manifest.json`) so `clip.mov` and
  /// `clip.mp4` never share companions.
  private static func companion(_ output: URL, _ suffix: String) -> URL {
    output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + "." + suffix)
  }

  /// Path of `file` relative to the longest matching source root; the bare file
  /// name when it sits under none of them.
  static func relativePath(of file: URL, roots: [URL]) -> String {
    let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
    var best: String?
    var bestLength = -1
    for root in roots {
      let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
      let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
      if filePath.hasPrefix(prefix), rootPath.count > bestLength {
        best = String(filePath.dropFirst(prefix.count))
        bestLength = rootPath.count
      }
    }
    return best ?? file.lastPathComponent
  }

  /// The clip a set's telemetry is read from: front, else back, else the first
  /// file by path. It need not be one of the exported cameras.
  static func telemetrySourceURL(for set: ClipSet) -> URL? {
    set.file(for: .front) ?? set.file(for: .back) ?? set.files.values.sorted { $0.path < $1.path }.first
  }

  private static func stamp(_ url: URL) -> (size: Int64, modified: Date?) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (
      (attributes?[.size] as? NSNumber)?.int64Value ?? -1,
      attributes?[.modificationDate] as? Date
    )
  }

  private static func hashSource(
    _ url: URL,
    onBytes: (Int) -> Void,
    shouldCancel: () -> Bool
  ) throws -> EvidenceHashedSource {
    let before = stamp(url)
    let fingerprint = try FileHasher.fingerprint(of: url, onBytes: onBytes, shouldCancel: shouldCancel)
    return EvidenceHashedSource(url: url, fingerprint: fingerprint, size: before.size, modified: before.modified)
  }

  /// Run before rendering starts: hashes every candidate source clip once (enabled
  /// cameras, plus the clips telemetry is read from) and records its size and
  /// modification date. `progress` receives 0...1.
  static func prepare(
    _ input: EvidenceExportInput,
    shouldCancel: () -> Bool = { false },
    progress: (Double) -> Void = { _ in }
  ) throws -> EvidencePreparedSources {
    var urls: [URL] = []
    var seen = Set<String>()
    for set in input.sets {
      var candidates = input.cameras.compactMap { set.file(for: $0) }
      if input.includeTelemetryFiles, let url = telemetrySourceURL(for: set) { candidates.append(url) }
      for url in candidates where seen.insert(url.path).inserted { urls.append(url) }
    }
    let totalBytes = max(1, urls.reduce(Int64(0)) { $0 + max(0, stamp($1).size) })
    var doneBytes: Int64 = 0
    var prepared = EvidencePreparedSources()
    for url in urls {
      prepared.sources[url.path] = try hashSource(url, onBytes: { count in
        doneBytes += Int64(count)
        progress(min(1, Double(doneBytes) / Double(totalBytes)))
      }, shouldCancel: shouldCancel)
    }
    progress(1)
    return prepared
  }

  private struct TelemetryStream {
    var csv: EvidenceStreamFile?
    var gpx: EvidenceStreamFile?
    var sourceURLs: [URL] = []
    var sampleCount = 0
    var estimatedCount = 0
  }

  /// Reads telemetry set by set and writes each sample straight to the CSV and
  /// GPX temp files, so no more than one clip's samples are in memory.
  private static func streamTelemetry(
    _ input: EvidenceExportInput,
    shouldCancel: () -> Bool
  ) throws -> TelemetryStream {
    var result = TelemetryStream()
    guard input.includeTelemetryFiles else { return result }
    let rows = TelemetryCSVWriter.RowFormatter(timeZone: input.timeZone)
    let gpxTime = EvidenceFormat.formatter(timeZone: EvidenceFormat.utc, fractional: true)
    let gpxName = input.outputURL.deletingPathExtension().lastPathComponent
    do {
      for set in input.sets.sorted(by: { $0.date < $1.date }) {
        if shouldCancel() { throw EvidenceError.cancelled }
        guard set.date.addingTimeInterval(set.duration) >= input.trimStartDate,
              set.date <= input.trimEndDate,
              let url = telemetrySourceURL(for: set),
              let timeline = try? TelemetryParser.parseTimeline(url: url) else { continue }
        var contributed = false
        for frame in timeline.frames {
          let date = set.date.addingTimeInterval(frame.timestampMs / 1000)
          if date < input.trimStartDate || date > input.trimEndDate { continue }
          let sample = EvidenceTelemetrySample(sei: frame.sei, date: date, timeEstimated: frame.isTimeEstimated)
          if result.csv == nil {
            let file = try EvidenceStreamFile(finalURL: csvURL(for: input.outputURL))
            result.csv = file
            try file.append(TelemetryCSVWriter.headerLine)
          }
          try result.csv?.append(rows.row(sample))
          if let point = GPXWriter.point(sample, formatter: gpxTime) {
            if result.gpx == nil {
              let file = try EvidenceStreamFile(finalURL: gpxURL(for: input.outputURL))
              result.gpx = file
              try file.append(GPXWriter.header(name: gpxName, firstDate: sample.date))
            }
            try result.gpx?.append(point)
          }
          result.sampleCount += 1
          if sample.timeEstimated { result.estimatedCount += 1 }
          contributed = true
        }
        if contributed { result.sourceURLs.append(url) }
      }
      try result.gpx?.append(GPXWriter.footer)
    } catch {
      result.csv?.discard()
      result.gpx?.discard()
      throw error
    }
    return result
  }

  /// Writes the CSV, GPX and manifest next to the video and returns the files.
  /// Everything is written to temp names first and moved into place only after
  /// the sources have been re-checked and cancellation tested, so a failed or
  /// cancelled run leaves earlier files alone. The video is never touched; the
  /// error names the file at fault. `progress` receives 0...1.
  static func write(
    _ input: EvidenceExportInput,
    prepared: EvidencePreparedSources,
    usage: EvidenceSourceUsage,
    exportedAt: Date = Date(),
    appInfo: AppInfo = .current,
    shouldCancel: () -> Bool = { false },
    progress: (Double) -> Void = { _ in }
  ) throws -> [URL] {
    let fm = FileManager.default
    var temps: [EvidenceStreamFile] = []
    var promoted: [URL] = []
    func cleanup() {
      temps.forEach { $0.discard() }
      promoted.forEach { try? fm.removeItem(at: $0) }
    }

    do {
      var sourceChecks: [EvidenceHashedSource] = []
      func hashed(_ url: URL) throws -> EvidenceHashedSource {
        let source = try prepared.sources[url.path]
          ?? hashSource(url, onBytes: { _ in }, shouldCancel: shouldCancel)
        sourceChecks.append(source)
        return source
      }

      // What the export actually read, not what was requested.
      var sources: [EvidenceSourceRecord] = []
      for entry in usage.entries {
        let source = try hashed(entry.url)
        sources.append(EvidenceSourceRecord(
          path: relativePath(of: entry.url, roots: input.sourceRoots),
          camera: entry.camera.rawValue,
          clipStart: entry.clipStart,
          byteCount: source.fingerprint.byteCount,
          sha256: source.fingerprint.sha256
        ))
      }

      let outputSize = max(1, stamp(input.outputURL).size)
      var doneBytes: Int64 = 0
      let outputFingerprint = try FileHasher.fingerprint(
        of: input.outputURL,
        onBytes: { count in
          doneBytes += Int64(count)
          progress(min(0.9, Double(doneBytes) / Double(outputSize) * 0.9))
        },
        shouldCancel: shouldCancel
      )

      let telemetry = try streamTelemetry(input, shouldCancel: shouldCancel)
      var companions: [(kind: String, file: EvidenceFileRecord)] = []
      if let csv = telemetry.csv {
        temps.append(csv)
        companions.append(("telemetry_csv", try csv.finish()))
      }
      if let gpx = telemetry.gpx {
        temps.append(gpx)
        companions.append(("gpx", try gpx.finish()))
      }

      var telemetrySources: [EvidenceSourceRecord] = []
      for url in telemetry.sourceURLs {
        let source = try hashed(url)
        let owner = input.sets.first { $0.files.values.contains(url) }
        telemetrySources.append(EvidenceSourceRecord(
          path: relativePath(of: url, roots: input.sourceRoots),
          camera: owner?.files.first { $0.value == url }?.key.rawValue ?? "unknown",
          clipStart: owner?.date ?? input.trimStartDate,
          byteCount: source.fingerprint.byteCount,
          sha256: source.fingerprint.sha256
        ))
      }

      let manifest = try EvidenceManifest.data(EvidenceManifestInput(
        appName: appInfo.name,
        appVersion: appInfo.version,
        appBuild: appInfo.build,
        exportedAt: exportedAt,
        rangeStart: input.trimStartDate,
        rangeEnd: input.trimEndDate,
        rangeText: input.rangeText,
        trimStartSeconds: input.trimStartSeconds,
        trimEndSeconds: input.trimEndSeconds,
        cameras: input.cameras.map(\.rawValue).sorted(),
        layout: input.layout,
        useSixCam: input.useSixCam,
        canvasWidth: input.canvasWidth,
        canvasHeight: input.canvasHeight,
        preset: input.preset,
        presetName: input.presetName,
        codec: input.codec,
        cameraCutCount: input.cameraCutCount,
        overlays: input.overlays,
        sources: sources,
        output: EvidenceFileRecord(
          name: input.outputURL.lastPathComponent,
          byteCount: outputFingerprint.byteCount,
          sha256: outputFingerprint.sha256
        ),
        companions: companions,
        telemetrySources: telemetrySources,
        telemetrySampleCount: telemetry.sampleCount,
        telemetryEstimatedCount: telemetry.estimatedCount,
        timeZone: input.timeZone
      ))
      let manifestFile = try EvidenceStreamFile(finalURL: manifestURL(for: input.outputURL))
      temps.append(manifestFile)
      try manifestFile.append(manifest)
      _ = try manifestFile.finish()

      // A clip replaced or edited while the export ran means the video and the
      // hashes disagree: refuse rather than publish a wrong fingerprint.
      for source in sourceChecks {
        let now = stamp(source.url)
        if now.size != source.size || now.modified != source.modified {
          throw EvidenceError.sourceChanged(file: source.url.lastPathComponent)
        }
      }
      if shouldCancel() { throw EvidenceError.cancelled }

      // Manifest last: its presence means the set is complete.
      for file in temps.dropLast() + [manifestFile] {
        try file.promote()
        promoted.append(file.finalURL)
      }
      if shouldCancel() { throw EvidenceError.cancelled }
      progress(1)
      return promoted
    } catch let error as EvidenceError {
      cleanup()
      throw error
    } catch {
      cleanup()
      throw EvidenceError.writeFailed(
        file: manifestURL(for: input.outputURL).lastPathComponent,
        detail: error.localizedDescription
      )
    }
  }
}
