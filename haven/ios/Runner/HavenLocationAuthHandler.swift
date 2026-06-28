import CoreLocation
import Flutter

/// Bridges CoreLocation "Always" authorization to Flutter over a `MethodChannel`.
///
/// `geolocator` can only ever request "When In Use" on iOS, but Haven's
/// background location sharing needs "Always" to keep delivering while the app
/// is backgrounded or the device is locked. This handler owns a single
/// long-lived `CLLocationManager` and calls `requestAlwaysAuthorization()`
/// directly.
///
/// The pending Flutter result is stored and resolved from the authorization
/// delegate callback — never via a blocking wait, which would deadlock the main
/// thread that both the `MethodChannel` handler and the delegate run on. A
/// timeout guard resolves the result if the OS never invokes the delegate (for
/// example when it grants provisional "Always" without a status change), so the
/// Dart future can never hang.
///
/// Deployment target is iOS 15.5, so the iOS 14+ delegate
/// (`locationManagerDidChangeAuthorization`) and `authorizationStatus` property
/// are used directly.
final class HavenLocationAuthHandler: NSObject, CLLocationManagerDelegate {
  static let channelName = "haven.app/ios_location_auth"

  /// Resolves a never-answered request so the Dart future always completes.
  private static let requestTimeout: TimeInterval = 30

  private let locationManager = CLLocationManager()
  private var pendingResult: FlutterResult?
  private var timeoutWorkItem: DispatchWorkItem?

  override init() {
    super.init()
    locationManager.delegate = self
  }

  /// Registers the method channel on the given binary messenger.
  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "handler deallocated", details: nil))
        return
      }
      switch call.method {
      case "checkAlwaysStatus":
        result(self.statusString())
      case "requestAlwaysAuthorization":
        self.requestAlways(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Request

  private func requestAlways(result: @escaping FlutterResult) {
    // Resolve any previous in-flight request with the current status so its
    // Dart future never hangs if two requests overlap.
    resolvePending(with: statusString())

    let status = locationManager.authorizationStatus
    // If the user has already made a terminal choice (denied / restricted) or
    // already granted Always, no prompt will appear — answer immediately.
    if status != .notDetermined && status != .authorizedWhenInUse {
      result(statusString())
      return
    }

    pendingResult = result

    // Guard against the OS never invoking the delegate — calling
    // requestAlwaysAuthorization() while already "When In Use" grants a
    // provisional Always without a status change, so no delegate callback may
    // fire. The timeout resolves the future with whatever the status is then.
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.resolvePending(with: self.statusString())
    }
    timeoutWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout, execute: work)

    locationManager.requestAlwaysAuthorization()
  }

  private func resolvePending(with value: String) {
    timeoutWorkItem?.cancel()
    timeoutWorkItem = nil
    guard let pending = pendingResult else { return }
    pendingResult = nil
    pending(value)
  }

  // MARK: - CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Ignore the interim ".notDetermined" state; resolve on any settled status.
    if manager.authorizationStatus == .notDetermined { return }
    resolvePending(with: statusString())
  }

  // MARK: - Status mapping

  /// Maps the current `CLAuthorizationStatus` to the Dart `IosAuthStatus`
  /// vocabulary.
  private func statusString() -> String {
    switch locationManager.authorizationStatus {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedWhenInUse: return "whenInUse"
    case .authorizedAlways: return "always"
    @unknown default: return "unknown"
    }
  }
}
