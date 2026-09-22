import Foundation
import Combine
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

struct TimelineStore {
  private(set) var clipSets: [ClipSet] = []
  private(set) var minDate: Date?
  private(set) var maxDate: Date?
  private(set) var selectedStart: Date = Date()
  private(set) var selectedEnd: Date = Date()
  private(set) var trimStartSeconds: Double = 0
  private(set) var trimEndSeconds: Double = 0
  private(set) var isDraggingTrim: Bool = false
  private(set) var totalDuration: Double = 0
  private(set) var gapRanges: [TimelineGapRange] = []

  private var coverage = TimelineCoverageMap(sets: [])

  mutating func clear() {
    clipSets = []
    minDate = nil
    maxDate = nil
    selectedStart = Date()
    selectedEnd = Date()
    trimStartSeconds = 0
    trimEndSeconds = 0
    isDraggingTrim = false
    totalDuration = 0
    gapRanges = []
    coverage = TimelineCoverageMap(sets: [])
  }

  mutating func load(sets: [ClipSet], minDate: Date? = nil, maxDate: Date? = nil) {
    guard !sets.isEmpty else {
      clear()
      return
    }

    clipSets = sets
    coverage = TimelineCoverageMap(sets: sets, scale: .recordedClips)
    totalDuration = coverage.totalDuration
    gapRanges = coverage.gapRanges(minimumDuration: 5)
    self.minDate = minDate ?? coverage.date(forGlobalSeconds: 0)
    self.maxDate = maxDate ?? coverage.date(forGlobalSeconds: totalDuration)
    setTrimRange(startSeconds: 0, endSeconds: totalDuration)
  }

  mutating func setDragging(_ dragging: Bool) {
    isDraggingTrim = dragging
  }

  mutating func setFullRange() {
    setTrimRange(startSeconds: 0, endSeconds: totalDuration, snapToMinute: true)
  }

  mutating func setCurrentMinuteRange(currentSeconds: Double) {
    guard totalDuration > 0 else { return }
    let start = floor(currentSeconds / 60.0) * 60.0
    let end = min(totalDuration, start + 60.0)
    setTrimRange(startSeconds: start, endSeconds: end, snapToMinute: true)
  }

  mutating func setRecentRange(minutes: Int) {
    guard totalDuration > 0 else { return }
    let window = Double(minutes * 60)
    let end = totalDuration
    let start = max(0, end - window)
    setTrimRange(startSeconds: start, endSeconds: end, snapToMinute: true)
  }

  mutating func setTestExportRange(minutes: Int, currentSeconds: Double) {
    guard totalDuration > 0 else { return }
    let halfWindow = Double(minutes * 60) / 2
    var start = max(0, currentSeconds - halfWindow)
    var end = min(totalDuration, currentSeconds + halfWindow)
    if end - start < Double(minutes * 60) {
      if start == 0 {
        end = min(totalDuration, Double(minutes * 60))
      } else if end == totalDuration {
        start = max(0, totalDuration - Double(minutes * 60))
      }
    }
    setTrimRange(startSeconds: start, endSeconds: end, snapToMinute: true)
  }

  mutating func setTrimRange(startSeconds: Double, endSeconds: Double, snapToMinute: Bool = false) {
    guard !clipSets.isEmpty else { return }
    let upperBound = max(totalDuration, 1 / 30)
    let clampedStart = max(0, min(startSeconds, upperBound))
    let clampedEnd = max(clampedStart, min(endSeconds, upperBound))

    var normalizedStart = clampedStart
    var normalizedEnd = max(clampedEnd, normalizedStart + (1 / 30))

    if snapToMinute {
      normalizedStart = snappedTrimBoundary(clampedStart, roundsUp: false)
      normalizedEnd = snappedTrimBoundary(clampedEnd, roundsUp: true)
      normalizedEnd = max(normalizedEnd, normalizedStart + 1)
      normalizedEnd = min(normalizedEnd, upperBound)
      if normalizedEnd <= normalizedStart {
        normalizedEnd = min(upperBound, normalizedStart + 1)
      }
    }

    trimStartSeconds = normalizedStart
    trimEndSeconds = normalizedEnd
    selectedStart = trimStartDate
    selectedEnd = trimEndDate
  }

  var trimStartDate: Date {
    date(forGlobalSeconds: trimStartSeconds)
  }

  var trimEndDate: Date {
    date(forGlobalSeconds: trimEndSeconds)
  }

  var selectedTrimDuration: Double {
    max(0, trimEndSeconds - trimStartSeconds)
  }

  var selectedSetsForExport: [ClipSet] {
    let startDate = trimStartDate
    let endDate = trimEndDate
    return clipSets.filter { set in
      set.endDate > startDate && set.date < endDate
    }
  }

  func currentGapRange(at seconds: Double) -> TimelineGapRange? {
    gapRanges.first { $0.contains(seconds) }
  }

  func date(forGlobalSeconds seconds: Double) -> Date {
    coverage.date(forGlobalSeconds: seconds) ?? Date()
  }

  func globalSeconds(for date: Date) -> Double {
    coverage.globalSeconds(for: date)
  }

  func clipStartOffset(at index: Int) -> Double {
    coverage.clipStartOffset(at: index)
  }

  func activeClipIndex(at globalSeconds: Double) -> Int? {
    coverage.activeClipIndex(at: globalSeconds)
  }

  func nearestClipIndex(to globalSeconds: Double) -> Int {
    coverage.nearestClipIndex(to: globalSeconds)
  }

  func playbackSegment(at globalSeconds: Double) -> TimelinePlaybackSegment {
    coverage.playbackSegment(at: globalSeconds)
  }

  private func snappedTrimBoundary(_ seconds: Double, roundsUp: Bool) -> Double {
    let minute = 60.0
    let clamped = max(0, min(seconds, totalDuration))
    let rounded = roundsUp
      ? ceil(clamped / minute) * minute
      : floor(clamped / minute) * minute
    return max(0, min(rounded, totalDuration))
  }
}

struct ExportStore {
  var fileManager: FileManager = .default

  func defaultFilename(
    sets: [ClipSet],
    preset: ExportPreset,
    trimStartDate: Date,
    trimEndDate: Date
  ) -> String {
    guard !sets.isEmpty else {
      return "tescam_\(preset.outputLabel).\(preset.defaultExtension)"
    }
    let suffix = "\(filenameStamp(trimStartDate))_to_\(filenameStamp(trimEndDate))"
    return "tescam_\(suffix)_\(preset.outputLabel).\(preset.defaultExtension)"
  }

  func resolvedOutputURL(
    chosenURL: URL,
    preferredFilename: String,
    preset: ExportPreset
  ) -> URL {
    var outputURL = chosenURL
    if (try? chosenURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      outputURL = uniqueAvailableOutputURL(for: chosenURL.appendingPathComponent(preferredFilename))
    }

    let expectedExtension = preset.defaultExtension
    if outputURL.pathExtension.lowercased() != expectedExtension {
      outputURL.deletePathExtension()
      outputURL.appendPathExtension(expectedExtension)
    }
    return uniqueAvailableOutputURL(for: outputURL)
  }

  func makeRequest(
    sets: [ClipSet],
    chosenURL: URL,
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
  ) -> ExportRequest? {
    guard !sets.isEmpty else { return nil }
    let useExpandedGrid: Bool
    switch layoutRequest {
    case .legacy4:
      useExpandedGrid = false
    case .sixcam:
      useExpandedGrid = true
    case .auto:
      useExpandedGrid = enabledCameras.count > 4 || sets.contains { set in
        !Set(set.files.keys).intersection([.left, .right, .left_pillar, .right_pillar]).isEmpty
      }
    }
    return ExportRequest(
      sets: sets,
      outputURL: resolvedOutputURL(
        chosenURL: chosenURL,
        preferredFilename: defaultFilename(
          sets: sets,
          preset: preset,
          trimStartDate: trimStartDate,
          trimEndDate: trimEndDate
        ),
        preset: preset
      ),
      useSixCam: useExpandedGrid,
      preset: preset,
      enabledCameras: enabledCameras,
      layoutRequest: layoutRequest,
      overlayOptions: overlayOptions,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: trimEndSeconds,
      trimStartDate: trimStartDate,
      trimEndDate: trimEndDate,
      selectedRangeText: selectedRangeText,
      partialClipCount: partialClipCount,
      cameraTrack: cameraTrack,
      isPreviewSample: isPreviewSample
    )
  }

  private func uniqueAvailableOutputURL(for preferredURL: URL) -> URL {
    guard fileManager.fileExists(atPath: preferredURL.path) else {
      return preferredURL
    }

    let directory = preferredURL.deletingLastPathComponent()
    let baseName = preferredURL.deletingPathExtension().lastPathComponent
    let pathExtension = preferredURL.pathExtension

    for suffix in 2...999 {
      var candidate = directory.appendingPathComponent("\(baseName)-\(suffix)")
      if !pathExtension.isEmpty {
        candidate.appendPathExtension(pathExtension)
      }
      if !fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
    }

    var fallback = directory.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(8))")
    if !pathExtension.isEmpty {
      fallback.appendPathExtension(pathExtension)
    }
    return fallback
  }

  private func filenameStamp(_ date: Date) -> String {
    TeslaCamFormatters.fullDateTime
      .string(from: date)
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: " ", with: "_")
  }
}

final class AppState: ObservableObject {
  private enum DebugEnvironment {
    static let source = "TESLACAM_DEBUG_SOURCE"
    static let exportDirectory = "TESLACAM_DEBUG_EXPORT_DIR"
    static let uiTestMode = "TESLACAM_UI_TEST_MODE"
    static let xCTestConfiguration = "XCTestConfigurationFilePath"
  }

  let debugLog = DebugLogSink()
  let playbackUI = PlaybackUIState()

  @Published var rootURL: URL?
  @Published var sourceURLs: [URL] = []
  @Published var clipSets: [ClipSet] = []
  @Published var isIndexing: Bool = false
  @Published var indexStatus: String = ""
  @Published var scanStage: ScanStage = .scanningNestedFolders
  @Published var scanDiscoveredClipCount: Int = 0
  @Published var minDate: Date?
  @Published var maxDate: Date?
  @Published var selectedStart: Date = Date()
  @Published var selectedEnd: Date = Date()
  @Published var trimStartSeconds: Double = 0
  @Published var trimEndSeconds: Double = 0
  @Published var isDraggingTrim: Bool = false
  @Published var currentIndex: Int = 0
  @Published var totalDuration: Double = 0
  @Published var timelineGapRanges: [TimelineGapRange] = []
  @Published var errorMessage: String = ""
  @Published var showError: Bool = false
  @Published var camerasDetected: [Camera] = []
  @Published var duplicatePolicy: DuplicateClipPolicy = .mergeByTime
  @Published var selectedExportCameras: Set<Camera> = Set(Camera.allCases)
  @Published var exportPreset: ExportPreset = .maxQualityHEVC
  @Published var healthSummary: ExportHealthSummary?
  @Published var layoutProfile: CameraLayoutProfile = .mixedUnknown
  @Published var duplicateSummary = DuplicateResolutionSummary(
    duplicateFileCount: 0,
    duplicateTimestampCount: 0,
    overlapMinuteCount: 0
  )
  @Published var telemetryModel: TelemetryDisplayModel?
  @Published var telemetryRoute: [TelemetryRoutePoint] = []
  @Published var telemetryEventMarkers: [TelemetryEventMarker] = []
  /// Whether the currently-loaded clip carries usable telemetry. Presence is
  /// per-clip (SavedClips typically embed it, RecentClips often don't), so the
  /// map/HUD would otherwise be silently empty on a telemetry-less clip; the
  /// UI uses this to show an explicit "no telemetry" state.
  @Published var telemetryAvailability: TelemetryAvailability = .unknown
  @Published var eventSummaries: [TeslaCamEventSummary] = []
  @Published var eventSearchText: String = ""
  @Published var eventReasonFilter: String = "all"
  @Published var eventSortMode: TeslaCamEventSortMode = .oldestFirst
  @Published var currentEvent: TeslaCamEventSummary?
  @Published var previewLayoutMode: PreviewLayoutMode = .grid
  @Published var layoutRequest: CameraLayoutRequest = .auto
  @Published var focusedCamera: Camera?
  @Published var cameraTrack: CameraTrack = .empty
  @Published var clipHealthFacts: [ClipHealthFact] = []
  @Published var layoutPresetStatus: String = ""
  @Published var playbackRate: Double = 1.0 {
    didSet {
      let allowed = Self.allowedPlaybackRates
      playbackRate = allowed.min(by: { abs($0 - playbackRate) < abs($1 - playbackRate) }) ?? 1.0
      playback.playbackRate = playbackRate
    }
  }
  @Published var privacyMode: Bool = false {
    didSet {
      let local = max(0, currentSeconds - currentSegmentStartSeconds)
      updateOverlayAndTelemetry(
        globalSeconds: currentSeconds,
        clipIndex: currentSegmentClipIndex,
        localSeconds: local
      )
    }
  }
  // Keep telemetry engraving opt-in, but the default export itself stays the
  // regular encoded grid video users expect from the app.
  @Published var exportOverlayOptions = ExportOverlayOptions(
    telemetryHUD: false,
    routeMap: false,
    privacyMask: false,
    includeReport: false,
    includeScreenshot: false
  )
  @Published var isDuplicateResolverPresented: Bool = false
  @Published var duplicateResolverMessage: String = ""
  @Published var showDuplicateResolverForConflicts: Bool = false

  let playback = MultiCamPlaybackController()
  let exporter: NativeExportController
  static let allowedPlaybackRates: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0, 4.0]

  private var timelineStore = TimelineStore()
  private let exportStore = ExportStore()
  private let sourceStore = SourceStore()
  private var observers: Set<AnyCancellable> = []
  private var currentSegmentStartSeconds: Double = 0
  private var currentSegmentClipIndex: Int?
  private var isUserSeeking = false
  private var wasPlayingBeforeSeek = false
  private var telemetryTimeline: TelemetryTimeline?
  private var telemetryURL: URL?
  private var telemetryRouteByURL: [URL: [TelemetryRoutePoint]] = [:]

  init() {
    exporter = NativeExportController()
    exporter.debugLog = debugLog
    exporter.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &observers)
    playback.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &observers)
  }

  var currentSeconds: Double {
    get { playbackUI.currentSeconds }
    set { playbackUI.currentSeconds = newValue }
  }

  var overlayText: String {
    get { playbackUI.overlayText }
    set { playbackUI.overlayText = newValue }
  }

  var telemetryText: String {
    get { playbackUI.telemetryText }
    set { playbackUI.telemetryText = newValue }
  }

  func onAppear() {
    configurePlaybackCallbacks()
    debug("launch")
    guard clipSets.isEmpty, sourceURLs.isEmpty, !isIndexing else { return }
#if DEBUG
    if applyDebugLaunchModeIfNeeded() {
      return
    }
#endif
    // Re-open the folder(s) the user picked last time so they don't have to
    // re-pick on every launch. No-op (falls through to onboarding) when no
    // bookmarks are persisted or none currently resolve.
    restoreLastSourcesIfPossible()
  }

  private func configurePlaybackCallbacks() {
    playback.onTimeUpdate = { [weak self] seconds in
      self?.updateCurrentSeconds(localSeconds: seconds)
    }
    playback.onFinished = { [weak self] in
      self?.advanceToNextTimelineSegment()
    }
  }

  var previewTimelineState: PreviewTimelineState {
    PreviewTimelineState(
      currentGlobalSeconds: currentSeconds,
      activeClipSetIndex: currentIndex,
      playing: playback.isPlaying
    )
  }

  var currentGapRange: TimelineGapRange? {
    timelineStore.currentGapRange(at: currentSeconds)
  }

  var trimSelection: TimelineTrimSelection {
    TimelineTrimSelection(
      startSeconds: trimStartSeconds,
      endSeconds: trimEndSeconds,
      isDragging: isDraggingTrim
    )
  }

  /// On iPad this is a no-op; the view layer uses SwiftUI `.fileImporter`.
  @Published var isFileImporterPresented: Bool = false
  /// On iPad, set when the user needs to pick an export destination.
  @Published var isFileExporterPresented: Bool = false
  /// iPad export scratch URL for sharing.
  @Published var pendingExportScratchURL: URL?

  func chooseFolder() {
    guard !exporter.isExporting else { return }
    #if os(macOS)
    PlatformFileAccess.activateApp()
    PlatformFileAccess.chooseFolder(
      directoryURL: sourceURLs.first?.deletingLastPathComponent() ?? rootURL
    ) { [weak self] urls in
      self?.indexSources(urls)
    }
    #else
    isFileImporterPresented = true
    #endif
  }

  func loadDemoTimeline() {
    guard !exporter.isExporting else { return }
    isIndexing = false
    indexStatus = ""
    scanStage = .scanningNestedFolders
    scanDiscoveredClipCount = 0
    errorMessage = ""
    showError = false
    loadSampleTimeline()
    debug("demo timeline loaded", category: "demo")
  }

  func indexFolder(_ url: URL) {
    indexSources([url])
  }

  func indexSources(_ urls: [URL], surfaceErrors: Bool = true) {
    guard !exporter.isExporting else { return }
    let normalizedSources = normalizeSources(urls)
    guard !normalizedSources.isEmpty else {
      if surfaceErrors {
        errorMessage = "Couldn't open the selected folder. Pick the TeslaCam folder again from Files."
        showError = true
        debug("index failed: selected source was unreadable", category: "index")
      }
      return
    }
    debug("index start: \(normalizedSources.map { $0.lastPathComponent }.joined(separator: ", "))", category: "index")

    let previousSources = sourceURLs
    activateSecurityScopedAccess(for: normalizedSources)

    isIndexing = true
    indexStatus = "Putting the timeline together"
    scanStage = .scanningNestedFolders
    scanDiscoveredClipCount = 0
    // The current timeline and its derived state are deliberately NOT cleared
    // here: a failed scan (ejected card, unreadable folder) must leave the
    // working session intact. Derived state is reset in the success path
    // below — atomically, just before the freshly-scanned index is applied.

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let index = try ClipIndexer.index(inputURLs: normalizedSources, duplicatePolicy: self.duplicatePolicy) { scanned in
          DispatchQueue.main.async {
            self.scanStage = .scanningNestedFolders
            self.scanDiscoveredClipCount = scanned
            self.indexStatus = "Putting the timeline together"
          }
        }
        DispatchQueue.main.async {
          self.scanStage = .parsingTimestamps
          // Reset per-source derived/UI state now that a fresh index succeeded.
          // (Previously done up front; moved here so a failed scan keeps the
          // old session intact — see the prologue note above.)
          self.currentEvent = nil
          self.telemetryModel = nil
          self.telemetryRoute = []
          self.telemetryEventMarkers = []
          self.telemetryText = ""
          self.eventSearchText = ""
          self.eventReasonFilter = "all"
          self.cameraTrack = .empty
          self.layoutPresetStatus = ""
          self.isDuplicateResolverPresented = false
          self.duplicateResolverMessage = ""
          self.rootURL = normalizedSources.first
          self.sourceURLs = normalizedSources
          self.clipSets = index.sets
          self.minDate = index.minDate
          self.maxDate = index.maxDate
          self.currentIndex = 0
          self.layoutProfile = index.layoutProfile
          self.camerasDetected = self.orderCameras(Array(index.camerasFound), profile: index.layoutProfile)
          self.selectedExportCameras = Set(self.camerasDetected)
          self.healthSummary = self.buildHealthSummary(from: index.sets)
          self.clipHealthFacts = self.buildClipHealthFacts(from: index.sets)
          self.eventSummaries = self.buildEventSummaries(from: index.sets)
          self.duplicateSummary = index.duplicateSummary
          self.rememberLastSources(normalizedSources)
          self.scanStage = .mergingClips
          self.rebuildTimeline()
          self.setTrimRange(
            startSeconds: 0,
            endSeconds: self.totalDuration,
            snapToMinute: true
          )
          self.currentSeconds = 0
          self.seekToGlobalTime(0, exact: true)
          self.scanStage = .preparingTimeline
          self.isIndexing = false
          self.indexStatus = "Ready"
          self.debug(
            "index ready: sets=\(index.sets.count) cameras=\(self.camerasDetected.map { $0.rawValue }.joined(separator: ",")) profile=\(index.layoutProfile.rawValue) gaps=\(self.timelineGapRanges.count)",
            category: "index"
          )
        }
      } catch {
        DispatchQueue.main.async {
          self.isIndexing = false
          if !surfaceErrors && self.clipSets.isEmpty {
            self.indexStatus = ""
            self.sourceURLs = previousSources
            self.rootURL = previousSources.first
            if !previousSources.isEmpty,
               previousSources.map(\.path) != normalizedSources.map(\.path) {
              self.activateSecurityScopedAccess(for: previousSources)
            }
            self.showError = false
            self.debug("silent restore failed: \(error.localizedDescription)", category: "index")
            return
          }
          if self.clipSets.isEmpty {
            // No prior timeline to fall back to — surface the empty/onboarding error.
            self.indexStatus = ""
            self.errorMessage = "No clips found in the selected files/folders."
          } else {
            // A timeline is already loaded; keep it and re-acquire its security
            // scope (the failed load switched scope to the new sources).
            self.indexStatus = "Ready"
            if !previousSources.isEmpty,
               previousSources.map(\.path) != normalizedSources.map(\.path) {
              self.activateSecurityScopedAccess(for: previousSources)
            }
            self.errorMessage = "Couldn't load the selected source. The current timeline is unchanged."
          }
          self.showError = true
          self.debug("index failed: \(error.localizedDescription)", category: "index")
        }
      }
    }
  }

  func reloadSources() {
    guard !sourceURLs.isEmpty else { return }
    indexSources(sourceURLs)
  }

  func chooseDuplicatePolicy(_ policy: DuplicateClipPolicy) {
    isDuplicateResolverPresented = false
    duplicateResolverMessage = ""
    guard duplicatePolicy != .mergeByTime else { return }
    duplicatePolicy = .mergeByTime
  }

  func dismissDuplicateResolver() {
    isDuplicateResolverPresented = false
    duplicateResolverMessage = ""
  }

  func updateDuplicatePolicy(_ policy: DuplicateClipPolicy) {
    chooseDuplicatePolicy(.mergeByTime)
  }

  func togglePlay() {
    if playback.isPlaying {
      playback.pause()
    } else {
      if totalDuration > 0,
         (playback.currentDuration <= 0 || currentSegmentClipIndex == nil) {
        let start = currentSeconds >= totalDuration ? 0 : currentSeconds
        seekToGlobalTime(start, exact: true)
      }
      playback.play()
    }
  }

  func setPlaybackRate(_ rate: Double) {
    playbackRate = rate
  }

  func refreshTelemetryOverlay() {
    let local = max(0, currentSeconds - currentSegmentStartSeconds)
    updateOverlayAndTelemetry(
      globalSeconds: currentSeconds,
      clipIndex: currentSegmentClipIndex,
      localSeconds: local
    )
  }

  func cyclePlaybackRate() {
    let rates = Self.allowedPlaybackRates
    guard let index = rates.firstIndex(of: playbackRate) else {
      setPlaybackRate(1.0)
      return
    }
    setPlaybackRate(rates[(index + 1) % rates.count])
  }

  func stepPlayback(by seconds: Double) {
    guard totalDuration > 0 else { return }
    seekToGlobalTime(currentSeconds + seconds, exact: true)
  }

  func jumpToEvent(_ event: TeslaCamEventSummary) {
    guard clipSets.indices.contains(event.clipIndex) else { return }
    // Seek to the recorded trigger moment (event.json timestamp), not the start
    // of the clip folder. Tesla writes ~70s of pre-roll before the trigger, so
    // landing at the folder start buries the actual incident. #17
    let folderStart = clipStartOffset(at: event.clipIndex)
    let triggerSeconds = globalSeconds(for: event.timestamp)
    let seconds: Double
    if triggerSeconds.isFinite, triggerSeconds >= folderStart - 0.5, triggerSeconds < totalDuration {
      seconds = triggerSeconds
    } else {
      // No / out-of-range trigger timestamp (e.g. a plain RecentClips folder) —
      // fall back to the folder start.
      seconds = folderStart
    }
    seekToGlobalTime(seconds, exact: true)
    currentEvent = event
    debug("event jump \(event.id) -> \(String(format: "%.1f", seconds))s", category: "event")
  }

  func jumpToNextEvent(direction: Int = 1) {
    guard !eventSummaries.isEmpty else { return }
    let sorted = eventSummaries.sorted { $0.timestamp < $1.timestamp }
    let current = currentSeconds
    let target: TeslaCamEventSummary?
    if direction >= 0 {
      target = sorted.first { clipStartOffset(at: $0.clipIndex) > current + 0.5 } ?? sorted.first
    } else {
      target = sorted.reversed().first { clipStartOffset(at: $0.clipIndex) < current - 0.5 } ?? sorted.last
    }
    if let target {
      jumpToEvent(target)
    }
  }

  func restart() {
    guard !clipSets.isEmpty else { return }
    currentIndex = 0
    seekToGlobalTime(0, exact: true)
  }

  func normalizeRange() {
    setTrimRange(startSeconds: trimStartSeconds, endSeconds: trimEndSeconds)
  }

  func setFullRange() {
    timelineStore.setFullRange()
    applyTimelineStoreSnapshot()
  }

  func setCurrentMinuteRange() {
    timelineStore.setCurrentMinuteRange(currentSeconds: currentSeconds)
    applyTimelineStoreSnapshot()
  }

  func setRecentRange(minutes: Int) {
    timelineStore.setRecentRange(minutes: minutes)
    applyTimelineStoreSnapshot()
  }

  func setTrimStartAtPlayhead() {
    guard totalDuration > 0 else { return }
    let start = max(0, min(currentSeconds, totalDuration))
    let end = max(trimEndSeconds, start + (1.0 / 30.0))
    setTrimRange(startSeconds: start, endSeconds: end)
  }

  func setTrimEndAtPlayhead() {
    guard totalDuration > 0 else { return }
    let end = max(0, min(currentSeconds, totalDuration))
    let start = min(trimStartSeconds, max(0, end - (1.0 / 30.0)))
    setTrimRange(startSeconds: start, endSeconds: end)
  }

  func setTestExportRange(minutes: Int = 3) {
    timelineStore.setTestExportRange(minutes: minutes, currentSeconds: currentSeconds)
    applyTimelineStoreSnapshot()
  }

  func toggleExportCamera(_ camera: Camera, isEnabled: Bool) {
    if isEnabled {
      selectedExportCameras.insert(camera)
    } else {
      selectedExportCameras.remove(camera)
      if selectedExportCameras.isEmpty, let first = camerasDetected.first {
        selectedExportCameras.insert(first)
      }
    }
  }

  func setFocusedCamera(_ camera: Camera?) {
    focusedCamera = camera
    if camera != nil {
      previewLayoutMode = .focus
    }
  }

  func addCameraTrackCut(camera: Camera? = nil) {
    let selected = camera ?? focusedCamera ?? activePreviewCameras.first ?? camerasDetected.first
    guard let selected else { return }
    cameraTrack = cameraTrack.addingCut(seconds: currentSeconds, camera: selected)
    focusedCamera = selected
    previewLayoutMode = .focus
    debug("camera track cut \(selected.rawValue) at \(String(format: "%.1f", currentSeconds))s", category: "camera-track")
  }

  func clearCameraTrack() {
    cameraTrack = .empty
    debug("camera track cleared", category: "camera-track")
  }

  func cameraForTrack(at seconds: Double) -> Camera? {
    cameraTrack.camera(at: seconds)
  }

  func exportPreviewSample() {
    exportRange(previewOnly: true, queued: false)
  }

  func queueExportRange() {
    exportRange(previewOnly: false, queued: true)
  }

  func currentLayoutPresetData() throws -> Data {
    let preset = CustomLayoutPreset(
      name: "Tescam Layout",
      layoutRequest: layoutRequest,
      previewLayoutMode: previewLayoutMode,
      focusedCamera: focusedCamera,
      overlayOptions: exportOverlayOptions,
      cameraTrack: cameraTrack
    )
    return try CustomLayoutPresetCodec.encode(preset)
  }

  func applyLayoutPreset(data: Data) throws {
    let preset = try CustomLayoutPresetCodec.decode(data)
    layoutRequest = preset.layoutRequest
    previewLayoutMode = preset.previewLayoutMode
    focusedCamera = preset.focusedCamera
    exportOverlayOptions = preset.overlayOptions
    cameraTrack = preset.cameraTrack.normalized
    layoutPresetStatus = "Layout loaded"
  }

  func exportRange() {
    exportRange(previewOnly: false, queued: false)
  }

  private func exportRange(previewOnly: Bool, queued: Bool) {
    guard !clipSets.isEmpty else { return }
    guard queued || !exporter.isExporting else { return }
    normalizeRange()
    debug("export open save panel: \(selectedRangeDescription)", category: "export")

#if DEBUG
    let isAutomatedTest = ProcessInfo.processInfo.environment[DebugEnvironment.uiTestMode] != nil
    if isAutomatedTest, let debugOutputURL = debugOutputURL() {
      exportRange(to: debugOutputURL, previewOnly: previewOnly, queued: queued)
      return
    }
#endif

    #if os(macOS)
    PlatformFileAccess.presentSavePanel(
      nameFieldStringValue: defaultExportFilename(),
      allowedContentTypes: PlatformFileAccess.contentTypes(for: effectiveExportPreset),
      directoryURL: rootURL?.deletingLastPathComponent() ?? sourceURLs.first?.deletingLastPathComponent()
    ) { [weak self] url in
      self?.exportRange(to: url, previewOnly: previewOnly, queued: queued)
    }
    #else
    // On iPad, export to app scratch space, then offer share.
    let scratchDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tescam_export", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    let filename = previewOnly ? "preview_\(defaultExportFilename())" : defaultExportFilename()
    let outputURL = scratchDir.appendingPathComponent(filename)
    exportRange(to: outputURL, previewOnly: previewOnly, queued: queued)
    #endif
  }

  func cancelExport() {
    debug("export cancel requested", category: "export")
    exporter.cancelExport()
  }

  func revealLastExport() {
    #if os(macOS)
    exporter.revealOutput(for: exporter.exportHistory.first)
    #else
    if let url = exporter.exportHistory.first?.outputURL {
      PlatformFileAccess.shareFile(url)
    }
    #endif
  }

  func dismissExportStatus() {
    exporter.dismissStatus()
  }

  func beginTrimDrag() {
    timelineStore.setDragging(true)
    applyTimelineStoreSnapshot()
  }

  func updateTrimRange(startSeconds: Double, endSeconds: Double, snapToMinute: Bool = false) {
    setTrimRange(startSeconds: startSeconds, endSeconds: endSeconds, snapToMinute: snapToMinute)
  }

  func endTrimDrag(startSeconds: Double, endSeconds: Double) {
    timelineStore.setDragging(false)
    applyTimelineStoreSnapshot()
    setTrimRange(startSeconds: startSeconds, endSeconds: endSeconds, snapToMinute: true)
  }

  func updateTrimStart(from date: Date) {
    setTrimRange(
      startSeconds: globalSeconds(for: date),
      endSeconds: trimEndSeconds
    )
  }

  func updateTrimEnd(from date: Date) {
    setTrimRange(
      startSeconds: trimStartSeconds,
      endSeconds: globalSeconds(for: date)
    )
  }

  @discardableResult
  func applyTrimStartInput(_ text: String) -> Bool {
    guard let seconds = parseHMS(text) else { return false }
    setTrimRange(
      startSeconds: seconds,
      endSeconds: trimEndSeconds
    )
    return true
  }

  @discardableResult
  func applyTrimEndInput(_ text: String) -> Bool {
    guard let seconds = parseHMS(text) else { return false }
    setTrimRange(
      startSeconds: trimStartSeconds,
      endSeconds: seconds
    )
    return true
  }

  func beginSeek() {
    guard !isUserSeeking else { return }
    wasPlayingBeforeSeek = playback.isPlaying
    playback.pause()
    isUserSeeking = true
    debug("seek begin at \(String(format: "%.2f", currentSeconds))s", category: "seek")
  }

  func endSeek() {
    guard isUserSeeking else { return }
    isUserSeeking = false
    seekToGlobalTime(currentSeconds, exact: true)
    if wasPlayingBeforeSeek { playback.play() }
    debug("seek end at \(String(format: "%.2f", currentSeconds))s", category: "seek")
  }

  func liveSeek(to seconds: Double) {
    guard isUserSeeking else { return }
    seekToGlobalTime(seconds, exact: false)
  }

  func ingestDroppedURLs(_ urls: [URL]) {
    guard !exporter.isExporting else { return }
    debug("drop ingest: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))", category: "index")
    indexSources(urls)
  }

  var sourceSummary: String {
    guard !sourceURLs.isEmpty else { return "" }
    if sourceURLs.count == 1 {
      return sourceURLs[0].path
    }
    return "\(sourceURLs.count) inputs • \(sourceURLs[0].lastPathComponent) + \(sourceURLs.count - 1) more"
  }

  var canReloadSources: Bool {
    !sourceURLs.isEmpty && !isIndexing && !exporter.isExporting
  }

  var canExport: Bool {
    !clipSets.isEmpty && !exporter.isExporting
  }

  var eventReasonOptions: [String] {
    let reasons = Set(eventSummaries.map { $0.reasonTitle }.filter { !$0.isEmpty })
    return ["All"] + reasons.sorted()
  }

  var filteredEventSummaries: [TeslaCamEventSummary] {
    let query = eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let selectedReason = eventReasonFilter == "all" ? "" : eventReasonFilter.lowercased()
    let filtered = eventSummaries.filter { event in
      let matchesReason = selectedReason.isEmpty || event.reasonTitle.lowercased() == selectedReason
      guard matchesReason else { return false }
      guard !query.isEmpty else { return true }
      return event.locationTitle.lowercased().contains(query)
        || event.reasonTitle.lowercased().contains(query)
        || TeslaCamFormatters.timelineSameDay.string(from: event.timestamp).lowercased().contains(query)
    }

    switch eventSortMode {
    case .oldestFirst:
      return filtered.sorted { $0.timestamp < $1.timestamp }
    case .newestFirst:
      return filtered.sorted { $0.timestamp > $1.timestamp }
    case .location:
      return filtered.sorted {
        if $0.locationTitle == $1.locationTitle {
          return $0.timestamp < $1.timestamp
        }
        return $0.locationTitle.localizedCaseInsensitiveCompare($1.locationTitle) == .orderedAscending
      }
    }
  }

  var scanDateRangeSummary: String {
    guard let minDate, let maxDate else { return "Detecting date range" }
    return "\(formatShortDate(minDate)) – \(formatShortDate(maxDate))"
  }

  var scanDurationSummary: String {
    TelemetryProcessor.durationString(seconds: totalDuration)
  }

  var selectedSetsForExport: [ClipSet] {
    timelineStore.selectedSetsForExport
  }

  var totalMergedFileCount: Int {
    clipSets.reduce(0) { $0 + $1.files.count }
  }

  var duplicateSummaryText: String {
    var parts: [String] = []
    if duplicateSummary.duplicateFileCount > 0 {
      parts.append("\(duplicateSummary.duplicateFileCount) duplicate file\(duplicateSummary.duplicateFileCount == 1 ? "" : "s")")
    }
    if duplicateSummary.duplicateTimestampCount > 0 {
      parts.append("\(duplicateSummary.duplicateTimestampCount) timestamp collision\(duplicateSummary.duplicateTimestampCount == 1 ? "" : "s")")
    }
    if duplicateSummary.overlapMinuteCount > 0 {
      parts.append("\(duplicateSummary.overlapMinuteCount) overlap\(duplicateSummary.overlapMinuteCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: " • ")
  }

  var selectedRangeDescription: String {
    guard !clipSets.isEmpty else { return "No clips selected" }
    return "\(formatDateTime(trimStartDate))  ->  \(formatDateTime(trimEndDate))"
  }

  var partialSelectedSetCount: Int {
    let enabled = activeExportCameras
    guard !enabled.isEmpty else { return 0 }
    return selectedSetsForExport.reduce(into: 0) { result, set in
      let available = Set(set.files.keys).intersection(enabled)
      if available.count < enabled.count {
        result += 1
      }
    }
  }

  var trimStartDate: Date {
    timelineStore.trimStartDate
  }

  var trimEndDate: Date {
    timelineStore.trimEndDate
  }

  var selectedTrimDuration: Double {
    timelineStore.selectedTrimDuration
  }

  var exportWarningsPreview: [String] {
    var warnings: [String] = []
    if partialSelectedSetCount > 0 {
      warnings.append("\(partialSelectedSetCount) selected clip span(s) are missing one or more enabled cameras and will use black placeholders.")
    }
    if !hiddenExportCameraNames.isEmpty {
      warnings.append("Hidden cameras will export as black tiles: \(hiddenExportCameraNames.joined(separator: ", ")).")
    }
    return warnings
  }

  var hiddenExportCameraNames: [String] {
    camerasDetected.filter { !activeExportCameras.contains($0) }.map(\.displayName)
  }

  var activeExportCameras: Set<Camera> {
    let detected = Set(camerasDetected)
    let filtered = selectedExportCameras.intersection(detected)
    if !filtered.isEmpty {
      return filtered
    }
    return detected.isEmpty ? Set(Camera.allCases) : detected
  }

  var effectiveExportOverlayOptions: ExportOverlayOptions {
    var options = exportOverlayOptions
    if privacyMode {
      options.telemetryHUD = false
      options.routeMap = false
      options.privacyMask = true
      options.includeReport = false
    }
    return options
  }

  /// The codec the export will adopt from the source footage: the first
  /// readable camera's codec across the sets selected for export, preferring a
  /// concrete H.264/HEVC over `.other`, defaulting to `.hevc` when unknown.
  var dominantSourceCodec: VideoCodec {
    for set in selectedSetsForExport {
      if let codec = set.dominantCodec, codec == .hevc || codec == .h264 {
        return codec
      }
    }
    for set in clipSets {
      if let codec = set.dominantCodec, codec == .hevc || codec == .h264 {
        return codec
      }
    }
    return .hevc
  }

  /// Whether the export will composite + re-encode (vs. lossless passthrough
  /// mux).
  var exportWillReencode: Bool {
    effectiveExportPreset != .originalTracksMOV
  }

  /// Human-readable codec label for the active export mode.
  var exportCodecLabel: String {
    switch effectiveExportPreset {
    case .maxQualityH264:
      return "H.264"
    case .maxQualityHEVC, .fastHEVC, .socialShareHEVC, .proxyHEVC:
      return "H.265"
    case .editFriendlyProRes:
      return "ProRes"
    case .originalTracksMOV:
      return dominantSourceCodec.displayName
    }
  }

  /// Caption beneath the export cluster.
  var exportModeCaption: String {
    exportWillReencode
      ? "Grid export · \(exportCodecLabel)"
      : "Muxed · originals preserved"
  }

  var effectiveExportPreset: ExportPreset {
    resolvedExportPreset(
      requested: exportPreset,
      overlayOptions: effectiveExportOverlayOptions,
      cameraTrack: cameraTrack
    )
  }

  var activePreviewCameras: [Camera] {
    let ordered = camerasForCurrentLayout()
    switch previewLayoutMode {
    case .focus:
      if let focusedCamera, ordered.contains(focusedCamera) {
        return [focusedCamera]
      }
      return Array(ordered.prefix(1))
    case .frontRear:
      let pair = [.front, .back].filter { ordered.contains($0) }
      return pair.isEmpty ? Array(ordered.prefix(2)) : pair
    case .horizontal, .pictureInPicture, .grid:
      return ordered
    }
  }

  var gridPreviewCameras: [Camera] {
    camerasForCurrentLayout()
  }

  var currentPreviewNaturalSizes: [Camera: CGSize] {
    guard clipSets.indices.contains(currentIndex) else { return [:] }
    return clipSets[currentIndex].naturalSizes
  }

  var timelineStartOffsetForCurrentClip: Double {
    currentSegmentStartSeconds
  }

  func shutdownForTermination() {
    playback.stop()
    exporter.cancelExport()
    deactivateSecurityScopedAccess()
  }

  private func updateCurrentSeconds(localSeconds: Double) {
    guard !isUserSeeking else { return }
    let local = max(0, localSeconds)
    let global = min(totalDuration, currentSegmentStartSeconds + local)
    currentSeconds = global
    updateOverlayAndTelemetry(globalSeconds: global, clipIndex: currentSegmentClipIndex, localSeconds: local)
  }

  private func rebuildTimeline() {
    guard !clipSets.isEmpty else {
      timelineStore.clear()
      applyTimelineStoreSnapshot()
      currentSegmentStartSeconds = 0
      currentSegmentClipIndex = nil
      return
    }

    timelineStore.load(sets: clipSets, minDate: minDate, maxDate: maxDate)
    applyTimelineStoreSnapshot()
    debug("timeline rebuilt: duration=\(Int(totalDuration)) gaps=\(timelineGapRanges.count)", category: "timeline")
    currentSegmentStartSeconds = 0
    currentSegmentClipIndex = clipSets.isEmpty ? nil : 0
  }

  func rebuildTimelineForTesting() {
    rebuildTimeline()
  }

  private func applyTimelineStoreSnapshot() {
    clipSets = timelineStore.clipSets
    minDate = timelineStore.minDate
    maxDate = timelineStore.maxDate
    selectedStart = timelineStore.selectedStart
    selectedEnd = timelineStore.selectedEnd
    trimStartSeconds = timelineStore.trimStartSeconds
    trimEndSeconds = timelineStore.trimEndSeconds
    isDraggingTrim = timelineStore.isDraggingTrim
    totalDuration = timelineStore.totalDuration
    timelineGapRanges = timelineStore.gapRanges
  }

  private func setTrimRange(startSeconds: Double, endSeconds: Double, snapToMinute: Bool = false) {
    timelineStore.setTrimRange(startSeconds: startSeconds, endSeconds: endSeconds, snapToMinute: snapToMinute)
    applyTimelineStoreSnapshot()
  }

  private func date(forGlobalSeconds seconds: Double) -> Date {
    timelineStore.date(forGlobalSeconds: seconds)
  }

  private func globalSeconds(for date: Date) -> Double {
    timelineStore.globalSeconds(for: date)
  }

  private func clipStartOffset(at index: Int) -> Double {
    timelineStore.clipStartOffset(at: index)
  }

  private func activeClipIndex(at globalSeconds: Double) -> Int? {
    timelineStore.activeClipIndex(at: globalSeconds)
  }

  private func nearestClipIndex(to globalSeconds: Double) -> Int {
    timelineStore.nearestClipIndex(to: globalSeconds)
  }

  private func timelineSegment(at globalSeconds: Double) -> TimelinePlaybackSegment {
    timelineStore.playbackSegment(at: globalSeconds)
  }

  private func advanceToNextTimelineSegment() {
    guard totalDuration > 0 else { return }
    let epsilon = 1.0 / 30.0
    var nextStart = currentSegmentStartSeconds + playback.currentDuration + epsilon
    // Skip recording gaps during continuous playback: jump straight to the next
    // real segment instead of playing dead air in real time (a 30-minute gap
    // between events is otherwise 30 minutes of black screen). #22
    while let gap = timelineStore.currentGapRange(at: nextStart), gap.endSeconds > nextStart {
      nextStart = gap.endSeconds
    }
    guard nextStart < totalDuration else {
      currentSeconds = totalDuration
      updateOverlayAndTelemetry(
        globalSeconds: totalDuration,
        clipIndex: currentSegmentClipIndex,
        localSeconds: playback.currentDuration
      )
      return
    }
    seekToGlobalTime(nextStart, exact: true, autoplay: true)
  }

  private func seekToGlobalTime(_ time: Double, exact: Bool = true, autoplay: Bool = false) {
    guard !clipSets.isEmpty else { return }
    let upperBound = max(0, totalDuration - (1.0 / 30.0))
    let clamped = max(0, min(time, upperBound))
    let segment = timelineSegment(at: clamped)
    let segmentChanged = !segment.matchesLoadedSegment(
      clipIndex: currentSegmentClipIndex,
      startSeconds: currentSegmentStartSeconds,
      duration: playback.currentDuration
    )
    currentSegmentStartSeconds = segment.startSeconds
    currentSegmentClipIndex = segment.clipIndex
    let local = max(0, min(clamped - segment.startSeconds, segment.duration))

    if segmentChanged {
      if let clipIndex = segment.clipIndex {
        currentIndex = clipIndex
        playback.load(set: clipSets[clipIndex], startSeconds: local)
        if !exact {
          debug("seek live clip \(clipIndex) local=\(String(format: "%.2f", local))", category: "seek")
        } else {
          debug("seek exact clip \(clipIndex) local=\(String(format: "%.2f", local))", category: "seek")
        }
        if exact {
          loadTelemetry(for: clipSets[clipIndex])
        } else {
          clearTelemetry()
        }
      } else {
        currentIndex = nearestClipIndex(to: clamped)
        playback.loadGap(duration: segment.duration, startSeconds: local)
        debug("seek \(exact ? "exact" : "live") gap start=\(String(format: "%.2f", segment.startSeconds)) duration=\(String(format: "%.2f", segment.duration))", category: "seek")
        clearTelemetry()
      }
    } else {
      if let clipIndex = segment.clipIndex {
        currentIndex = clipIndex
        if exact, telemetryURL != clipSets[clipIndex].file(for: .front) ?? clipSets[clipIndex].file(for: .back) ?? clipSets[clipIndex].files.values.first {
          loadTelemetry(for: clipSets[clipIndex])
        }
      } else {
        currentIndex = nearestClipIndex(to: clamped)
        if exact {
          clearTelemetry()
        }
      }
      playback.seek(to: local, exact: exact)
    }

    currentSeconds = clamped
    updateOverlayAndTelemetry(globalSeconds: clamped, clipIndex: segment.clipIndex, localSeconds: local)

    if autoplay {
      playback.play()
    }
  }

  private func clearTelemetry() {
    telemetryTimeline = nil
    telemetryURL = nil
    telemetryModel = nil
    telemetryRoute = []
    telemetryEventMarkers = []
    telemetryText = ""
    telemetryAvailability = .unknown
  }

  private func loadTelemetry(for set: ClipSet?) {
    let url = set?.file(for: .front) ?? set?.file(for: .back) ?? set?.files.values.first
    telemetryTimeline = nil
    telemetryModel = nil
    telemetryRoute = url.flatMap { telemetryRouteByURL[$0] } ?? []
    telemetryEventMarkers = []
    telemetryURL = url
    telemetryText = ""
    telemetryAvailability = .unknown
    guard let fileURL = url else { return }
    debug("telemetry load \(fileURL.lastPathComponent)", category: "telemetry")
    DispatchQueue.global(qos: .utility).async {
      let timeline = try? TelemetryParser.parseTimeline(url: fileURL)
      let route = timeline.map { TelemetryProcessor.routePoints(from: $0) } ?? []
      let markers = timeline.map { TelemetryEventMarker.markers(from: $0) } ?? []
      DispatchQueue.main.async {
        guard self.telemetryURL == fileURL else { return }
        self.telemetryTimeline = timeline
        self.telemetryRouteByURL[fileURL] = route
        self.telemetryRoute = route
        self.telemetryEventMarkers = markers
        self.telemetryAvailability = route.isEmpty ? .unavailable : .available
        self.debug(
          timeline == nil ? "telemetry unavailable for \(fileURL.lastPathComponent)" : "telemetry ready for \(fileURL.lastPathComponent)",
          category: "telemetry"
        )
        let local = max(0, self.currentSeconds - self.currentSegmentStartSeconds)
        self.updateOverlayAndTelemetry(
          globalSeconds: self.currentSeconds,
          clipIndex: self.currentSegmentClipIndex,
          localSeconds: local
        )
      }
    }
  }

  private func updateOverlayAndTelemetry(globalSeconds: Double, clipIndex: Int?, localSeconds: Double) {
    overlayText = TeslaCamFormatters.fullDateTime.string(from: date(forGlobalSeconds: globalSeconds))
    currentEvent = eventSummaries.last { event in
      clipStartOffset(at: event.clipIndex) <= globalSeconds + 0.5
    }
    guard clipIndex != nil, let timeline = telemetryTimeline else {
      telemetryModel = nil
      telemetryText = ""
      return
    }
    let safeLocal = max(0, localSeconds)
    if let trackCamera = cameraForTrack(at: globalSeconds), camerasDetected.contains(trackCamera) {
      focusedCamera = trackCamera
      previewLayoutMode = .focus
    }
    let frame = timeline.closest(to: safeLocal * 1000.0)
    telemetryModel = frame.map { TelemetryDisplayModel(sei: $0.sei) }
    telemetryText = privacyMode ? "" : formatTelemetry(frame?.sei)
  }

  private func expectedCoverageCameras(for set: ClipSet) -> Set<Camera> {
    TelemetryProcessor.expectedCoverageCameras(for: set, layoutProfile: layoutProfile)
  }

  private func formatTelemetry(_ sei: SeiMetadata?) -> String {
    TelemetryProcessor.formatTelemetryDetailed(sei, unit: exportOverlayOptions.speedUnit)
  }

  private func orderCameras(_ cams: [Camera], profile: CameraLayoutProfile) -> [Camera] {
    let ordered = profile.orderedCameras.filter { cams.contains($0) }
    let leftovers = cams.filter { !ordered.contains($0) }
    return ordered + leftovers
  }

  private func normalizeSources(_ urls: [URL]) -> [URL] {
    sourceStore.normalize(urls)
  }

  private func rememberLastSources(_ urls: [URL]) {
    sourceStore.rememberBookmarks(for: urls)
  }

  @discardableResult
  private func restoreLastSourcesIfPossible() -> Bool {
    let restored = sourceStore.restoreBookmarkedURLs()
    guard !restored.isEmpty else { return false }
    indexSources(restored, surfaceErrors: false)
    return true
  }

  private func activateSecurityScopedAccess(for urls: [URL]) {
    sourceStore.activateSecurityScope(for: urls)
  }

  private func deactivateSecurityScopedAccess() {
    sourceStore.deactivateSecurityScope()
  }

  private func defaultExportFilename() -> String {
    exportStore.defaultFilename(
      sets: clipSets,
      preset: effectiveExportPreset,
      trimStartDate: trimStartDate,
      trimEndDate: trimEndDate
    )
  }

  private func resolvedExportPreset(
    requested preset: ExportPreset,
    overlayOptions: ExportOverlayOptions,
    cameraTrack: CameraTrack
  ) -> ExportPreset {
    guard preset == .originalTracksMOV else { return preset }
    if overlayOptions.telemetryHUD
      || overlayOptions.routeMap
      || overlayOptions.privacyMask
      || overlayOptions.needsSidecars
      || !cameraTrack.isEmpty {
      return .maxQualityHEVC
    }
    return preset
  }

  private func exportRange(to chosenURL: URL, previewOnly: Bool, queued: Bool) {
    guard let request = makeExportRequest(for: chosenURL, previewOnly: previewOnly) else {
      errorMessage = "No clips found in the selected range."
      showError = true
      return
    }
    let preflight = exporter.preflightSummary(request: request)
    if !preflight.canExport {
      exporter.export(request: request)
      return
    }
    debug("export request: preset=\(request.preset.rawValue) cameras=\(request.enabledCameras.map { $0.rawValue }.sorted().joined(separator: ",")) duration=\(String(format: "%.2f", request.totalDuration))", category: "export")
    if queued {
      exporter.enqueue(request: request)
    } else {
      exporter.export(request: request)
    }
  }

  private func debug(_ message: String, category: String = "app") {
    debugLog.record(message, category: category)
  }

  private func buildOutputURL(from chosenURL: URL) -> URL {
    exportStore.resolvedOutputURL(
      chosenURL: chosenURL,
      preferredFilename: defaultExportFilename(),
      preset: effectiveExportPreset
    )
  }

  func resolvedExportURL(forTesting chosenURL: URL) -> URL {
    buildOutputURL(from: chosenURL)
  }

  private func firstAvailableOutputURL(in directory: URL, preferredFilename: String) -> URL {
    exportStore.resolvedOutputURL(
      chosenURL: directory,
      preferredFilename: preferredFilename,
      preset: effectiveExportPreset
    )
  }

  private func uniqueAvailableOutputURL(for preferredURL: URL) -> URL {
    exportStore.resolvedOutputURL(
      chosenURL: preferredURL,
      preferredFilename: preferredURL.lastPathComponent,
      preset: effectiveExportPreset
    )
  }

  private func makeExportRequest(for chosenURL: URL, previewOnly: Bool = false) -> ExportRequest? {
    let sets = selectedSetsForExport
    let startDate = trimStartDate
    let overlayOptions = effectiveExportOverlayOptions
    let preset = effectiveExportPreset
    let endDate: Date
    let endSeconds: Double
    let rangeText: String
    if previewOnly {
      let duration = min(10, max(0.1, trimEndDate.timeIntervalSince(trimStartDate)))
      endDate = trimStartDate.addingTimeInterval(duration)
      endSeconds = min(trimEndSeconds, trimStartSeconds + duration)
      rangeText = "Preview sample \(Int(duration.rounded()))s"
    } else {
      endDate = trimEndDate
      endSeconds = trimEndSeconds
      rangeText = selectedRangeDescription
    }
    return exportStore.makeRequest(
      sets: sets,
      chosenURL: chosenURL,
      preset: preset,
      enabledCameras: activeExportCameras,
      layoutRequest: layoutRequest,
      overlayOptions: overlayOptions,
      trimStartSeconds: trimStartSeconds,
      trimEndSeconds: endSeconds,
      trimStartDate: startDate,
      trimEndDate: endDate,
      selectedRangeText: rangeText,
      partialClipCount: partialSelectedSetCount,
      cameraTrack: cameraTrack,
      isPreviewSample: previewOnly
    )
  }

  func setExportPreset(_ preset: ExportPreset) {
    exportPreset = preset
    switch preset {
    case .originalTracksMOV:
      exportOverlayOptions.telemetryHUD = false
      exportOverlayOptions.routeMap = false
      exportOverlayOptions.includeReport = false
      exportOverlayOptions.includeScreenshot = false
    case .maxQualityHEVC, .maxQualityH264, .fastHEVC, .socialShareHEVC, .proxyHEVC, .editFriendlyProRes:
      break
    }
  }

  private func buildHealthSummary(from sets: [ClipSet]) -> ExportHealthSummary {
    TelemetryProcessor.buildHealthSummary(from: sets, layoutProfile: layoutProfile)
  }

  private func buildClipHealthFacts(from sets: [ClipSet]) -> [ClipHealthFact] {
    TelemetryProcessor.buildClipHealthFacts(from: sets, layoutProfile: layoutProfile)
  }

  private func buildEventSummaries(from sets: [ClipSet]) -> [TeslaCamEventSummary] {
    TelemetryProcessor.buildEventSummaries(from: sets)
  }

  private func camerasForCurrentLayout() -> [Camera] {
    let detected = Set(camerasDetected)
    let plan = CameraLayoutPlan.build(
      requestedProfile: layoutRequest,
      detectedCameras: detected,
      enabledCameras: activeExportCameras,
      naturalSizes: [:]
    )
    let ordered = plan.renderOrder.filter { detected.contains($0) }
    return ordered.isEmpty ? camerasDetected : ordered
  }

  private func presentDuplicateResolverIfNeeded(for index: ClipIndex) {
    presentDuplicateResolverIfNeeded(summary: index.duplicateSummary)
  }

  private func presentDuplicateResolverIfNeeded(summary: DuplicateResolutionSummary) {
    duplicatePolicy = .mergeByTime
    duplicateResolverMessage = ""
    isDuplicateResolverPresented = false
  }

  #if DEBUG
  func presentDuplicateResolverIfNeededForTesting(summary: DuplicateResolutionSummary) {
    presentDuplicateResolverIfNeeded(summary: summary)
  }
  #endif

  #if DEBUG
  private func applyDebugLaunchModeIfNeeded() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    let arguments = ProcessInfo.processInfo.arguments

    if let mode = debugLaunchMode(environment: environment, arguments: arguments)?.lowercased() {
      switch mode {
      case "blank":
        return true
      case "sample":
        loadDemoTimeline()
        return true
      default:
        break
      }
    }

    if environment[DebugEnvironment.xCTestConfiguration] != nil {
      return true
    }

    guard let raw = environment[DebugEnvironment.source], !raw.isEmpty else {
      return false
    }

    let urls = raw
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0)) }
    guard !urls.isEmpty else { return false }
    indexSources(urls)
    return true
  }

  private func debugLaunchMode(environment: [String: String], arguments: [String]) -> String? {
    if let mode = environment[DebugEnvironment.uiTestMode], !mode.isEmpty {
      return mode
    }

    if let index = arguments.firstIndex(of: "--teslacam-ui-test-mode"),
       arguments.indices.contains(arguments.index(after: index)) {
      return arguments[arguments.index(after: index)]
    }

    let prefix = "--teslacam-ui-test-mode="
    if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
      return String(argument.dropFirst(prefix.count))
    }

    return nil
  }

  private func debugOutputURL() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    guard environment[DebugEnvironment.uiTestMode] != nil else {
      return nil
    }
    let fileManager = FileManager.default
    let fallbackDirectory = fileManager.temporaryDirectory

    if let raw = environment[DebugEnvironment.exportDirectory], !raw.isEmpty {
      let candidate = URL(fileURLWithPath: raw, isDirectory: true)
      if ensureWritableDirectory(candidate, fileManager: fileManager) {
        return firstAvailableOutputURL(in: candidate, preferredFilename: defaultExportFilename())
      }
    }

    return firstAvailableOutputURL(in: fallbackDirectory, preferredFilename: defaultExportFilename())
  }

  private func ensureWritableDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
      return false
    }
    let probeURL = directory.appendingPathComponent(".teslacam-ui-test-\(UUID().uuidString)")
    let created = fileManager.createFile(atPath: probeURL.path, contents: Data())
    if created {
      try? fileManager.removeItem(at: probeURL)
    }
    return created
  }
  #endif

  #if os(macOS)
  private func presentOpenPanel(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
    PlatformFileAccess.presentOpenPanel(panel, completion: completion)
  }

  private func presentSavePanel(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        completion(url)
      }
      return
    }

    if panel.runModal() == .OK, let url = panel.url {
      completion(url)
    }
  }
  #endif

  private func loadSampleTimeline() {
    let base = Date()
    let sampleSets = [
      ClipSet(timestamp: "sample_1", date: base, duration: 10, files: [:]),
      ClipSet(timestamp: "sample_2", date: base.addingTimeInterval(60), duration: 10, files: [:]),
      ClipSet(timestamp: "sample_3", date: base.addingTimeInterval(120), duration: 10, files: [:])
    ]
    sourceURLs = []
    clipSets = sampleSets
    minDate = sampleSets.first?.date
    maxDate = sampleSets.last?.endDate
    layoutProfile = .hw4SixCam
    camerasDetected = [.front, .back, .left, .right, .left_pillar, .right_pillar]
    selectedExportCameras = Set(camerasDetected)
    eventSummaries = demoEventSummaries(for: sampleSets)
    clipHealthFacts = buildClipHealthFacts(from: sampleSets)
    duplicateSummary = DuplicateResolutionSummary(
      duplicateFileCount: 0,
      duplicateTimestampCount: 0,
      overlapMinuteCount: 0
    )
    currentEvent = eventSummaries.first
    eventSearchText = ""
    eventReasonFilter = "all"
    layoutPresetStatus = ""
    cameraTrack = .empty
    currentIndex = 0
    overlayText = formatDateTime(base)
    rebuildTimeline()
    setTrimRange(startSeconds: 0, endSeconds: totalDuration, snapToMinute: true)
    currentSeconds = 0
    seekToGlobalTime(0, exact: true)
    applyDemoTelemetry(for: sampleSets)
  }

  private func demoEventSummaries(for sets: [ClipSet]) -> [TeslaCamEventSummary] {
    let coordinates = demoCoordinates
    return sets.enumerated().map { index, set in
      TeslaCamEventSummary(
        id: "demo-\(index)",
        clipIndex: index,
        timestamp: set.date,
        folderURL: nil,
        thumbnailURL: nil,
        city: "Demo",
        street: "Sample route",
        reason: index == 1 ? "sentry" : "drive",
        camera: Camera.front.rawValue,
        coordinate: coordinates[index % coordinates.count]
      )
    }
  }

  private func applyDemoTelemetry(for sets: [ClipSet]) {
    telemetryTimeline = demoTelemetryTimeline()
    telemetryURL = nil
    telemetryRoute = demoTelemetryRoute(for: sets)
    telemetryEventMarkers = demoTelemetryEventMarkers()
    updateOverlayAndTelemetry(globalSeconds: 0, clipIndex: 0, localSeconds: 0)
  }

  private func demoTelemetryTimeline() -> TelemetryTimeline {
    TelemetryTimeline(frames: [
      TelemetryFrame(timestampMs: 0, sei: demoTelemetryMetadata())
    ])
  }

  private func demoTelemetryMetadata() -> SeiMetadata {
    var metadata = SeiMetadata()
    metadata.gearState = .drive
    metadata.vehicleSpeedMps = 13.4
    metadata.acceleratorPedalPosition = 18
    metadata.steeringWheelAngle = -4
    metadata.autopilotState = .tacc
    metadata.latitudeDeg = demoCoordinates[0].latitude
    metadata.longitudeDeg = demoCoordinates[0].longitude
    metadata.headingDeg = 272
    return metadata
  }

  private func demoTelemetryRoute(for sets: [ClipSet]) -> [TelemetryRoutePoint] {
    let coordinates = demoCoordinates
    return sets.enumerated().map { index, set in
      TelemetryRoutePoint(
        id: index,
        seconds: max(0, set.date.timeIntervalSince(sets.first?.date ?? set.date)),
        coordinate: coordinates[index % coordinates.count],
        speedKmh: [48, 52, 41][index % 3],
        headingDeg: [272, 279, 285][index % 3]
      )
    }
  }

  private func demoTelemetryEventMarkers() -> [TelemetryEventMarker] {
    [
      TelemetryEventMarker(seconds: 12, kind: .accelerator, intensity: 0.52),
      TelemetryEventMarker(seconds: 66, kind: .autopilot, intensity: 1),
      TelemetryEventMarker(seconds: 126, kind: .brake, intensity: 0.8)
    ]
  }

  private var demoCoordinates: [TelemetryCoordinate] {
    [
      TelemetryCoordinate(latitude: 51.50740, longitude: -0.12780),
      TelemetryCoordinate(latitude: 51.50795, longitude: -0.13210),
      TelemetryCoordinate(latitude: 51.50860, longitude: -0.13620)
    ]
  }

}
