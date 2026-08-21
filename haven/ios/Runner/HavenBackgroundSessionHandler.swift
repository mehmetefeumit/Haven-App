import CoreLocation
import Flutter

/// Holds the CoreLocation background session objects while background sharing
/// is enabled.
///
/// ## Purpose
///
/// The unified position stream relies on the legacy
/// `CLLocationManager.allowsBackgroundLocationUpdates` contract to keep the
/// process executing while backgrounded. On modern iOS that contract is
/// supplemented by explicit session objects, and holding them is Apple's
/// supported way to declare the app's background-location needs:
///
///   - `CLBackgroundActivitySession` (iOS 17+): keeps a When-In-Use app
///     "effectively in-use" while backgrounded — a strictly stronger
///     assertion than `showsBackgroundLocationIndicator` alone.
///   - `CLServiceSession(authorization: .always)` (iOS 18+): since iOS 18,
///     Always authorization is only effective for the modern delivery APIs
///     while such a session is held; held here as forward-compatible
///     hardening for the SLC relaunch path, ONLY when Always is already
///     granted (creating it earlier could drive an authorization prompt).
///
/// ## Lifecycle rules (Apple contracts)
///
///   - Both objects must be held STRONGLY: deallocation invalidates them.
///   - `invalidate()` is permanent — an invalidated session can never become
///     active again, so `disarm()` always nils after invalidating and
///     `arm()` recreates from scratch.
///   - A new session may only become ACTIVE while the app is in use, with one
///     exception: a session held when the app was previously terminated can
///     be retaken for a few seconds after a background relaunch. `arm()` must
///     therefore run SYNCHRONOUSLY inside `didFinishLaunchingWithOptions`
///     (both the normal and the SLC-relaunch branch) — never in a deferred
///     task. A session created in background with no predecessor merely stays
///     inactive until the next foreground; creation itself never fails.
///
/// ## Consent + authorization gates
///
/// `arm()` re-reads, at call time (never cached): the persisted
/// background-sharing toggle AND the accepted background disclosure AND the
/// CoreLocation authorization status — and DISARMS unless all three permit.
/// So a launch-time or foreground-time arm can never hold an OS keep-alive
/// against the user's intent (or for a never-disclosed pre-2026-06-07
/// toggle), a Dart `arm` racing a disable fails closed, and no session
/// creation can ever drive an authorization prompt the user did not
/// initiate.
///
/// Main-thread only: every caller (AppDelegate hooks, method-channel
/// callbacks) already runs on the main thread.
final class HavenBackgroundSessionHandler: NSObject {
  /// The MethodChannel name for Dart arm/disarm/status requests.
  static let channelName = "haven.app/ios_background_session"

  /// UserDefaults key written by SharedPreferences for the background-sharing
  /// toggle. SharedPreferences stores bool values under the `flutter.` prefix.
  private static let kBgSharingKey = "flutter.haven.background_sharing"

  /// UserDefaults key for the accepted BACKGROUND prominent disclosure.
  ///
  /// ANDed into the arm predicate so the launch-time arm can never hold a
  /// keep-alive for the pre-2026-06-07 cohort whose persisted toggle is
  /// `true` without an accepted background disclosure — the exact state the
  /// Dart-side load reconcile repudiates ("disclosure before collection").
  private static let kBgDisclosureKey =
    "flutter.haven.location.disclosure_background_accepted"

  /// Strongly-held `CLBackgroundActivitySession` (iOS 17+). Stored as `Any?`
  /// because stored properties cannot be availability-guarded; every touch is
  /// inside an `#available` block.
  private var backgroundActivity: Any?

  /// Strongly-held `CLServiceSession` (iOS 18+, Always-authorized only).
  private var alwaysSession: Any?

  // MARK: - Registration

  /// Registers the MethodChannel on the given binary messenger.
  ///
  /// Must be called from `didFinishLaunchingWithOptions` after the Flutter
  /// engine is running (mirrors `HavenLocationAuthHandler.register`).
  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(
          code: "unavailable",
          message: "background session handler deallocated",
          details: nil
        ))
        return
      }
      switch call.method {
      case "arm":
        self.arm()
        result(nil)
      case "disarm":
        self.disarm()
        result(nil)
      case "status":
        result(self.status())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Session lifecycle

  /// Creates the session objects when background sharing is enabled;
  /// releases them when it is not. Idempotent.
  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      // Toggle off, background disclosure never accepted, or a racing
      // disable: fail closed.
      disarm()
      return
    }
    // An unauthorized app has no location claim for a session to assert, and
    // creating CLBackgroundActivitySession while .notDetermined can itself
    // drive a When-In-Use prompt — at launch, before any Haven UI — which a
    // TCC reset (Settings → Reset Location & Privacy) with a persisted-true
    // toggle would otherwise trigger.
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *), backgroundActivity == nil {
      backgroundActivity = CLBackgroundActivitySession()
    }
    if #available(iOS 18.0, *) {
      if status == .authorizedAlways {
        if alwaysSession == nil {
          // No prompt possible: Always is already granted, so there is
          // nothing for the session's authorization goal to "seek".
          alwaysSession = CLServiceSession(authorization: .always)
        }
      } else if let held = alwaysSession as? CLServiceSession {
        // Downgraded in Settings while held: drop the unfulfilled .always
        // goal so Core Location never re-asks on the app's behalf at the
        // next foreground.
        held.invalidate()
        alwaysSession = nil
      }
    }
  }

  /// Invalidates and releases every held session.
  ///
  /// Invalidated sessions can never become active again, so both references
  /// are nilled — `arm()` recreates from scratch.
  func disarm() {
    if #available(iOS 17.0, *) {
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
    }
    backgroundActivity = nil
    if #available(iOS 18.0, *) {
      (alwaysSession as? CLServiceSession)?.invalidate()
    }
    alwaysSession = nil
  }

  // MARK: - Status (observability; compiled into release, exposes booleans
  // only)

  private func status() -> [String: Bool] {
    var supported = false
    if #available(iOS 17.0, *) {
      supported = true
    }
    return [
      "supported": supported,
      "backgroundActivitySessionHeld": backgroundActivity != nil,
      "serviceSessionHeld": alwaysSession != nil,
    ]
  }
}
