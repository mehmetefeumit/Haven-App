import CoreLocation
import Flutter

/// Owns a CLLocationManager for Significant-Location-Change (SLC) monitoring
/// and triggers a Dart catch-up via a MethodChannel on SLC relaunches.
///
/// ## Purpose
///
/// SLC monitoring keeps the app alive (or relaunches it) in the background
/// when the device moves ~500 m. Haven uses this to trigger a receive-only
/// catch-up sweep so peers' location updates are decrypted without requiring
/// a full foreground session.
///
/// ## LIVE since M7-E (gated per call)
///
/// `startMonitoring()` is a no-op unless BOTH:
///   1. The user has enabled background sharing (`haven.background_sharing`
///      in UserDefaults/SharedPreferences), AND
///   2. `backgroundCatchupEnabled` is mirrored as true in UserDefaults
///      (`flutter.background_catchup_enabled`).
///
/// Since M7-E the Dart side writes `true` to
/// `flutter.background_catchup_enabled` at startup (see
/// `lib/src/services/ios_background_catchup.dart`), so monitoring arms once
/// the user enables background sharing. A rolled-back build rewrites `false`
/// on its first launch, re-inerting this path with no Swift change. Arming is
/// (re-)attempted at launch and on every `applicationDidEnterBackground`
/// (AppDelegate, A3 — closes the launch-arm-before-mirror-write lag).
///
/// ## Strong channel capture
///
/// The `FlutterMethodChannel` is held as a strong stored property. There is
/// NO `[weak channel]` capture in any `DispatchQueue.main.async` closure —
/// the reverted draft used weak captures which allowed the channel to
/// deallocate before use, silently killing both wake paths.
///
/// ## Main()-race mitigation
///
/// On SLC relaunch the Dart engine starts asynchronously. This handler does
/// NOT fire immediately on launch — it fires from the CLLocationManager
/// delegate after the engine is fully running. The 23-second background task
/// window (via `beginBackgroundTask`) gives the engine time to start and
/// register the channel handler. If the method call returns
/// `FlutterMethodNotImplemented` (Dart handler not yet registered), the
/// handler cancels its background task and reschedules by calling
/// `scheduleNextCatchup()` on the BGTask handler, which submits a
/// BGAppRefreshTask as a fallback wake. See `HavenBGTaskHandler` doc.
///
/// ## On-device validation required (cannot be asserted in flutter test)
///
///   - SLC wake fires on ~500 m movement.
///   - Channel call reaches Dart handler (no weak-reference deallocation).
///   - Monitoring does NOT start when either flag is false (privacy inert).
///   - `stopMonitoring()` via Dart teardown channel actually stops SLC.
final class HavenSLCHandler: NSObject, CLLocationManagerDelegate {
  /// The MethodChannel name for triggering a Dart catch-up from SLC wakes.
  static let channelName = "haven.app/ios_background_catchup"

  /// The MethodChannel name for SLC teardown requests from Dart.
  ///
  /// Dedicated to SLC — must NOT be shared with HavenBGTaskHandler. iOS keeps
  /// only one method-call handler per channel name, so a shared name would let
  /// one handler's registration silently overwrite the other's.
  static let teardownChannelName = "haven.app/ios_slc_teardown"

  /// UserDefaults key written by SharedPreferences for the background-sharing
  /// toggle. SharedPreferences stores bool values under the `flutter.` prefix.
  private static let kBgSharingKey = "flutter.haven.background_sharing"

  /// UserDefaults key written by Dart at startup to mirror the compile-time
  /// `backgroundCatchupEnabled` constant. With the flag OFF this is always
  /// false, so native scheduling never starts regardless of bg-sharing state.
  private static let kBgCatchupEnabledKey = "flutter.background_catchup_enabled"

  private let locationManager = CLLocationManager()

  /// Strong reference to the catch-up trigger channel. Must NOT be weak.
  private var channel: FlutterMethodChannel?

  /// Background task ID for the current SLC-triggered wake window (~23 s).
  private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

  /// Reference to the BGTask handler, used to schedule a fallback BGTask
  /// if the Dart handler is not yet registered on SLC relaunch.
  private weak var bgTaskHandler: HavenBGTaskHandler?

  /// Creates the SLC handler.
  ///
  /// - Parameters:
  ///   - bgTaskHandler: The BGTask handler used for fallback scheduling when
  ///     the Dart channel handler is not yet registered on cold SLC relaunch.
  init(bgTaskHandler: HavenBGTaskHandler?) {
    self.bgTaskHandler = bgTaskHandler
    super.init()
    locationManager.delegate = self
  }

  // MARK: - Registration

  /// Registers the MethodChannel on the given binary messenger and sets up
  /// the teardown channel so Dart can stop SLC monitoring.
  ///
  /// Must be called from `didFinishLaunchingWithOptions` after the Flutter
  /// engine is running (mirrors `HavenLocationAuthHandler.register`).
  func register(with messenger: FlutterBinaryMessenger) {
    // Strong reference — no [weak channel] capture anywhere below.
    let catchupChannel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    self.channel = catchupChannel

    // Teardown channel: Dart calls "stopSLC" when the user disables background
    // sharing (wired in disableBackgroundScheduling() → cancelNativeSchedulers).
    let teardownChannel = FlutterMethodChannel(
      name: Self.teardownChannelName,
      binaryMessenger: messenger
    )
    teardownChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "SLC handler deallocated", details: nil))
        return
      }
      switch call.method {
      case "stopSLC":
        self.stopMonitoring()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Enable predicate

  /// Returns true only when BOTH the bg-sharing toggle AND the
  /// `backgroundCatchupEnabled` mirror are true in UserDefaults.
  ///
  /// Re-read at every call site (never cached), so a Dart-side opt-out or a
  /// rollback build's `false` mirror takes effect on the next wake/arm.
  private func isEnabled() -> Bool {
    let defaults = UserDefaults.standard
    let bgSharing = defaults.bool(forKey: Self.kBgSharingKey)
    let catchupEnabled = defaults.bool(forKey: Self.kBgCatchupEnabledKey)
    return bgSharing && catchupEnabled
  }

  // MARK: - Monitoring lifecycle

  /// Starts SLC monitoring when the enable predicate holds AND the app has
  /// CLAuthorizationStatus.authorizedAlways.
  ///
  /// Safe to call multiple times (CLLocationManager ignores redundant
  /// `startMonitoringSignificantLocationChanges` calls).
  func startMonitoring() {
    guard isEnabled() else {
      // Background sharing off (or a rolled-back build wrote a false
      // mirror) → arm nothing.
      return
    }
    guard locationManager.authorizationStatus == .authorizedAlways else {
      // Cannot monitor without Always authorization. The SLC path is purely
      // additive — foreground sharing still works without it.
      return
    }
    locationManager.startMonitoringSignificantLocationChanges()
  }

  /// Stops SLC monitoring unconditionally.
  ///
  /// Called from the Dart teardown channel when the user disables background
  /// sharing, so SLC wakes stop immediately after opt-out.
  func stopMonitoring() {
    locationManager.stopMonitoringSignificantLocationChanges()
    endBackgroundTask()
  }

  // MARK: - CLLocationManagerDelegate

  /// Fires on a significant location change (OS criterion: ~500 m movement).
  ///
  /// This also fires on SLC relaunch: the OS delivers the accumulated location
  /// update to the app, which is the trigger for the catch-up sweep.
  ///
  /// We open a background task to get ~23 s of execution time, then invoke
  /// the Dart channel. If the channel is not yet ready (cold SLC relaunch with
  /// a slow engine start), the `FlutterMethodNotImplemented` reply causes a
  /// fallback to the BGTask handler, which schedules another wake.
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Re-check intent on every wake (C2 durable-intent re-check).
    guard isEnabled() else { return }

    // Open a background execution window. iOS typically grants ~23 s for
    // tasks started from a location delegate in the background.
    if bgTaskId == .invalid {
      bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "haven.slc.catchup") {
        // Expiration handler: end the task gracefully.
        self.endBackgroundTask()
      }
    }

    triggerDartCatchup()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Log type only — never the error message (could contain location data).
    debugLog("SLC didFailWithError: \(type(of: error))")
    endBackgroundTask()
  }

  // MARK: - Dart channel trigger

  /// Invokes `runCatchup` on the Dart MethodChannel.
  ///
  /// If the Dart handler is not yet registered (cold SLC relaunch before
  /// main() completes its ~10 awaits), `FlutterMethodNotImplemented` is
  /// received. In that case we schedule a BGAppRefreshTask as a fallback
  /// rather than losing the wake silently.
  private func triggerDartCatchup() {
    guard let channel = self.channel else {
      endBackgroundTask()
      return
    }

    channel.invokeMethod("runCatchup", arguments: nil) { [weak self] result in
      guard let self = self else { return }
      if let flutterError = result as? FlutterError {
        // Dart threw — log type only (no message; could contain internal state).
        debugLog("SLC: Dart catch-up returned error: \(flutterError.code)")
      } else if (result as? NSObject) === FlutterMethodNotImplemented {
        // Dart handler not yet registered (cold-launch race). Schedule a
        // BGAppRefreshTask so the wake is not lost.
        debugLog("SLC: Dart handler not ready — scheduling BGTask fallback")
        self.bgTaskHandler?.scheduleNextCatchup()
      }
      self.endBackgroundTask()
    }
  }

  // MARK: - Background task lifecycle

  private func endBackgroundTask() {
    guard bgTaskId != .invalid else { return }
    UIApplication.shared.endBackgroundTask(bgTaskId)
    bgTaskId = .invalid
  }

  // MARK: - Logging

  private func debugLog(_ message: String) {
    // Only log in debug builds — release builds silence all prints per
    // Haven's security policy (no internal state in logs).
    #if DEBUG
    NSLog("[HavenSLC] %@", message)
    #endif
  }
}
