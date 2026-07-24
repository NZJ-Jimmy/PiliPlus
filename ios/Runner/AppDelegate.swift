import AVFoundation
import AVKit
import Flutter
import UIKit

private final class IOSPiPManager: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = IOSPiPManager()

  weak var channel: FlutterMethodChannel?

  private var player: AVPlayer?
  private var playerItem: AVPlayerItem?
  private var playerLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?
  private var overlayWindow: UIWindow?
  private var hostContainer: UIView?
  private var pendingStartResult: FlutterResult?
  private var suppressStopCallback = false
  private var sessionID = UUID()
  private var startAttempts = 0
  private var possibleObservation: NSKeyValueObservation?
  private var statusObservation: NSKeyValueObservation?
  private var readyTimeoutWork: DispatchWorkItem?
  private var preparedItem: AVPlayerItem?
  private var preparedSignature: String?
  private var preparingSignature: String?
  private var playbackSpeed: Float = 1.0
  private var playWhenReady = true
  private var targetPositionMs = 0

  private override init() {
    super.init()
  }

  var isAvailable: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  func prepare(arguments: Any?, result: @escaping FlutterResult) {
    guard isAvailable else {
      result(false)
      return
    }
    guard
      let args = arguments as? [String: Any],
      let videoURL = args["videoUrl"] as? String
    else {
      result(false)
      return
    }

    let audioURL = args["audioUrl"] as? String
    let headers = args["headers"] as? [String: String] ?? [:]
    let signature = makeSignature(videoURL: videoURL, audioURL: audioURL)

    if preparedSignature == signature, preparedItem != nil {
      result(true)
      return
    }

    preparingSignature = signature
    buildPlayerItem(
      videoURL: videoURL,
      audioURL: audioURL,
      headers: headers
    ) { [weak self] item in
      DispatchQueue.main.async {
        guard let self else { return }
        guard self.preparingSignature == signature else {
          result(false)
          return
        }
        self.preparingSignature = nil
        self.preparedItem = item
        self.preparedSignature = item == nil ? nil : signature
        result(item != nil)
      }
    }
  }

  func enter(arguments: Any?, result: @escaping FlutterResult) {
    guard isAvailable else {
      result(false)
      return
    }
    guard
      let args = arguments as? [String: Any],
      let videoURL = args["videoUrl"] as? String
    else {
      result(false)
      return
    }

    let audioURL = args["audioUrl"] as? String
    let headers = args["headers"] as? [String: String] ?? [:]
    let signature = makeSignature(videoURL: videoURL, audioURL: audioURL)

    cancelPendingStart(success: false)
    pendingStartResult = result
    targetPositionMs = args["positionMs"] as? Int ?? 0
    playWhenReady = args["playWhenReady"] as? Bool ?? true
    playbackSpeed = Float(args["playbackSpeed"] as? Double ?? 1.0)
    startAttempts = 0

    let usePrepared =
      preparedSignature == signature
      && preparedItem != nil
      && preparedItem?.status != .failed

    if usePrepared, let item = preparedItem {
      startPiP(item: item.copyPlayerItem())
      return
    }

    preparingSignature = signature
    buildPlayerItem(
      videoURL: videoURL,
      audioURL: audioURL,
      headers: headers
    ) { [weak self] item in
      DispatchQueue.main.async {
        guard let self else { return }
        guard self.preparingSignature == signature else { return }
        self.preparingSignature = nil
        guard let item else {
          self.finishPendingStart(false)
          self.teardown(keepPrepared: true)
          return
        }
        self.preparedItem = item
        self.preparedSignature = signature
        self.startPiP(item: item.copyPlayerItem())
      }
    }
  }

  func restore() -> [String: Any] {
    let state = currentState(wasActive: isSessionActive)
    guard isSessionActive else {
      teardown(keepPrepared: true)
      return state
    }

    suppressStopCallback = true
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    teardown(keepPrepared: true)
    return state
  }

  private var isSessionActive: Bool {
    (pipController?.isPictureInPictureActive ?? false) || player != nil
  }

  private func startPiP(item: AVPlayerItem) {
    teardown(keepPrepared: true)
    let currentSession = UUID()
    sessionID = currentSession

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      // Continue; PiP can still work with the existing session.
    }

    playerItem = item
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    self.player = player

    guard attachPlayerLayer(player: player) else {
      finishPendingStart(false)
      teardown(keepPrepared: true)
      return
    }

    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard let self, self.sessionID == currentSession else { return }
      DispatchQueue.main.async {
        switch item.status {
        case .readyToPlay:
          self.onPlayerItemReady(session: currentSession)
        case .failed:
          self.finishPendingStart(false)
          self.teardown(keepPrepared: true)
        default:
          break
        }
      }
    }

    readyTimeoutWork?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.sessionID == currentSession else { return }
      if self.pipController?.isPictureInPictureActive != true {
        self.finishPendingStart(false)
        self.teardown(keepPrepared: true)
      }
    }
    readyTimeoutWork = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  private func onPlayerItemReady(session: UUID) {
    guard sessionID == session, let player else { return }

    let begin = { [weak self] in
      guard let self, self.sessionID == session else { return }
      if self.playWhenReady {
        player.playImmediately(atRate: self.playbackSpeed)
      } else {
        player.pause()
      }
      self.observePictureInPicturePossible(session: session)
    }

    if targetPositionMs > 0 {
      let seekTime = CMTime(value: CMTimeValue(targetPositionMs), timescale: 1000)
      player.seek(
        to: seekTime,
        toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
        toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
      ) { _ in
        begin()
      }
    } else {
      begin()
    }
  }

  private func observePictureInPicturePossible(session: UUID) {
    guard let pipController, sessionID == session else { return }

    possibleObservation?.invalidate()
    possibleObservation = pipController.observe(
      \.isPictureInPicturePossible,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      guard let self, self.sessionID == session else { return }
      DispatchQueue.main.async {
        if controller.isPictureInPicturePossible {
          self.attemptStartPictureInPicture(session: session)
        }
      }
    }

    // Kick a few deferred attempts in case KVO misses the first transition.
    for delay in [0.05, 0.2, 0.5, 1.0, 2.0] as [TimeInterval] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.attemptStartPictureInPicture(session: session)
      }
    }
  }

  private func attemptStartPictureInPicture(session: UUID) {
    guard sessionID == session, let pipController else { return }
    if pipController.isPictureInPictureActive {
      finishPendingStart(true)
      return
    }
    guard pipController.isPictureInPicturePossible else { return }
    guard startAttempts < 5 else { return }
    startAttempts += 1
    pipController.startPictureInPicture()
  }

  private func attachPlayerLayer(player: AVPlayer) -> Bool {
    // Prefer embedding in the Flutter view so the layer is actually rendered
    // (required for isPictureInPicturePossible to become true reliably).
    if let hostView = currentFlutterView() {
      let container = UIView(frame: CGRect(x: 8, y: 8, width: 160, height: 90))
      container.isUserInteractionEnabled = false
      container.backgroundColor = .clear
      container.alpha = 0.01

      let playerLayer = AVPlayerLayer(player: player)
      playerLayer.frame = container.bounds
      playerLayer.videoGravity = .resizeAspect
      playerLayer.isHidden = false
      container.layer.addSublayer(playerLayer)
      hostView.insertSubview(container, at: 0)

      self.hostContainer = container
      self.playerLayer = playerLayer
      return configurePipController(playerLayer: playerLayer)
    }

    guard let scene = currentWindowScene() else {
      return false
    }

    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
    let rootVC = UIViewController()
    rootVC.view.backgroundColor = .clear
    rootVC.view.frame = window.bounds

    let playerLayer = AVPlayerLayer(player: player)
    playerLayer.frame = rootVC.view.bounds
    playerLayer.videoGravity = .resizeAspect
    playerLayer.isHidden = false
    rootVC.view.layer.addSublayer(playerLayer)

    window.rootViewController = rootVC
    window.windowLevel = .normal - 1
    window.backgroundColor = .clear
    window.alpha = 0.02
    window.isHidden = false
    window.makeKeyAndVisible()
    DispatchQueue.main.async {
      scene.windows.first(where: { $0 !== window })?.makeKeyAndVisible()
    }

    self.overlayWindow = window
    self.playerLayer = playerLayer
    return configurePipController(playerLayer: playerLayer)
  }

  private func configurePipController(playerLayer: AVPlayerLayer) -> Bool {
    let pipController = AVPictureInPictureController(playerLayer: playerLayer)
    if #available(iOS 14.2, *) {
      pipController.canStartPictureInPictureAutomaticallyFromInline = false
    }
    pipController.delegate = self
    self.pipController = pipController
    return true
  }

  private func currentFlutterView() -> UIView? {
    if let window = (UIApplication.shared.delegate as? FlutterAppDelegate)?.window,
       let root = window.rootViewController
    {
      return root.view
    }
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController?
      .view
  }

  private func buildPlayerItem(
    videoURL: String,
    audioURL: String?,
    headers: [String: String],
    completion: @escaping (AVPlayerItem?) -> Void
  ) {
    let videoAsset = makeAsset(urlString: videoURL, headers: headers)

    guard let audioURL, !audioURL.isEmpty else {
      loadAsset(videoAsset) { loaded in
        completion(loaded ? AVPlayerItem(asset: videoAsset) : nil)
      }
      return
    }

    let audioAsset = makeAsset(urlString: audioURL, headers: headers)
    let group = DispatchGroup()
    var videoOK = false
    var audioOK = false

    group.enter()
    loadAsset(videoAsset) { loaded in
      videoOK = loaded
      group.leave()
    }
    group.enter()
    loadAsset(audioAsset) { loaded in
      audioOK = loaded
      group.leave()
    }

    group.notify(queue: .global(qos: .userInitiated)) {
      guard videoOK else {
        completion(nil)
        return
      }

      if audioOK, let composed = self.compose(videoAsset: videoAsset, audioAsset: audioAsset) {
        completion(composed)
        return
      }

      // Fallback: video-only PiP is better than failing entirely.
      completion(AVPlayerItem(asset: videoAsset))
    }
  }

  private func compose(videoAsset: AVURLAsset, audioAsset: AVURLAsset) -> AVPlayerItem? {
    let composition = AVMutableComposition()
    guard
      let videoSourceTrack = videoAsset.tracks(withMediaType: .video).first,
      let compositionVideoTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      return nil
    }

    let videoDuration = usableDuration(of: videoAsset, track: videoSourceTrack)
    guard videoDuration.isValid, videoDuration.seconds > 0 else {
      return nil
    }

    do {
      try compositionVideoTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: videoDuration),
        of: videoSourceTrack,
        at: .zero
      )
      compositionVideoTrack.preferredTransform = videoSourceTrack.preferredTransform

      if
        let audioSourceTrack = audioAsset.tracks(withMediaType: .audio).first,
        let compositionAudioTrack = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      {
        let audioDuration = usableDuration(of: audioAsset, track: audioSourceTrack)
        let insertDuration =
          audioDuration.isValid && audioDuration.seconds > 0
          ? CMTimeMinimum(audioDuration, videoDuration)
          : videoDuration
        try compositionAudioTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: insertDuration),
          of: audioSourceTrack,
          at: .zero
        )
      }

      return AVPlayerItem(asset: composition)
    } catch {
      return nil
    }
  }

  private func usableDuration(of asset: AVAsset, track: AVAssetTrack) -> CMTime {
    if asset.duration.isValid, !asset.duration.isIndefinite, asset.duration.seconds > 0 {
      return asset.duration
    }
    if track.timeRange.duration.isValid, track.timeRange.duration.seconds > 0 {
      return track.timeRange.duration
    }
    return .invalid
  }

  private func makeAsset(urlString: String, headers: [String: String]) -> AVURLAsset {
    var options: [String: Any] = [
      AVURLAssetPreferPreciseDurationAndTimingKey: true,
    ]
    if !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    return AVURLAsset(url: URL(string: urlString)!, options: options)
  }

  private func loadAsset(_ asset: AVURLAsset, completion: @escaping (Bool) -> Void) {
    let keys = ["tracks", "duration", "playable"]
    asset.loadValuesAsynchronously(forKeys: keys) {
      var error: NSError?
      for key in keys {
        let status = asset.statusOfValue(forKey: key, error: &error)
        if status == .failed || status == .cancelled {
          completion(false)
          return
        }
      }
      completion(asset.isPlayable || !asset.tracks(withMediaType: .video).isEmpty
        || !asset.tracks(withMediaType: .audio).isEmpty)
    }
  }

  private func makeSignature(videoURL: String, audioURL: String?) -> String {
    "\(videoURL)|\(audioURL ?? "")"
  }

  private func currentWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first {
      $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
    } ?? scenes.first
  }

  private func currentState(wasActive: Bool) -> [String: Any] {
    let positionSeconds = player?.currentTime().seconds ?? 0
    let positionMs = positionSeconds.isFinite ? Int(positionSeconds * 1000) : 0
    let isPlaying = player?.timeControlStatus == .playing
      || (player?.rate ?? 0) > 0
    return [
      "wasActive": wasActive,
      "positionMs": positionMs,
      "isPlaying": isPlaying,
    ]
  }

  private func cancelPendingStart(success: Bool) {
    if pendingStartResult != nil {
      finishPendingStart(success)
    }
  }

  private func finishPendingStart(_ started: Bool) {
    readyTimeoutWork?.cancel()
    readyTimeoutWork = nil
    pendingStartResult?(started)
    pendingStartResult = nil
  }

  private func teardown(keepPrepared: Bool) {
    readyTimeoutWork?.cancel()
    readyTimeoutWork = nil
    possibleObservation?.invalidate()
    possibleObservation = nil
    statusObservation?.invalidate()
    statusObservation = nil

    player?.pause()
    playerLayer?.player = nil
    playerLayer?.removeFromSuperlayer()
    hostContainer?.removeFromSuperview()
    hostContainer = nil
    overlayWindow?.isHidden = true
    overlayWindow = nil
    playerLayer = nil
    pipController?.delegate = nil
    pipController = nil
    playerItem = nil
    player = nil
    startAttempts = 0
    sessionID = UUID()

    if !keepPrepared {
      preparedItem = nil
      preparedSignature = nil
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    readyTimeoutWork?.cancel()
    readyTimeoutWork = nil
    finishPendingStart(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    if startAttempts < 5 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.attemptStartPictureInPicture(session: self.sessionID)
      }
      return
    }
    finishPendingStart(false)
    teardown(keepPrepared: true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    let state = currentState(wasActive: true)
    let shouldNotify = !suppressStopCallback
    suppressStopCallback = false
    teardown(keepPrepared: true)
    if shouldNotify {
      channel?.invokeMethod("onPipStop", arguments: state)
    }
  }
}

private extension AVPlayerItem {
  func copyPlayerItem() -> AVPlayerItem {
    AVPlayerItem(asset: asset)
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var iosPipChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupIOSPipChannel(binaryMessenger: engineBridge.applicationRegistrar.messenger())
  }

  private func setupIOSPipChannel(binaryMessenger: FlutterBinaryMessenger) {
    if iosPipChannel != nil {
      return
    }

    let channel = FlutterMethodChannel(
      name: "PiliPlus.iOSPiP",
      binaryMessenger: binaryMessenger
    )
    IOSPiPManager.shared.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        result(IOSPiPManager.shared.isAvailable)
      case "prepare":
        IOSPiPManager.shared.prepare(arguments: call.arguments, result: result)
      case "enter":
        IOSPiPManager.shared.enter(arguments: call.arguments, result: result)
      case "restore":
        result(IOSPiPManager.shared.restore())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    iosPipChannel = channel
  }
}
