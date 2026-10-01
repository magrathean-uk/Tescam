import Foundation

enum Camera: String, CaseIterable, Hashable {
  case front
  case back
  case left_repeater
  case right_repeater
  case left
  case right
  case left_pillar
  case right_pillar

  static let priority: [Camera] = [.front, .back, .left_repeater, .right_repeater, .left, .right, .left_pillar, .right_pillar]
}

struct ClipSet {
  let timestamp: String
  let date: Date
  var files: [Camera: URL]
}

struct SeiMetadata: Hashable {
  enum Gear: Int {
    case park = 0
    case drive = 1
    case reverse = 2
    case neutral = 3
  }

  enum AutopilotState: Int {
    case none = 0
    case selfDriving = 1
    case autosteer = 2
    case tacc = 3
  }

  var version: UInt32 = 0
  var gearState: Gear = .park
  var frameSeqNo: UInt64 = 0
  var vehicleSpeedMps: Float = 0
  var acceleratorPedalPosition: Float = 0
  var steeringWheelAngle: Float = 0
  var blinkerLeft: Bool = false
  var blinkerRight: Bool = false
  var brakeApplied: Bool = false
  var autopilotState: AutopilotState = .none
  var latitudeDeg: Double = 0
  var longitudeDeg: Double = 0
  var headingDeg: Double = 0
  var linearAccelX: Double = 0
  var linearAccelY: Double = 0
  var linearAccelZ: Double = 0
}

struct TelemetryFrame: Hashable {
  let timestampMs: Double
  let sei: SeiMetadata
}

struct TelemetryTimeline {
  let frames: [TelemetryFrame]
}

enum OverlayToolError: Error, CustomStringConvertible {
  case usage
  case invalidInput(String)

  var description: String {
    switch self {
    case .usage:
      return "Usage: TescamOverlayGenerator <input-dir> <overlay-dir>"
    case .invalidInput(let message):
      return message
    }
  }
}

@main
struct TescamOverlayGenerator {
  static func main() {
    do {
      try run()
    } catch let error as OverlayToolError {
      FileHandle.standardError.write(Data((error.description + "\n").utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data(("Unexpected error: \(error)\n").utf8))
      exit(1)
    }
  }

  private static func run() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else { throw OverlayToolError.usage }

    let inputDir = URL(fileURLWithPath: args[1], isDirectory: true)
    let overlayDir = URL(fileURLWithPath: args[2], isDirectory: true)
    let fm = FileManager.default

    guard fm.fileExists(atPath: inputDir.path) else {
      throw OverlayToolError.invalidInput("Input directory does not exist: \(inputDir.path)")
    }
    try fm.createDirectory(at: overlayDir, withIntermediateDirectories: true)

    let clipSets = try indexClipSets(inputDir: inputDir)
    guard !clipSets.isEmpty else {
      throw OverlayToolError.invalidInput("No Tescam clip sets found in \(inputDir.path)")
    }

    for set in clipSets {
      let source = Camera.priority.compactMap { set.files[$0] }.first
      let overlayURL = overlayDir.appendingPathComponent("\(set.timestamp).ass")
      guard let source else {
        try writeTimestampOnlyOverlay(for: set, to: overlayURL)
        continue
      }

      do {
        let timeline = try TelemetryParser.parseTimeline(url: source)
        try writeOverlay(for: set, timeline: timeline, to: overlayURL)
      } catch {
        try writeTimestampOnlyOverlay(for: set, to: overlayURL)
      }
    }
  }

  private static func indexClipSets(inputDir: URL) throws -> [ClipSet] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = fm.enumerator(at: inputDir, includingPropertiesForKeys: keys) else {
      return []
    }

    let regex = try NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2})-([A-Za-z0-9_-]+)\\.(mp4|mov)$", options: [.caseInsensitive])
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"

    var map: [String: ClipSet] = [:]

    for case let fileURL as URL in enumerator {
      let name = fileURL.lastPathComponent
      let range = NSRange(name.startIndex..<name.endIndex, in: name)
      guard let match = regex.firstMatch(in: name, range: range),
            let tsRange = Range(match.range(at: 1), in: name),
            let camRange = Range(match.range(at: 2), in: name)
      else { continue }

      let timestamp = String(name[tsRange])
      guard let date = df.date(from: timestamp),
            let camera = normalizeCamera(String(name[camRange]))
      else { continue }

      var set = map[timestamp] ?? ClipSet(timestamp: timestamp, date: date, files: [:])
      set.files[camera] = fileURL
      map[timestamp] = set
    }

    return map.values.sorted { $0.date < $1.date }
  }

  private static func normalizeCamera(_ raw: String) -> Camera? {
    var token = raw.lowercased().replacingOccurrences(of: "-", with: "_")
    token = token.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    token = token.replacingOccurrences(of: "_?\\d+$", with: "", options: .regularExpression)

    if token == "front" || token == "fwd" || token == "forward" { return .front }
    if token == "back" || token == "rear" || token == "rear_camera" { return .back }
    if token.contains("left") && token.contains("pillar") { return .left_pillar }
    if token.contains("right") && token.contains("pillar") { return .right_pillar }
    if token.contains("left") && token.contains("repeat") { return .left_repeater }
    if token.contains("right") && token.contains("repeat") { return .right_repeater }
    if token == "left_rear" { return .left_repeater }
    if token == "right_rear" { return .right_repeater }
    if token == "left" { return .left }
    if token == "right" { return .right }
    return Camera(rawValue: token)
  }

  private static func writeOverlay(for set: ClipSet, timeline: TelemetryTimeline, to url: URL) throws {
    var lines = assHeader()
    let frames = timeline.frames

    if frames.isEmpty {
      try writeTimestampOnlyOverlay(for: set, to: url)
      return
    }

    var segmentStartMs = 0.0
    var previousText = overlayText(for: set.date, telemetry: frames[0].sei)
    var previousBucket = Int(frames[0].timestampMs / 250.0)

    for frame in frames.dropFirst() {
      let text = overlayText(for: set.date.addingTimeInterval(frame.timestampMs / 1000.0), telemetry: frame.sei)
      let bucket = Int(frame.timestampMs / 250.0)
      if text != previousText || bucket != previousBucket {
        lines.append(dialogueLine(startMs: segmentStartMs, endMs: frame.timestampMs, text: previousText))
        segmentStartMs = frame.timestampMs
        previousText = text
        previousBucket = bucket
      }
    }

    let endMs = max(frames.last?.timestampMs ?? 60000.0, 60000.0)
    lines.append(dialogueLine(startMs: segmentStartMs, endMs: endMs, text: previousText))
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private static func writeTimestampOnlyOverlay(for set: ClipSet, to url: URL) throws {
    var lines = assHeader()
    for second in 0..<60 {
      let timestamp = set.date.addingTimeInterval(TimeInterval(second))
      let text = formatTimestamp(timestamp)
      lines.append(dialogueLine(startMs: Double(second * 1000), endMs: Double((second + 1) * 1000), text: text))
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  private static func assHeader() -> [String] {
    [
      "[Script Info]",
      "ScriptType: v4.00+",
      "PlayResX: 7680",
      "PlayResY: 4320",
      "WrapStyle: 2",
      "ScaledBorderAndShadow: yes",
      "",
      "[V4+ Styles]",
      "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
      "Style: Telemetry,Menlo,44,&H00FFFFFF,&H000000FF,&H00000000,&H66000000,1,0,0,0,100,100,0,0,1,3,0,8,64,64,44,1",
      "",
      "[Events]",
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
    ]
  }

  private static func dialogueLine(startMs: Double, endMs: Double, text: String) -> String {
    "Dialogue: 0,\(assTime(startMs)),\(assTime(max(endMs, startMs + 100))),Telemetry,,0,0,0,,\(escapeAss(text))"
  }

  private static func assTime(_ ms: Double) -> String {
    let totalCs = max(0, Int((ms / 10.0).rounded(.down)))
    let cs = totalCs % 100
    let totalSeconds = totalCs / 100
    let seconds = totalSeconds % 60
    let totalMinutes = totalSeconds / 60
    let minutes = totalMinutes % 60
    let hours = totalMinutes / 60
    return String(format: "%01d:%02d:%02d.%02d", hours, minutes, seconds, cs)
  }

  private static func overlayText(for timestamp: Date, telemetry: SeiMetadata) -> String {
    let speedKmh = Double(telemetry.vehicleSpeedMps) * 3.6
    let gear: String
    switch telemetry.gearState {
    case .park: gear = "P"
    case .drive: gear = "D"
    case .reverse: gear = "R"
    case .neutral: gear = "N"
    }
    let ap: String
    switch telemetry.autopilotState {
    case .none: ap = "Off"
    case .selfDriving: ap = "FSD"
    case .autosteer: ap = "Autosteer"
    case .tacc: ap = "TACC"
    }
    return "\(formatTimestamp(timestamp))\\NSpeed: \(String(format: "%.1f km/h", speedKmh))   Gear: \(gear)   AP: \(ap)   Brake: \(telemetry.brakeApplied ? "On" : "Off")"
  }

  private static func formatTimestamp(_ date: Date) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df.string(from: date)
  }

  private static func escapeAss(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "{", with: "\\{")
      .replacingOccurrences(of: "}", with: "\\}")
  }
}

final class TelemetryParser {
  static func parseTimeline(url: URL) throws -> TelemetryTimeline {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let mp4 = DashcamMP4(data: data)
    let frames = try mp4.parseSeiFrames()
    return TelemetryTimeline(frames: frames)
  }
}

private final class DashcamMP4 {
  private let data: Data

  init(data: Data) {
    self.data = data
  }

  func parseSeiFrames() throws -> [TelemetryFrame] {
    let config = try getConfig()
    let mdat = try findMdat()
    var frames: [TelemetryFrame] = []
    var cursor = mdat.offset
    let end = mdat.offset + mdat.size
    var pendingSei: SeiMetadata? = nil
    var currentTime: Double = 0
    var frameIndex = 0

    while cursor + 4 <= end {
      let len = Int(readUInt32BE(at: cursor))
      cursor += 4
      if len < 1 || cursor + len > end { break }

      let type = data[cursor] & 0x1F
      let nal = data.subdata(in: cursor..<(cursor + len))

      if type == 6 {
        pendingSei = decodeSei(nal: nal)
      } else if type == 5 || type == 1 {
        let duration = (frameIndex < config.durations.count) ? config.durations[frameIndex] : 33.333
        if let sei = pendingSei {
          frames.append(TelemetryFrame(timestampMs: currentTime, sei: sei))
        }
        currentTime += duration
        frameIndex += 1
        pendingSei = nil
      }

      cursor += len
    }
    return frames
  }

  private func getConfig() throws -> MP4Config {
    let moov = try findBox(start: 0, end: data.count, name: "moov")
    let trak = try findBox(start: moov.start, end: moov.end, name: "trak")
    let mdia = try findBox(start: trak.start, end: trak.end, name: "mdia")
    let minf = try findBox(start: mdia.start, end: mdia.end, name: "minf")
    let stbl = try findBox(start: minf.start, end: minf.end, name: "stbl")
    let stsd = try findBox(start: stbl.start, end: stbl.end, name: "stsd")
    let avc1 = try findBox(start: stsd.start + 8, end: stsd.end, name: "avc1")
    let _ = try findBox(start: avc1.start + 78, end: avc1.end, name: "avcC")

    let mdhd = try findBox(start: mdia.start, end: mdia.end, name: "mdhd")
    let mdhdVersion = readUInt8(at: mdhd.start)
    let timescale: UInt32 = mdhdVersion == 1 ? readUInt32BE(at: mdhd.start + 20) : readUInt32BE(at: mdhd.start + 12)

    let stts = try findBox(start: stbl.start, end: stbl.end, name: "stts")
    let entryCount = Int(readUInt32BE(at: stts.start + 4))
    var durations: [Double] = []
    var pos = stts.start + 8
    for _ in 0..<entryCount {
      let count = Int(readUInt32BE(at: pos))
      let delta = Int(readUInt32BE(at: pos + 4))
      let ms = (Double(delta) / Double(timescale)) * 1000.0
      for _ in 0..<count { durations.append(ms) }
      pos += 8
    }
    return MP4Config(durations: durations)
  }

  private func findMdat() throws -> (offset: Int, size: Int) {
    let mdat = try findBox(start: 0, end: data.count, name: "mdat")
    return (offset: mdat.start, size: mdat.size)
  }

  private func findBox(start: Int, end: Int, name: String) throws -> (start: Int, end: Int, size: Int) {
    var pos = start
    while pos + 8 <= end {
      var size = Int(readUInt32BE(at: pos))
      let type = readAscii(at: pos + 4, len: 4)
      let headerSize = (size == 1) ? 16 : 8
      if size == 1 {
        let high = UInt64(readUInt32BE(at: pos + 8))
        let low = UInt64(readUInt32BE(at: pos + 12))
        size = Int((high << 32) | low)
      } else if size == 0 {
        size = end - pos
      }
      if type == name {
        return (start: pos + headerSize, end: pos + size, size: size - headerSize)
      }
      pos += size
    }
    throw OverlayToolError.invalidInput("Box not found: \(name)")
  }

  private func decodeSei(nal: Data) -> SeiMetadata? {
    if nal.count < 4 { return nil }
    var i = 3
    while i < nal.count && nal[i] == 0x42 { i += 1 }
    if i <= 3 || i + 1 >= nal.count || nal[i] != 0x69 { return nil }
    let payload = nal.subdata(in: (i + 1)..<(nal.count - 1))
    return ProtoSeiDecoder.decode(stripEmulationBytes(data: payload))
  }

  private func stripEmulationBytes(data: Data) -> Data {
    var out = [UInt8]()
    var zeros = 0
    out.reserveCapacity(data.count)
    for byte in data {
      if zeros >= 2 && byte == 0x03 {
        zeros = 0
        continue
      }
      out.append(byte)
      zeros = (byte == 0) ? zeros + 1 : 0
    }
    return Data(out)
  }

  private func readUInt8(at offset: Int) -> UInt8 { data[offset] }
  private func readUInt32BE(at offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
  }
  private func readAscii(at offset: Int, len: Int) -> String {
    String(bytes: data[offset..<(offset + len)], encoding: .ascii) ?? ""
  }
}

private struct MP4Config {
  let durations: [Double]
}

private enum ProtoSeiDecoder {
  static func decode(_ data: Data) -> SeiMetadata? {
    var reader = ProtoReader(data: data)
    var msg = SeiMetadata()
    while !reader.isAtEnd {
      guard let key = reader.readVarint() else { break }
      let field = Int(key >> 3)
      let wire = Int(key & 0x7)
      switch field {
      case 1: if let v = reader.readVarint() { msg.version = UInt32(truncatingIfNeeded: v) } else { return nil }
      case 2: if let v = reader.readVarint() { msg.gearState = SeiMetadata.Gear(rawValue: Int(v)) ?? .park } else { return nil }
      case 3: if let v = reader.readVarint() { msg.frameSeqNo = v } else { return nil }
      case 4: if let v = reader.readFixed32() { msg.vehicleSpeedMps = Float(bitPattern: v) } else { return nil }
      case 5: if let v = reader.readFixed32() { msg.acceleratorPedalPosition = Float(bitPattern: v) } else { return nil }
      case 6: if let v = reader.readFixed32() { msg.steeringWheelAngle = Float(bitPattern: v) } else { return nil }
      case 7: if let v = reader.readVarint() { msg.blinkerLeft = v != 0 } else { return nil }
      case 8: if let v = reader.readVarint() { msg.blinkerRight = v != 0 } else { return nil }
      case 9: if let v = reader.readVarint() { msg.brakeApplied = v != 0 } else { return nil }
      case 10: if let v = reader.readVarint() { msg.autopilotState = SeiMetadata.AutopilotState(rawValue: Int(v)) ?? .none } else { return nil }
      case 11: if let v = reader.readFixed64() { msg.latitudeDeg = Double(bitPattern: v) } else { return nil }
      case 12: if let v = reader.readFixed64() { msg.longitudeDeg = Double(bitPattern: v) } else { return nil }
      case 13: if let v = reader.readFixed64() { msg.headingDeg = Double(bitPattern: v) } else { return nil }
      case 14: if let v = reader.readFixed64() { msg.linearAccelX = Double(bitPattern: v) } else { return nil }
      case 15: if let v = reader.readFixed64() { msg.linearAccelY = Double(bitPattern: v) } else { return nil }
      case 16: if let v = reader.readFixed64() { msg.linearAccelZ = Double(bitPattern: v) } else { return nil }
      default: if !reader.skipField(wireType: wire) { return nil }
      }
    }
    return msg
  }
}

private struct ProtoReader {
  private let data: Data
  private var offset = 0

  init(data: Data) { self.data = data }
  var isAtEnd: Bool { offset >= data.count }

  mutating func readVarint() -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while offset < data.count {
      let byte = data[offset]
      offset += 1
      result |= UInt64(byte & 0x7F) << shift
      if (byte & 0x80) == 0 { return result }
      shift += 7
      if shift > 63 { return nil }
    }
    return nil
  }

  mutating func readFixed32() -> UInt32? {
    guard offset + 4 <= data.count else { return nil }
    let value = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    offset += 4
    return value
  }

  mutating func readFixed64() -> UInt64? {
    guard offset + 8 <= data.count else { return nil }
    var value: UInt64 = 0
    for i in 0..<8 { value |= UInt64(data[offset + i]) << (UInt64(i) * 8) }
    offset += 8
    return value
  }

  mutating func skipField(wireType: Int) -> Bool {
    switch wireType {
    case 0: return readVarint() != nil
    case 1: guard offset + 8 <= data.count else { return false }; offset += 8; return true
    case 2:
      guard let len = readVarint() else { return false }
      let length = Int(len)
      guard offset + length <= data.count else { return false }
      offset += length
      return true
    case 5: guard offset + 4 <= data.count else { return false }; offset += 4; return true
    default: return false
    }
  }
}
