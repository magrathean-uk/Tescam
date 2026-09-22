#if os(macOS)
import SwiftUI

struct MacLoadedWorkspace: View {
  @ObservedObject var state: AppState
  @ObservedObject var playback: MultiCamPlaybackController
  @ObservedObject var playbackUI: PlaybackUIState
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  let timelineMarkers: [Date]
  let isSingleDayTimeline: Bool
  let loadedContentMaxWidth: CGFloat
  let maxPreviewHeight: CGFloat

  var body: some View {
    GeometryReader { proxy in
      MacTimelineWorkspace(
        state: state,
        playback: playback,
        playbackUI: playbackUI,
        timelineMarkers: timelineMarkers,
        isSingleDayTimeline: isSingleDayTimeline,
        loadedContentMaxWidth: max(980, proxy.size.width - TeslaCamTheme.Metrics.contentPadding * 2),
        maxPreviewHeight: maxPreviewHeight
      )
    }
  }
}

struct MacEventSidebar: View {
  @ObservedObject var state: AppState

  var body: some View {
    let events = state.filteredEventSummaries

    VStack(spacing: 0) {
      List {
        Section("Source") {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(sourceTitle)
                .lineLimit(1)
              Text(sourceDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          } icon: {
            Image(systemName: "externaldrive")
          }

          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(state.scanDateRangeSummary)
                .lineLimit(1)
              Text(state.scanDurationSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          } icon: {
            Image(systemName: "calendar")
          }
        }

        Section {
          Picker("Sort", selection: $state.eventSortMode) {
            ForEach(TeslaCamEventSortMode.allCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }

          Picker("Type", selection: Binding(
            get: { state.eventReasonFilter == "all" ? "All" : state.eventReasonFilter },
            set: { state.eventReasonFilter = $0 == "All" ? "all" : $0 }
          )) {
            ForEach(state.eventReasonOptions, id: \.self) { reason in
              Text(reason).tag(reason)
            }
          }
        } header: {
          Text("Events")
        } footer: {
          Text("\(events.count) matching event\(events.count == 1 ? "" : "s")")
        }

        Section {
          if events.isEmpty {
            Label {
              Text("No matching events")
                .foregroundStyle(.secondary)
            } icon: {
              Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            }
          } else {
            ForEach(events) { event in
              MacEventRow(
                event: event,
                active: state.currentEvent?.id == event.id
              ) {
                state.jumpToEvent(event)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
    }
    .searchable(text: $state.eventSearchText, prompt: "Search Events")
    .accessibilityIdentifier("event-browser")
  }

  private var sourceTitle: String {
    state.rootURL?.lastPathComponent ?? "Tescam"
  }

  private var sourceDetail: String {
    "\(state.clipSets.count) spans, \(state.totalMergedFileCount) clips"
  }
}

private struct MacEventRow: View {
  let event: TeslaCamEventSummary
  let active: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: active ? "record.circle.fill" : "record.circle")
          .foregroundStyle(active ? TeslaCamTheme.Colors.accent : .secondary)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: TeslaCamTheme.Spacing.xs) {
          Text(event.locationTitle)
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text("\(TeslaCamFormatters.timelineSameDay.string(from: event.timestamp)) · \(event.reasonTitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("event-row")
  }
}
#endif
