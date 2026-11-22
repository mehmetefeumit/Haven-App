import AVFoundation
import Flutter
import UIKit
import Vision

/// Haven's QR scanner on iOS: an AVFoundation preview in a Flutter platform
/// view, with each frame decoded on the device by Apple's Vision framework (the
/// decoder mobile_scanner used here before). Frames never leave the delegate,
/// nothing is captured or written, only decoded text reaches Dart, and nothing
/// here logs.
///
/// Channel `haven.app/qr_scanner` (Dart, `QrScannerChannel`):
///   Dart -> native: `requestAccess` / `checkAccess` -> "granted" | "denied" |
///     "unavailable"; `setTorch {token, on}`; `switchCamera {token}`;
///     `stop {token}`.
///   native -> Dart: `detected {token, text}`, each distinct text once per view;
///     `torch {token, on}`; `unavailable {token}` when no camera could start.
/// The token is the page's, given to the view at creation: a page closing while
/// the next one scans must not stop, steer or hear the newer camera.
final class HavenQrScannerHandler: NSObject, FlutterPlatformViewFactory {
  static let channelName = "haven.app/qr_scanner"
  static let viewType = "haven.app/qr_scanner_view"

  private var channel: FlutterMethodChannel?
  private var current: HavenQrScannerView?

  func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
    registrar.register(self, withId: Self.viewType)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let target = current.flatMap { $0.token == args?["token"] as? Int ? $0 : nil }
    switch call.method {
    case "checkAccess":
      result(Self.access())
    case "requestAccess":
      guard AVCaptureDevice.default(for: .video) != nil,
            AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
        result(Self.access())
        return
      }
      AVCaptureDevice.requestAccess(for: .video) { _ in
        DispatchQueue.main.async { result(Self.access()) }
      }
    case "setTorch":
      target?.setTorch(args?["on"] as? Bool == true)
      result(nil)
    case "switchCamera":
      target?.switchCamera()
      result(nil)
    case "stop":
      if let target = target {
        target.stop()
        current = nil
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// A restricted camera (device management, Screen Time) is one the user
  /// cannot allow in Settings, so it reads as unavailable, not denied.
  private static func access() -> String {
    if AVCaptureDevice.default(for: .video) == nil { return "unavailable" }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "granted"
    case .restricted: return "unavailable"
    default: return "denied"
    }
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    // One camera at a time: a newer page's view takes it from the last.
    current?.stop()
    let token = (args as? [String: Any])?["token"] as? Int ?? -1
    let view = HavenQrScannerView(frame: frame, token: token) { [weak self] method, fields in
      self?.channel?.invokeMethod(method, arguments: fields)
    }
    current = view
    return view
  }
}

/// A view whose own layer is the preview, so it always fills the view.
private final class HavenQrPreview: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}

/// One running capture session, stopped at `stop()` (the page closing) or when
/// the view is released, whichever comes first.
final class HavenQrScannerView: NSObject, FlutterPlatformView,
  AVCaptureVideoDataOutputSampleBufferDelegate {
  let token: Int
  private let preview: HavenQrPreview
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "haven.qr.session")
  private let frameQueue = DispatchQueue(label: "haven.qr.frames")
  private let send: (String, [String: Any]) -> Void
  // Touched on sessionQueue only.
  private var input: AVCaptureDeviceInput?
  private var position: AVCaptureDevice.Position = .back
  private var torchObservation: NSKeyValueObservation?
  // Touched on the main queue only.
  private var lastText: String?
  private var stopped = false

  init(frame: CGRect, token: Int, send: @escaping (String, [String: Any]) -> Void) {
    self.token = token
    preview = HavenQrPreview(frame: frame)
    self.send = send
    super.init()
    preview.backgroundColor = .black
    preview.previewLayer.session = session
    preview.previewLayer.videoGravity = .resizeAspectFill
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(runtimeError),
      name: .AVCaptureSessionRuntimeError,
      object: session
    )
    sessionQueue.async { [weak self] in self?.start() }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    let session = self.session
    sessionQueue.async { if session.isRunning { session.stopRunning() } }
  }

  func view() -> UIView { preview }

  /// On the main queue, and never after `stop()`.
  private func emit(_ method: String, _ fields: [String: Any] = [:]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.stopped else { return }
      self.send(method, fields.merging(["token": self.token]) { _, token in token })
    }
  }

  private func start() {
    guard configure(position) else {
      emit("unavailable")
      return
    }
    session.startRunning()
  }

  /// Builds the session around the camera at `wanted`, or the other one when a
  /// device has only that. On sessionQueue.
  private func configure(_ wanted: AVCaptureDevice.Position) -> Bool {
    let other: AVCaptureDevice.Position = wanted == .back ? .front : .back
    guard let device = Self.camera(at: wanted) ?? Self.camera(at: other),
          let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
    if let old = input { session.removeInput(old) }
    guard session.canAddInput(newInput) else {
      if let old = input { session.addInput(old) }
      return false
    }
    session.addInput(newInput)
    input = newInput
    position = device.position
    // iOS turns the torch off on its own (backgrounding, heat), so the button
    // follows the device, not the last request.
    torchObservation = device.observe(\.torchMode, options: [.initial, .new]) { [weak self] device, _ in
      self?.emit("torch", ["on": device.torchMode == .on])
    }
    if session.outputs.isEmpty {
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      ]
      output.setSampleBufferDelegate(self, queue: frameQueue)
      guard session.canAddOutput(output) else { return false }
      session.addOutput(output)
    }
    return true
  }

  private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
  }

  func setTorch(_ on: Bool) {
    sessionQueue.async { [weak self] in
      guard let device = self?.input?.device, device.hasTorch,
            (try? device.lockForConfiguration()) != nil else { return }
      device.torchMode = on ? .on : .off
      device.unlockForConfiguration()
    }
  }

  func switchCamera() {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      let wanted: AVCaptureDevice.Position = self.position == .back ? .front : .back
      guard Self.camera(at: wanted) != nil else { return }
      _ = self.configure(wanted)
    }
  }

  /// Stops the camera and empties the session, which also lets go of the frame
  /// delegate (this view) so nothing keeps the view alive.
  func stop() {
    stopped = true
    let session = self.session
    sessionQueue.async { [weak self] in
      self?.torchObservation = nil
      if session.isRunning { session.stopRunning() }
      session.beginConfiguration()
      for output in session.outputs {
        (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        session.removeOutput(output)
      }
      for input in session.inputs { session.removeInput(input) }
      session.commitConfiguration()
    }
  }

  /// A media-services reset stops the session; iOS does not restart it.
  @objc private func runtimeError() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.stopped else { return }
      self.sessionQueue.async { self.session.startRunning() }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
    guard let text = request.results?
      .compactMap({ $0.payloadStringValue })
      .first(where: { !$0.isEmpty }) else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.stopped, text != self.lastText else { return }
      self.lastText = text
      self.send("detected", ["token": self.token, "text": text])
    }
  }
}
