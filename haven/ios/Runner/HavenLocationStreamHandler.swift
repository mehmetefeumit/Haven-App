import CoreLocation
import Flutter
import UIKit

/// Owns the single `CLLocationManager` that delivers Haven's position stream
/// on iOS, and bridges it to Dart over one MethodChannel + one EventChannel.
///
/// ## Why a native owner
///
/// The stream must run at ONE of exactly two accuracy tiers and move between
/// them LIVE — `kCLLocationAccuracyBest` while foregrounded or moving,
/// `kCLLocationAccuracyHundredMeters` while backgrounded and stationary. A
/// live `desiredAccuracy` write is the only way to do that without a
/// stop/start cycle; `geolocator` can only express start and stop, and a
/// RESTART while backgrounded is refused by iOS. The stationary/moving
/// decision itself stays in Dart (nothing runs Swift unit tests in CI), so
/// this class holds no policy beyond the two writes it is told to make.
///
/// Both profiles keep the shape that lets a backgrounded app keep receiving:
/// background updates allowed, `distanceFilter` pinned to
/// `kCLDistanceFilterNone`, `desiredAccuracy` never coarser than
/// `kCLLocationAccuracyHundredMeters`, and automatic pausing off. A THIRD,
/// coarser tier would leave that shape and re-create the suspension the 16.4
/// rule describes, so exactly two accuracy values are ever assigned.
///
/// ## Background starts are refused, not attempted
///
/// iOS rejects a background-capable location start issued while the app is in
/// the background, and a refused start is indistinguishable from a
/// running one until peers stop receiving. `onListen` therefore refuses it
/// itself when `applicationState == .background` — the state test is `==
/// .background` and never `!= .active`, because Flutter's `resumed` is
/// delivered from `applicationDidBecomeActive`, so a legitimate foreground
/// start can land while UIKit still reports `.inactive`. Together with the
/// Dart cold-cache shortcut (which reads `backgrounded` from `status()` and
/// fails closed) a process relaunched in the background can only ever receive,
/// never publish.
///
/// ## Errors travel through the SINK
///
/// A `FlutterError` RETURNED from `onListen` is handed to
/// `FlutterError.reportError` on the Dart side and never reaches the stream,
/// so a refusal returned that way would be silently swallowed. Every outcome
/// — the background refusal and every CoreLocation failure — is pushed
/// through the event sink instead, and `onListen` always returns `nil`.
/// Failures carry the error TYPE only: an error's text can carry internal
/// state, and no such string may reach Dart (Security Rule 8).
///
/// One error is deliberately NOT forwarded: `CLError.locationUnknown` is the
/// documented "no fix right now, still trying" signal, not a failure. It is
/// routine indoors — precisely where the stationary 100 m tier runs — and Dart
/// treats an error as the end of the session's tier bookkeeping, so passing it
/// on ended background sharing over a momentary loss of signal.
///
/// ## Only Best-profile fixes are publishable
///
/// `bestSince` records the instant of every switch to Best. A fix is treated
/// as Best — cached in `lastBestFix`, tagged `best` on the wire to Dart — only
/// when the manager is at Best AND the fix was computed after that switch, so
/// a fix produced under the 100 m tier that arrives just after the switch is
/// never mistaken for a GPS-grade one. `lastBestFix` is dropped on `onCancel`
/// and on `clearLastBestFix` (logout, opt-out pause): a full-precision
/// coordinate must not outlive the consent that produced it, in Dart or in
/// native memory (privacy Rule 10).
///
/// No logging: this class has nothing it could say that would not be a
/// coordinate or an error's internals (Security Rule 6, and the posture of
/// `HavenBackgroundSessionHandler`).
///
/// Main-thread only: the manager is created on the main thread, so its
/// delegate callbacks, the channel callbacks and the `UIApplication` reads all
/// run there.
final class HavenLocationStreamHandler: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
  /// The MethodChannel name for profile switches, the cached Best fix and
  /// status reads.
  static let channelName = "haven.app/ios_location_stream"

  /// The EventChannel name carrying the position stream. Distinct from
  /// `channelName`: iOS keeps one handler per channel name.
  static let eventChannelName = "haven.app/ios_location_stream/events"

  /// The two profile names shared with Dart, used both as the `setProfile`
  /// argument and as the `profile` tag on every delivered fix.
  private static let profileBest = "best"
  private static let profileHundredMeters = "hundredMeters"

  /// Called on every CoreLocation authorization change. `AppDelegate` wires it
  /// to the session handler's `arm()`, which re-evaluates the tier policy.
  /// Assigned AFTER registration, so the callback CoreLocation fires at
  /// manager creation finds nothing to call.
  var onAuthorizationChanged: (() -> Void)?

  /// Owner of the `alwaysConfirmed` predicate that decides the indicator
  /// policy. Weak: `AppDelegate` retains both handlers for the app's lifetime.
  weak var sessionHandler: HavenBackgroundSessionHandler?

  private let manager = CLLocationManager()

  /// The live event sink, or nil while nothing is subscribed. Doubles as the
  /// "running" flag: no fix is emitted or cached without a subscriber.
  private var sink: FlutterEventSink?

  /// Instant of the most recent switch to the Best profile. `distantFuture`
  /// until the first start, so nothing counts as Best before one.
  private var bestSince = Date.distantFuture

  /// The most recent Best-profile fix, served to Dart as the last-known
  /// position while backgrounded. Cleared with the subscription and on demand.
  private var lastBestFix: CLLocation?

  override init() {
    super.init()
    manager.delegate = self
    // Set once, for both profiles: auto-pause would end delivery with no
    // callback and no restart path while backgrounded; no distance filter and
    // an accuracy never coarser than 100 m are what keep a backgrounded app
    // receiving; `.other` claims no activity-specific behaviour.
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .other
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  // MARK: - Registration

  /// Registers both channels on the given binary messenger.
  ///
  /// Must be called from `didFinishLaunchingWithOptions` after the Flutter
  /// engine is running (mirrors `HavenBackgroundSessionHandler.register`).
  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(
          code: "unavailable",
          message: "location stream handler deallocated",
          details: nil
        ))
        return
      }
      switch call.method {
      case "setProfile":
        let name = call.arguments as? String ?? ""
        if self.setProfile(name) {
          result(nil)
        } else {
          result(FlutterError(code: "invalid_profile", message: nil, details: nil))
        }
      case "lastBestFix":
        result(self.lastBestFixMap())
      case "clearLastBestFix":
        self.lastBestFix = nil
        result(nil)
      case "status":
        result(self.status())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    FlutterEventChannel(
      name: Self.eventChannelName,
      binaryMessenger: messenger
    ).setStreamHandler(self)
  }

  // MARK: - Indicator policy

  /// Re-applies the tier-driven indicator policy.
  ///
  /// Under CONFIRMED Always the flag is the only remaining source of the blue
  /// bar, and OD1 turns it off; under When-In-Use — which is what the OS
  /// treats a provisional or iOS 17 Always as — the bar is mandatory and the
  /// OS ignores the flag, so `true` there is simply honest. Called at start,
  /// on every authorization change, and whenever the session handler's
  /// confirmation flips.
  func applyIndicatorPolicy() {
    manager.showsBackgroundLocationIndicator = !(sessionHandler?.alwaysConfirmed ?? false)
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    // A re-listen is engine-driven — the engine cancels the existing sink
    // before delivering a new listen — so this is unreachable.
    guard sink == nil else { return nil }

    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false

    if allowsBg && UIApplication.shared.applicationState == .background {
      // iOS rejects the start itself; refusing it here makes the rejection
      // observable instead of silent, and keeps a background relaunch
      // receive-only.
      events(FlutterError(code: "background_start_refused", message: nil, details: nil))
      events(FlutterEndOfEventStream)
      return nil
    }

    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    // Recorded BEFORE the accuracy write, so no fix computed under the
    // previous tier can fall on the Best side of the comparison.
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    lastBestFix = nil
    sink = nil
    return nil
  }

  // MARK: - Profile

  /// Moves `desiredAccuracy` between the two permitted values on the RUNNING
  /// manager. Returns false for any other name, which the channel reports as
  /// an error rather than silently picking a tier.
  private func setProfile(_ name: String) -> Bool {
    switch name {
    case Self.profileBest:
      bestSince = Date()
      manager.desiredAccuracy = kCLLocationAccuracyBest
    case Self.profileHundredMeters:
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    default:
      return false
    }
    return true
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let events = sink else { return }
    for loc in locations {
      if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince {
        lastBestFix = loc
        events(fixMap(loc, profile: Self.profileBest))
      } else {
        events(fixMap(loc, profile: Self.profileHundredMeters))
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let events = sink else { return }
    let code = (error as? CLError)?.code
    // `locationUnknown` means "no fix right now"; CoreLocation keeps trying and
    // Apple documents clients as ignoring it. It is routine INDOORS, which is
    // exactly where the stationary 100 m tier runs — and forwarding it ended
    // the Dart session's tier bookkeeping, so one ordinary indoor moment used
    // to stop background sharing until the app was reopened.
    if code == .locationUnknown { return }
    events(FlutterError(
      code: code == .denied ? "denied" : "failed",
      message: "\(type(of: error))",
      details: nil
    ))
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Re-arm first: the indicator policy reads the predicate that arm()
    // re-evaluates. CoreLocation fires this at manager creation and in the
    // background, and both callees are idempotent.
    onAuthorizationChanged?()
    applyIndicatorPolicy()
  }

  // MARK: - Status and cached fix (booleans and enum strings only)

  private func status() -> [String: Any] {
    return [
      "running": sink != nil,
      "allowsBackgroundLocationUpdates": manager.allowsBackgroundLocationUpdates,
      "showsBackgroundLocationIndicator": manager.showsBackgroundLocationIndicator,
      "profile": manager.desiredAccuracy == kCLLocationAccuracyBest
        ? Self.profileBest
        : Self.profileHundredMeters,
      "authorization": authorizationString(),
      "backgrounded": UIApplication.shared.applicationState == .background,
    ]
  }

  private func lastBestFixMap() -> [String: Any]? {
    guard let fix = lastBestFix else { return nil }
    return fixMap(fix, profile: Self.profileBest)
  }

  private func fixMap(_ loc: CLLocation, profile: String) -> [String: Any] {
    return [
      "lat": loc.coordinate.latitude,
      "lon": loc.coordinate.longitude,
      "tsMs": Int(loc.timestamp.timeIntervalSince1970 * 1000),
      "acc": loc.horizontalAccuracy,
      "alt": loc.altitude,
      "speed": loc.speed,
      "course": loc.course,
      "profile": profile,
    ]
  }

  /// The Dart `IosAuthStatus` vocabulary, identical to
  /// `HavenLocationAuthHandler.statusString()`.
  private func authorizationString() -> String {
    switch manager.authorizationStatus {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedWhenInUse: return "whenInUse"
    case .authorizedAlways: return "always"
    @unknown default: return "unknown"
    }
  }
}
