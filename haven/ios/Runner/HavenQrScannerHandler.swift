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
///     "unavailable"; `setTorch(Bool)`; `switchCamera`; `stop`.
///   native -> Dart: `detected(String)`, each distinct text once per view;
///     `torch(Bool)`; `unavailable` when no camera could be started.
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
    switch call.method {
    case "checkAccess":
      result(Self.access())
    case "requestAccess":
      guard Self.access() == "denied",
            AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
        result(Self.access())
        return
      }
      AVCaptureDevice.requestAccess(for: .video) { _ in
        DispatchQueue.main.async { result(Self.access()) }
      }
    case "setTorch":
      current?.setTorch(call.arguments as? Bool == true)
      result(nil)
    case "switchCamera":
      current?.switchCamera()
      result(nil)
    case "stop":
      current?.stop()
      current = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func access() -> String {
    if AVCaptureDevice.default(for: .video) == nil { return "unavailable" }
    return AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? "granted" : "denied"
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    current?.stop()
    let view = HavenQrScannerView(frame: frame) { [weak self] method, argument in
      self?.channel?.invokeMethod(method, arguments: argument)
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
  private let preview: HavenQrPreview
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "haven.qr.session")
  private let frameQueue = DispatchQueue(label: "haven.qr.frames")
  private let emit: (String, Any?) -> Void
  // Touched on sessionQueue only.
  private var input: AVCaptureDeviceInput?
  private var position: AVCaptureDevice.Position = .back
  // Touched on the main queue only.
  private var lastText: String?
  private var stopped = false

  init(frame: CGRect, emit: @escaping (String, Any?) -> Void) {
    preview = HavenQrPreview(frame: frame)
    self.emit = emit
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

  private func start() {
    guard configure(position) else {
      DispatchQueue.main.async { [weak self] in self?.emit("unavailable", nil) }
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
      guard let self = self, let device = self.input?.device, device.hasTorch,
            (try? device.lockForConfiguration()) != nil else { return }
      device.torchMode = on ? .on : .off
      device.unlockForConfiguration()
      let lit = device.torchMode == .on
      DispatchQueue.main.async { self.emit("torch", lit) }
    }
  }

  func switchCamera() {
    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      let wanted: AVCaptureDevice.Position = self.position == .back ? .front : .back
      guard Self.camera(at: wanted) != nil, self.configure(wanted) else { return }
      // A new camera starts with its torch off.
      DispatchQueue.main.async { self.emit("torch", false) }
    }
  }

  func stop() {
    stopped = true
    let session = self.session
    sessionQueue.async { if session.isRunning { session.stopRunning() } }
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
      self.emit("detected", text)
    }
  }
}
