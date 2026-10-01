import Foundation
import AVFoundation
import CoreGraphics

enum ClipIndexError: Error {
  case noClipsFound
}

final class ClipIndexer {
  nonisolated private static let regex: NSRegularExpression = {
    // Accept broad camera tokens and normalize them in code to avoid dropping clips
    // from slightly different Tesla naming variants.
    let pattern = "^(\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2})-([A-Za-z0-9_-]+)\\.(mp4|mov)$"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }()

  private static nonisolated func makeDateFormatter() -> DateFormatter {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return df
  }

  static nonisolated func index(rootURL: URL, progress: @escaping (Int) -> Void) throws -> ClipIndex {
    try index(inputURLs: [rootURL], duplicatePolicy: .mergeByTime, progress: progress)
  }

  static nonisolated func index(
    inputURLs: [URL],
    duplicatePolicy: DuplicateClipPolicy = .mergeByTime,
    progress: @escaping (Int) -> Void
  ) throws -> ClipIndex {
    try measure("clip_index_full") {
      let fm = FileManager.default
      let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey, .isHiddenKey]

      var map: [String: IndexedClipSetBuilder] = [:]
      var keepAllSets: [ClipSet] = []
      var keepAllPrimaryIndexByTimestamp: [String: Int] = [:]
      var camerasFound = Set<Camera>()
      var duplicateFileCount = 0
      var duplicateTimestampCount = 0
      var scanned = 0
      var seenDuplicateTimestamps = Set<String>()
      var metadataCache: [String: ClipAssetProbe] = [:]

      let normalizedInputs = normalizeInputs(inputURLs)
      guard !normalizedInputs.isEmpty else {
        throw ClipIndexError.noClipsFound
      }

      // Pass 1: enumerate every candidate file in a deterministic order
      // (per input, path-sorted within a directory) WITHOUT probing media.
      var orderedURLs: [URL] = []
      for input in normalizedInputs {
        let values = try? input.resourceValues(forKeys: Set(keys))
        let isDir = values?.isDirectory ?? false

        if isDir {
          guard let enumerator = fm.enumerator(
            at: input,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
          ) else {
            continue
          }

          var fileURLs: [URL] = []
          while let item = enumerator.nextObject() as? URL {
            let fileURL = item.standardizedFileURL
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))

            if hasHiddenPathComponent(fileURL, relativeTo: input) {
              if resourceValues?.isDirectory == true {
                enumerator.skipDescendants()
              }
              continue
            }

            if resourceValues?.isSymbolicLink == true {
              if resourceValues?.isDirectory == true {
                enumerator.skipDescendants()
              }
              continue
            }

            if resourceValues?.isDirectory == true {
              continue
            }

            guard resourceValues?.isRegularFile == true else {
              continue
            }

            fileURLs.append(fileURL)
          }

          fileURLs.sort { $0.path < $1.path }
          orderedURLs.append(contentsOf: fileURLs)
        } else {
          if values?.isSymbolicLink == true || values?.isRegularFile != true {
            continue
          }
          orderedURLs.append(input)
        }
      }

      // Pass 2: probe the actual clips' media metadata concurrently. This is
      // the cold-scan bottleneck on large dumps; parallelizing it is the win.
      let clipURLs = orderedURLs.filter { url in
        let ext = url.pathExtension.lowercased()
        return (ext == "mp4" || ext == "mov") && firstMatch(in: url.lastPathComponent) != nil
      }
      prewarmMetadata(clipURLs, cache: &metadataCache)

      // Pass 3: build the index in deterministic order. parseClipFile now hits
      // the warmed cache, so this pass does no blocking media I/O.
      for fileURL in orderedURLs {
        parseClipFile(
          fileURL,
          duplicatePolicy: duplicatePolicy,
          into: &map,
          keepAllSets: &keepAllSets,
          keepAllPrimaryIndexByTimestamp: &keepAllPrimaryIndexByTimestamp,
          camerasFound: &camerasFound,
          duplicateFileCount: &duplicateFileCount,
          duplicateTimestampCount: &duplicateTimestampCount,
          seenDuplicateTimestamps: &seenDuplicateTimestamps,
          scanned: &scanned,
          metadataCache: &metadataCache,
          progress: progress
        )
      }

      var sets: [ClipSet]
      if duplicatePolicy == .keepAll {
        sets = keepAllSets
      } else {
        sets = []
        sets.reserveCapacity(map.count)
        for (_, entry) in map {
          sets.append(entry.makeClipSet())
        }
      }
      sets.sort { lhs, rhs in
        if lhs.date == rhs.date {
          if lhs.timestamp == rhs.timestamp {
            let lhsPaths = lhs.files.values.map(\.path).sorted()
            let rhsPaths = rhs.files.values.map(\.path).sorted()
            if lhsPaths == rhsPaths {
              return lhs.id < rhs.id
            }
            return lhsPaths.lexicographicallyPrecedes(rhsPaths)
          }
          return lhs.timestamp < rhs.timestamp
        }
        return lhs.date < rhs.date
      }

      guard let first = sets.first, let last = sets.last else {
        throw ClipIndexError.noClipsFound
      }

      let maxEnd = sets.map(\.endDate).max() ?? last.endDate
      let totalDuration = max(0.1, maxEnd.timeIntervalSince(first.date))
      let overlapMinuteCount = overlapCount(in: sets)

      return ClipIndex(
        sets: sets,
        minDate: first.date,
        maxDate: maxEnd,
        totalDuration: totalDuration,
        camerasFound: camerasFound,
        layoutProfile: detectLayoutProfile(camerasFound: camerasFound),
        duplicateSummary: DuplicateResolutionSummary(
          duplicateFileCount: duplicateFileCount,
          duplicateTimestampCount: duplicateTimestampCount,
          overlapMinuteCount: overlapMinuteCount
        )
      )
    }
  }

  private static nonisolated func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
    let start = ContinuousClock.now
    defer {
      let elapsed = start.duration(to: .now)
      NSLog("[perf] %@ took %@", name, String(describing: elapsed))
    }
    return try work()
  }

  private static nonisolated func normalizeInputs(_ inputs: [URL]) -> [URL] {
    var seen = Set<String>()
    var out: [URL] = []
    out.reserveCapacity(inputs.count)
    for raw in inputs {
      let url = raw.standardizedFileURL
      let key = url.path
      if seen.contains(key) { continue }
      seen.insert(key)
      out.append(url)
    }
    return out
  }

  private static nonisolated func hasHiddenPathComponent(_ url: URL, relativeTo root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    let relativePath: String
    if filePath.hasPrefix(rootPath) {
      relativePath = String(filePath.dropFirst(rootPath.count))
    } else {
      relativePath = filePath
    }
    return relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
  }

  private static nonisolated func parseClipFile(
    _ fileURL: URL,
    duplicatePolicy: DuplicateClipPolicy,
    into map: inout [String: IndexedClipSetBuilder],
    keepAllSets: inout [ClipSet],
    keepAllPrimaryIndexByTimestamp: inout [String: Int],
    camerasFound: inout Set<Camera>,
    duplicateFileCount: inout Int,
    duplicateTimestampCount: inout Int,
    seenDuplicateTimestamps: inout Set<String>,
    scanned: inout Int,
    metadataCache: inout [String: ClipAssetProbe],
    progress: (Int) -> Void
  ) {
    let fm = FileManager.default
    let ext = fileURL.pathExtension.lowercased()
    if ext != "mp4" && ext != "mov" { return }

    let name = fileURL.lastPathComponent
    guard let match = firstMatch(in: name) else { return }
    let timestamp = match.timestamp
    guard let date = makeDateFormatter().date(from: timestamp) else { return }
    let camera = match.camera
    let metadata = probeMetadata(for: fileURL, cache: &metadataCache)

    if duplicatePolicy == .keepAll {
      if let primaryIndex = keepAllPrimaryIndexByTimestamp[timestamp] {
        if keepAllSets[primaryIndex].files[camera] == nil {
          var files = keepAllSets[primaryIndex].files
          files[camera] = fileURL
          var durations = keepAllSets[primaryIndex].cameraDurations
          durations[camera] = metadata.duration
          var naturalSizes = keepAllSets[primaryIndex].naturalSizes
          naturalSizes[camera] = metadata.naturalSize
          var frameRates = keepAllSets[primaryIndex].cameraFrameRates
          if let frameRate = metadata.frameRate {
            frameRates[camera] = frameRate
          } else {
            frameRates.removeValue(forKey: camera)
          }
          var codecs = keepAllSets[primaryIndex].cameraCodecs
          if let codec = metadata.codec {
            codecs[camera] = codec
          } else {
            codecs.removeValue(forKey: camera)
          }
          var unreadable = keepAllSets[primaryIndex].unreadableCameras
          if metadata.isReadable { unreadable.remove(camera) } else { unreadable.insert(camera) }
          keepAllSets[primaryIndex] = ClipSet(
            id: keepAllSets[primaryIndex].id,
            timestamp: keepAllSets[primaryIndex].timestamp,
            date: keepAllSets[primaryIndex].date,
            duration: max(keepAllSets[primaryIndex].duration, metadata.duration),
            files: files,
            cameraDurations: durations,
            naturalSizes: naturalSizes,
            cameraFrameRates: frameRates,
            cameraCodecs: codecs,
            unreadableCameras: unreadable
          )
        } else {
          duplicateFileCount += 1
          if seenDuplicateTimestamps.insert(timestamp).inserted {
            duplicateTimestampCount += 1
          }
          let suffix = keepAllSets.filter { $0.timestamp == timestamp }.count + 1
          let duplicateID = "\(timestamp)__dup\(suffix)"
          keepAllSets.append(
            ClipSet(
              id: duplicateID,
              timestamp: timestamp,
              date: date,
              duration: metadata.duration,
              files: [camera: fileURL],
              cameraDurations: [camera: metadata.duration],
              naturalSizes: [camera: metadata.naturalSize],
              cameraFrameRates: metadata.frameRate.map { [camera: $0] } ?? [:],
              cameraCodecs: metadata.codec.map { [camera: $0] } ?? [:],
              unreadableCameras: metadata.isReadable ? [] : [camera]
            )
          )
        }
      } else {
        keepAllPrimaryIndexByTimestamp[timestamp] = keepAllSets.count
        keepAllSets.append(
          ClipSet(
            id: timestamp,
            timestamp: timestamp,
            date: date,
            duration: metadata.duration,
            files: [camera: fileURL],
            cameraDurations: [camera: metadata.duration],
            naturalSizes: [camera: metadata.naturalSize],
            cameraFrameRates: metadata.frameRate.map { [camera: $0] } ?? [:],
            cameraCodecs: metadata.codec.map { [camera: $0] } ?? [:],
            unreadableCameras: metadata.isReadable ? [] : [camera]
          )
        )
      }
      camerasFound.insert(camera)
      scanned += 1
      if scanned % 100 == 0 { progress(scanned) }
      return
    }

    var entry = map[timestamp] ?? IndexedClipSetBuilder(timestamp: timestamp, date: date)
    if let existing = entry.files[camera] {
      duplicateFileCount += 1
      if seenDuplicateTimestamps.insert(timestamp).inserted {
        duplicateTimestampCount += 1
      }
      switch duplicatePolicy {
      case .mergeByTime, .keepAll:
        if fileURL.path < existing.path {
          entry.replace(camera: camera, url: fileURL, metadata: metadata)
        }
      case .preferNewest:
        let existingDate = (try? fm.attributesOfItem(atPath: existing.path)[.modificationDate] as? Date) ?? .distantPast
        let candidateDate = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? .distantPast
        if candidateDate > existingDate || (candidateDate == existingDate && fileURL.path < existing.path) {
          entry.replace(camera: camera, url: fileURL, metadata: metadata)
        }
      }
    } else {
      entry.insert(camera: camera, url: fileURL, metadata: metadata)
    }
    map[timestamp] = entry
    camerasFound.insert(camera)

    scanned += 1
    if scanned % 100 == 0 { progress(scanned) }
  }

  private static nonisolated func firstMatch(in filename: String) -> (timestamp: String, camera: Camera)? {
    let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
    guard let m = regex.firstMatch(in: filename, options: [], range: range) else { return nil }
    guard let tsRange = Range(m.range(at: 1), in: filename) else { return nil }
    guard let camRange = Range(m.range(at: 2), in: filename) else { return nil }
    let timestamp = String(filename[tsRange])
    let rawCamera = String(filename[camRange])
    guard let camera = normalizeCamera(rawCamera) else { return nil }
    return (timestamp, camera)
  }

  private static nonisolated func normalizeCamera(_ raw: String) -> Camera? {
    var token = raw.lowercased().replacingOccurrences(of: "-", with: "_")
    token = token.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    token = token.replacingOccurrences(of: "_?\\d+$", with: "", options: .regularExpression)

    if token == "front" || token == "fwd" || token == "forward" {
      return .front
    }
    if token == "back" || token == "rear" || token == "rear_camera" {
      return .back
    }
    if token.contains("left") && token.contains("pillar") {
      return .left_pillar
    }
    if token.contains("right") && token.contains("pillar") {
      return .right_pillar
    }
    if (token.contains("left") && token.contains("repeat")) || token == "left_rear" {
      return .left_repeater
    }
    if (token.contains("right") && token.contains("repeat")) || token == "right_rear" {
      return .right_repeater
    }
    if token == "left" {
      return .left
    }
    if token == "right" {
      return .right
    }

    return Camera(rawValue: token)
  }

  private static nonisolated func probeMetadata(for fileURL: URL, cache: inout [String: ClipAssetProbe]) -> ClipAssetProbe {
    if let cached = cache[fileURL.path] {
      return cached
    }
    let probe = computeMetadataAwayFromMainThread(for: fileURL)
    cache[fileURL.path] = probe
    return probe
  }

  /// Loads one clip's duration + natural size. Marks the clip unreadable when
  /// the asset has no valid duration or no video track (corrupt/truncated).
  private static nonisolated func computeMetadata(for fileURL: URL) -> ClipAssetProbe {
    let asset = AVURLAsset(
      url: fileURL,
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    let loaded = loadAssetMetadata(for: asset)
    let seconds = CMTimeGetSeconds(loaded.duration)
    let durationValid = loaded.duration.isValid && seconds.isFinite && seconds > 0
    let isReadable = durationValid && loaded.naturalSize != nil
    let durationSeconds = max(0.1, normalizedDuration(loaded.duration))
    return ClipAssetProbe(
      duration: durationSeconds,
      naturalSize: loaded.naturalSize ?? CGSize(width: 1280, height: 960),
      frameRate: loaded.frameRate,
      codec: loaded.codec,
      isReadable: isReadable
    )
  }

  /// Probes every supplied clip's metadata concurrently, populating `cache`.
  ///
  /// AVAsset duration/track loading is I/O bound, so probing serially (one
  /// blocking load per file) dominates cold-scan time on large dumps. This
  /// fans the work out across `concurrentPerform`'s libdispatch worker pool;
  /// each `computeMetadata` bridges its own async load via a private
  /// semaphore on a worker thread, distinct from the Swift cooperative pool
  /// that runs the loads — so there is no thread-pool deadlock.
  private static nonisolated func prewarmMetadata(_ urls: [URL], cache: inout [String: ClipAssetProbe]) {
    var toProbe: [URL] = []
    var seen = Set<String>()
    toProbe.reserveCapacity(urls.count)
    for url in urls {
      let path = url.path
      if cache[path] != nil { continue }
      if seen.insert(path).inserted {
        toProbe.append(url)
      }
    }
    guard !toProbe.isEmpty else {
      return
    }

    guard toProbe.count > 1 else {
      for url in toProbe {
        cache[url.path] = computeMetadataAwayFromMainThread(for: url)
      }
      return
    }

    let lock = NSLock()
    var probed: [String: ClipAssetProbe] = [:]
    probed.reserveCapacity(toProbe.count)
    DispatchQueue.concurrentPerform(iterations: toProbe.count) { index in
      let url = toProbe[index]
      let probe = computeMetadataAwayFromMainThread(for: url)
      lock.lock()
      probed[url.path] = probe
      lock.unlock()
    }
    for (path, probe) in probed {
      cache[path] = probe
    }
  }

  private static nonisolated func computeMetadataAwayFromMainThread(for fileURL: URL) -> ClipAssetProbe {
    if Thread.isMainThread {
      return DispatchQueue.global(qos: .userInitiated).sync {
        computeMetadata(for: fileURL)
      }
    }
    return computeMetadata(for: fileURL)
  }

  private static nonisolated func normalizedDuration(_ time: CMTime) -> Double {
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds > 0 else { return 60.0 }
    return seconds
  }

  private static nonisolated func loadAssetMetadata(for asset: AVURLAsset) -> (duration: CMTime, naturalSize: CGSize?, frameRate: Double?, codec: VideoCodec?) {
    let semaphore = DispatchSemaphore(value: 0)
    var loadedDuration = CMTime.invalid
    var loadedNaturalSize: CGSize?
    var loadedFrameRate: Double?
    var loadedCodec: VideoCodec?

    Task.detached(priority: .userInitiated) {
      defer { semaphore.signal() }
      do {
        async let duration = asset.load(.duration)
        async let tracks = asset.loadTracks(withMediaType: .video)
        loadedDuration = try await duration
        if let track = try await tracks.first {
          async let naturalSize = track.load(.naturalSize)
          async let preferredTransform = track.load(.preferredTransform)
          async let nominalFrameRate = track.load(.nominalFrameRate)
          async let formatDescriptions = track.load(.formatDescriptions)
          let transformed = try await naturalSize.applying(preferredTransform)
          loadedNaturalSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
          let frameRate = try await nominalFrameRate
          loadedFrameRate = frameRate > 0 ? Double(frameRate) : nil
          if let formatDescription = try await formatDescriptions.first {
            loadedCodec = VideoCodec(mediaSubType: CMFormatDescriptionGetMediaSubType(formatDescription))
          }
        } else {
          loadedNaturalSize = nil
          loadedFrameRate = nil
          loadedCodec = nil
        }
      } catch {
        loadedDuration = .invalid
        loadedNaturalSize = nil
        loadedFrameRate = nil
        loadedCodec = nil
      }
    }

    semaphore.wait()
    return (loadedDuration, loadedNaturalSize, loadedFrameRate, loadedCodec)
  }

  private static nonisolated func detectLayoutProfile(camerasFound: Set<Camera>) -> CameraLayoutProfile {
    CameraLayoutPlan.detectedProfile(for: camerasFound)
  }

  private static nonisolated func overlapCount(in sets: [ClipSet]) -> Int {
    guard sets.count > 1 else { return 0 }
    var overlaps = 0
    for index in 0..<(sets.count - 1) {
      if sets[index + 1].date < sets[index].endDate {
        overlaps += 1
      }
    }
    return overlaps
  }
}

nonisolated private struct ClipAssetProbe {
  let duration: Double
  let naturalSize: CGSize
  let frameRate: Double?
  /// Source video codec (H.264 vs HEVC), or nil when undetectable. The export
  /// pipeline adopts this so footage is never needlessly transcoded.
  var codec: VideoCodec?
  /// `false` when the asset failed to load a valid duration / video track —
  /// i.e. a corrupt or truncated clip. Such clips still get a fallback
  /// duration so the timeline stays intact, but they are flagged rather than
  /// silently presented as a healthy 60-second set.
  var isReadable: Bool = true
}

nonisolated private struct IndexedClipSetBuilder {
  let timestamp: String
  let date: Date
  var files: [Camera: URL] = [:]
  var durations: [Camera: Double] = [:]
  var naturalSizes: [Camera: CGSize] = [:]
  var frameRates: [Camera: Double] = [:]
  var codecs: [Camera: VideoCodec] = [:]
  var unreadableCameras: Set<Camera> = []

  mutating func insert(camera: Camera, url: URL, metadata: ClipAssetProbe) {
    files[camera] = url
    durations[camera] = metadata.duration
    naturalSizes[camera] = metadata.naturalSize
    if let frameRate = metadata.frameRate {
      frameRates[camera] = frameRate
    } else {
      frameRates.removeValue(forKey: camera)
    }
    if let codec = metadata.codec {
      codecs[camera] = codec
    } else {
      codecs.removeValue(forKey: camera)
    }
    if metadata.isReadable {
      unreadableCameras.remove(camera)
    } else {
      unreadableCameras.insert(camera)
    }
  }

  mutating func replace(camera: Camera, url: URL, metadata: ClipAssetProbe) {
    insert(camera: camera, url: url, metadata: metadata)
  }

  func makeClipSet() -> ClipSet {
    ClipSet(
      timestamp: timestamp,
      date: date,
      duration: durations.values.max() ?? 60.0,
      files: files,
      cameraDurations: durations,
      naturalSizes: naturalSizes,
      cameraFrameRates: frameRates,
      cameraCodecs: codecs,
      unreadableCameras: unreadableCameras
    )
  }
}
