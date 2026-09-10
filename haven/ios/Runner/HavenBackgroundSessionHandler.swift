import CoreLocation
import Flutter
import UIKit

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
///     assertion than `showsBackgroundLocationIndicator` alone. Created under
///     When-In-Use and until Always is CONFIRMED; under confirmed Always it
///     would be the pill, and nothing else needs it. `arm()` never withdraws
///     a claim while backgrounded; `disarm()` always does.
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
/// callbacks) already runs on the main thread, and the one asynchronous
/// producer — the `.always` session's diagnostics — hops back onto it before
/// touching any state. A hop is not a lock, though: a block enqueued there
/// runs after whatever ran in between, and `Task.cancel()` cannot reach it, so
/// it re-checks the session it speaks for rather than assuming one.
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

  /// Iterates the held `.always` session's diagnostics. Stored so a dropped
  /// session takes its observer with it.
  private var diagnosticsTask: Task<Void, Never>?

  /// Whether the OS has POSITIVELY confirmed effective Always authorization.
  ///
  /// FAIL-SAFE, and deliberately not `authorizationStatus == .authorizedAlways`:
  /// that property already reports `.authorizedAlways` while the second prompt
  /// is unanswered, although the EFFECTIVE authorization is still When-In-Use.
  /// Treating that provisional cohort as Always would drop the activity
  /// session for users the OS handles as When-In-Use — the exact shape that
  /// failed in the field. So this stays false until the `.always` service
  /// session's diagnostics say otherwise, which on iOS 17 (no diagnostics API)
  /// is never.
  private(set) var alwaysConfirmed = false

  /// Fired whenever `alwaysConfirmed` changes. `AppDelegate` wires it to the
  /// stream handler's indicator policy, which is the other half of the tier
  /// decision.
  var onAlwaysConfirmedChanged: (() -> Void)?

  /// Whether the consent + authorization gates last PASSED, i.e. whether this
  /// handler is running a session at all.
  ///
  /// Exists to disambiguate `alwaysConfirmed == false`, which otherwise
  /// carries two unrelated meanings: "a diagnostic measured this tier and it
  /// is not Always" and "nothing is running, so nothing has been measured".
  /// `disarm()` clears the predicate unconditionally, so while sharing is off
  /// the false is FORCED — and a reader (the settings copy) that treats it as
  /// a measurement promises the blue bar to a user who may well get the arrow
  /// once sharing starts. Nothing in Swift branches on this; it exists for the
  /// status channel, where the Dart side declines to name an indicator at all
  /// while it is false.
  private(set) var armed = false

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
    // Every gate passed: from here the handler IS running a session, so
    // `alwaysConfirmed` becomes a reading of the tier rather than the residue
    // of the last disarm. Set before the availability blocks, which decide
    // which objects the run holds, not whether there is one — on iOS 15/16
    // neither block creates anything while the stream handler's indicator flag
    // still puts the blue bar on screen.
    armed = true
    if #available(iOS 17.0, *) {
      // The activity session is what keeps a When-In-Use app executing while
      // backgrounded, and it is inseparable from the blue bar. Under CONFIRMED
      // Always neither is needed; a provisional Always and every iOS 17 Always
      // (no diagnostics API) stay unconfirmed and therefore keep both.
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        // arm() never withdraws a claim while backgrounded: an upgrade
        // delivered in the background would otherwise drop the only keep-alive
        // the process has, while its replacement cannot start outside the
        // foreground. The AppDelegate's foreground re-arm performs the
        // deferred invalidate.
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
    if #available(iOS 18.0, *) {
      if status == .authorizedAlways {
        if alwaysSession == nil {
          // No prompt possible: Always is already granted, so there is
          // nothing for the session's authorization goal to "seek".
          let session = CLServiceSession(authorization: .always)
          alwaysSession = session
          observeAlwaysDiagnostics(session)
        }
      } else {
        // Downgraded in Settings while held: drop the unfulfilled .always
        // goal so Core Location never re-asks on the app's behalf at the
        // next foreground.
        (alwaysSession as? CLServiceSession)?.invalidate()
        alwaysSession = nil
        // A confirmation is never more current than the session that yielded
        // it, and the clear is UNCONDITIONAL: gated on a still-held reference,
        // a `true` would survive any arm() that found the session already
        // gone. The stream handler's own authorization callback re-applies
        // the indicator right after this arm returns.
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        alwaysConfirmed = false
      }
    }
  }

  /// Watches the held `.always` session for the verdict that promotes
  /// `alwaysConfirmed`.
  ///
  /// The verdict is ASYNCHRONOUS — even the "immediate" first diagnostic of a
  /// settled authorization lands after `arm()` has returned — so this must
  /// re-run the tier policy itself. Without that, every genuinely-Always
  /// launch would spend its whole first background window on the When-In-Use
  /// posture, and nothing would undo it before the next foreground.
  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask?.cancel()
    diagnosticsTask = Task { [weak self] in
      do {
        for try await diagnostic in session.diagnostics {
          // Every clause must hold: a request still in progress means the user
          // has not answered the second prompt, and `insufficientlyInUse` means
          // Core Location cannot act on the Always goal yet. Either way the
          // effective authorization is When-In-Use.
          let confirmed = !diagnostic.alwaysAuthorizationDenied
            && !diagnostic.authorizationRequestInProgress
            && !diagnostic.insufficientlyInUse
          DispatchQueue.main.async {
            // Cancelling this task cannot reach a block already ENQUEUED here,
            // so the block re-checks WHICH session it speaks for: an arm() or
            // disarm() that ran in between may have invalidated the observed
            // session and dropped or replaced it. Identity against the held
            // reference is self-coupling — no release site can forget to
            // defeat it — and this block's own strong capture keeps `session`
            // alive, so the comparison can never alias a later object. A
            // confirmation applied from a dead session would leave
            // `alwaysConfirmed` true with nothing behind it, and the NEXT
            // Always grant would drop the activity session before any
            // diagnostic had confirmed anything — the provisional-Always shape
            // that failed in the field.
            guard let self = self,
              let held = self.alwaysSession as? CLServiceSession,
              held === session,
              self.alwaysConfirmed != confirmed
            else { return }
            self.alwaysConfirmed = confirmed
            self.arm()
            self.onAlwaysConfirmedChanged?()
          }
        }
      } catch {
        // A cancelled or failed diagnostics stream never PROMOTES the
        // predicate: the fail-safe When-In-Use posture simply stays.
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
    // The confirmation belonged to the session just released. Silent: the next
    // start re-applies the indicator policy from this (false) value, and the
    // manager is being torn down with the sessions anyway.
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    alwaysConfirmed = false
    // Cleared LAST, and always: it is what tells a reader that the `false`
    // above is a teardown and not a verdict.
    armed = false
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
      "alwaysConfirmed": alwaysConfirmed,
      "armed": armed,
    ]
  }
}
