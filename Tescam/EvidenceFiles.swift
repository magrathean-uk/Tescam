import Foundation
import CryptoKit

// Evidence files written next to an export: a manifest with SHA-256 hashes, a
// telemetry CSV and a GPX track. Everything here is pure (Data in, Data out) or
// a streaming file helper, so it can be tested without running an export.

nonisolated enum EvidenceError: LocalizedError, Equatable {
  case cancelled
  case unreadable(file: String, detail: String)
  case writeFailed(file: String, detail: String)

  var errorDescription: String? {
    switch self {
    case .cancelled:
      return "Evidence files were cancelled."
    case .unreadable(let file, let detail):
      return "Could not read \(file) to hash it: \(detail)"
    case .writeFailed(let file, let detail):
      return "Could not write evidence file \(file): \(detail)"
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

  private static func hex(_ digest: SHA256.Digest) -> String {
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
  var speedKmh: Double?
  var autopilotState: String
  var acceleratorPercent: Double?
  var brakeApplied: Bool
  var steeringAngleDeg: Double?
  var headingDeg: Double?
  var latitude: Double?
  var longitude: Double?

  var hasPosition: Bool { latitude != nil && longitude != nil }

  init(sei: SeiMetadata, date: Date) {
    func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
    self.date = date
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

  static func iso8601(_ date: Date, fractional: Bool) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.formatOptions = fractional
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter.string(from: date)
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
  static let header = [
    "timestamp_utc",
    "speed_kmh",
    "autopilot_state",
    "accelerator_pedal_percent",
    "brake_applied",
    "steering_angle_deg",
    "heading_deg",
    "latitude",
    "longitude"
  ]

  static func data(samples: [EvidenceTelemetrySample]) -> Data {
    var out = header.map(EvidenceCSV.escape).joined(separator: ",") + "\r\n"
    out.reserveCapacity(out.count + samples.count * 96)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for sample in samples {
      let cells = [
        formatter.string(from: sample.date),
        EvidenceFormat.fixed(sample.speedKmh, decimals: 2),
        sample.autopilotState,
        EvidenceFormat.fixed(sample.acceleratorPercent, decimals: 1),
        sample.brakeApplied ? "1" : "0",
        EvidenceFormat.fixed(sample.steeringAngleDeg, decimals: 1),
        EvidenceFormat.fixed(sample.headingDeg, decimals: 1),
        EvidenceFormat.fixed(sample.latitude, decimals: 7),
        EvidenceFormat.fixed(sample.longitude, decimals: 7)
      ]
      out += cells.map(EvidenceCSV.escape).joined(separator: ",") + "\r\n"
    }
    return Data(out.utf8)
  }
}

// MARK: - GPX

nonisolated enum GPXWriter {
  static let garminNamespace = "http://www.garmin.com/xmlschemas/TrackPointExtension/v1"

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

  /// GPX 1.1 track, one point per sample that has a usable position. GPX 1.1 has
  /// no speed element, so speed (m/s) and heading go in the Garmin
  /// TrackPointExtension v1 (`gpxtpx:speed`, `gpxtpx:course`), the extension most
  /// GPX readers understand. Returns nil when no sample has a position.
  static func data(samples: [EvidenceTelemetrySample], name: String) -> Data? {
    let points = samples.filter(\.hasPosition)
    guard let first = points.first else { return nil }
    var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    out += "<gpx version=\"1.1\" creator=\"Tescam\""
    out += " xmlns=\"http://www.topografix.com/GPX/1/1\""
    out += " xmlns:gpxtpx=\"\(garminNamespace)\""
    out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
    out += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd"
    out += " \(garminNamespace) http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd\">\n"
    out += "  <metadata>\n    <name>\(escape(name))</name>\n"
    out += "    <time>\(EvidenceFormat.iso8601(first.date, fractional: true))</time>\n  </metadata>\n"
    out += "  <trk>\n    <name>\(escape(name))</name>\n    <trkseg>\n"
    for point in points {
      guard let latitude = point.latitude, let longitude = point.longitude else { continue }
      out += "      <trkpt lat=\"\(EvidenceFormat.fixed(latitude, decimals: 7))\" lon=\"\(EvidenceFormat.fixed(longitude, decimals: 7))\">\n"
      out += "        <time>\(EvidenceFormat.iso8601(point.date, fractional: true))</time>\n"
      var extensionLines = ""
      if let speed = point.speedKmh {
        extensionLines += "            <gpxtpx:speed>\(EvidenceFormat.fixed(speed / 3.6, decimals: 2))</gpxtpx:speed>\n"
      }
      if let heading = point.headingDeg {
        let course = heading.truncatingRemainder(dividingBy: 360)
        extensionLines += "            <gpxtpx:course>\(EvidenceFormat.fixed(course < 0 ? course + 360 : course, decimals: 1))</gpxtpx:course>\n"
      }
      if !extensionLines.isEmpty {
        out += "        <extensions>\n          <gpxtpx:TrackPointExtension>\n\(extensionLines)          </gpxtpx:TrackPointExtension>\n        </extensions>\n"
      }
      out += "      </trkpt>\n"
    }
    out += "    </trkseg>\n  </trk>\n</gpx>\n"
    return Data(out.utf8)
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
    let sources = input.sources
      .sorted { ($0.path, $0.camera) < ($1.path, $1.camera) }
      .map { source -> [String: Any] in
        [
          "path": source.path,
          "camera": source.camera,
          "clip_start_utc": EvidenceFormat.iso8601(source.clipStart, fractional: true),
          "bytes": source.byteCount,
          "sha256": source.sha256
        ]
      }
    let companions = input.companions
      .sorted { $0.file.name < $1.file.name }
      .map { entry -> [String: Any] in
        var item = file(entry.file)
        item["kind"] = entry.kind
        return item
      }
    let overlays = input.overlays
    let root: [String: Any] = [
      "manifest_version": formatVersion,
      "app": ["name": input.appName, "version": input.appVersion, "build": input.appBuild],
      "exported_at": EvidenceFormat.iso8601(input.exportedAt, fractional: false),
      "range": [
        "start_utc": EvidenceFormat.iso8601(input.rangeStart, fractional: true),
        "end_utc": EvidenceFormat.iso8601(input.rangeEnd, fractional: true),
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
      "source_clips": sources,
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
      cameras: cameraOrder.filter { enabledCameras.contains($0) },
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

  private static func companion(_ output: URL, _ suffix: String) -> URL {
    output.deletingPathExtension().appendingPathExtension(suffix)
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

  /// Telemetry for the exported range, in time order. Clips whose telemetry
  /// cannot be read contribute nothing.
  static func telemetrySamples(
    sets: [ClipSet],
    from start: Date,
    to end: Date,
    shouldCancel: () -> Bool = { false }
  ) throws -> [EvidenceTelemetrySample] {
    var out: [EvidenceTelemetrySample] = []
    for set in sets {
      if shouldCancel() { throw EvidenceError.cancelled }
      guard set.date.addingTimeInterval(set.duration) >= start, set.date <= end else { continue }
      guard let url = set.file(for: .front) ?? set.file(for: .back)
        ?? set.files.values.sorted(by: { $0.path < $1.path }).first,
        let timeline = try? TelemetryParser.parseTimeline(url: url) else { continue }
      for frame in timeline.frames {
        let date = set.date.addingTimeInterval(frame.timestampMs / 1000)
        if date < start || date > end { continue }
        out.append(EvidenceTelemetrySample(sei: frame.sei, date: date))
      }
    }
    out.sort { $0.date < $1.date }
    return out
  }

  /// Hashes sources and output, then writes the CSV, GPX and manifest next to the
  /// video. Returns the files written. On any failure the files written by this
  /// call are removed again (the video is never touched) and the error names the
  /// file at fault. `progress` receives 0...1.
  static func write(
    _ input: EvidenceExportInput,
    exportedAt: Date = Date(),
    appInfo: AppInfo = .current,
    shouldCancel: () -> Bool = { false },
    progress: (Double) -> Void = { _ in }
  ) throws -> [URL] {
    let fm = FileManager.default
    var seen = Set<String>()
    var sourceFiles: [(url: URL, camera: Camera, clipStart: Date)] = []
    for set in input.sets {
      for camera in input.cameras {
        guard let url = set.file(for: camera), seen.insert(url.path).inserted else { continue }
        sourceFiles.append((url, camera, set.date))
      }
    }

    func size(_ url: URL) -> Int64 {
      Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
    let totalBytes = max(1, sourceFiles.reduce(Int64(0)) { $0 + size($1.url) } + size(input.outputURL))
    var doneBytes: Int64 = 0
    func hash(_ url: URL) throws -> FileFingerprint {
      try FileHasher.fingerprint(
        of: url,
        onBytes: { count in
          doneBytes += Int64(count)
          progress(min(0.95, Double(doneBytes) / Double(totalBytes) * 0.95))
        },
        shouldCancel: shouldCancel
      )
    }

    var sources: [EvidenceSourceRecord] = []
    for source in sourceFiles {
      let fingerprint = try hash(source.url)
      sources.append(EvidenceSourceRecord(
        path: relativePath(of: source.url, roots: input.sourceRoots),
        camera: source.camera.rawValue,
        clipStart: source.clipStart,
        byteCount: fingerprint.byteCount,
        sha256: fingerprint.sha256
      ))
    }
    let outputFingerprint = try hash(input.outputURL)

    let samples = input.includeTelemetryFiles
      ? try telemetrySamples(sets: input.sets, from: input.trimStartDate, to: input.trimEndDate, shouldCancel: shouldCancel)
      : []
    let stem = input.outputURL.deletingPathExtension().lastPathComponent
    var pending: [(kind: String, url: URL, data: Data)] = []
    if !samples.isEmpty {
      let url = csvURL(for: input.outputURL)
      pending.append(("telemetry_csv", url, TelemetryCSVWriter.data(samples: samples)))
    }
    if let gpx = GPXWriter.data(samples: samples, name: stem) {
      pending.append(("gpx", gpxURL(for: input.outputURL), gpx))
    }

    var written: [URL] = []
    func writeFile(_ data: Data, to url: URL) throws {
      if shouldCancel() { throw EvidenceError.cancelled }
      do {
        try data.write(to: url, options: .atomic)
        written.append(url)
      } catch {
        throw EvidenceError.writeFailed(file: url.lastPathComponent, detail: error.localizedDescription)
      }
    }

    do {
      var companions: [(kind: String, file: EvidenceFileRecord)] = []
      for item in pending {
        try writeFile(item.data, to: item.url)
        companions.append((item.kind, EvidenceFileRecord(
          name: item.url.lastPathComponent,
          byteCount: Int64(item.data.count),
          sha256: FileHasher.sha256Hex(of: item.data)
        )))
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
        companions: companions
      ))
      try writeFile(manifest, to: manifestURL(for: input.outputURL))
    } catch let error as EvidenceError {
      for url in written { try? fm.removeItem(at: url) }
      throw error
    } catch {
      for url in written { try? fm.removeItem(at: url) }
      throw EvidenceError.writeFailed(
        file: manifestURL(for: input.outputURL).lastPathComponent,
        detail: error.localizedDescription
      )
    }
    progress(1)
    return written
  }
}
