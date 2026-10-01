import Foundation
import Combine
import AVFoundation
import QuartzCore

final class MultiCamPlaybackController: ObservableObject {
  @Published var isPlaying: Bool = false
  @Published private(set) var redrawTick: Int = 0

  var onTimeUpdate: ((Double) -> Void)?
  var onFinished: (() -> Void)?

  private(set) var files: [Camera: URL] = [:]
  private(set) var cameraDurations: [Camera: Double] = [:]
  private(set) var currentDuration: Double = 0
  var playbackRate: Double = 1.0
  private var currentSecondsValue: Double = 0
  private var timer: Timer?
  private var lastTickHostTime: CFTimeInterval = 0
  private let timeProvider: () -> CFTimeInterval
  private let uiUpdateInterval: TimeInterval = 1.0 / 12.0

  init(timeProvider: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
    self.timeProvider = timeProvider
  }

  func currentItemTime() -> CMTime {
    CMTime(seconds: projectedCurrentSeconds(), preferredTimescale: 600)
  }

  func load(set: ClipSet, startSeconds: Double = 0) {
    load(files: set.files, cameraDurations: set.cameraDurations, duration: max(0.1, set.duration), startSeconds: startSeconds)
  }

  func loadGap(duration: Double, startSeconds: Double = 0) {
    load(files: [:], cameraDurations: [:], duration: duration, startSeconds: startSeconds)
  }

  func load(
    files: [Camera: URL],
    cameraDurations: [Camera: Double] = [:],
    duration: Double,
    startSeconds: Double = 0
  ) {
    pause()
    self.files = files
    self.cameraDurations = cameraDurations
    currentDuration = max(0.1, duration)
    currentSecondsValue = min(max(0, startSeconds), currentDuration)
    lastTickHostTime = timeProvider()
    onTimeUpdate?(currentSecondsValue)
    publishRedrawTick()
  }

  func play() {
    guard currentDuration > 0, !isPlaying else { return }
    isPlaying = true
    publishRedrawTick()
    lastTickHostTime = timeProvider()
    let timer = Timer(timeInterval: uiUpdateInterval, repeats: true) { [weak self] _ in
      self?.advancePlayback()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func pause() {
    if isPlaying {
      currentSecondsValue = projectedCurrentSeconds()
      lastTickHostTime = timeProvider()
    }
    timer?.invalidate()
    timer = nil
    isPlaying = false
  }

  func stop() {
    pause()
    files.removeAll()
    cameraDurations.removeAll()
    currentDuration = 0
    currentSecondsValue = 0
  }

  func seek(to seconds: Double, exact: Bool = true) {
    let _ = exact
    currentSecondsValue = min(max(0, seconds), currentDuration)
    lastTickHostTime = timeProvider()
    onTimeUpdate?(currentSecondsValue)
    publishRedrawTick()
  }

  private func projectedCurrentSeconds() -> Double {
    guard isPlaying else { return currentSecondsValue }
    let elapsed = max(0, timeProvider() - lastTickHostTime)
    return min(currentDuration, currentSecondsValue + (elapsed * max(0.1, playbackRate)))
  }

  private func advancePlayback() {
    guard isPlaying else { return }
    let now = timeProvider()
    let delta = max(0, now - lastTickHostTime)
    lastTickHostTime = now
    currentSecondsValue = min(currentDuration, currentSecondsValue + (delta * max(0.1, playbackRate)))
    onTimeUpdate?(currentSecondsValue)
    publishRedrawTick()

    if currentSecondsValue >= currentDuration {
      pause()
      onFinished?()
    }
  }

  private func publishRedrawTick() {
    redrawTick = redrawTick == Int.max ? 0 : redrawTick + 1
  }
}
