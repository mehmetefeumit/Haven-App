import CoreLocation
import Flutter
import os

/// The unified-log destination for this file's DEBUG diagnostics.
///
/// `os_log` under a Haven subsystem, never `NSLog`: the runtime log scanner
/// decides whose line a `log show` record is from the record's own emitter —
/// its subsystem, else the emitting library, else the process
/// (`tooling/logscan/policy.toml`'s `owned_emitters`). An `NSLog` record
/// reaches `_os_log_impl` from inside Foundation and carries no subsystem at
/// all, and `Foundation` is the library on 36 673 lines of one real capture,
/// vendor plugins included, so it can never be owned. A subsystem Haven names
/// makes these lines Haven's by construction rather than by inference. A
/// file-level constant so the call sites can name it bare, which is what
/// `scripts/ci/check_native_log_allowlist.sh` admits as a logged argument.
///
/// No `type:` at the call sites: that is OS_LOG_TYPE_DEFAULT, which logd
/// PERSISTS. `.debug` and `.info` live in a wrapping memory buffer that
/// `log collect` finds only if it runs soon enough — the eviction that cost CI
/// run 35280144455's two long lanes their Rust plant.
private let HAVEN_SLC_LOG = OSLog(subsystem: "haven_ios", category: "slc")

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
/// ## Relaunch region (paired with SLC, same gates)
///
/// SLC is driven by cell-tower transitions, so where towers are sparse
/// (rural areas, a single-tower town, indoors on Wi-Fi only) a terminated app
/// can go a long way before the OS decides anything "significant" happened.
/// Region monitoring is a second, independent relaunch source with the same
/// termination survival: one ~500 m circular region centred on the last
/// delivered fix, re-centred on every SLC delivery, so leaving the
/// neighbourhood relaunches Haven even when SLC stays quiet. Exit only —
/// entry would fire immediately on re-arm and buy nothing.
///
/// It is armed and torn down strictly with SLC (same `isEnabled()` predicate,
/// same Always requirement, released by `stopMonitoring()`), adds no
/// UserDefaults key, and reaches Dart through the SAME `runCatchup` channel,
/// so the receive-only guarantee and the consent chokepoint are unchanged. No
/// coordinate is ever logged (Security Rule 6): the region's centre is passed
/// to CoreLocation and never to a log line.
///
/// Ceiling, stated honestly: like SLC, this cannot be proven on the Simulator
/// — see the owner checklist in `docs/M7_BACKGROUND_SHARING.md` §6.
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

  /// Identifier of the single relaunch region. Stable, so re-registering
  /// replaces the previous circle instead of accumulating regions (iOS caps an
  /// app at 20) and so `stopMonitoring()` can find it again after a relaunch,
  /// when `monitoredRegions` is restored by the OS rather than by this class.
  private static let relaunchRegionIdentifier = "haven.relaunch"

  /// Radius of the relaunch region, in metres. Chosen to match the OS's own
  /// ~500 m significant-change criterion: a smaller circle would wake the app
  /// on ordinary movement around home, a larger one would take longer than SLC
  /// to notice a real departure, and either way this is the backstop for the
  /// case where SLC does not fire at all.
  private static let relaunchRegionRadiusMeters: CLLocationDistance = 500

  /// Oldest fix the region may be centred on.
  ///
  /// `CLLocationManager.location` is whatever CoreLocation last retrieved, and
  /// on a region-triggered relaunch it is NOT guaranteed to post-date the
  /// crossing — it can be a cached fix from an earlier session, i.e. the
  /// user's home. Centring the new circle there would pin it to a place the
  /// device has already left, so the NEXT departure never crosses a boundary
  /// and the relaunch source goes quiet exactly when it is needed. Skipping
  /// instead leaves the previous circle in place (no worse) and lets the next
  /// SLC delivery, which always carries a genuinely fresh location, re-centre
  /// it. Generous rather than tight, and knowingly so: at vehicle speed a
  /// 300 s-old fix is already ~8 km away, far outside the circle it would
  /// centre. That direction is unreachable here — a crossing-triggered wake
  /// carries a fix seconds old, and SLC delivers its own — so the bound only
  /// ever has to reject a previous session's cache, which is the case that
  /// silently pins the circle to the user's home.
  private static let relaunchRegionMaxFixAge: TimeInterval = 300

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
    // Arm the relaunch region from whatever fix CoreLocation already holds.
    // A cold launch with no cached fix simply arms nothing here; the first SLC
    // delivery centres it.
    refreshRelaunchRegion(around: locationManager.location)
  }

  /// Stops SLC monitoring and releases the relaunch region unconditionally.
  ///
  /// Called from the Dart teardown channel when the user disables background
  /// sharing, so SLC wakes stop immediately after opt-out.
  func stopMonitoring() {
    locationManager.stopMonitoringSignificantLocationChanges()
    stopRelaunchRegion()
    endBackgroundTask()
  }

  /// Re-centres the single relaunch region on [location].
  ///
  /// No-op when there is no fix to centre on, when that fix is older than
  /// `relaunchRegionMaxFixAge`, when region monitoring is unavailable on this
  /// device, or when the enable predicate no longer holds — the last of which
  /// makes this safe to call from any delivery path.
  ///
  /// The region APIs used here (`CLCircularRegion`,
  /// `isMonitoringAvailable(for:)`, `startMonitoring(for:)`) are deprecated in
  /// favour of `CLMonitor` from iOS 17, but remain functional and are the only
  /// option at this target's floor (`IPHONEOS_DEPLOYMENT_TARGET = 15.5`). They
  /// compile as warnings only — no `SWIFT_TREAT_WARNINGS_AS_ERRORS` is set on
  /// the Runner target.
  private func refreshRelaunchRegion(around location: CLLocation?) {
    guard isEnabled(),
      locationManager.authorizationStatus == .authorizedAlways,
      CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
      let fix = location,
      -fix.timestamp.timeIntervalSinceNow <= Self.relaunchRegionMaxFixAge
    else { return }

    // `maximumRegionMonitoringDistance` reports -1 when region monitoring is
    // unavailable or unauthorized, and a bare `min` would then hand
    // CoreLocation a negative radius.
    let maxRadius = locationManager.maximumRegionMonitoringDistance
    let region = CLCircularRegion(
      center: fix.coordinate,
      radius: maxRadius > 0
        ? min(Self.relaunchRegionRadiusMeters, maxRadius)
        : Self.relaunchRegionRadiusMeters,
      identifier: Self.relaunchRegionIdentifier
    )
    // Exit only: an entry trigger fires the instant the region is armed around
    // the device's own position, which would wake the app for nothing.
    region.notifyOnEntry = false
    region.notifyOnExit = true
    // Same identifier → replaces the previous circle rather than adding one.
    locationManager.startMonitoring(for: region)
  }

  /// Stops monitoring the relaunch region, including one restored by the OS
  /// after a relaunch (this class never held a reference to that instance).
  private func stopRelaunchRegion() {
    for region in locationManager.monitoredRegions
    where region.identifier == Self.relaunchRegionIdentifier {
      locationManager.stopMonitoring(for: region)
    }
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

    // Follow the device with the relaunch region so a termination is always
    // recoverable from wherever the app was last known to be.
    refreshRelaunchRegion(around: locations.last)

    beginCatchupWindow()
    triggerDartCatchup()
  }

  /// Fires when the device leaves the relaunch region, including on the
  /// relaunch of a terminated app. Same receive-only catch-up as an SLC wake.
  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isEnabled(), region.identifier == Self.relaunchRegionIdentifier else { return }

    // The circle just exited will not fire again on a continuing journey, so
    // re-centre it. `manager.location` is usually the fix that triggered this
    // crossing, but nothing guarantees it post-dates it — the staleness bound
    // inside `refreshRelaunchRegion` is what stops a cached fix from an
    // earlier session pinning the new circle where the device no longer is.
    refreshRelaunchRegion(around: manager.location)

    beginCatchupWindow()
    triggerDartCatchup()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Log type only — never the error message (could contain location data).
    debugLog("SLC didFailWithError: \(type(of: error))")
    endBackgroundTask()
  }

  func locationManager(
    _ manager: CLLocationManager,
    monitoringDidFailFor region: CLRegion?,
    withError error: Error
  ) {
    // Type only: the identifier is a Haven constant, but the error may carry
    // region details. SLC remains armed, so this degrades the relaunch
    // coverage rather than disabling it.
    debugLog("region monitoring failed: \(type(of: error))")
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

  /// Opens a background execution window if one is not already open. iOS
  /// typically grants ~23 s for tasks started from a location delegate in the
  /// background.
  private func beginCatchupWindow() {
    guard bgTaskId == .invalid else { return }
    bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "haven.slc.catchup") {
      // Expiration handler: end the task gracefully.
      self.endBackgroundTask()
    }
  }

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
    os_log("%{public}@", log: HAVEN_SLC_LOG, message)
    #endif
  }
}
