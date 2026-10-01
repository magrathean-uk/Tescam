import Foundation

// MARK: - Selection manifest

struct DomainSelectedClipSetManifest: Codable, Equatable {
  let timestamp: String
  let startTime: String
  let duration: Double
  let trimStart: Double
  let trimEnd: Double
  let renderedDuration: Double
  let cameras: [String]
  let files: [String: String]

  enum CodingKeys: String, CodingKey {
    case timestamp
    case startTime = "start_time"
    case duration
    case trimStart = "trim_start"
    case trimEnd = "trim_end"
    case renderedDuration = "rendered_duration"
    case cameras
    case files
  }
}

struct DomainSelectionManifest: Codable, Equatable {
  let clipSetCount: Int
  let renderedDuration: Double
  let clipSets: [DomainSelectedClipSetManifest]

  enum CodingKeys: String, CodingKey {
    case clipSetCount = "clip_set_count"
    case renderedDuration = "rendered_duration"
    case clipSets = "clip_sets"
  }

  /// Empty-selection sentinel: matches what Python's
  /// `selected_sets_manifest` returns when no clips survive filtering.
  static let empty = DomainSelectionManifest(
    clipSetCount: 0,
    renderedDuration: 0.0,
    clipSets: []
  )
}

extension Array where Element == ClipSet {
  /// Build the selection manifest for the contract.
  ///
  /// Mirrors Python's `selected_sets_manifest()` (in
  /// `tescam_cli/domain_contract.py`) and exists so fixture-scale
  /// Swift parity tests can produce the same JSON shape without
  /// running AVAsset duration probes against empty fixture files.
  ///
  /// - Parameters:
  ///   - startTime: lower time bound (inclusive); clips ending at or
  ///     before this are dropped.
  ///   - endTime: upper time bound (exclusive); clips starting at or
  ///     after this are dropped.
  ///   - clipDurationSeconds: assumed duration for every clip set.
  ///     Pass the natural value from real AVAsset probes in production
  ///     code, or a stub (60s for fixture parity tests) when the
  ///     underlying media is synthetic.
  ///   - rootURL: source directory used to make the file paths
  ///     relative in the manifest output.
  func domainSelectionManifest(
    startTime: Date,
    endTime: Date,
    clipDurationSeconds: Double,
    relativeTo rootURL: URL
  ) -> DomainSelectionManifest {
    let cameraOrder = Dictionary(
      uniqueKeysWithValues: Camera.mixedOrder.enumerated().map { ($0.element, $0.offset) }
    )

    var manifests: [DomainSelectedClipSetManifest] = []
    var totalRendered: Double = 0.0

    for clipSet in self {
      let clipEnd = clipSet.date.addingTimeInterval(clipDurationSeconds)
      if clipSet.date >= endTime || clipEnd <= startTime {
        continue
      }
      // Inside an `Array<ClipSet>` extension, bare `max` / `min` resolve
      // to the Array instance methods. Force the global numeric ones.
      let trimStart = Swift.max(0.0, startTime.timeIntervalSince(clipSet.date))
      let trimEnd = Swift.min(clipDurationSeconds, endTime.timeIntervalSince(clipSet.date))
      if trimEnd - trimStart <= 0.001 {
        continue
      }
      let rendered = Swift.max(0.0, trimEnd - trimStart)
      totalRendered += rendered

      let orderedCameras = clipSet.files.keys.sorted { lhs, rhs in
        let lhsIndex = cameraOrder[lhs] ?? Int.max
        let rhsIndex = cameraOrder[rhs] ?? Int.max
        if lhsIndex == rhsIndex { return lhs.rawValue < rhs.rawValue }
        return lhsIndex < rhsIndex
      }
      var files: [String: String] = [:]
      for camera in orderedCameras {
        if let url = clipSet.files[camera] {
          files[camera.rawValue] = DomainContractPath.relative(url, to: rootURL)
        }
      }
      manifests.append(
        DomainSelectedClipSetManifest(
          timestamp: clipSet.timestamp,
          startTime: DomainContractPath.timestamp(clipSet.date),
          duration: DomainContractPath.round6(clipDurationSeconds),
          trimStart: DomainContractPath.round6(trimStart),
          trimEnd: DomainContractPath.round6(trimEnd),
          renderedDuration: DomainContractPath.round6(rendered),
          cameras: orderedCameras.map(\.rawValue),
          files: files
        )
      )
    }

    return DomainSelectionManifest(
      clipSetCount: manifests.count,
      renderedDuration: DomainContractPath.round6(totalRendered),
      clipSets: manifests
    )
  }
}

// MARK: - Output policy

/// Output-conflict policy for the contract's CLI default-naming flow.
/// Mirrors Python's `OutputConflictPolicy` enum.
enum OutputConflictPolicy: String, Codable, CaseIterable {
  case unique
  case overwrite
  case error
}

/// Thrown by ``DomainOutputContract.applyConflictPolicy`` when policy
/// is ``OutputConflictPolicy/error`` and the target path already
/// exists. The message intentionally embeds the conflicting path so
/// the surfaced text matches Python's ``RuntimeError("Output file
/// already exists: ...")`` to within the contract-pinned fragment.
struct OutputAlreadyExistsError: Error, LocalizedError {
  let path: URL
  var errorDescription: String? {
    "Output file already exists: \(path.path)"
  }
}

/// Contract-side helpers mirroring Python's ``cli.default_output_filename``,
/// ``cli.unique_output_path``, and ``cli.apply_output_conflict_policy``.
/// Pure functions; the only side effect is a ``FileManager`` existence
/// check (the same surface Python's ``Path.exists()`` exposes). Lives on
/// the contract layer so the macOS app and any future CLI-style Swift
/// adapter share one source of truth.
enum DomainOutputContract {
  static let errorMessageFragment = "Output file already exists"

  static func defaultOutputFilename(mode: String, startTime: Date, endTime: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let start = formatter.string(from: startTime)
    let end = formatter.string(from: endTime)
    return "tescam_\(mode)_\(start)_to_\(end).mp4"
  }

  static func uniqueOutputPath(_ path: URL, fileManager: FileManager = .default) -> URL {
    guard fileManager.fileExists(atPath: path.path) else { return path }
    let parent = path.deletingLastPathComponent()
    let stem = path.deletingPathExtension().lastPathComponent
    let extn = path.pathExtension
    let suffix = extn.isEmpty ? "" : ".\(extn)"
    for counter in 2..<10_000 {
      let candidate = parent.appendingPathComponent("\(stem)-\(counter)\(suffix)")
      if !fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return path
  }

  /// Apply ``policy`` to ``path``. Returns the resolved URL or throws
  /// ``OutputAlreadyExistsError`` when policy is ``.error`` and the
  /// path already exists. ``.overwrite`` returns the input path
  /// unchanged regardless of file-system state — the caller takes
  /// responsibility for replacing the file.
  static func applyConflictPolicy(
    path: URL,
    policy: OutputConflictPolicy,
    fileManager: FileManager = .default
  ) throws -> URL {
    if !fileManager.fileExists(atPath: path.path) || policy == .overwrite {
      return path
    }
    if policy == .error {
      throw OutputAlreadyExistsError(path: path)
    }
    return uniqueOutputPath(path, fileManager: fileManager)
  }
}

// MARK: - Output manifest (fixture JSON shape)

/// JSON shape for ``expected_output`` blocks under
/// ``fixtures/domain/cases/*.json``. Mirrors the dict that
/// ``script/regen_fixtures.py``'s ``_output_block`` produces.
struct DomainOutputErrorEntry: Codable, Equatable {
  let raises: Bool
  let exceptionType: String?
  let messageContains: String?

  enum CodingKeys: String, CodingKey {
    case raises
    case exceptionType = "exception_type"
    case messageContains = "message_contains"
  }
}

struct DomainOutputManifest: Codable, Equatable {
  /// Set when the fixture's scan yields zero clips. The other fields
  /// are absent in that branch, so the parity test must check this
  /// first and skip the populated assertions.
  let emptyDataset: Bool?
  let defaultFilenameByMode: [String: String]?
  let uniqueResolution: [String]?
  let overwriteWithConflict: String?
  let errorWithConflict: DomainOutputErrorEntry?

  enum CodingKeys: String, CodingKey {
    case emptyDataset = "empty_dataset"
    case defaultFilenameByMode = "default_filename_by_mode"
    case uniqueResolution = "unique_resolution"
    case overwriteWithConflict = "overwrite_with_conflict"
    case errorWithConflict = "error_with_conflict"
  }
}

// MARK: - Shared formatting helpers

/// Contract formatting helpers shared by every `DomainScanManifest` /
/// `DomainSelectionManifest` builder. Matches the `path_for_manifest`
/// / `datetime_for_manifest` / `round(value, 6)` behaviour in
/// Python's `domain_contract.py`.
enum DomainContractPath {
  static func relative(_ url: URL, to rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    if path.hasPrefix(prefix) {
      return String(path.dropFirst(prefix.count))
    }
    return path
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: date)
  }

  /// Mirror Python's `round(value, 6)`. For the deterministic fixture
  /// values (60.0 etc.) the input is already exact; this helper exists
  /// so future contract-shape changes stay symmetric.
  static func round6(_ value: Double) -> Double {
    let scale = 1_000_000.0
    return (value * scale).rounded() / scale
  }
}
