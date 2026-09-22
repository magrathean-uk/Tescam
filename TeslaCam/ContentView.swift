import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
  @EnvironmentObject var state: AppState
  @State private var isDropTarget = false
  #if os(iOS)
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  #endif

  var body: some View {
    platformContent
      .preferredTeslaCamColorScheme()
      #if os(iOS)
      // Hide the status bar only in landscape (no room / no Dynamic Island reserve
      // needed there). In portrait, keep it visible so the system reserves the
      // Dynamic Island region and content is inset below it.
      .statusBarHidden(verticalSizeClass == .compact)
      #endif
      .onAppear {
        state.onAppear()
        #if DEBUG && os(iOS)
        applyScreenshotSceneIfNeeded()
        #endif
      }
      .alert("Error", isPresented: $state.showError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(state.errorMessage)
      }
      .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleFileDrop(providers:))
      .onOpenURL { url in
        state.indexSources([url])
      }
      #if os(iOS)
      .fileImporter(
        isPresented: $state.isFileImporterPresented,
        allowedContentTypes: [.folder],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          state.indexSources(urls)
        case .failure(let error):
          let nsError = error as NSError
          guard nsError.code != NSUserCancelledError else { return }
          state.errorMessage = "Couldn't open the selected folder. Pick the TeslaCam folder again from Files."
          state.showError = true
        }
      }
      #endif
  }

  @ViewBuilder
  private var platformContent: some View {
#if os(iOS)
    IOSContentView(state: state)
#else
    MacContentView(state: state)
#endif
  }

  private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
    guard !state.exporter.isExporting else { return false }
    let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    guard !fileProviders.isEmpty else { return false }

    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []

    for provider in fileProviders {
      group.enter()
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
        defer { group.leave() }
        guard let data,
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              url.isFileURL else { return }
        lock.lock()
        urls.append(url)
        lock.unlock()
      }
    }

    group.notify(queue: .main) {
      guard !urls.isEmpty else { return }
      state.ingestDroppedURLs(urls)
    }
    return true
  }

  #if DEBUG && os(iOS)
  private func applyScreenshotSceneIfNeeded() {
    guard let scene = ProcessInfo.processInfo.environment["TESLACAM_SCREENSHOT_SCENE"] else { return }
    switch scene {
    case "02-playback":
      state.togglePlay()
    case "03-cameras":
      state.setFocusedCamera(.front)
    case "04-timeline":
      state.setRecentRange(minutes: 5)
    case "05-export":
      state.exportOverlayOptions.telemetryHUD = true
    default:
      break
    }
  }
  #endif
}

#if os(macOS)
private struct MacContentView: View {
  @ObservedObject var state: AppState

  var body: some View {
    ZStack {
      TeslaCamSceneBackground()

      Group {
        if state.isIndexing {
          IndexingScreen(state: state)
        } else if state.clipSets.isEmpty {
          OnboardingScreen(state: state)
        } else {
          loadedScreen
        }
      }
      .disabled(state.exporter.isExporting)

      if let job = state.exporter.currentJob, state.exporter.isExporting || state.exporter.isStatusPresented {
        ExportOverlayCard(state: state, job: job)
      }
    }
    .frame(minWidth: 1100, minHeight: 760)
  }

  private var loadedScreen: some View {
    GeometryReader { proxy in
      MacLoadedWorkspace(
        state: state,
        playback: state.playback,
        playbackUI: state.playbackUI,
        timelineMarkers: timelineMarkers,
        isSingleDayTimeline: isSingleDayTimeline,
        loadedContentMaxWidth: loadedContentMaxWidth,
        maxPreviewHeight: loadedPreviewMaxHeight(for: proxy.size.height)
      )
    }
    .accessibilityIdentifier("loaded-screen")
  }

  private var timelineMarkers: [Date] {
    guard let min = state.minDate, let max = state.maxDate else { return [] }
    let interval = max.timeIntervalSince(min)
    guard interval > 0 else { return [] }
    return [0.2, 0.4, 0.6, 0.8].map { fraction in
      min.addingTimeInterval(interval * fraction)
    }
  }

  private var isSingleDayTimeline: Bool {
    guard let min = state.minDate, let max = state.maxDate else { return true }
    return Calendar.current.isDate(min, inSameDayAs: max)
  }

  private var loadedContentMaxWidth: CGFloat {
    switch state.camerasDetected.count {
    case 0...4:
      return 860
    case 5...6:
      return 1080
    default:
      return 1320
    }
  }

  private func loadedPreviewMaxHeight(for totalHeight: CGFloat) -> CGFloat {
    // Keep the controls reachable without scrolling.
    let reserved: CGFloat = 236
    return max(240, totalHeight - reserved)
  }
}
#endif

#if os(iOS)
private struct GridPanel<Content: View>: View {
  var role: SurfaceRole = .panel
  var padding: CGFloat = TeslaCamTheme.Metrics.cardPaddingCompact
  var radius: CGFloat = TeslaCamTheme.Metrics.cardCorner
  @ViewBuilder var content: () -> Content

  var body: some View {
    GlassEffectGroup(spacing: TeslaCamTheme.Spacing.m) {
      content()
        .padding(padding)
        .glassSurface(role: role, radius: radius)
    }
  }
}

private struct PanelHeader: View {
  let title: String
  var systemImage: String? = nil

  var body: some View {
    HStack(spacing: TeslaCamTheme.Spacing.s) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
      }
      Text(title.uppercased())
        .font(TeslaCamTheme.Typography.label)
        .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
      Spacer(minLength: 0)
    }
  }
}

private struct MetricTile: View {
  let title: String
  let value: String
  var warning: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.xs) {
      Text(title.uppercased())
        .font(TeslaCamTheme.Typography.label)
        .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
      Text(value)
        .font(TeslaCamTheme.Typography.metricValue)
        .foregroundStyle(warning ? TeslaCamTheme.Colors.gapAccent : TeslaCamTheme.Colors.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(TeslaCamTheme.Spacing.m)
    .glassSurface(role: warning ? .selected : .control, radius: TeslaCamTheme.Metrics.compactCorner)
  }
}

private struct CommandChip: View {
  let title: String
  var systemImage: String? = nil
  var role: SurfaceRole = .control
  var disabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
    .compactButtonStyle(role: role, size: .command)
    .disabled(disabled)
  }
}

private struct IOSContentView: View {
  @ObservedObject var state: AppState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    GeometryReader { proxy in
      // `proxy` (no ignoresSafeArea) is already the usable, island-free size — hand
      // it straight to the workspace and let the scene background bleed behind via
      // `.background()`'s own ignoresSafeArea. `isWide` picks the split-column vs
      // vertical layout; it's a pure layout decision, not a safe-area hack.
      let isWide = horizontalSizeClass == .regular || proxy.size.width > proxy.size.height
      Group {
        if state.isIndexing {
          IndexingScreen(state: state)
        } else if state.clipSets.isEmpty {
          OnboardingScreen(state: state)
        } else {
          IOSWorkspace(
            state: state,
            playback: state.playback,
            playbackUI: state.playbackUI,
            size: proxy.size,
            isWide: isWide,
            horizontalSizeClass: horizontalSizeClass
          )
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .disabled(state.exporter.isExporting)
      .overlay {
        if let job = state.exporter.currentJob, state.exporter.isExporting || state.exporter.isStatusPresented {
          ExportOverlayCard(state: state, job: job)
        }
      }
    }
    .background(TeslaCamSceneBackground())
  }
}

/// The single adaptive iOS/iPadOS workspace over the shared core. In a compact
/// (portrait) width it's a vertical scroll of Teslatlas-styled sections with the
/// export CTA pinned above the home indicator; in a wide (landscape / iPad) width
/// it splits into a filling player on the left and a scrollable control column on
/// the right. Safe areas are handled by the parent and standard containers — no
/// manual inset math lives here.
private struct IOSWorkspace: View {
  @ObservedObject var state: AppState
  @ObservedObject var playback: MultiCamPlaybackController
  @ObservedObject var playbackUI: PlaybackUIState
  let size: CGSize
  let isWide: Bool
  let horizontalSizeClass: UserInterfaceSizeClass?

  @State private var trimStartInput = ""
  @State private var trimEndInput = ""
  @FocusState private var focusedTrimField: TrimField?
  @State private var lastFocusedTrimField: TrimField?

  var body: some View {
    Group {
      if isWide {
        wideBody
      } else {
        compactBody
      }
    }
    .accessibilityIdentifier("loaded-screen")
    .onAppear(perform: syncTrimInputs)
    .onChange(of: state.trimStartSeconds) {
      guard focusedTrimField != .start else { return }
      trimStartInput = formatHMS(state.trimStartSeconds)
    }
    .onChange(of: state.trimEndSeconds) {
      guard focusedTrimField != .end else { return }
      trimEndInput = formatHMS(state.trimEndSeconds)
    }
    .onChange(of: focusedTrimField) {
      let newValue = focusedTrimField
      if lastFocusedTrimField == .start, newValue != .start { commitTrimStartInput() }
      if lastFocusedTrimField == .end, newValue != .end { commitTrimEndInput() }
      lastFocusedTrimField = newValue
    }
  }

  // MARK: Compact (portrait) layout

  private var compactBody: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.l) {
          TeslaCamPageHeader(title: "Tescam", subtitle: headerSubtitle, subtitleSystemImage: "car.fill")
            .id("screenshot-overview")
            .teslaCamReveal(index: 0, trigger: revealTrigger)

          PreviewPanelCard(
            state: state,
            playbackUI: playbackUI,
            maxAvailableHeight: playerHeight,
            usesCompactPhonePreview: true,
            fixedHeight: playerHeight
          )
          .id("screenshot-playback")
          .teslaCamReveal(index: 1, trigger: revealTrigger)

          transportSection.teslaCamReveal(index: 2, trigger: revealTrigger)
          scrubberSection
            .id("screenshot-timeline")
            .teslaCamReveal(index: 3, trigger: revealTrigger)
          rangeSection.teslaCamReveal(index: 4, trigger: revealTrigger)
          cameraSection
            .id("screenshot-cameras")
            .teslaCamReveal(index: 5, trigger: revealTrigger)
          exportSection
            .id("screenshot-export")
            .teslaCamReveal(index: 6, trigger: revealTrigger)
        }
        .frame(maxWidth: contentColumnWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, pagePadding)
        .padding(.top, TeslaCamTheme.Spacing.s)
      }
      .scrollIndicators(.hidden)
      .scrollDismissesKeyboard(.interactively)
      .onAppear {
        #if DEBUG
        guard let scene = ProcessInfo.processInfo.environment["TESLACAM_SCREENSHOT_SCENE"] else { return }
        let anchor = scene.replacingOccurrences(of: #"^\d{2}-"#, with: "", options: .regularExpression)
        DispatchQueue.main.async {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            proxy.scrollTo("screenshot-\(anchor)", anchor: .top)
          }
        }
        #endif
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { exportCTABar }
    }
  }

  // MARK: Wide (landscape / iPad) layout

  private var wideBody: some View {
    HStack(alignment: .top, spacing: TeslaCamTheme.Spacing.m) {
      // Left: the player alone fills the whole column — the biggest possible
      // cameras. All the controls live in the column on the right.
      PreviewPanelCard(
        state: state,
        playbackUI: playbackUI,
        maxAvailableHeight: 0,
        fillsContainer: true
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Right: transport pinned at the top (always reachable), then the scrollable
      // controls, then the export CTA pinned at the base — no dead space.
      VStack(spacing: TeslaCamTheme.Spacing.s) {
        transportSection

        ScrollView {
          VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.m) {
            scrubberSection
            rangeSection
            cameraSection
            exportSection
          }
          .padding(.bottom, TeslaCamTheme.Spacing.s)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)

        wideExportButton
      }
      .frame(width: controlColumnWidth)
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .padding(.horizontal, pagePadding)
    .padding(.top, TeslaCamTheme.Spacing.s)
    .padding(.bottom, TeslaCamTheme.Spacing.s)
  }

  private var wideExportButton: some View {
    VStack(spacing: TeslaCamTheme.Spacing.s) {
      Rectangle()
        .fill(TeslaCamTheme.Colors.stroke)
        .frame(height: 1)
      Button {
        state.exportRange()
      } label: {
        Label(exportButtonTitle, systemImage: "square.and.arrow.up")
      }
      .buttonStyle(TeslaCamCTAButtonStyle())
      .disabled(state.clipSets.isEmpty || state.exporter.isExporting)
      .accessibilityIdentifier("export-video")
    }
    .padding(.top, TeslaCamTheme.Spacing.s)
  }

  // MARK: Sections

  private var transportSection: some View {
    HStack(spacing: 0) {
      // Balance the row so the transport cluster is optically centered while the
      // rate chip sits on the trailing edge.
      Color.clear.frame(width: 56, height: 1)
      Spacer(minLength: 0)
      HStack(spacing: TeslaCamTheme.Spacing.xl) {
        transportButton("gobackward.5", label: "Back 5 seconds", id: "step-back-5") { state.stepPlayback(by: -5) }
        transportButton(
          playback.isPlaying ? "pause.fill" : "play.fill",
          label: playback.isPlaying ? "Pause" : "Play",
          id: "toggle-playback",
          prominent: true
        ) { state.togglePlay() }
        transportButton("goforward.5", label: "Forward 5 seconds", id: "step-forward-5") { state.stepPlayback(by: 5) }
      }
      Spacer(minLength: 0)
      rateChip
    }
    .padding(.vertical, TeslaCamTheme.Spacing.xs)
  }

  private var scrubberSection: some View {
    TeslaCamSectionCard(title: "Timeline", systemImage: "timeline.selection") {
      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.s) {
        HStack {
          Text(formatHMS(playbackUI.currentSeconds))
            .font(TeslaCamTheme.Typography.numericLarge)
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
          Spacer()
          Text(formatHMS(state.totalDuration))
            .font(TeslaCamTheme.Typography.numericBody)
            .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
        }

        TimelineSelectionTrack(
          currentSeconds: playbackSecondsBinding,
          selectedStartSeconds: $state.trimStartSeconds,
          selectedEndSeconds: $state.trimEndSeconds,
          gapRanges: state.timelineGapRanges,
          totalDuration: max(state.totalDuration, 1),
          onSeekStart: { state.beginSeek() },
          onSeekChange: { state.liveSeek(to: $0) },
          onSeekEnd: { state.endSeek() },
          onDragStart: { state.beginTrimDrag() },
          onDragChange: { start, end in state.updateTrimRange(startSeconds: start, endSeconds: end) },
          onDragEnd: { start, end in state.endTrimDrag(startSeconds: start, endSeconds: end) }
        )
        .frame(height: 44)
      }
    }
  }

  private var rangeSection: some View {
    TeslaCamSectionCard(title: "Export range", systemImage: "scissors") {
      VStack(spacing: TeslaCamTheme.Spacing.s) {
        HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
          rangeButton("All", "arrow.left.and.right", id: "range-whole-timeline") { state.setFullRange() }
          rangeButton("1m", "clock", id: "range-current-minute") { state.setCurrentMinuteRange() }
          rangeButton("5m", "clock.arrow.circlepath", id: "range-last-5m") { state.setRecentRange(minutes: 5) }
          rangeButton("15m", "clock.badge", id: "range-last-15m") { state.setRecentRange(minutes: 15) }
        }
        HStack(spacing: TeslaCamTheme.Spacing.s) {
          trimField("In", text: $trimStartInput, field: .start)
          Button("At playhead") { state.setTrimStartAtPlayhead() }
            .buttonStyle(QuickActionButtonStyle())
            .disabled(state.clipSets.isEmpty)
            .accessibilityLabel("Set export start to playhead")
            .accessibilityIdentifier("set-trim-start-at-playhead")
        }
        HStack(spacing: TeslaCamTheme.Spacing.s) {
          trimField("Out", text: $trimEndInput, field: .end)
          Button("At playhead") { state.setTrimEndAtPlayhead() }
            .buttonStyle(QuickActionButtonStyle())
            .disabled(state.clipSets.isEmpty)
            .accessibilityLabel("Set export end to playhead")
            .accessibilityIdentifier("set-trim-end-at-playhead")
        }
      }
    }
  }

  private var cameraSection: some View {
    TeslaCamSectionCard(title: "Cameras", systemImage: "camera") {
      MacCameraToggleGrid(state: state)
    }
  }

  private var exportSection: some View {
    TeslaCamSectionCard(title: "Export", systemImage: "square.and.arrow.up") {
      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.m) {
        HStack(spacing: TeslaCamTheme.Spacing.s) {
          Text("CODEC")
            .font(TeslaCamTheme.Typography.label)
            .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
            .tracking(0.6)
          Spacer(minLength: TeslaCamTheme.Spacing.s)
          TeslaCamPillPicker(
            options: [
              TeslaCamPillOption(ExportPreset.maxQualityHEVC, "H.265"),
              TeslaCamPillOption(ExportPreset.maxQualityH264, "H.264")
            ],
            selection: exportPresetBinding,
            accessibilityLabel: "Export codec"
          )
          .frame(width: 168)
          .accessibilityIdentifier("export-codec-picker")
        }

        Toggle(isOn: $state.exportOverlayOptions.telemetryHUD) {
          Text("Engrave telemetry")
            .font(TeslaCamTheme.Typography.bodySmall)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        }
        .toggleStyle(.switch)
        .tint(TeslaCamTheme.Colors.accent)
        .accessibilityIdentifier("engrave-telemetry-toggle")
        .accessibilityHint("Burns the telemetry HUD into the exported video. Off keeps a lossless, faster muxed copy.")

        HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(TeslaCamTheme.Colors.accent)
            .frame(width: 6, height: 6)
          Text(state.exportModeCaption)
            .font(TeslaCamTheme.Typography.monoSmall)
            .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
            .lineLimit(2)
        }
      }
    }
  }

  private var exportCTABar: some View {
    Button {
      state.exportRange()
    } label: {
      Label(exportButtonTitle, systemImage: "square.and.arrow.up")
    }
    .buttonStyle(TeslaCamCTAButtonStyle())
    .disabled(state.clipSets.isEmpty || state.exporter.isExporting)
    .accessibilityIdentifier("export-video")
    .frame(maxWidth: contentColumnWidth)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, pagePadding)
    .padding(.top, TeslaCamTheme.Spacing.s)
    .padding(.bottom, TeslaCamTheme.Spacing.s)
    .background(alignment: .top) {
      ZStack(alignment: .top) {
        TeslaCamTheme.Colors.overlaySurfaceStrong.opacity(0.9)
        Rectangle()
          .fill(TeslaCamTheme.Colors.stroke)
          .frame(height: 1)
      }
      .ignoresSafeArea(.container, edges: .bottom)
    }
  }

  // MARK: Reusable controls

  private func transportButton(_ system: String, label: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: prominent ? 24 : 18, weight: .semibold))
        .foregroundStyle(prominent ? Color.white : TeslaCamTheme.Colors.textPrimary)
        .frame(width: prominent ? 64 : 52, height: prominent ? 64 : 52)
        .background(
          Circle().fill(prominent ? TeslaCamTheme.Colors.accent : TeslaCamTheme.Colors.surfaceElevated)
        )
        .overlay(Circle().stroke(TeslaCamTheme.Colors.stroke, lineWidth: prominent ? 0 : 1))
    }
    .buttonStyle(.plain)
    .disabled(state.clipSets.isEmpty)
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  private var rateChip: some View {
    Button {
      state.cyclePlaybackRate()
    } label: {
      Text(rateText)
        .font(TeslaCamTheme.Typography.monoDetail.weight(.semibold))
        .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
        .frame(width: 56, height: 44)
        .glassSurface(role: .control, radius: TeslaCamTheme.Metrics.compactCorner)
    }
    .buttonStyle(.plain)
    .disabled(state.clipSets.isEmpty)
    .accessibilityLabel("Playback speed")
    .accessibilityValue(rateText)
  }

  private func rangeButton(_ title: String, _ system: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: system).font(.system(size: 14, weight: .semibold))
        Text(title).font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .glassSurface(role: .control, radius: TeslaCamTheme.Metrics.compactCorner)
    }
    .buttonStyle(.plain)
    .disabled(state.clipSets.isEmpty)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
  }

  private func trimField(_ title: String, text: Binding<String>, field: TrimField) -> some View {
    HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
      Text(title.uppercased())
        .font(TeslaCamTheme.Typography.label)
        .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
      TextField(title, text: text)
        .textFieldStyle(.plain)
        .keyboardType(.numbersAndPunctuation)
        .font(TeslaCamTheme.Typography.monoDetail)
        .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        .focused($focusedTrimField, equals: field)
        .onSubmit {
          if field == .start { commitTrimStartInput() } else { commitTrimEndInput() }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.m)
    .frame(height: 44)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassSurface(role: .control, radius: TeslaCamTheme.Metrics.controlCorner)
  }

  // MARK: Derived values

  private var isPad: Bool { horizontalSizeClass == .regular }

  private var pagePadding: CGFloat {
    isPad ? TeslaCamTheme.Spacing.screen : TeslaCamTheme.Spacing.screenCompact
  }

  private var contentColumnWidth: CGFloat {
    isPad ? TeslaCamTheme.Layout.contentMaxWidth : .infinity
  }

  /// Width of the control column in the wide (landscape / iPad) layout. The player
  /// takes all the rest, so keep this as narrow as the controls allow.
  private var controlColumnWidth: CGFloat {
    min(max(320, size.width * 0.32), 420)
  }

  private var contentWidth: CGFloat {
    let column = isPad ? min(size.width, TeslaCamTheme.Layout.contentMaxWidth) : size.width
    return max(0, column - pagePadding * 2)
  }

  private var playerHeight: CGFloat {
    let aspect: CGFloat = state.camerasDetected.count > 4 ? 1.85 : 1.5
    let ideal = contentWidth / aspect
    return min(max(190, ideal), size.height * 0.5)
  }

  private var revealTrigger: String { state.rootURL?.path ?? "demo" }

  private var headerSubtitle: String {
    let cams = state.camerasDetected.count
    let camText = "\(cams) camera\(cams == 1 ? "" : "s")"
    return "\(camText) · \(formatHMS(state.totalDuration))"
  }

  private var rateText: String {
    let rate = state.playbackRate
    let value = (rate == rate.rounded()) ? String(Int(rate)) : String(format: "%g", rate)
    return value + "×"
  }

  private var exportButtonTitle: String {
    state.exporter.isExporting ? "Exporting…" : "Export video"
  }

  private var exportPresetBinding: Binding<ExportPreset> {
    Binding(
      get: { state.exportPreset == .maxQualityH264 ? .maxQualityH264 : .maxQualityHEVC },
      set: { state.setExportPreset($0) }
    )
  }

  private var playbackSecondsBinding: Binding<Double> {
    Binding(
      get: { playbackUI.currentSeconds },
      set: { playbackUI.currentSeconds = $0 }
    )
  }

  private func syncTrimInputs() {
    trimStartInput = formatHMS(state.trimStartSeconds)
    trimEndInput = formatHMS(state.trimEndSeconds)
  }

  private func commitTrimStartInput() {
    _ = state.applyTrimStartInput(trimStartInput)
    trimStartInput = formatHMS(state.trimStartSeconds)
  }

  private func commitTrimEndInput() {
    _ = state.applyTrimEndInput(trimEndInput)
    trimEndInput = formatHMS(state.trimEndSeconds)
  }

  private enum TrimField: Hashable {
    case start
    case end
  }
}

private struct DemoVideoWallPlaceholder: View {
  let cameras: [Camera]
  let layoutRequest: CameraLayoutRequest
  let naturalSizes: [Camera: CGSize]
  var usesCompactPhonePreview: Bool = false

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let gap = TeslaCamTheme.Spacing.xs
      let columns = displayCameras.count > 4 ? 3 : 2
      let rows = max(1, Int(ceil(Double(max(displayCameras.count, 1)) / Double(columns))))
      let cellWidth = (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
      let cellHeight = (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
      let shouldShowCameraLabels = !usesCompactPhonePreview && size.height >= 260

      ZStack {
        Rectangle().fill(Color.black.opacity(0.94))

        VStack(spacing: gap) {
          ForEach(0..<rows, id: \.self) { row in
            HStack(spacing: gap) {
              ForEach(0..<columns, id: \.self) { column in
                let index = row * columns + column
                if displayCameras.indices.contains(index) {
                  let camera = displayCameras[index]
                  DemoVideoWallTile(camera: camera, showLabels: shouldShowCameraLabels)
                    .aspectRatio(normalizedAspectRatio(for: camera), contentMode: .fill)
                    .frame(width: cellWidth, height: cellHeight)
                    .clipped()
                } else {
                  Color.clear
                    .frame(width: cellWidth, height: cellHeight)
                }
              }
            }
          }
        }
      }
      .frame(width: size.width, height: size.height)
      .clipped()
    }
  }

  private var displayCameras: [Camera] {
    cameras.isEmpty ? Camera.hw3ClassicOrder : cameras
  }

  private var effectiveNaturalSizes: [Camera: CGSize] {
    var sizes = naturalSizes
    for camera in displayCameras where sizes[camera] == nil {
      sizes[camera] = defaultSize(for: camera)
    }
    return sizes
  }

  private func normalizedAspectRatio(for camera: Camera) -> CGFloat {
    let size = effectiveNaturalSizes[camera] ?? defaultSize(for: camera)
    let raw = size.height > 0 ? size.width / size.height : 16.0 / 9.0
    return raw > 1.45 ? 16.0 / 9.0 : 4.0 / 3.0
  }

  private func defaultSize(for _: Camera) -> CGSize {
    if usesHW4Layout {
      return CGSize(width: 1920, height: 1080)
    }
    return CGSize(width: 1280, height: 960)
  }

  private var usesHW4Layout: Bool {
    layoutRequest == .sixcam || !Set(displayCameras).isDisjoint(with: Set([.left, .right, .left_pillar, .right_pillar]))
  }
}

private struct DemoVideoWallTile: View {
  let camera: Camera
  let showLabels: Bool

  var body: some View {
    ZStack {
      Rectangle()
        .fill(TeslaCamTheme.Colors.surfaceElevated)

      VStack(alignment: .leading) {
        if showLabels {
          HStack {
            Image(systemName: "video")
            Text(camera.shortName.uppercased())
            Spacer()
            Text("DEMO")
          }
          .font(TeslaCamTheme.Typography.label)
          .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        }

        Spacer()

        HStack(spacing: TeslaCamTheme.Spacing.xs) {
          ForEach(0..<18, id: \.self) { index in
            Rectangle()
              .fill(index % 5 == 0 ? TeslaCamTheme.Colors.accent.opacity(0.34) : TeslaCamTheme.Colors.stroke)
              .frame(width: 2, height: CGFloat(10 + (index % 4) * 6))
          }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .opacity(0.42)

        Spacer()
      }
      .padding(TeslaCamTheme.Spacing.m)
    }
  }
}
#endif

#if os(macOS)
struct MacTimelineWorkspace: View {
  @ObservedObject var state: AppState
  @ObservedObject var playback: MultiCamPlaybackController
  @ObservedObject var playbackUI: PlaybackUIState
  let timelineMarkers: [Date]
  let isSingleDayTimeline: Bool
  let loadedContentMaxWidth: CGFloat
  let maxPreviewHeight: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let outerPadding = TeslaCamTheme.Spacing.m * 2
      let controlDockHeight: CGFloat = 236
      let availablePreviewHeight = max(
        320,
        proxy.size.height - outerPadding - controlDockHeight - TeslaCamTheme.Spacing.s
      )
      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.s) {
        PreviewPanelCard(
          state: state,
          playbackUI: playbackUI,
          maxAvailableHeight: min(maxPreviewHeight, availablePreviewHeight)
        )

        TimelineExportCard(
          state: state,
          playback: playback,
          playbackUI: playbackUI,
          timelineMarkers: timelineMarkers,
          isSingleDayTimeline: isSingleDayTimeline
        )
      }
      .frame(maxWidth: loadedContentMaxWidth, alignment: .top)
      .padding(TeslaCamTheme.Spacing.m)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
}
#endif

private struct OnboardingScreen: View {
  @ObservedObject var state: AppState

  var body: some View {
    #if os(iOS)
    VStack {
      Spacer()

      VStack(spacing: TeslaCamTheme.Spacing.xxl) {
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surfaceElevated)
          .frame(width: 52, height: 52)
          .overlay(
            Image(systemName: "archivebox")
              .font(.system(size: 22, weight: .medium))
              .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
          )

        VStack(spacing: TeslaCamTheme.Spacing.m) {
          Text("Drop Tesla folder.\nGet timeline.")
            .font(TeslaCamTheme.Typography.panelTitle)
            .multilineTextAlignment(.center)
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)

          Text("TeslaCam scans nested folders, keeps true clock time, shows real gaps, and exports one native timeline.")
            .font(TeslaCamTheme.Typography.bodySmall)
            .multilineTextAlignment(.center)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
            .frame(maxWidth: 480)
        }

        HStack(spacing: TeslaCamTheme.Spacing.m) {
          Button("Choose Folder") { state.chooseFolder() }
            .buttonStyle(PrimaryButtonStyle(fixedWidth: 180))
            .disabled(state.exporter.isExporting)
            .accessibilityIdentifier("choose-folder")

          Button("Demo") { state.loadDemoTimeline() }
            .buttonStyle(QuickActionButtonStyle())
            .disabled(state.exporter.isExporting)
            .accessibilityIdentifier("load-demo")
        }
      }
      .padding(TeslaCamTheme.Spacing.xxl)
      .frame(maxWidth: 540)
      .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: TeslaCamTheme.Metrics.cardCorner)

      Spacer()
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .accessibilityIdentifier("onboarding-screen")
    #else
    VStack {
      Spacer()

      VStack(spacing: TeslaCamTheme.Spacing.section) {
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surfaceElevated)
          .frame(width: 72, height: 72)
          .overlay(
            Image(systemName: "archivebox")
              .font(.system(size: 28, weight: .medium))
              .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
          )

        VStack(spacing: TeslaCamTheme.Spacing.m) {
          Text("Drop Tesla folder.\nGet timeline.")
            .font(TeslaCamTheme.Typography.heroTitle)
            .multilineTextAlignment(.center)
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)

          Text("TeslaCam scans nested folders, keeps true clock time, shows real gaps, and exports one native timeline.")
            .font(TeslaCamTheme.Typography.panelSubtitle)
            .multilineTextAlignment(.center)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
            .frame(maxWidth: 520)
        }

        HStack(spacing: TeslaCamTheme.Spacing.m) {
          Button("Choose Folder") { state.chooseFolder() }
            .buttonStyle(PrimaryButtonStyle(fixedWidth: 220))
            .disabled(state.exporter.isExporting)
            .accessibilityIdentifier("choose-folder")

          Button("Demo") { state.loadDemoTimeline() }
            .buttonStyle(QuickActionButtonStyle())
            .disabled(state.exporter.isExporting)
            .accessibilityIdentifier("load-demo")
        }
      }

      Spacer()
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .accessibilityIdentifier("onboarding-screen")
    #endif
  }
}

private struct IndexingScreen: View {
  @ObservedObject var state: AppState

  var body: some View {
    #if os(iOS)
    VStack {
      Spacer()

      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.m) {
        Text("Putting the timeline together")
          .font(TeslaCamTheme.Typography.panelTitle)
          .foregroundStyle(TeslaCamTheme.Colors.textPrimary)

        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .tint(TeslaCamTheme.Colors.accent)

        HStack {
          Text(indexingSubtitle)
            .font(TeslaCamTheme.Typography.bodySmall)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
            .lineLimit(1)
          Spacer()
          Text(progressText)
            .font(TeslaCamTheme.Typography.numericBody)
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
        }
      }
      .padding(TeslaCamTheme.Spacing.xxl)
      .frame(width: min(TeslaCamTheme.Layout.narrowPanelWidth, 520), alignment: .leading)
      .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: TeslaCamTheme.Metrics.cardCorner)

      Spacer()
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .accessibilityIdentifier("indexing-screen")
    #else
    VStack {
      Spacer()

      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.m) {
        Text("Putting the timeline together")
          .font(TeslaCamTheme.Typography.panelTitle)
          .foregroundStyle(TeslaCamTheme.Colors.textPrimary)

        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .tint(TeslaCamTheme.Colors.accent)

        HStack {
          Text(indexingSubtitle)
            .font(TeslaCamTheme.Typography.body)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
            .lineLimit(1)
          Spacer()
          Text(progressText)
            .font(TeslaCamTheme.Typography.numericBody)
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
        }
      }
      .padding(TeslaCamTheme.Spacing.xxl)
      .frame(width: min(TeslaCamTheme.Layout.narrowPanelWidth, 520), alignment: .leading)
      .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: TeslaCamTheme.Metrics.cardCorner)

      Spacer()
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    .accessibilityIdentifier("indexing-screen")
    #endif
  }

  private var progress: Double {
    let stageCount = max(1, ScanStage.allCases.count)
    let stageBase = Double(state.scanStage.rawValue) / Double(stageCount)
    let stageSpan = 1.0 / Double(stageCount)
    let clipBoost = min(0.7, Double(state.scanDiscoveredClipCount) / 6_000.0)
    return min(0.97, max(0.06, stageBase + stageSpan * clipBoost))
  }

  private var progressText: String {
    "\(Int((progress * 100).rounded()))%"
  }

  private var indexingSubtitle: String {
    state.scanDiscoveredClipCount > 0
      ? "\(state.scanDiscoveredClipCount) clips found"
      : "Scanning clips"
  }
}

private struct PreviewPanelCard: View {
  @ObservedObject var state: AppState
  @ObservedObject var playbackUI: PlaybackUIState
  let maxAvailableHeight: CGFloat
  var usesCompactPhonePreview: Bool = false
  /// When set, the card uses exactly this height (portrait, aspect-driven) instead
  /// of the landscape "fill the remaining space" math — avoids letterbox gaps.
  var fixedHeight: CGFloat? = nil
  /// When true, the card fills its container (used by the wide layout's player
  /// column); the video letterboxes inside. Overrides `fixedHeight`/`maxAvailableHeight`.
  var fillsContainer: Bool = false

  var body: some View {
    GeometryReader { proxy in
      let height = fillsContainer ? proxy.size.height : (fixedHeight ?? previewHeight(for: proxy.size.width))

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surface)
          .overlay(
            Group {
              if state.sourceURLs.isEmpty {
#if os(iOS)
                DemoVideoWallPlaceholder(
                  cameras: state.gridPreviewCameras,
                  layoutRequest: state.layoutRequest,
                  naturalSizes: state.currentPreviewNaturalSizes,
                  usesCompactPhonePreview: usesCompactPhonePreview
                )
#else
                Rectangle()
                  .fill(Color.black)
#endif
              } else {
                MetalPlayerView(
                  playback: state.playback,
                  cameraOrder: state.gridPreviewCameras,
                  layoutRequest: state.layoutRequest,
                  previewLayoutMode: effectivePreviewLayoutMode,
                  focusedCamera: nil,
                  naturalSizes: state.currentPreviewNaturalSizes
                )
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous))
          )

        VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.xs) {
          Text(state.privacyMode ? "Privacy" : overlayDate)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
          Text(state.privacyMode ? "Hidden" : overlayTime)
            .font(TeslaCamTheme.Typography.monoDetail)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        }
        .padding(.horizontal, TeslaCamTheme.Metrics.chipPaddingHorizontal)
        .padding(.vertical, TeslaCamTheme.Metrics.chipPaddingVertical)
        .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: TeslaCamTheme.Metrics.compactCorner)
        .padding(TeslaCamTheme.Spacing.l)

        if state.currentGapRange != nil {
          Text("No recording in this span")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
            .padding(.horizontal, TeslaCamTheme.Spacing.l)
            .padding(.vertical, TeslaCamTheme.Spacing.m)
            .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: TeslaCamTheme.Metrics.compactCorner)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(width: proxy.size.width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.cardCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 0.5)
      )
    }
    .frame(maxWidth: .infinity, maxHeight: fillsContainer ? .infinity : nil)
    .frame(height: fillsContainer ? nil : (fixedHeight ?? maxAvailableHeight))
  }

  private var overlayDate: String {
    let parts = playbackUI.overlayText.split(separator: " ")
    if let first = parts.first {
      return String(first)
    }
    return "Loaded"
  }

  private var overlayTime: String {
    let parts = playbackUI.overlayText.split(separator: " ")
    if parts.count >= 2 {
      return String(parts[1])
    }
    return "00:00:00"
  }

  private var previewHeightFactor: CGFloat {
    switch state.camerasDetected.count {
    case 0...4:
      return 0.75
    case 5...6:
      return 0.66
    default:
      return 0.58
    }
  }

  private var effectivePreviewLayoutMode: PreviewLayoutMode {
    // Always a grid — 2×2 for four cameras, 3×2 for six. (Previously a single
    // horizontal row on compact phones, which the portrait layout doesn't want.)
    return .grid
  }

  private func previewHeight(for width: CGFloat) -> CGFloat {
    min(maxAvailableHeight, max(320, width * previewHeightFactor))
  }
}

private struct TimelineExportCard: View {
  @ObservedObject var state: AppState
  @ObservedObject var playback: MultiCamPlaybackController
  @ObservedObject var playbackUI: PlaybackUIState
  let timelineMarkers: [Date]
  let isSingleDayTimeline: Bool
  @State private var trimStartInput = ""
  @State private var trimEndInput = ""
  @FocusState private var focusedTrimField: TrimField?
  @State private var lastFocusedTrimField: TrimField?

  var body: some View {
    let minDate = state.minDate ?? Date()
    let maxDate = state.maxDate ?? Date()

    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.s) {
      timelineDock

      macControlStack(minDate: minDate, maxDate: maxDate)
    }
    .padding(TeslaCamTheme.Metrics.cardPaddingCompact)
    .teslaCamCard()
    .onAppear(perform: syncTrimInputs)
    .onChange(of: state.trimStartSeconds) {
      guard focusedTrimField != .start else { return }
      trimStartInput = formatHMS(state.trimStartSeconds)
    }
    .onChange(of: state.trimEndSeconds) {
      guard focusedTrimField != .end else { return }
      trimEndInput = formatHMS(state.trimEndSeconds)
    }
    .onChange(of: focusedTrimField) {
      let newValue = focusedTrimField
      if lastFocusedTrimField == .start, newValue != .start {
        commitTrimStartInput()
      }
      if lastFocusedTrimField == .end, newValue != .end {
        commitTrimEndInput()
      }
      lastFocusedTrimField = newValue
    }
  }

  private var timelineDock: some View {
    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.s) {
      TimelineSelectionTrack(
        currentSeconds: playbackSecondsBinding,
        selectedStartSeconds: $state.trimStartSeconds,
        selectedEndSeconds: $state.trimEndSeconds,
        gapRanges: state.timelineGapRanges,
        totalDuration: max(state.totalDuration, 1),
        onSeekStart: { state.beginSeek() },
        onSeekChange: { state.liveSeek(to: $0) },
        onSeekEnd: { state.endSeek() },
        onDragStart: { state.beginTrimDrag() },
        onDragChange: { start, end in state.updateTrimRange(startSeconds: start, endSeconds: end) },
        onDragEnd: { start, end in state.endTrimDrag(startSeconds: start, endSeconds: end) }
      )
      .frame(height: 36)

      HStack(spacing: 0) {
        Text(formatHMS(0))
          .frame(width: 72, alignment: .leading)
        ForEach(recordedTickFractions, id: \.self) { fraction in
          Text(formatHMS(state.totalDuration * fraction))
            .frame(maxWidth: .infinity)
        }
        Text(formatHMS(state.totalDuration))
          .frame(width: 72, alignment: .trailing)
      }
      .font(TeslaCamTheme.Typography.monoSmall)
      .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
      .padding(.horizontal, 20)
      .padding(.top, 2)
      .padding(.bottom, TeslaCamTheme.Spacing.xs)
    }
  }

  private var transportButtonCluster: some View {
    HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
      Button {
        state.stepPlayback(by: -5)
      } label: {
        Label("Back 5 seconds", systemImage: "gobackward.5")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(IconButtonStyle())
      .disabled(state.clipSets.isEmpty)
      .accessibilityLabel("Back 5 seconds")
      .accessibilityIdentifier("step-back-5")

      Button {
        state.togglePlay()
      } label: {
        Label(
          playback.isPlaying ? "Pause" : "Play",
          systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
        )
        .labelStyle(.iconOnly)
      }
      .buttonStyle(IconButtonStyle(prominent: true))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
      .accessibilityValue(playback.isPlaying ? "playing" : "paused")
      .accessibilityIdentifier("toggle-playback")

      Button {
        state.stepPlayback(by: 5)
      } label: {
        Label("Forward 5 seconds", systemImage: "goforward.5")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(IconButtonStyle())
      .disabled(state.clipSets.isEmpty)
      .accessibilityLabel("Forward 5 seconds")
      .accessibilityIdentifier("step-forward-5")
    }
  }

  private var inOutCluster: some View {
    HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
      Button("In") { state.setTrimStartAtPlayhead() }
        .buttonStyle(QuickActionButtonStyle())
        .disabled(state.clipSets.isEmpty)
        .accessibilityLabel("Set export start to playhead")
        .accessibilityIdentifier("set-trim-start-at-playhead")

      Button("Out") { state.setTrimEndAtPlayhead() }
        .buttonStyle(QuickActionButtonStyle())
        .disabled(state.clipSets.isEmpty)
        .accessibilityLabel("Set export end to playhead")
        .accessibilityIdentifier("set-trim-end-at-playhead")
    }
  }

  private var quickRangeCluster: some View {
    HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
      Button {
        state.setFullRange()
      } label: {
        Label("All", systemImage: "arrow.left.and.right")
      }
        .buttonStyle(QuickActionButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Whole Timeline")
        .accessibilityIdentifier("range-whole-timeline")

      Button {
        state.setCurrentMinuteRange()
      } label: {
        Label("1m", systemImage: "clock")
      }
        .buttonStyle(QuickActionButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current Minute")
        .accessibilityIdentifier("range-current-minute")

      Button {
        state.setRecentRange(minutes: 5)
      } label: {
        Label("5m", systemImage: "clock.arrow.circlepath")
      }
        .buttonStyle(QuickActionButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 5m")
        .accessibilityIdentifier("range-last-5m")

      Button {
        state.setRecentRange(minutes: 15)
      } label: {
        Label("15m", systemImage: "clock.badge")
      }
        .buttonStyle(QuickActionButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 15m")
        .accessibilityIdentifier("range-last-15m")
    }
  }

  private var selectedSpanSummary: String {
    "\(formatHMS(state.selectedTrimDuration)) • \(state.selectedSetsForExport.count) spans"
  }

  private func macControlStack(minDate _: Date, maxDate _: Date) -> some View {
    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.s) {
      ViewThatFits(in: .horizontal) {
        controlTopRow(timeWidth: 118, exportWidth: 176)
        controlTopRow(timeWidth: 104, exportWidth: 132)
        controlTopRow(timeWidth: 88, exportWidth: 112)
      }
      .frame(height: TeslaCamTheme.Metrics.compactControlHeight)

      HStack(spacing: TeslaCamTheme.Spacing.s) {
        // Telemetry burn-in remains optional. The base export stays a regular
        // encoded grid unless the user explicitly asks for original tracks.
        Toggle(isOn: $state.exportOverlayOptions.telemetryHUD) {
          Text("Engrave telemetry")
            .font(TeslaCamTheme.Typography.label)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        }
        .toggleStyle(.switch)
        .tint(TeslaCamTheme.Colors.accent)
        .fixedSize()
        .accessibilityIdentifier("engrave-telemetry-toggle")
        .accessibilityHint("Burns the telemetry HUD into the exported video.")

        Spacer(minLength: 0)

        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(TeslaCamTheme.Colors.accent)
          .frame(width: 6, height: 6)
        Text(state.exportModeCaption)
          .font(TeslaCamTheme.Typography.monoSmall)
          .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }

      HStack(alignment: .top, spacing: TeslaCamTheme.Spacing.s) {
        MacCameraToggleGrid(state: state)
          .frame(width: state.camerasDetected.count > 4 ? 242 : 156, alignment: .topLeading)

        MacRangeGrid(state: state)
          .frame(width: 124, alignment: .topLeading)

        ClipInformationPanel(
          state: state,
          playbackUI: playbackUI,
          statusText: selectedSpanSummary
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func controlTopRow(timeWidth: CGFloat, exportWidth: CGFloat) -> some View {
    HStack(spacing: TeslaCamTheme.Spacing.s) {
      trimInputField("In", text: $trimStartInput, field: .start, width: timeWidth)

      transportButtonCluster

      trimInputField("Out", text: $trimEndInput, field: .end, width: timeWidth)

      inOutCluster

      Spacer(minLength: 0)

      codecPickerField

      Button {
        state.exportRange()
      } label: {
        Label(exportButtonTitle, systemImage: "square.and.arrow.up")
      }
        .buttonStyle(PrimaryButtonStyle(fixedWidth: exportWidth))
        .disabled(state.clipSets.isEmpty || state.exporter.isExporting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exportButtonTitle)
        .accessibilityIdentifier("export-video")
    }
  }

  private func trimInputField(_ title: String, text: Binding<String>, field: TrimField, width: CGFloat = 118) -> some View {
    HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
      Text(title.uppercased())
        .font(TeslaCamTheme.Typography.label)
        .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
      TextField(title, text: text)
        .textFieldStyle(.plain)
        .font(TeslaCamTheme.Typography.monoDetail)
        .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        .multilineTextAlignment(.leading)
        .focused($focusedTrimField, equals: field)
        .onSubmit {
          switch field {
          case .start:
            commitTrimStartInput()
          case .end:
            commitTrimEndInput()
          }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.s)
    .frame(width: width, height: TeslaCamTheme.Metrics.compactControlHeight, alignment: .leading)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)
  }

  private var codecPickerField: some View {
    HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
      Text("Codec".uppercased())
        .font(TeslaCamTheme.Typography.label)
        .foregroundStyle(TeslaCamTheme.Colors.textTertiary)

      Picker("", selection: exportPresetBinding) {
        Text("H.265").tag(ExportPreset.maxQualityHEVC)
        Text("H.264").tag(ExportPreset.maxQualityH264)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 132)
    }
  }

  private var exportPresetBinding: Binding<ExportPreset> {
    Binding(
      get: { state.exportPreset == .maxQualityH264 ? .maxQualityH264 : .maxQualityHEVC },
      set: { state.setExportPreset($0) }
    )
  }

  private func syncTrimInputs() {
    trimStartInput = formatHMS(state.trimStartSeconds)
    trimEndInput = formatHMS(state.trimEndSeconds)
  }

  private func commitTrimStartInput() {
    _ = state.applyTrimStartInput(trimStartInput)
    trimStartInput = formatHMS(state.trimStartSeconds)
  }

  private func commitTrimEndInput() {
    _ = state.applyTrimEndInput(trimEndInput)
    trimEndInput = formatHMS(state.trimEndSeconds)
  }

  private var playbackSecondsBinding: Binding<Double> {
    Binding(
      get: { playbackUI.currentSeconds },
      set: { playbackUI.currentSeconds = $0 }
    )
  }

  private var playbackSummaryText: String {
    "\(formatHMS(playbackUI.currentSeconds)) / \(formatHMS(state.totalDuration))"
  }

  private var recordedTickFractions: [Double] {
    [0.2, 0.4, 0.6, 0.8]
  }

  private var exportButtonTitle: String {
    "Export"
  }

  private var trimRangeSummary: String {
    formattedTimelineDate(state.selectedStart) + " - " + formattedTimelineDate(state.selectedEnd)
  }

  private func tickLabel(for date: Date?) -> String {
    guard let date else { return "" }
    if isSingleDayTimeline {
      return TeslaCamFormatters.timelineSameDay.string(from: date)
    }
    let span = (state.maxDate ?? date).timeIntervalSince(state.minDate ?? date)
    if span <= 172_800 {
      return TeslaCamFormatters.timelineTwoDay.string(from: date)
    }
    return TeslaCamFormatters.timelineMultiDay.string(from: date)
  }

  private func formattedTimelineDate(_ date: Date) -> String {
    TeslaCamFormatters.selectedRange.string(from: date)
  }

  private func coverageSummary(for summary: ExportHealthSummary) -> String {
    var parts = [
      "\(summary.totalMinutes)m timeline",
      "\(summary.gapCount) gap\(summary.gapCount == 1 ? "" : "s")",
      "\(summary.partialSetCount) partial span\(summary.partialSetCount == 1 ? "" : "s")"
    ]

    if summary.hasMixedCoverage {
      parts.append("mixed 4- and 6-camera coverage")
    }

    if !summary.missingCoverageSummary.isEmpty {
      parts.append(summary.missingCoverageSummary)
    }

    return parts.joined(separator: " • ")
  }

  private enum TrimField: Hashable {
    case start
    case end
  }
}

private struct ClipInformationPanel: View {
  @ObservedObject var state: AppState
  @ObservedObject var playbackUI: PlaybackUIState
  let statusText: String

  var body: some View {
    VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.xs) {
      HStack(spacing: TeslaCamTheme.Spacing.s) {
        Image(systemName: "info.circle")
          .font(TeslaCamTheme.Typography.monoSmall)
          .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
        Text("Clip information".uppercased())
          .font(TeslaCamTheme.Typography.monoSmall.weight(.semibold))
          .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
        Spacer(minLength: 0)
      }

      LazyVGrid(columns: infoColumns, alignment: .leading, spacing: TeslaCamTheme.Spacing.xs) {
        ClipInfoTile(title: "Time", value: clipTime)
        ClipInfoTile(title: "Speed", value: speedText)
        ClipInfoTile(title: "GPS", value: gpsText)
        ClipInfoTile(title: "Heading", value: headingText)
        ClipInfoTile(title: "Gear", value: gearText, warning: telemetryModel?.brakeApplied == true)
        ClipInfoTile(title: "Signal", value: signalText)
        ClipInfoTile(title: "Selection", value: statusText)
        ClipInfoTile(title: "Coverage", value: coverageText)
      }
    }
    .padding(.horizontal, TeslaCamTheme.Spacing.s)
    .padding(.vertical, TeslaCamTheme.Spacing.s)
    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)
  }

  private var infoColumns: [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: TeslaCamTheme.Spacing.tightGap), count: 4)
  }

  private var telemetryModel: TelemetryDisplayModel? {
    state.privacyMode ? nil : state.telemetryModel
  }

  private var clipTime: String {
    playbackUI.overlayText.isEmpty ? "--" : playbackUI.overlayText
  }

  private var speedText: String {
    if state.privacyMode {
      return "Hidden"
    }
    return telemetryModel?.speedText(unit: state.exportOverlayOptions.speedUnit) ?? "No data"
  }

  private var gpsText: String {
    if state.privacyMode {
      return "Hidden"
    }
    return telemetryModel?.locationText ?? "No GPS"
  }

  private var headingText: String {
    telemetryModel?.headingText ?? "--"
  }

  private var gearText: String {
    guard let model = telemetryModel else { return "--" }
    return model.brakeApplied ? "\(model.gear) / Brake" : model.gear
  }

  private var signalText: String {
    telemetryModel?.signalText ?? "--"
  }

  private var exportHUDText: String {
    state.effectiveExportOverlayOptions.telemetryHUD ? "Engraved" : "Preview only"
  }

  private var coverageText: String {
    var parts = [
      "G\(state.timelineGapRanges.count)",
      "P\(state.partialSelectedSetCount)",
      "H\(state.hiddenExportCameraNames.count)"
    ]
    if state.duplicateSummary.duplicateFileCount > 0 {
      parts.append("D\(state.duplicateSummary.duplicateFileCount)")
    }
    if state.duplicateSummary.duplicateTimestampCount > 0 {
      parts.append("C\(state.duplicateSummary.duplicateTimestampCount)")
    }
    if state.duplicateSummary.overlapMinuteCount > 0 {
      parts.append("O\(state.duplicateSummary.overlapMinuteCount)")
    }
    parts.append(exportHUDText)
    return parts.joined(separator: " ")
  }
}

private struct ClipInfoTile: View {
  let title: String
  let value: String
  var warning: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title.uppercased())
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(TeslaCamTheme.Colors.textTertiary)
        .lineLimit(1)
      Text(value)
        .font(TeslaCamTheme.Typography.monoSmall)
        .foregroundStyle(warning ? TeslaCamTheme.Colors.gapAccent : TeslaCamTheme.Colors.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.62)
    }
    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
  }
}

/// Read-only two-segment codec indicator (H.265 / H.264). The active segment
/// reflects the codec the export adopts from the source footage; it is not a
/// control. Fixed width by construction so it cannot bleed into the timeline.
private struct CodecSegmentIndicator: View {
  let activeCodec: VideoCodec

  private let options: [VideoCodec] = [.hevc, .h264]

  private var resolvedActive: VideoCodec {
    activeCodec == .h264 ? .h264 : .hevc
  }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.self) { codec in
        segment(for: codec, isActive: codec == resolvedActive)
      }
    }
    .padding(3)
    .frame(height: TeslaCamTheme.Metrics.compactControlHeight)
    .teslaCamCard(fill: TeslaCamTheme.Colors.surface, radius: TeslaCamTheme.Metrics.controlCorner)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Export codec")
    .accessibilityValue("\(resolvedActive.displayName), adopted from source")
    .accessibilityIdentifier("export-codec-indicator")
  }

  @ViewBuilder
  private func segment(for codec: VideoCodec, isActive: Bool) -> some View {
    let label = Text(codec.displayName)
      .font(TeslaCamTheme.Typography.monoSmall.weight(.semibold))
      .foregroundStyle(isActive ? TeslaCamTheme.Colors.textPrimary : TeslaCamTheme.Colors.textTertiary)
      .padding(.horizontal, 11)
      .frame(height: 26)

    if isActive {
      label.glassSurface(role: .selected, radius: TeslaCamTheme.Metrics.compactCorner)
    } else {
      label
    }
  }
}

private struct MacCameraToggleGrid: View {
  @ObservedObject var state: AppState

  var body: some View {
    LazyVGrid(columns: columns, spacing: TeslaCamTheme.Spacing.tightGap) {
      ForEach(orderedCameras, id: \.self) { camera in
        Button {
          let isEnabled = state.activeExportCameras.contains(camera)
          state.toggleExportCamera(camera, isEnabled: !isEnabled)
        } label: {
          HStack(spacing: TeslaCamTheme.Spacing.tightGap) {
            Image(systemName: state.activeExportCameras.contains(camera) ? "checkmark.square.fill" : "square")
              .font(TeslaCamTheme.Typography.label)
            Text(camera.shortName)
              .font(TeslaCamTheme.Typography.label)
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }
          .foregroundStyle(state.activeExportCameras.contains(camera) ? TeslaCamTheme.Colors.textPrimary : TeslaCamTheme.Colors.textSecondary)
          .frame(maxWidth: .infinity)
          .frame(height: TeslaCamTheme.Metrics.compactControlHeight)
          .glassSurface(
            role: state.activeExportCameras.contains(camera) ? .selected : .control,
            radius: TeslaCamTheme.Metrics.compactCorner,
            interactive: true
          )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(camera.displayName)
        .accessibilityValue(state.activeExportCameras.contains(camera) ? "Included" : "Excluded")
        .accessibilityHint("Toggles whether this camera appears in the export.")
        .accessibilityIdentifier("camera-\(camera.rawValue)")
      }
    }
  }

  private var columns: [GridItem] {
    let count = state.camerasDetected.count > 4 ? 3 : 2
    return Array(repeating: GridItem(.flexible(), spacing: TeslaCamTheme.Spacing.tightGap), count: count)
  }

  private var orderedCameras: [Camera] {
    let detected = Set(state.camerasDetected)
    let preferred: [Camera] = [
      .front,
      .left_repeater,
      .left,
      .left_pillar,
      .back,
      .right_repeater,
      .right,
      .right_pillar
    ]
    let ordered = preferred.filter { detected.contains($0) }
    let remaining = state.camerasDetected.filter { !ordered.contains($0) }
    return ordered + remaining
  }
}

private struct MacRangeGrid: View {
  @ObservedObject var state: AppState

  var body: some View {
    LazyVGrid(columns: columns, spacing: TeslaCamTheme.Spacing.tightGap) {
      Button {
        state.setFullRange()
      } label: {
        Label("All", systemImage: "arrow.left.and.right")
      }
        .buttonStyle(CompactRangeButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Whole Timeline")
        .accessibilityIdentifier("range-whole-timeline")

      Button {
        state.setCurrentMinuteRange()
      } label: {
        Label("1m", systemImage: "clock")
      }
        .buttonStyle(CompactRangeButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current Minute")
        .accessibilityIdentifier("range-current-minute")

      Button {
        state.setRecentRange(minutes: 5)
      } label: {
        Label("5m", systemImage: "clock.arrow.circlepath")
      }
        .buttonStyle(CompactRangeButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 5m")
        .accessibilityIdentifier("range-last-5m")

      Button {
        state.setRecentRange(minutes: 15)
      } label: {
        Label("15m", systemImage: "clock.badge")
      }
        .buttonStyle(CompactRangeButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last 15m")
        .accessibilityIdentifier("range-last-15m")
    }
  }

  private var columns: [GridItem] {
    [
      GridItem(.flexible(), spacing: TeslaCamTheme.Spacing.tightGap),
      GridItem(.flexible(), spacing: TeslaCamTheme.Spacing.tightGap)
    ]
  }
}

private struct ExportOverlayCard: View {
  @ObservedObject var state: AppState
  let job: ExportJobSnapshot

  var body: some View {
    #if os(iOS)
    ZStack {
      TeslaCamTheme.Colors.overlayScrim
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.l) {
        PanelHeader(
          title: title,
          systemImage: job.isTerminal ? "checkmark.square" : "hourglass"
        )
        .accessibilityIdentifier("export-overlay-title")

        ProgressView(value: max(0, min(job.progress, 1)))
          .tint(TeslaCamTheme.Colors.accent)
          .opacity(job.isTerminal ? 0.75 : 1)

        HStack(spacing: TeslaCamTheme.Spacing.s) {
          MetricTile(title: "Progress", value: job.progressPercentText)
          MetricTile(title: "State", value: job.phaseLabel)
        }

        Text(detail)
          .font(TeslaCamTheme.Typography.bodySmall)
          .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
          .lineLimit(2)

        HStack(spacing: TeslaCamTheme.Spacing.s) {
          if job.isTerminal {
            if job.phase == .completed {
              Button {
                state.exporter.revealOutput(for: job)
              } label: {
                Label("Reveal", systemImage: "arrow.up.forward.app")
              }
              .buttonStyle(TeslaCamCTAButtonStyle(tint: TeslaCamTheme.Colors.overlaySurface))
              .accessibilityLabel("Reveal File")
            } else {
              Button {
                state.exporter.revealLog()
              } label: {
                Label("Log", systemImage: "doc.text")
              }
              .buttonStyle(TeslaCamCTAButtonStyle(tint: TeslaCamTheme.Colors.overlaySurface))
              .accessibilityLabel("Show Log")
            }

            Button {
              state.dismissExportStatus()
            } label: {
              Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(TeslaCamCTAButtonStyle())
            .accessibilityLabel("Done")
            .accessibilityIdentifier("dismiss-export-status")
          } else {
            Button {
              state.cancelExport()
            } label: {
              Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(TeslaCamCTAButtonStyle(tint: TeslaCamTheme.Colors.overlaySurface))
            .accessibilityLabel("Cancel Export")
          }
        }
      }
      .padding(TeslaCamTheme.Spacing.xxl)
      .frame(maxWidth: 420)
      .glassSurface(role: .overlay, radius: TeslaCamTheme.Metrics.cardCorner)
      .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    }
    .allowsHitTesting(true)
    .accessibilityIdentifier("export-overlay")
    .zIndex(20)
    #else
    ZStack {
      TeslaCamTheme.Colors.overlayScrim
        .ignoresSafeArea()

      VStack(spacing: TeslaCamTheme.Spacing.xxl) {
        Text(title)
          .font(TeslaCamTheme.Typography.panelTitle)
          .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
          .accessibilityIdentifier("export-overlay-title")

        Text(job.phaseLabel)
          .font(TeslaCamTheme.Typography.panelSubtitle.weight(.medium))
          .foregroundStyle(TeslaCamTheme.Colors.textSecondary)

        ProgressView(value: max(0, min(job.progress, 1)))
          .tint(TeslaCamTheme.Colors.accent)
          .scaleEffect(x: 1, y: 2.6, anchor: .center)
          .frame(maxWidth: TeslaCamTheme.Layout.overlayContentWidth)
          .opacity(job.isTerminal ? 0.75 : 1)

        HStack {
          Text(detail)
            .font(TeslaCamTheme.Typography.body)
            .foregroundStyle(TeslaCamTheme.Colors.textSecondary)
            .lineLimit(2)

          Spacer()

          Text(job.progressPercentText)
            .font(TeslaCamTheme.Typography.numericBody)
            .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
        }
        .frame(maxWidth: TeslaCamTheme.Layout.overlayContentWidth)

        if job.isTerminal {
          VStack(spacing: TeslaCamTheme.Spacing.m) {
            if job.phase == .completed {
              Button("Reveal File") {
                state.exporter.revealOutput(for: job)
              }
              .buttonStyle(PrimaryButtonStyle(fixedWidth: 240))
              .accessibilityLabel("Reveal File")
            } else {
              Button("Show Log") {
                state.exporter.revealLog()
              }
              .buttonStyle(PrimaryButtonStyle(fixedWidth: 240))
              .accessibilityLabel("Show Log")
            }

            Button("Done") {
              state.dismissExportStatus()
            }
            .buttonStyle(QuickActionButtonStyle())
            .accessibilityLabel("Done")
            .accessibilityIdentifier("dismiss-export-status")
          }
        } else {
          Button("Cancel Export") {
            state.cancelExport()
          }
          .buttonStyle(PrimaryButtonStyle(fixedWidth: 240))
          .accessibilityLabel("Cancel Export")
        }
      }
      .padding(TeslaCamTheme.Spacing.section)
      .frame(maxWidth: TeslaCamTheme.Layout.overlayCardWidth)
      .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurfaceStrong, radius: TeslaCamTheme.Metrics.cardCorner)
      .padding(.horizontal, TeslaCamTheme.Spacing.screen)
    }
    .allowsHitTesting(true)
    .accessibilityIdentifier("export-overlay")
    .zIndex(20)
    #endif
  }

  private var title: String {
    switch job.phase {
    case .completed:
      return "Export Complete"
    case .failed:
      return "Export Failed"
    case .cancelled:
      return "Export Cancelled"
    default:
      return "Exporting Video"
    }
  }

  private var detail: String {
    if let reason = job.failureReason, job.isTerminal {
      return reason
    }
    return job.detailText
  }
}

private struct TimelineSelectionTrack: View {
  @Binding var currentSeconds: Double
  @Binding var selectedStartSeconds: Double
  @Binding var selectedEndSeconds: Double
  let gapRanges: [TimelineGapRange]
  let totalDuration: Double
  let onSeekStart: () -> Void
  let onSeekChange: (Double) -> Void
  let onSeekEnd: () -> Void
  let onDragStart: () -> Void
  let onDragChange: (Double, Double) -> Void
  let onDragEnd: (Double, Double) -> Void

  @State private var dragAnchor: DragAnchor?
  @State private var isSeeking = false

  var body: some View {
    GeometryReader { proxy in
      let fullWidth = proxy.size.width
      let safeDuration = max(totalDuration, 1)
      let laneHeight: CGFloat = 36
      let laneY: CGFloat = 0
      let trackInset: CGFloat = 20
      let trackWidth = max(fullWidth - (trackInset * 2), 1)
      let startX = trackInset + trackWidth * CGFloat(max(0, min(1, selectedStartSeconds / safeDuration)))
      let endX = trackInset + trackWidth * CGFloat(max(0, min(1, selectedEndSeconds / safeDuration)))
      let playheadX = trackInset + trackWidth * CGFloat(max(0, min(1, currentSeconds / safeDuration)))
      let selectionWidth = max(endX - startX, 8)

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surface)
          .frame(width: trackWidth, height: laneHeight)
          .offset(x: trackInset, y: laneY)
          .contentShape(Rectangle())
          .gesture(backgroundSeekGesture(originX: trackInset, width: trackWidth))

        ForEach(Array(gapRanges.enumerated()), id: \.offset) { _, gap in
          let gapStartX = trackInset + trackWidth * CGFloat(max(0, min(1, gap.startSeconds / safeDuration)))
          let gapEndX = trackInset + trackWidth * CGFloat(max(0, min(1, gap.endSeconds / safeDuration)))
          let gapWidth = max(gapEndX - gapStartX, 2)

          TimelineGapBand(showLabel: gap.duration > max(600, safeDuration * 0.12))
            .frame(width: gapWidth, height: laneHeight)
            .offset(x: gapStartX, y: laneY)
            .allowsHitTesting(false)
        }

        let isFullRange = selectedStartSeconds <= 0.01 && selectedEndSeconds >= totalDuration - 0.01

        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.accentSoft)
          .frame(width: selectionWidth, height: laneHeight)
          .overlay(
            RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
              .stroke(TeslaCamTheme.Colors.accent, lineWidth: 1.2)
          )
          .offset(x: startX, y: laneY)
          .contentShape(Rectangle())
          .gesture(selectionTapGesture(originX: trackInset, width: trackWidth))
          .simultaneousGesture(selectionDrag(width: trackWidth))
          .allowsHitTesting(!isFullRange)

        handle(kind: .start)
          .offset(x: clampedHandleX(centerX: startX, trackInset: trackInset, trackWidth: trackWidth), y: laneY)
          .contentShape(Rectangle())
          .gesture(handleDrag(kind: .start, originX: trackInset, width: trackWidth))

        handle(kind: .end)
          .offset(x: clampedHandleX(centerX: endX, trackInset: trackInset, trackWidth: trackWidth), y: laneY)
          .contentShape(Rectangle())
          .gesture(handleDrag(kind: .end, originX: trackInset, width: trackWidth))

        playhead
          .offset(x: clampedPlayheadX(centerX: playheadX, trackInset: trackInset, trackWidth: trackWidth), y: laneY)
          .contentShape(Rectangle())
          .gesture(playheadSeekGesture(originX: trackInset, width: trackWidth))
      }
    }
    .accessibilityIdentifier("merged-timeline-track")
  }

  private func handle(kind: HandleKind) -> some View {
    ZStack {
      Color.clear.frame(width: 24, height: 36)
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(TeslaCamTheme.Colors.accent.opacity(0.95))
        .frame(width: 4, height: 26)
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(TeslaCamTheme.Colors.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
    }
    #if os(macOS)
    .help(kind == .start ? "Drag export start" : "Drag export end")
    #endif
  }

  private var playhead: some View {
    ZStack(alignment: .center) {
      Color.clear.frame(width: 24, height: 36)
      VStack(spacing: 0) {
        Capsule(style: .continuous)
          .fill(TeslaCamTheme.Colors.accent)
          .frame(width: 10, height: 4)
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(TeslaCamTheme.Colors.accent)
          .frame(width: 2, height: 30)
      }
      .shadow(color: .black.opacity(0.16), radius: 1, x: 0, y: 1)
      #if os(macOS)
      .help("Drag playhead")
      #endif
    }
  }

  private func clampedHandleX(centerX: CGFloat, trackInset: CGFloat, trackWidth: CGFloat) -> CGFloat {
    max(trackInset, min(trackInset + trackWidth - 24, centerX - 12))
  }

  private func clampedPlayheadX(centerX: CGFloat, trackInset: CGFloat, trackWidth: CGFloat) -> CGFloat {
    max(trackInset, min(trackInset + trackWidth - 24, centerX - 12))
  }

  private func seconds(forX x: CGFloat, originX: CGFloat, width: CGFloat) -> Double {
    let clamped = max(0, min(width, x - originX))
    let fraction = Double(max(0, min(1, clamped / max(width, 1))))
    return totalDuration * fraction
  }

  private func updateSeek(from x: CGFloat, originX: CGFloat, width: CGFloat) {
    let seconds = seconds(forX: x, originX: originX, width: width)
    currentSeconds = seconds
    onSeekChange(seconds)
  }

  private func backgroundSeekGesture(originX: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard dragAnchor == nil else { return }
        if !isSeeking {
          isSeeking = true
          onSeekStart()
        }
        updateSeek(from: value.location.x, originX: originX, width: width)
      }
      .onEnded { value in
        guard isSeeking else { return }
        updateSeek(from: value.location.x, originX: originX, width: width)
        onSeekEnd()
        isSeeking = false
      }
  }

  private func playheadSeekGesture(originX: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !isSeeking {
          isSeeking = true
          onSeekStart()
        }
        updateSeek(from: value.location.x, originX: originX, width: width)
      }
      .onEnded { value in
        updateSeek(from: value.location.x, originX: originX, width: width)
        onSeekEnd()
        isSeeking = false
      }
  }

  private func selectionTapGesture(originX: CGFloat, width: CGFloat) -> some Gesture {
    SpatialTapGesture()
      .onEnded { value in
        guard dragAnchor == nil else { return }
        onSeekStart()
        updateSeek(from: value.location.x, originX: originX, width: width)
        onSeekEnd()
      }
  }

  private func handleDrag(kind: HandleKind, originX: CGFloat, width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard !isSeeking else { return }
        if dragAnchor == nil {
          dragAnchor = DragAnchor(kind: kind, startSeconds: selectedStartSeconds, endSeconds: selectedEndSeconds)
          onDragStart()
        }
        var start = selectedStartSeconds
        var end = selectedEndSeconds
        let grabbed = seconds(forX: value.location.x, originX: originX, width: width)
        switch kind {
        case .start:
          start = min(grabbed, selectedEndSeconds)
        case .end:
          end = max(grabbed, selectedStartSeconds)
        case .selection:
          break
        }
        onDragChange(start, end)
      }
      .onEnded { _ in
        onDragEnd(selectedStartSeconds, selectedEndSeconds)
        dragAnchor = nil
      }
  }

  private func selectionDrag(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard !isSeeking else { return }
        if dragAnchor == nil {
          dragAnchor = DragAnchor(kind: .selection, startSeconds: selectedStartSeconds, endSeconds: selectedEndSeconds)
          onDragStart()
        }
        guard let dragAnchor else { return }
        let delta = Double(value.translation.width / max(width, 1)) * totalDuration
        let range = dragAnchor.endSeconds - dragAnchor.startSeconds
        var start = dragAnchor.startSeconds + delta
        start = max(0, min(start, totalDuration - range))
        let end = min(totalDuration, start + range)
        onDragChange(start, end)
      }
      .onEnded { _ in
        onDragEnd(selectedStartSeconds, selectedEndSeconds)
        dragAnchor = nil
      }
  }

  private enum HandleKind {
    case start
    case end
    case selection
  }

  private struct DragAnchor {
    let kind: HandleKind
    let startSeconds: Double
    let endSeconds: Double
  }
}

private struct TimelineGapBand: View {
  let showLabel: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
        .fill(TeslaCamTheme.Colors.gapFill)

      Canvas { context, size in
        var path = Path()
        var x: CGFloat = -size.height
        while x < size.width {
          path.move(to: CGPoint(x: x, y: size.height))
          path.addLine(to: CGPoint(x: x + size.height, y: 0))
          x += 12
        }
        context.stroke(path, with: .color(TeslaCamTheme.Colors.gapAccent.opacity(0.22)), lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous))

      VStack(spacing: 0) {
        Rectangle()
          .fill(TeslaCamTheme.Colors.gapAccent.opacity(0.85))
          .frame(height: 2)
        Spacer()
        Rectangle()
          .fill(TeslaCamTheme.Colors.gapAccent.opacity(0.35))
          .frame(height: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous))

      if showLabel {
        Text("Gap")
          .font(TeslaCamTheme.Typography.label)
          .foregroundStyle(TeslaCamTheme.Colors.textPrimary)
          .padding(.horizontal, TeslaCamTheme.Spacing.s)
          .padding(.vertical, TeslaCamTheme.Spacing.xs)
          .teslaCamCard(fill: TeslaCamTheme.Colors.overlaySurface, radius: TeslaCamTheme.Metrics.compactCorner)
      }
    }
  }
}

private struct PrimaryButtonStyle: ButtonStyle {
  var fixedWidth: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    let width = fixedWidth ?? CompactControlSize.command.visualWidth

    configuration.label
      .font(TeslaCamTheme.Typography.label)
      .foregroundStyle(.white)
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .padding(.horizontal, TeslaCamTheme.Spacing.s)
      .frame(width: width, height: TeslaCamTheme.Metrics.controlHeight)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.accent.opacity(configuration.isPressed ? 0.82 : 1))
      )
      .contentShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.controlCorner, style: .continuous))
  }
}

private struct IconButtonStyle: ButtonStyle {
  var prominent: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(prominent ? .white : TeslaCamTheme.Colors.textPrimary)
      .frame(width: TeslaCamTheme.Metrics.compactControlHeight, height: TeslaCamTheme.Metrics.compactControlHeight)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(prominent ? TeslaCamTheme.Colors.accentSoft : TeslaCamTheme.Colors.surfaceElevated)
      )
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 0.5)
      )
      .opacity(configuration.isPressed ? 0.82 : 1)
      .contentShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous))
  }
}

private struct QuickActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(TeslaCamTheme.Typography.label)
      .foregroundStyle(TeslaCamTheme.Colors.textPrimary.opacity(configuration.isPressed ? 0.78 : 0.95))
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .padding(.horizontal, TeslaCamTheme.Spacing.s)
      .frame(minWidth: CompactControlSize.chip.visualWidth)
      .frame(maxWidth: CompactControlSize.chip.maxWidth)
      .frame(height: TeslaCamTheme.Metrics.compactControlHeight)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surfaceElevated.opacity(configuration.isPressed ? 1 : 0.86))
      )
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 0.5)
      )
      .contentShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous))
  }
}

private struct CompactRangeButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(TeslaCamTheme.Typography.label)
      .foregroundStyle(TeslaCamTheme.Colors.textPrimary.opacity(configuration.isPressed ? 0.78 : 0.95))
      .lineLimit(1)
      .minimumScaleFactor(0.72)
      .frame(width: 56, height: TeslaCamTheme.Metrics.compactControlHeight)
      .background(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .fill(TeslaCamTheme.Colors.surfaceElevated.opacity(configuration.isPressed ? 1 : 0.86))
      )
      .overlay(
        RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous)
          .stroke(TeslaCamTheme.Colors.stroke, lineWidth: 0.5)
      )
      .contentShape(RoundedRectangle(cornerRadius: TeslaCamTheme.Metrics.compactCorner, style: .continuous))
  }
}
