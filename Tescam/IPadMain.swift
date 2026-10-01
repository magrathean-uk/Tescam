#if os(iOS)
import SwiftUI
@main
struct TescamIPadApp: App {
  @StateObject private var state = AppState()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(state)
    }
    .onChange(of: scenePhase) { _, phase in
      // Stop the playback tick + Metal redraw when leaving the foreground so a
      // backgrounded app isn't burning CPU/battery on a hidden video.
      if phase != .active, state.playback.isPlaying {
        state.togglePlay()
      }
    }
    .commands {
      CommandMenu("Playback") {
        Button("Play/Pause") {
          state.togglePlay()
        }
        .keyboardShortcut(.space, modifiers: [])

        Button("Back 5s") {
          state.stepPlayback(by: -5)
        }
        .keyboardShortcut(.leftArrow, modifiers: [])

        Button("Forward 5s") {
          state.stepPlayback(by: 5)
        }
        .keyboardShortcut(.rightArrow, modifiers: [])

        Button("Next Event") {
          state.jumpToNextEvent(direction: 1)
        }
        .keyboardShortcut(.downArrow, modifiers: [])

        Button("Previous Event") {
          state.jumpToNextEvent(direction: -1)
        }
        .keyboardShortcut(.upArrow, modifiers: [])

        Button("Playback Speed") {
          state.cyclePlaybackRate()
        }
        .keyboardShortcut("]", modifiers: [])
      }
    }
  }
}
#endif
