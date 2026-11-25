import Foundation
import Testing
@testable import Tescam

// Evidence files: streaming hash, manifest bytes, CSV/GPX output, and one round
// trip through the real export controller.

private func sample(
  at seconds: Double,
  speedMps: Float = 0,
  autopilot: SeiMetadata.AutopilotState = .none,
  accelerator: Float = 0,
  brake: Bool = false,
  steering: Float = 0,
  heading: Double = 0,
  latitude: Double = 0,
  longitude: Double = 0
) -> EvidenceTelemetrySample {
  var sei = SeiMetadata()
  sei.vehicleSpeedMps = speedMps
  sei.autopilotState = autopilot
  sei.acceleratorPedalPosition = accelerator
  sei.brakeApplied = brake
  sei.steeringWheelAngle = steering
  sei.headingDeg = heading
  sei.latitudeDeg = latitude
  sei.longitudeDeg = longitude
  return EvidenceTelemetrySample(sei: sei, date: Date(timeIntervalSince1970: seconds))
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

private let london = TimeZone(identifier: "Europe/London")!

private func evidenceInput(
  output: URL, sets: [ClipSet], cameras: [Camera], root: URL, start: Date, seconds: Double = 5,
  privacy: Bool = false
) -> EvidenceExportInput {
  EvidenceExportInput(
    outputURL: output, sets: sets, cameras: cameras, sourceRoots: [root],
    trimStartDate: start, trimEndDate: start.addingTimeInterval(seconds),
    trimStartSeconds: 0, trimEndSeconds: seconds, rangeText: "range", layout: "auto", useSixCam: false,
    canvasWidth: 640, canvasHeight: 480, preset: "maxQualityHEVC", presetName: "Evidence HEVC",
    codec: "hevc", cameraCutCount: 0, overlays: ExportOverlayOptions(),
    includeTelemetryFiles: !privacy, timeZone: london
  )
}

/// Prepare (before the "export"), optionally mutate, then write, like the controller does.
private func writeEvidence(
  _ input: EvidenceExportInput,
  used: [(url: URL, camera: Camera, start: Date)],
  between: () throws -> Void = {},
  shouldCancel: () -> Bool = { false }
) throws -> [URL] {
  let usage = EvidenceSourceUsage()
  for clip in used { usage.record(url: clip.url, camera: clip.camera, clipStart: clip.start) }
  let prepared = try EvidenceExporter.prepare(input)
  try between()
  return try EvidenceExporter.write(input, prepared: prepared, usage: usage, shouldCancel: shouldCancel)
}

private func json(_ url: URL) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

@MainActor
struct EvidenceFilesTests {

  @Test func hashesStreamAcrossChunksAndFailClearly() throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let file = root.url.appendingPathComponent("fixture.bin")
    // NIST two-block test vector, read in 7-byte chunks.
    try Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8).write(to: file)

    var reported = 0
    let fingerprint = try FileHasher.fingerprint(of: file, chunkSize: 7, onBytes: { reported += $0 })
    #expect(fingerprint.sha256 == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(fingerprint.byteCount == 56)
    #expect(reported == 56)

    #expect(throws: EvidenceError.cancelled) {
      try FileHasher.fingerprint(of: file, chunkSize: 7, shouldCancel: { true })
    }
    do {
      _ = try FileHasher.fingerprint(of: URL(fileURLWithPath: "/nonexistent/clip-front.mp4"))
      Issue.record("expected failure")
    } catch let error as EvidenceError {
      #expect(error.localizedDescription.contains("clip-front.mp4"))
    }
  }

  @Test func manifestIsStableAndCarriesHashesOfAKnownInput() throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let clip = root.url.appendingPathComponent("RecentClips/clip-front.mp4")
    try FileManager.default.createDirectory(at: clip.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: clip)
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let fingerprint = try FileHasher.fingerprint(of: clip)
    #expect(fingerprint.sha256 == abc)
    #expect(EvidenceExporter.relativePath(of: clip, roots: [root.url]) == "RecentClips/clip-front.mp4")
    #expect(EvidenceExporter.relativePath(of: clip, roots: []) == "clip-front.mp4")

    func input(exportedAt: Double) -> EvidenceManifestInput {
      EvidenceManifestInput(
        appVersion: "1.0.1",
        appBuild: "8",
        exportedAt: Date(timeIntervalSince1970: exportedAt),
        rangeStart: Date(timeIntervalSince1970: 1_775_650_200),
        rangeEnd: Date(timeIntervalSince1970: 1_775_650_260),
        rangeText: "12:50:00 - 12:51:00",
        trimStartSeconds: 0,
        trimEndSeconds: 60,
        cameras: ["front"],
        layout: "auto",
        useSixCam: false,
        canvasWidth: 1280,
        canvasHeight: 960,
        preset: "maxQualityHEVC",
        presetName: "Evidence HEVC",
        codec: "hevc",
        cameraCutCount: 0,
        overlays: ExportOverlayOptions(),
        sources: [EvidenceSourceRecord(
          path: "RecentClips/clip-front.mp4",
          camera: "front",
          clipStart: Date(timeIntervalSince1970: 1_775_650_200),
          byteCount: fingerprint.byteCount,
          sha256: fingerprint.sha256
        )],
        output: EvidenceFileRecord(name: "out.mp4", byteCount: 3, sha256: abc),
        companions: [("gpx", EvidenceFileRecord(name: "out.gpx", byteCount: 3, sha256: abc))],
        timeZone: london
      )
    }

    let first = try EvidenceManifest.data(input(exportedAt: 1_775_700_000))
    let second = try EvidenceManifest.data(input(exportedAt: 1_775_700_000))
    #expect(first == second)

    let json = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
    #expect(Array(json.keys).sorted() == ["app", "cameras", "companion_files", "export", "exported_at", "manifest_version", "output", "range", "source_clips", "telemetry", "time_basis"])
    let sources = try #require(json["source_clips"] as? [[String: Any]])
    #expect(sources.first?["sha256"] as? String == abc)
    #expect(sources.first?["path"] as? String == "RecentClips/clip-front.mp4")
    #expect(sources.first?["bytes"] as? Int == 3)
    #expect(json["exported_at"] as? String == "2026-04-09T02:00:00Z")
    // File names are local wall-clock time: the zone is recorded and UTC is labelled as derived.
    let basis = try #require(json["time_basis"] as? [String: Any])
    #expect(basis["assumed_time_zone"] as? String == "Europe/London")
    #expect(basis["utc_offset_at_range_start"] as? String == "+01:00")
    let range = try #require(json["range"] as? [String: Any])
    #expect(range["start_utc"] as? String == "2026-04-08T12:10:00.000Z")
    #expect(range["start_local"] as? String == "2026-04-08T13:10:00.000+01:00")
    #expect(sources.first?["clip_start_local"] as? String == "2026-04-08T13:10:00.000+01:00")

    // Only the export time differs between two exports of the same inputs.
    let later = text(try EvidenceManifest.data(input(exportedAt: 1_775_800_000)))
    let differing = zip(text(first).split(separator: "\n"), later.split(separator: "\n")).filter { $0 != $1 }
    #expect(differing.count == 1)
    #expect(differing.first?.0.contains("exported_at") == true)
  }

  @Test func csvAndGpxFromSamples() throws {
    let rows = [
      sample(at: 1_775_650_200.5, speedMps: 10, autopilot: .autosteer, accelerator: 12.5, brake: true,
             steering: -3.25, heading: 271.5, latitude: 51.5074, longitude: -0.1278),
      sample(at: 1_775_650_201.0)
    ]

    var estimated = rows[1]
    estimated.timeEstimated = true
    let lines = text(TelemetryCSVWriter.data(samples: [rows[0], estimated], timeZone: london)).components(separatedBy: "\r\n")
    #expect(lines[0] == "timestamp_utc,speed_kmh,autopilot_state,accelerator_pedal_percent,brake_applied,steering_angle_deg,heading_deg,latitude,longitude,timestamp_local,time_estimated")
    // "." decimals regardless of locale; no position means empty cells, not 0.
    #expect(lines[1] == "2026-04-08T12:10:00.500Z,36.00,autosteer,12.5,1,-3.3,271.5,51.5074000,-0.1278000,2026-04-08T13:10:00.500+01:00,0")
    #expect(lines[2] == "2026-04-08T12:10:01.000Z,0.00,none,0.0,0,0.0,0.0,,,2026-04-08T13:10:01.000+01:00,1")
    #expect(lines.count == 4)
    #expect(EvidenceCSV.escape("say \"hi\", ok") == "\"say \"\"hi\"\", ok\"")
    #expect(EvidenceCSV.escape("plain") == "plain")

    let gpx = text(try #require(GPXWriter.data(samples: rows, name: "a & b")))
    #expect(gpx.contains("<gpx version=\"1.1\" creator=\"Tescam\""))
    #expect(gpx.contains("<name>a &amp; b</name>"))
    #expect(gpx.components(separatedBy: "<trkpt ").count == 2) // only the positioned sample
    #expect(gpx.contains("<trkpt lat=\"51.5074000\" lon=\"-0.1278000\">"))
    #expect(gpx.contains("<time>2026-04-08T12:10:00.500Z</time>"))
    #expect(gpx.contains("<gpxtpx:speed>10.00</gpxtpx:speed>"))
    #expect(gpx.contains("<gpxtpx:course>271.5</gpxtpx:course>"))
    #expect(GPXWriter.data(samples: [sample(at: 0)], name: "none") == nil)
  }

  @Test func gpxDeclaresTrackPointExtensionV2AndClampsCoordinates() throws {
    let rows = [
      sample(at: 1_775_650_200, speedMps: 5, heading: 10, latitude: 89.99999999, longitude: 179.99999999),
      sample(at: 1_775_650_201, speedMps: 5, heading: 10, latitude: 45, longitude: 45)
    ]
    let gpx = text(try #require(GPXWriter.data(samples: rows, name: "edge")))
    #expect(gpx.contains("xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v2\""))
    #expect(gpx.contains("http://www.garmin.com/xmlschemas/TrackPointExtensionv2.xsd"))
    #expect(!gpx.contains("TrackPointExtension/v1"))
    #expect(gpx.contains("lon=\"-180.0000000\"")) // 180 is outside GPX's [-180, 180)
    #expect(GPXWriter.latitudeText(90.5) == "90.0000000")
    #expect(GPXWriter.latitudeText(-91) == "-90.0000000")
    #expect(GPXWriter.longitudeText(-200) == "-180.0000000")
    #expect(GPXWriter.longitudeText(180) == "-180.0000000")
    #expect(GPXWriter.longitudeText(12.5) == "12.5000000")
  }

  @Test func writesCsvGpxAndManifestWithMatchingHashesAndSkipsThemWithoutTelemetry() throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    var sei = SeiMetadata()
    sei.vehicleSpeedMps = 13.4
    sei.latitudeDeg = 51.5074
    sei.longitudeDeg = -0.1278
    let withTelemetry = root.url.appendingPathComponent("with-telemetry-front.mp4")
    try makeMp4WithTeslaSei(metadata: sei).write(to: withTelemetry)
    let withoutTelemetry = root.url.appendingPathComponent("plain-front.mp4")
    try Data("not a telemetry clip".utf8).write(to: withoutTelemetry)
    let start = Date(timeIntervalSince1970: 1_775_650_200)

    func run(clip: URL, name: String, privacy: Bool = false) throws -> [URL] {
      let output = root.url.appendingPathComponent(name)
      try Data("video bytes".utf8).write(to: output)
      let sets = [ClipSet(timestamp: "t", date: start, duration: 5, files: [.front: clip])]
      return try writeEvidence(
        evidenceInput(output: output, sets: sets, cameras: [.front], root: root.url, start: start, privacy: privacy),
        used: [(clip, .front, start)]
      )
    }

    let full = try run(clip: withTelemetry, name: "full.mp4")
    #expect(full.map(\.lastPathComponent) == ["full.mp4.telemetry.csv", "full.mp4.gpx", "full.mp4.manifest.json"])
    let manifest = try json(full[2])
    let companions = try #require(manifest["companion_files"] as? [[String: Any]])
    #expect(companions.count == 2)
    for entry in companions {
      let url = root.url.appendingPathComponent(try #require(entry["name"] as? String))
      let fingerprint = try FileHasher.fingerprint(of: url)
      #expect(entry["sha256"] as? String == fingerprint.sha256)
      #expect(entry["bytes"] as? Int == Int(fingerprint.byteCount))
    }
    // No per-sample timing in this clip: the samples are flagged as estimates, never exact.
    let telemetry = try #require(manifest["telemetry"] as? [String: Any])
    #expect(telemetry["timing"] as? String == "estimated")
    #expect(telemetry["estimated_time_samples"] as? Int == telemetry["samples"] as? Int)
    let csvLines = text(try Data(contentsOf: full[0])).components(separatedBy: "\r\n")
    #expect(csvLines[1].hasSuffix(",1"))

    #expect(try run(clip: withoutTelemetry, name: "plain.mp4").map(\.lastPathComponent) == ["plain.mp4.manifest.json"])
    #expect(try run(clip: withTelemetry, name: "private.mp4", privacy: true).map(\.lastPathComponent) == ["private.mp4.manifest.json"])
  }

  @Test func companionsKeepTheVideoNameAndAFailedRunLeavesEarlierFilesIntact() throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let clip = root.url.appendingPathComponent("a-front.mp4")
    try Data("source".utf8).write(to: clip)
    let start = Date(timeIntervalSince1970: 1_775_650_200)
    let sets = [ClipSet(timestamp: "t", date: start, duration: 5, files: [.front: clip])]

    // clip.mov and clip.mp4 no longer share companion paths.
    let mov = root.url.appendingPathComponent("clip.mov")
    let mp4 = root.url.appendingPathComponent("clip.mp4")
    #expect(EvidenceExporter.manifestURL(for: mov).lastPathComponent == "clip.mov.manifest.json")
    #expect(EvidenceExporter.csvURL(for: mov).lastPathComponent == "clip.mov.telemetry.csv")
    #expect(EvidenceExporter.gpxURL(for: mov).lastPathComponent == "clip.mov.gpx")
    #expect(EvidenceExporter.manifestURL(for: mov) != EvidenceExporter.manifestURL(for: mp4))

    try Data("mov video".utf8).write(to: mov)
    try Data("mp4 video".utf8).write(to: mp4)
    let first = try writeEvidence(
      evidenceInput(output: mov, sets: sets, cameras: [.front], root: root.url, start: start),
      used: [(clip, .front, start)]
    )
    let earlier = try Data(contentsOf: first[0])

    // The source is swapped after hashing: the second run fails and touches nothing.
    do {
      _ = try writeEvidence(
        evidenceInput(output: mp4, sets: sets, cameras: [.front], root: root.url, start: start),
        used: [(clip, .front, start)],
        between: { try Data("swapped source!".utf8).write(to: clip) }
      )
      Issue.record("expected the source swap to be detected")
    } catch let error as EvidenceError {
      #expect(error == .sourceChanged(file: "a-front.mp4"))
    }
    #expect(try Data(contentsOf: first[0]) == earlier)
    #expect(!FileManager.default.fileExists(atPath: EvidenceExporter.manifestURL(for: mp4).path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path).allSatisfy { !$0.hasSuffix(".tmp") })
  }

  @Test func telemetrySourceOutsideTheExportedCamerasIsListedWithItsHash() throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    var sei = SeiMetadata()
    sei.vehicleSpeedMps = 10
    sei.latitudeDeg = 51.5
    sei.longitudeDeg = -0.12
    let front = root.url.appendingPathComponent("t-front.mp4")
    try makeMp4WithTeslaSei(metadata: sei).write(to: front)
    let back = root.url.appendingPathComponent("t-back.mp4")
    try Data("rear video".utf8).write(to: back)
    let start = Date(timeIntervalSince1970: 1_775_650_200)
    let output = root.url.appendingPathComponent("rear.mp4")
    try Data("video".utf8).write(to: output)
    let sets = [ClipSet(timestamp: "t", date: start, duration: 5, files: [.front: front, .back: back])]

    let written = try writeEvidence(
      evidenceInput(output: output, sets: sets, cameras: [.back], root: root.url, start: start),
      used: [(back, .back, start)]
    )
    let manifest = try json(try #require(written.last))
    let sources = try #require(manifest["source_clips"] as? [[String: Any]])
    #expect(sources.map { $0["path"] as? String } == ["t-back.mp4"])
    let telemetry = try #require(manifest["telemetry"] as? [String: Any])
    let telemetrySources = try #require(telemetry["source_clips"] as? [[String: Any]])
    #expect(telemetrySources.count == 1)
    #expect(telemetrySources[0]["path"] as? String == "t-front.mp4")
    #expect(telemetrySources[0]["camera"] as? String == "front")
    let fingerprint = try FileHasher.fingerprint(of: front)
    #expect(telemetrySources[0]["sha256"] as? String == fingerprint.sha256)
    #expect(telemetrySources[0]["bytes"] as? Int == Int(fingerprint.byteCount))
  }

  @Test func cancellationAfterTheManifestIsWrittenRemovesThisRunsFiles() throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    var sei = SeiMetadata()
    sei.latitudeDeg = 51.5
    sei.longitudeDeg = -0.12
    let clip = root.url.appendingPathComponent("c-front.mp4")
    try makeMp4WithTeslaSei(metadata: sei).write(to: clip)
    let start = Date(timeIntervalSince1970: 1_775_650_200)
    let output = root.url.appendingPathComponent("cancel.mp4")
    try Data("video".utf8).write(to: output)
    let sets = [ClipSet(timestamp: "t", date: start, duration: 5, files: [.front: clip])]
    let manifestURL = EvidenceExporter.manifestURL(for: output)

    // Cancel is reported only once the final manifest exists, i.e. after it was moved into place.
    #expect(throws: EvidenceError.cancelled) {
      _ = try writeEvidence(
        evidenceInput(output: output, sets: sets, cameras: [.front], root: root.url, start: start),
        used: [(clip, .front, start)],
        shouldCancel: { FileManager.default.fileExists(atPath: manifestURL.path) }
      )
    }
    let left = try FileManager.default.contentsOfDirectory(atPath: root.url.path).sorted()
    #expect(left == ["c-front.mp4", "cancel.mp4"])
  }

  @Test func exportWithEvidenceOptionWritesManifestMatchingFilesOnDisk() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let recordings = root.url.appendingPathComponent("recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)

    let timestamp = "2026-07-29_17-00-00"
    let clipDate = try #require(teslaTimestampDate(timestamp))
    let size = CGSize(width: 160, height: 120)
    let clip = recordings.appendingPathComponent("\(timestamp)-front.mov")
    try await makeVideo(at: clip, duration: 1, size: size, fill: 90)
    let outputURL = root.url.appendingPathComponent("evidence.mov")

    func request(evidence: Bool, output: URL) -> ExportRequest {
      ExportRequest(
        sets: [ClipSet(
          timestamp: timestamp, date: clipDate, duration: 1, files: [.front: clip],
          cameraDurations: [.front: 1], naturalSizes: [.front: size]
        )],
        outputURL: output,
        useSixCam: false,
        preset: .editFriendlyProRes,
        enabledCameras: [.front],
        trimStartSeconds: 0,
        trimEndSeconds: 1,
        trimStartDate: clipDate,
        trimEndDate: clipDate.addingTimeInterval(1),
        selectedRangeText: "evidence",
        partialClipCount: 0,
        evidenceFiles: evidence,
        evidenceSourceRoots: [recordings]
      )
    }

    let controller = NativeExportController()
    controller.export(request: request(evidence: true, output: outputURL))
    _ = await waitForTerminalExport(controller, timeout: 90)

    #expect(controller.currentJob?.phase == .completed)
    let manifestURL = EvidenceExporter.manifestURL(for: outputURL)
    #expect(controller.currentJob?.evidenceFileURLs == [manifestURL]) // no telemetry in this clip
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    let output = try #require(manifest["output"] as? [String: Any])
    let outputPrint = try FileHasher.fingerprint(of: outputURL)
    #expect(output["name"] as? String == "evidence.mov")
    #expect(output["sha256"] as? String == outputPrint.sha256)
    #expect(output["bytes"] as? Int == Int(outputPrint.byteCount))
    let sources = try #require(manifest["source_clips"] as? [[String: Any]])
    #expect(sources.count == 1)
    #expect(sources[0]["path"] as? String == "\(timestamp)-front.mov")
    #expect(sources[0]["sha256"] as? String == (try FileHasher.fingerprint(of: clip)).sha256)
    #expect(!FileManager.default.fileExists(atPath: EvidenceExporter.csvURL(for: outputURL).path))
    #expect(!FileManager.default.fileExists(atPath: EvidenceExporter.gpxURL(for: outputURL).path))

    // Option off: no evidence files, same flow as before.
    let plainURL = root.url.appendingPathComponent("plain.mov")
    controller.dismissStatus()
    controller.export(request: request(evidence: false, output: plainURL))
    _ = await waitForTerminalExport(controller, timeout: 90)
    #expect(controller.currentJob?.phase == .completed)
    #expect(!FileManager.default.fileExists(atPath: EvidenceExporter.manifestURL(for: plainURL).path))
  }

  @Test func manifestListsOnlyTheClipsThePassthroughExportInserted() async throws {
    let root = try TemporaryDirectory.make()
    defer { try? root.remove() }
    let recordings = root.url.appendingPathComponent("recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let size = CGSize(width: 160, height: 120)
    let firstStamp = "2026-07-29_17-00-00"
    let secondStamp = "2026-07-29_17-00-01"
    let firstDate = try #require(teslaTimestampDate(firstStamp))
    let secondDate = try #require(teslaTimestampDate(secondStamp))
    var sets: [ClipSet] = []
    for (stamp, date) in [(firstStamp, firstDate), (secondStamp, secondDate)] {
      let front = recordings.appendingPathComponent("\(stamp)-front.mov")
      let back = recordings.appendingPathComponent("\(stamp)-back.mov")
      try await makeVideo(at: front, duration: 1, size: size, fill: 60)
      try await makeVideo(at: back, duration: 1, size: size, fill: 120)
      sets.append(ClipSet(
        timestamp: stamp, date: date, duration: 1, files: [.front: front, .back: back],
        cameraDurations: [.front: 1, .back: 1], naturalSizes: [.front: size, .back: size]
      ))
    }
    let outputURL = root.url.appendingPathComponent("passthrough.mov")
    // The trim starts where the first set ends, so the muxer skips the whole first set.
    let request = ExportRequest(
      sets: sets, outputURL: outputURL, useSixCam: false, preset: .originalTracksMOV,
      enabledCameras: [.front, .back], trimStartSeconds: 1, trimEndSeconds: 2,
      trimStartDate: secondDate, trimEndDate: secondDate.addingTimeInterval(1),
      selectedRangeText: "second clip", partialClipCount: 0,
      evidenceFiles: true, evidenceSourceRoots: [recordings]
    )
    let controller = NativeExportController()
    controller.export(request: request)
    _ = await waitForTerminalExport(controller, timeout: 90)
    #expect(controller.currentJob?.phase == .completed)

    let manifest = try json(EvidenceExporter.manifestURL(for: outputURL))
    let sources = try #require(manifest["source_clips"] as? [[String: Any]])
    #expect(sources.compactMap { $0["path"] as? String } == ["\(secondStamp)-back.mov", "\(secondStamp)-front.mov"])
  }
}
