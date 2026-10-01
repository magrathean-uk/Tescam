import Foundation
import Metal
import MetalKit
import AVFoundation

protocol PreviewFrameCaching: AnyObject {
  func texture(
    for camera: Camera,
    at itemTime: CMTime,
    from fileURLs: [Camera: URL],
    cameraDurations: [Camera: Double],
    previousTexture: MTLTexture?,
    onReady: @escaping () -> Void
  ) -> MTLTexture?

  func invalidate(camera: Camera)
}

private final class PreviewImageResultBox: @unchecked Sendable {
  nonisolated(unsafe) var image: CGImage?
}

final class PreviewFrameCache: PreviewFrameCaching {
  private let textureLoader: MTKTextureLoader
  // Sequential-decode path (zero-copy AVAssetReader -> CVMetalTextureCache) used
  // during linear playback; falls back to the image-generator path below for
  // seeks/scrubs/backward motion. nil when no Metal device was supplied (tests).
  private let device: MTLDevice?
  private let metalTextureCache: CVMetalTextureCache?
  private var sequentialDecoders: [Camera: SequentialCameraDecoder] = [:]
  private var lastLinearTime: [Camera: Double] = [:]
  private var fallbackGenerators: [URL: PreviewImageGeneratorBox] = [:]
  private var generatorOrder: [URL] = []
  // Bound the per-URL generator dictionary (previously unbounded — one
  // AVAssetImageGenerator per clip ever opened). ~2 clip-sets of 6 cameras.
  private let maxGenerators = 14
  private let decodeQueue = DispatchQueue(label: "com.magrathean.Tescam.preview-cache", qos: .userInitiated, attributes: .concurrent)
  private let cacheLock = NSLock()
  private let generatorLock = NSLock()
  private var pendingFrameKeys: Set<String> = []
  private var queuedFrameKeysByCamera: [Camera: String] = [:]
  private var lastFrameKeysByCamera: [Camera: String] = [:]
  private var cachedTextures: [String: MTLTexture] = [:]
  private var cachedTextureOrder: [String] = []
  private var cachedTextureBytes = 0
  private let maxCachedTextureCount = 90
  // Byte ceiling on the texture cache. 90 full-res BGRA frames can be ~1.9 GB;
  // cap total bytes so memory stays bounded regardless of frame size.
  private let maxCachedTextureBytes = 256 * 1024 * 1024
  // Frame keys whose decode failed, with the time of the last failure. A
  // corrupt/truncated clip would otherwise be re-queued on every 30 Hz draw
  // (an unbounded decode spin); this backs each failed key off to one retry
  // per interval and lets the tile fall back to black instead of a stale frame.
  private var failedFrameKeys: [String: Date] = [:]
  private let failedFrameRetryInterval: TimeInterval = 1.0

  init(textureLoader: MTKTextureLoader, device: MTLDevice? = nil) {
    self.textureLoader = textureLoader
    self.device = device
    if let device {
      var cache: CVMetalTextureCache?
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
      self.metalTextureCache = cache
    } else {
      self.metalTextureCache = nil
    }
  }

  private func sequentialDecoder(for camera: Camera) -> SequentialCameraDecoder? {
    guard let metalTextureCache else { return nil }
    if let existing = sequentialDecoders[camera] { return existing }
    let decoder = SequentialCameraDecoder(textureCache: metalTextureCache)
    sequentialDecoders[camera] = decoder
    return decoder
  }

  func texture(
    for camera: Camera,
    at itemTime: CMTime,
    from fileURLs: [Camera: URL],
    cameraDurations: [Camera: Double],
    previousTexture: MTLTexture?,
    onReady: @escaping () -> Void
  ) -> MTLTexture? {
    guard let url = fileURLs[camera] else {
      invalidate(camera: camera)
      return nil
    }

    let seconds = max(0, itemTime.seconds.isFinite ? itemTime.seconds : 0)
    if let duration = cameraDurations[camera], seconds > duration + (1.0 / 30.0) {
      invalidate(camera: camera)
      return nil
    }

    // Sequential-decode fast path for linear playback: when time advances
    // forward by a small step within the same clip, drive a per-camera
    // AVAssetReader that decodes in order and hands back zero-copy textures.
    // This delivers native-frame-rate playback without the per-frame
    // random-access GOP decode + main-thread upload the generator path does.
    if let decoder = sequentialDecoder(for: camera) {
      let previousLinear = lastLinearTime[camera]
      let sameClip = decoder.currentURL == url
      let isLinearForward = sameClip
        && previousLinear != nil
        && seconds >= (previousLinear! - 0.05)
        && (seconds - previousLinear!) < 1.0
      if isLinearForward {
        lastLinearTime[camera] = seconds
        if let texture = decoder.requestTexture(url: url, at: seconds, onReady: onReady) {
          lastFrameKeysByCamera[camera] = nil
          return texture
        }
        return previousTexture
      } else {
        // New clip / seek / scrub-backward: position the reader here for the
        // playback that will follow, and serve this instant from the generator
        // path below (fast and tolerant of arbitrary times).
        decoder.reposition(url: url, at: seconds)
        lastLinearTime[camera] = seconds
      }
    }

    let bucket = Int((seconds * 12.0).rounded(.down))
    let frameKey = "\(url.path)#\(bucket)"
    if lastFrameKeysByCamera[camera] == frameKey {
      return previousTexture
    }
    if let texture = cachedTexture(for: frameKey) {
      lastFrameKeysByCamera[camera] = frameKey
      return texture
    }

    // If this exact frame recently failed to decode, don't re-queue it on every
    // draw. Show black (not the previous clip's stale frame) until the backoff
    // window elapses, then allow a single retry.
    if let failedAt = recentDecodeFailure(for: frameKey) {
      if Date().timeIntervalSince(failedAt) < failedFrameRetryInterval {
        return nil
      }
      clearDecodeFailure(for: frameKey)
    }

    queuePreviewDecode(camera: camera, frameKey: frameKey, url: url, seconds: seconds, onReady: onReady)
    return previousTexture
  }

  func invalidate(camera: Camera) {
    cacheLock.lock()
    lastFrameKeysByCamera[camera] = nil
    queuedFrameKeysByCamera[camera] = nil
    cacheLock.unlock()
    lastLinearTime[camera] = nil
    sequentialDecoders[camera]?.tearDown()
  }

  private func queuePreviewDecode(
    camera: Camera,
    frameKey: String,
    url: URL,
    seconds: Double,
    onReady: @escaping () -> Void
  ) {
    guard beginQueuedDecode(camera: camera, frameKey: frameKey) else { return }

    decodeQueue.async { [weak self] in
      guard let self else { return }
      guard self.shouldDecode(camera: camera, frameKey: frameKey) else {
        self.finishQueuedDecode(camera: camera, frameKey: frameKey)
        return
      }

      let image = self.copyPreviewImage(url: url, seconds: seconds)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        defer {
          self.finishQueuedDecode(camera: camera, frameKey: frameKey)
          onReady()
        }

        guard let image,
              let texture = try? self.textureLoader.newTexture(
                cgImage: image,
                options: [MTKTextureLoader.Option.SRGB: false]
              )
        else {
          // Decode/upload failed — record it so the draw loop backs off
          // instead of re-queuing this frame 30 times a second.
          self.recordDecodeFailure(for: frameKey)
          return
        }

        self.clearDecodeFailure(for: frameKey)
        self.storeCachedTexture(texture, for: frameKey)
      }
    }
  }

  private func copyPreviewImage(url: URL, seconds: Double) -> CGImage? {
    generatorLock.lock()
    let generator: PreviewImageGeneratorBox
    if let existing = fallbackGenerators[url] {
      generator = existing
      generatorOrder.removeAll { $0 == url }
      generatorOrder.append(url)
    } else {
      let asset = AVURLAsset(url: url)
      // Half a frame (~1 cache bucket) instead of ±1.0s. The old 1-second
      // tolerance let adjacent camera tiles show frames up to ~2s apart while
      // presented as simultaneous — wrong for incident review. The remaining
      // small ladder only covers keyframe-sparse clips.
      let tolerance = CMTime(value: 1, timescale: 48)
      let box = PreviewImageGeneratorBox(asset: asset, tolerance: tolerance)
      fallbackGenerators[url] = box
      generatorOrder.append(url)
      while generatorOrder.count > maxGenerators {
        let evicted = generatorOrder.removeFirst()
        fallbackGenerators.removeValue(forKey: evicted)
      }
      generator = box
    }
    generatorLock.unlock()

    let attempts = [seconds, max(0, seconds - 1.0 / 24.0), seconds + 1.0 / 24.0, seconds + 1.0 / 12.0]
    for candidate in attempts {
      if let image = waitForImage(from: generator, at: CMTime(seconds: candidate, preferredTimescale: 600)) {
        return image
      }
    }
    return nil
  }

  private func waitForImage(from generator: PreviewImageGeneratorBox, at time: CMTime) -> CGImage? {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = PreviewImageResultBox()
    Task.detached(priority: .userInitiated) {
      resultBox.image = await generator.image(at: time)
      semaphore.signal()
    }
    semaphore.wait()
    return resultBox.image
  }

  private func beginQueuedDecode(camera: Camera, frameKey: String) -> Bool {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    queuedFrameKeysByCamera[camera] = frameKey
    if pendingFrameKeys.contains(frameKey) {
      return false
    }
    pendingFrameKeys.insert(frameKey)
    return true
  }

  private func shouldDecode(camera: Camera, frameKey: String) -> Bool {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return queuedFrameKeysByCamera[camera] == frameKey
  }

  private func finishQueuedDecode(camera: Camera, frameKey: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    pendingFrameKeys.remove(frameKey)
    if queuedFrameKeysByCamera[camera] == frameKey {
      queuedFrameKeysByCamera[camera] = nil
    }
  }

  private func cachedTexture(for frameKey: String) -> MTLTexture? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return cachedTextures[frameKey]
  }

  private func storeCachedTexture(_ texture: MTLTexture, for frameKey: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if let existing = cachedTextures[frameKey] {
      cachedTextureBytes -= Self.textureByteSize(existing)
    }
    cachedTextures[frameKey] = texture
    cachedTextureBytes += Self.textureByteSize(texture)
    cachedTextureOrder.removeAll { $0 == frameKey }
    cachedTextureOrder.append(frameKey)
    // Evict by count AND by total bytes — 90 full-res BGRA frames can exceed
    // 1.9 GB, so the byte ceiling is the real bound. Keep at least one frame.
    while cachedTextureOrder.count > 1,
          cachedTextureOrder.count > maxCachedTextureCount || cachedTextureBytes > maxCachedTextureBytes {
      let oldest = cachedTextureOrder.removeFirst()
      if let evicted = cachedTextures.removeValue(forKey: oldest) {
        cachedTextureBytes -= Self.textureByteSize(evicted)
      }
    }
  }

  private static func textureByteSize(_ texture: MTLTexture) -> Int {
    // 4 bytes per pixel for the BGRA preview textures.
    max(0, texture.width * texture.height * 4)
  }

  private func recordDecodeFailure(for frameKey: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    failedFrameKeys[frameKey] = Date()
    // Keep the failure map bounded; drop entries already past their backoff.
    if failedFrameKeys.count > 256 {
      let now = Date()
      failedFrameKeys = failedFrameKeys.filter { now.timeIntervalSince($0.value) < failedFrameRetryInterval }
    }
  }

  private func recentDecodeFailure(for frameKey: String) -> Date? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return failedFrameKeys[frameKey]
  }

  private func clearDecodeFailure(for frameKey: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    failedFrameKeys.removeValue(forKey: frameKey)
  }
}

private actor PreviewImageGeneratorBox {
  private let generator: AVAssetImageGenerator

  init(asset: AVAsset, tolerance: CMTime) {
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
  }

  func image(at time: CMTime) async -> CGImage? {
    try? await generator.image(at: time).image
  }
}

/// Per-camera sequential video decoder for linear playback. Runs an
/// `AVAssetReader` that decodes BGRA frames in order on a background queue and
/// publishes the most recent frame at/just-before the requested time as a
/// zero-copy Metal texture (via `CVMetalTextureCache`). Returning nil is safe —
/// `PreviewFrameCache` falls back to its image-generator path.
private final class SequentialCameraDecoder {
  private let textureCache: CVMetalTextureCache
  private let queue = DispatchQueue(label: "com.magrathean.Tescam.seq-decoder", qos: .userInitiated)
  private let lock = NSLock()

  // Lock-guarded state shared with the main (draw) thread.
  private var _currentURL: URL?
  private var current: (time: Double, texture: MTLTexture, retain: CVMetalTexture)?
  private var decoding = false

  // Decode-thread-only state.
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var readerURL: URL?
  private var pending: CMSampleBuffer?

  init(textureCache: CVMetalTextureCache) {
    self.textureCache = textureCache
  }

  var currentURL: URL? {
    lock.lock(); defer { lock.unlock() }
    return _currentURL
  }

  /// Returns the most recent decoded texture (or nil) and schedules a forward
  /// decode toward `target`. Non-blocking; safe to call every draw.
  func requestTexture(url: URL, at target: Double, onReady: @escaping () -> Void) -> MTLTexture? {
    lock.lock()
    let tex = current?.texture
    let needAdvance = (_currentURL == url) && (current == nil || current!.time < target - 0.001)
    let willDispatch = needAdvance && !decoding
    if willDispatch { decoding = true }
    lock.unlock()

    if willDispatch {
      queue.async { [weak self] in self?.advance(url: url, to: target, onReady: onReady) }
    }
    return tex
  }

  /// Point the reader at `seconds` in `url` for the playback that follows a
  /// seek / clip change. The instant itself is served by the generator path.
  func reposition(url: URL, at seconds: Double) {
    lock.lock()
    let sameURL = (_currentURL == url)
    _currentURL = url
    if !sameURL { current = nil }
    let willDispatch = !decoding
    if willDispatch { decoding = true }
    lock.unlock()

    if willDispatch {
      queue.async { [weak self] in
        guard let self else { return }
        self.recreateReader(url: url, at: seconds)
        self.lock.lock(); self.decoding = false; self.lock.unlock()
      }
    }
  }

  func tearDown() {
    queue.async { [weak self] in
      guard let self else { return }
      self.reader?.cancelReading()
      self.reader = nil
      self.output = nil
      self.readerURL = nil
      self.pending = nil
      self.lock.lock()
      self.current = nil
      self._currentURL = nil
      self.decoding = false
      self.lock.unlock()
    }
  }

  // MARK: - Decode thread

  private func advance(url: URL, to target: Double, onReady: @escaping () -> Void) {
    if readerURL != url {
      recreateReader(url: url, at: target)
    }
    guard let output, let reader, reader.status == .reading else {
      lock.lock(); decoding = false; lock.unlock()
      return
    }
    var produced = false
    let epsilon = 1.0 / 120.0
    while true {
      let sample = pending ?? output.copyNextSampleBuffer()
      pending = nil
      guard let sample else { break } // EOF: keep the last frame
      let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard pts.isFinite else { continue }
      if pts <= target + epsilon {
        if let imageBuffer = CMSampleBufferGetImageBuffer(sample),
           let made = makeTexture(from: imageBuffer) {
          lock.lock()
          current = (pts, made.texture, made.retain)
          lock.unlock()
          produced = true
        }
      } else {
        pending = sample // future frame; consume on the next advance
        break
      }
    }
    lock.lock(); decoding = false; lock.unlock()
    if produced { DispatchQueue.main.async { onReady() } }
  }

  private func recreateReader(url: URL, at seconds: Double) {
    reader?.cancelReading()
    reader = nil; output = nil; pending = nil; readerURL = nil

    let asset = AVURLAsset(url: url)
    guard let track = loadFirstVideoTrack(asset),
          let newReader = try? AVAssetReader(asset: asset) else { return }
    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    newOutput.alwaysCopiesSampleData = false
    guard newReader.canAdd(newOutput) else { return }
    newReader.add(newOutput)
    if seconds > 0.05 {
      newReader.timeRange = CMTimeRange(
        start: CMTime(seconds: seconds, preferredTimescale: 600),
        duration: .positiveInfinity
      )
    }
    guard newReader.startReading() else { return }
    reader = newReader
    output = newOutput
    readerURL = url
  }

  private func loadFirstVideoTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: AVAssetTrack?
    Task.detached(priority: .userInitiated) {
      result = try? await asset.loadTracks(withMediaType: .video).first
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }

  private func makeTexture(from pixelBuffer: CVPixelBuffer) -> (texture: MTLTexture, retain: CVMetalTexture)? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return nil }
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, pixelBuffer, nil,
      .bgra8Unorm, width, height, 0, &cvTexture
    )
    guard status == kCVReturnSuccess,
          let cvTexture,
          let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
    return (texture, cvTexture)
  }
}

final class MetalRenderer: NSObject, MTKViewDelegate {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private let vertexBuffer: MTLBuffer
  private let blackTexture: MTLTexture
  private weak var view: MTKView?
  private let frameCache: PreviewFrameCaching

  var cameraOrder: [Camera] = []
  var layoutRequest: CameraLayoutRequest = .auto
  var previewLayoutMode: PreviewLayoutMode = .grid
  var focusedCamera: Camera?
  var naturalSizes: [Camera: CGSize] = [:]
  var itemTimeProvider: (() -> CMTime)?
  var fileURLsProvider: (() -> [Camera: URL])?
  var cameraDurationsProvider: (() -> [Camera: Double])?

  private var lastTextures: [Camera: MTLTexture] = [:]

  init?(mtkView: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    self.device = device
    self.view = mtkView
    guard let queue = device.makeCommandQueue() else { return nil }
    self.commandQueue = queue
    self.frameCache = PreviewFrameCache(textureLoader: MTKTextureLoader(device: device), device: device)

    mtkView.device = device
    mtkView.colorPixelFormat = .bgra8Unorm
    mtkView.framebufferOnly = false

    guard let lib = MetalRenderer.loadLibrary(device: device),
          let vertexFunc = lib.makeFunction(name: "vertex_main"),
          let fragFunc = lib.makeFunction(name: "fragment_main") else { return nil }

    let pipelineDesc = MTLRenderPipelineDescriptor()
    pipelineDesc.vertexFunction = vertexFunc
    pipelineDesc.fragmentFunction = fragFunc
    pipelineDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

    do {
      pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
    } catch {
      return nil
    }

    let samplerDesc = MTLSamplerDescriptor()
    samplerDesc.minFilter = .linear
    samplerDesc.magFilter = .linear
    samplerDesc.sAddressMode = .clampToEdge
    samplerDesc.tAddressMode = .clampToEdge
    sampler = device.makeSamplerState(descriptor: samplerDesc)!

    let quad: [Float] = [
      -1, -1, 0, 1,
       1, -1, 1, 1,
      -1,  1, 0, 0,
       1, -1, 1, 1,
       1,  1, 1, 0,
      -1,  1, 0, 0
    ]
    vertexBuffer = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<Float>.size, options: [])!

    let blackDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
    blackDesc.usage = [.shaderRead]
    blackTexture = device.makeTexture(descriptor: blackDesc)!
    var blackPixel: [UInt8] = [0, 0, 0, 255]
    blackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &blackPixel, bytesPerRow: 4)

    super.init()
  }

  private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    guard let url = bundle.url(forResource: "MetalShaders", withExtension: "metal") else {
      return device.makeDefaultLibrary()
    }
    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      return try device.makeLibrary(source: source, options: nil)
    } catch {
      return device.makeDefaultLibrary()
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let pass = view.currentRenderPassDescriptor else { return }

    let itemTime = itemTimeProvider?() ?? .zero
    let fileURLs = fileURLsProvider?() ?? [:]
    let cameraDurations = cameraDurationsProvider?() ?? [:]
    for camera in cameraOrder {
      let onReady: () -> Void = { [weak view] in
        guard let view else { return }
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
      }
      if let texture = frameCache.texture(
        for: camera,
        at: itemTime,
        from: fileURLs,
        cameraDurations: cameraDurations,
        previousTexture: lastTextures[camera],
        onReady: onReady
      ) {
        lastTextures[camera] = texture
      } else {
        lastTextures[camera] = nil
      }
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)

    let w = Double(view.drawableSize.width)
    let h = Double(view.drawableSize.height)
    let viewSize = CGSize(width: w, height: h)
    let viewports = previewViewports(in: viewSize)

    for (camera, tileViewport) in viewports {
      let texture = lastTextures[camera] ?? blackTexture
      let viewport = aspectFitViewport(
        tile: tileViewport,
        textureWidth: texture.width,
        textureHeight: texture.height
      )
      encoder.setViewport(viewport)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func previewViewports(in size: CGSize) -> [(Camera, MTLViewport)] {
    let width = max(1, Double(size.width))
    let height = max(1, Double(size.height))
    let cameras = cameraOrder.filter { camera in
      cameraOrder.contains(camera)
    }
    let visible = cameras.isEmpty ? Camera.hw3ClassicOrder : cameras

    switch previewLayoutMode {
    case .focus:
      let camera = focusedCamera.flatMap { visible.contains($0) ? $0 : nil } ?? visible[0]
      return [(camera, fullViewport(width: width, height: height))]

    case .frontRear:
      let pair = [.front, .back].filter { visible.contains($0) }
      let shown = pair.isEmpty ? Array(visible.prefix(2)) : pair
      guard shown.count > 1 else {
        return [(shown.first ?? visible[0], fullViewport(width: width, height: height))]
      }
      return [
        (shown[0], MTLViewport(originX: 0, originY: 0, width: width / 2, height: height, znear: 0, zfar: 1)),
        (shown[1], MTLViewport(originX: width / 2, originY: 0, width: width / 2, height: height, znear: 0, zfar: 1))
      ]

    case .horizontal:
      let tileWidth = width / Double(max(1, visible.count))
      return visible.enumerated().map { index, camera in
        (
          camera,
          MTLViewport(
            originX: Double(index) * tileWidth,
            originY: 0,
            width: tileWidth,
            height: height,
            znear: 0,
            zfar: 1
          )
        )
      }

    case .pictureInPicture:
      let main = focusedCamera.flatMap { visible.contains($0) ? $0 : nil } ?? visible.first ?? .front
      var result: [(Camera, MTLViewport)] = [(main, fullViewport(width: width, height: height))]
      let extras = visible.filter { $0 != main }
      let pipWidth = width * 0.22
      let pipHeight = height * 0.22
      let gap = max(8, min(width, height) * 0.012)
      for (index, camera) in extras.prefix(4).enumerated() {
        let x = width - pipWidth - gap
        let y = gap + Double(index) * (pipHeight + gap)
        result.append(
          (
            camera,
            MTLViewport(originX: x, originY: y, width: pipWidth, height: pipHeight, znear: 0, zfar: 1)
          )
        )
      }
      return result

    case .grid:
      let detected = Set(visible)
      let layout = CameraLayoutPlan.build(
        requestedProfile: layoutRequest,
        detectedCameras: detected,
        enabledCameras: detected,
        naturalSizes: naturalSizes
      )
      let scaleX = width / max(1, Double(layout.canvasSize.width))
      let scaleY = height / max(1, Double(layout.canvasSize.height))
      return layout.renderOrder.compactMap { camera in
        guard detected.contains(camera), let cell = layout.cellByCamera[camera] else { return nil }
        return (
          camera,
          MTLViewport(
            originX: Double(cell.minX) * scaleX,
            originY: Double(cell.minY) * scaleY,
            width: Double(cell.width) * scaleX,
            height: Double(cell.height) * scaleY,
            znear: 0,
            zfar: 1
          )
        )
      }
    }
  }

  private func fullViewport(width: Double, height: Double) -> MTLViewport {
    MTLViewport(originX: 0, originY: 0, width: width, height: height, znear: 0, zfar: 1)
  }

  private func aspectFitViewport(tile: MTLViewport, textureWidth: Int, textureHeight: Int) -> MTLViewport {
    guard textureWidth > 0, textureHeight > 0, tile.width > 0, tile.height > 0 else {
      return tile
    }

    let sourceAspect = Double(textureWidth) / Double(textureHeight)
    let tileAspect = tile.width / tile.height

    if sourceAspect > tileAspect {
      let fittedHeight = tile.width / sourceAspect
      let yInset = (tile.height - fittedHeight) / 2
      return MTLViewport(
        originX: tile.originX,
        originY: tile.originY + yInset,
        width: tile.width,
        height: fittedHeight,
        znear: tile.znear,
        zfar: tile.zfar
      )
    } else {
      let fittedWidth = tile.height * sourceAspect
      let xInset = (tile.width - fittedWidth) / 2
      return MTLViewport(
        originX: tile.originX + xInset,
        originY: tile.originY,
        width: fittedWidth,
        height: tile.height,
        znear: tile.znear,
        zfar: tile.zfar
      )
    }
  }
}
