#if canImport(Flutter)
  import AVFoundation
  import AVKit
  import CoreMedia
  import Flutter
  import UIKit

  /// Bridges `AVPictureInPictureController` with a `media_kit_video`
  /// `VideoOutput` frame source. Requires iOS 15+ to compile-guard access to
  /// `AVSampleBufferDisplayLayer`-based PiP APIs.
  @available(iOS 15.0, *)
  final class MediaKitPictureInPictureController: NSObject {
    typealias EventCallback = ([String: Any]) -> Void

    private let hostView: UIView
    private let outputManager: VideoOutputManager
    private let eventCallback: EventCallback
    private let displayLayer: AVSampleBufferDisplayLayer
    private var pipController: AVPictureInPictureController?
    private let enqueueQueue = DispatchQueue(
      label: "com.alexmercerind.media_kit_video.pip.enqueue",
      qos: .userInteractive
    )

    private var handle: Int64?
    private var isPlayingState: Bool = true
    private var isLiveState: Bool = false
    private var playbackPositionSeconds: Double = 0
    private var playbackDurationSeconds: Double = 0
    private var playbackRate: Double = 1
    private var playbackAnchorTime: CMTime = .zero
    private var startRequested: Bool = false
    private var firstFrameEnqueued: Bool = false
    private var startAttempts: Int = 0
    private var didRestoreInterface: Bool = false

    init(
      hostView: UIView,
      outputManager: VideoOutputManager,
      videoSize: CGSize,
      eventCallback: @escaping EventCallback
    ) {
      self.hostView = hostView
      self.outputManager = outputManager
      self.eventCallback = eventCallback
      self.displayLayer = AVSampleBufferDisplayLayer()
      super.init()

      // Keep the display layer as a tiny transparent sublayer so Flutter's
      // texture view remains the primary on-screen surface.
      displayLayer.videoGravity = .resizeAspect
      displayLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
      displayLayer.isOpaque = false
      displayLayer.backgroundColor = UIColor.clear.cgColor
      hostView.layer.insertSublayer(displayLayer, at: 0)
    }

    deinit {
      teardown()
    }

    var isActive: Bool {
      return pipController?.isPictureInPictureActive ?? false
    }

    @discardableResult
    func start(
      handle: Int64,
      positionSeconds: Double,
      durationSeconds: Double,
      isLive: Bool,
      isPlaying: Bool,
      playbackRate: Double,
      autoEnter: Bool,
      startImmediately: Bool
    ) -> Bool {
      self.handle = handle
      updatePlaybackState(
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
        isLive: isLive,
        isPlaying: isPlaying,
        playbackRate: playbackRate
      )

      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      // On current iOS SDKs this initializer is non-optional. Older /
      // transitional SDKs marked it failable; avoid `guard let` so both
      // compile paths stay valid on GitHub Actions macOS runners.
      let controller = AVPictureInPictureController(contentSource: contentSource)
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter
      self.pipController = controller

      outputManager.setOnFrameRendered(handle: handle) { [weak self] pixelBuffer in
        self?.enqueue(pixelBuffer: pixelBuffer)
      }

      self.startRequested = startImmediately
      self.firstFrameEnqueued = false
      self.startAttempts = 0
      return true
    }

    private func attemptStart() {
      guard let controller = pipController else { return }
      if controller.isPictureInPictureActive { return }
      if controller.isPictureInPicturePossible {
        controller.startPictureInPicture()
        return
      }
      startAttempts += 1
      if startAttempts >= 20 {
        eventCallback(["event": "failed", "reason": "pip_not_possible"])
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.attemptStart()
      }
    }

    func stop() {
      if let controller = pipController, controller.isPictureInPictureActive {
        DispatchQueue.main.async { controller.stopPictureInPicture() }
      }
      teardown()
    }

    func setAutoEnter(_ enabled: Bool) {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func updatePlaybackState(
      positionSeconds: Double,
      durationSeconds: Double,
      isLive: Bool,
      isPlaying: Bool,
      playbackRate: Double
    ) {
      self.playbackPositionSeconds = max(0, positionSeconds)
      self.playbackDurationSeconds = max(0, durationSeconds)
      self.isLiveState = isLive
      self.isPlayingState = isPlaying
      self.playbackRate = playbackRate > 0 ? playbackRate : 1
      self.playbackAnchorTime = currentHostTime()
      pipController?.invalidatePlaybackState()
    }

    private func currentHostTime() -> CMTime {
      return CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func currentPlaybackPosition(at hostTime: CMTime? = nil) -> Double {
      var position = playbackPositionSeconds
      if isPlayingState {
        let elapsed = CMTimeGetSeconds(
          CMTimeSubtract(hostTime ?? currentHostTime(), playbackAnchorTime)
        )
        if elapsed.isFinite && elapsed > 0 {
          position += elapsed * playbackRate
        }
      }
      if playbackDurationSeconds > 0 {
        return min(max(0, position), playbackDurationSeconds)
      }
      return max(0, position)
    }

    private func snapshotPlaybackPosition() {
      playbackPositionSeconds = currentPlaybackPosition()
      playbackAnchorTime = currentHostTime()
    }

    private func teardown() {
      if let handle = handle {
        outputManager.setOnFrameRendered(handle: handle, nil)
        self.handle = nil
      }
      pipController = nil
      displayLayer.flushAndRemoveImage()
      displayLayer.removeFromSuperlayer()
    }

    private func enqueue(pixelBuffer: CVPixelBuffer) {
      let retained = pixelBuffer
      enqueueQueue.async { [weak self] in
        guard let self = self else { return }
        guard self.displayLayer.isReadyForMoreMediaData else { return }
        guard let sample = self.makeSampleBuffer(from: retained) else { return }
        self.displayLayer.enqueue(sample)
        if !self.firstFrameEnqueued {
          self.firstFrameEnqueued = true
          if self.startRequested {
            DispatchQueue.main.async { [weak self] in
              self?.attemptStart()
            }
          }
        }
      }
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
      var formatDescription: CMVideoFormatDescription?
      let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
      guard fdStatus == noErr, let description = formatDescription else { return nil }

      let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
      var timingInfo = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
      )

      var sampleBuffer: CMSampleBuffer?
      let status = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: description,
        sampleTiming: &timingInfo,
        sampleBufferOut: &sampleBuffer
      )
      guard status == noErr, let buffer = sampleBuffer else { return nil }

      if let attachments = CMSampleBufferGetSampleAttachmentsArray(
        buffer,
        createIfNecessary: true
      ) as? [NSMutableDictionary],
        let first = attachments.first
      {
        first[kCMSampleAttachmentKey_DisplayImmediately as NSString] = kCFBooleanTrue
      }
      return buffer
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      eventCallback(["event": "willStart"])
    }

    func pictureInPictureControllerDidStartPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      eventCallback(["event": "didStart"])
    }

    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      failedToStartPictureInPictureWithError error: Error
    ) {
      eventCallback(["event": "failed", "reason": error.localizedDescription])
    }

    func pictureInPictureControllerWillStopPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      didRestoreInterface = false
      eventCallback(["event": "willStop"])
    }

    func pictureInPictureControllerDidStopPictureInPicture(
      _ controller: AVPictureInPictureController
    ) {
      if didRestoreInterface {
        eventCallback(["event": "didStop"])
      } else {
        eventCallback(["event": "closed"])
      }
      didRestoreInterface = false
    }

    func pictureInPictureController(
      _ controller: AVPictureInPictureController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
        @escaping (Bool) -> Void
    ) {
      didRestoreInterface = true
      eventCallback(["event": "restore"])
      completionHandler(true)
    }
  }

  @available(iOS 15.0, *)
  extension MediaKitPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      setPlaying playing: Bool
    ) {
      snapshotPlaybackPosition()
      isPlayingState = playing
      eventCallback(["event": "setPlaying", "playing": playing])
      pipController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
      _ pipController: AVPictureInPictureController
    ) -> CMTimeRange {
      if isLiveState {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
      }
      guard playbackDurationSeconds > 0 else {
        return .invalid
      }

      // AVKit requires a finite VOD range to contain the current time of the
      // sample-buffer layer's host-clock timeline. Subtracting the media
      // position from "now" maps that timeline back to media time zero.
      let now = currentHostTime()
      let position = CMTime(
        seconds: currentPlaybackPosition(at: now),
        preferredTimescale: 1_000
      )
      let start = CMTimeSubtract(now, position)
      let duration = CMTime(
        seconds: playbackDurationSeconds,
        preferredTimescale: 1_000
      )
      return CMTimeRange(start: start, duration: duration)
    }

    func pictureInPictureControllerIsPlaybackPaused(
      _ pipController: AVPictureInPictureController
    ) -> Bool {
      return !isPlayingState
    }

    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
    }

    func pictureInPictureController(
      _ pipController: AVPictureInPictureController,
      skipByInterval skipInterval: CMTime,
      completion completionHandler: @escaping () -> Void
    ) {
      let intervalMs = CMTimeGetSeconds(skipInterval) * 1000.0
      snapshotPlaybackPosition()
      playbackPositionSeconds = min(
        max(0, playbackPositionSeconds + intervalMs / 1000.0),
        playbackDurationSeconds
      )
      playbackAnchorTime = currentHostTime()
      eventCallback([
        "event": "skip",
        "intervalMs": intervalMs,
      ])
      pipController.invalidatePlaybackState()
      completionHandler()
    }
  }
#endif
