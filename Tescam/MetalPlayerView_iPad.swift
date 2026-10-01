#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation
import MetalKit

struct MetalPlayerView: UIViewRepresentable {
  @ObservedObject var playback: MultiCamPlaybackController
  var cameraOrder: [Camera]
  var layoutRequest: CameraLayoutRequest = .auto
  var previewLayoutMode: PreviewLayoutMode = .grid
  var focusedCamera: Camera?
  var naturalSizes: [Camera: CGSize] = [:]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView()
    view.backgroundColor = UIColor.black
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.preferredFramesPerSecond = 30

    if let renderer = MetalRenderer(mtkView: view) {
      context.coordinator.renderer = renderer
      applyState(to: renderer)
      view.delegate = renderer
    }

    return view
  }

  func updateUIView(_ uiView: MTKView, context: Context) {
    guard let renderer = context.coordinator.renderer else { return }
    applyState(to: renderer)
    uiView.setNeedsDisplay()
  }

  static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
    uiView.delegate = nil
    coordinator.renderer = nil
  }

  private func applyState(to renderer: MetalRenderer) {
    renderer.cameraOrder = cameraOrder
    renderer.layoutRequest = layoutRequest
    renderer.previewLayoutMode = previewLayoutMode
    renderer.focusedCamera = focusedCamera
    renderer.naturalSizes = naturalSizes
    renderer.itemTimeProvider = { playback.currentItemTime() }
    renderer.fileURLsProvider = { playback.files }
    renderer.cameraDurationsProvider = { playback.cameraDurations }
  }

  final class Coordinator: NSObject {
    var renderer: MetalRenderer?
  }
}
#endif
