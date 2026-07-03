import BackgroundTasks
import Flutter

/// Registers and handles a `BGAppRefreshTask` that triggers a Dart catch-up
/// sweep as a background floor for when SLC monitoring is insufficient.
///
/// ## Purpose
///
/// `BGAppRefreshTask` provides a best-effort periodic floor (minutes–hours,
/// OS-discretionary). Haven uses it to supplement the Significant-Location-
/// Change path, ensuring the receive-only sweep runs even when the device
/// does not move significantly.
///
/// ## Registration contract (Apple requirement)
///
/// `BGTaskScheduler.register(forTaskWithIdentifier:)` MUST be called before
/// `didFinishLaunchingWithOptions` returns — Apple's contract. Therefore
/// `registerBGTask()` is called unconditionally from AppDelegate regardless of
/// the enable predicate (harmless on Simulator and flag-OFF builds).
///
/// The identifier `app.haven.catchup` must also appear in
/// `Info.plist → BGTaskSchedulerPermittedIdentifiers`. A mismatch causes a
/// crash on device (the task is registered but iOS cannot find the identifier).
///
/// ## SHIPPED INERT
///
/// `scheduleNextCatchup()` is a no-op unless BOTH:
///   1. The user has enabled background sharing (`haven.background_sharing`
///      in UserDefaults/SharedPreferences), AND
///   2. `backgroundCatchupEnabled` is mirrored as true in UserDefaults
///      (`flutter.background_catchup_enabled`).
///
/// On this ship, `backgroundCatchupEnabled = false` → Dart writes `false` to
/// `flutter.background_catchup_enabled` at startup → `scheduleNextCatchup()`
/// is always a no-op → zero BGTasks are ever submitted.
///
/// In the Simulator, `BGTaskScheduler.submit()` returns `notPermitted` — this
/// is swallowed silently so CI (e2e-ios) does not fail.
///
/// ## Strong channel capture
///
/// The `FlutterMethodChannel` is held as a strong stored property. There is
/// NO `[weak channel]` capture in any completion-handler closure — the
/// reverted draft's weak captures allowed the channel to deallocate before
/// use, silently killing both wake paths.
///
/// ## Main()-race mitigation
///
/// BGAppRefreshTask fires after the app is relaunched by the OS; the Dart
/// engine starts asynchronously from `main()`. The handler always calls
/// `setTaskCompleted(success:)` in the expiration handler so the task is
/// never left dangling. If the Dart handler is not yet registered, the reply
/// is `FlutterMethodNotImplemented`; the handler simply marks the task
/// completed and schedules the next BGTask so the window is retried.
///
/// ## On-device validation required (cannot be asserted in flutter test)
///
///   - BGTask fires after ~15+ min (OS-discretionary).
///   - Channel call reaches Dart handler.
///   - No task is submitted when either flag is false (privacy inert).
///   - Simulator submit() error is swallowed (CI safe).
final class HavenBGTaskHandler {
  /// The BGTaskScheduler identifier. Must match
  /// `Info.plist → BGTaskSchedulerPermittedIdentifiers → app.haven.catchup`.
  static let taskIdentifier = "app.haven.catchup"

  /// The MethodChannel name. Shared with HavenSLCHandler (same Dart handler).
  static let channelName = "haven.app/ios_background_catchup"

  /// The teardown channel for `cancelAllBGTasks` calls from Dart.
  ///
  /// Dedicated to BGTask — must NOT be shared with HavenSLCHandler. iOS keeps
  /// only one method-call handler per channel name, so a shared name would let
  /// one handler's registration silently overwrite the other's.
  static let teardownChannelName = "haven.app/ios_bgtask_teardown"

  /// UserDefaults key written by SharedPreferences for the background-sharing
  /// toggle. SharedPreferences stores bool values under the `flutter.` prefix.
  private static let kBgSharingKey = "flutter.haven.background_sharing"

  /// UserDefaults key written by Dart at startup to mirror the compile-time
  /// `backgroundCatchupEnabled` constant.
  private static let kBgCatchupEnabledKey = "flutter.background_catchup_enabled"

  /// Minimum interval between BGAppRefreshTask submissions.
  ///
  /// The OS enforces its own minimum (typically ~15 min for BGAppRefreshTask);
  /// this constant is a lower bound hint — the OS may delay longer.
  private static let minimumFetchInterval: TimeInterval = 15 * 60 // 15 min

  /// Strong reference to the catch-up trigger channel. Must NOT be weak.
  private var channel: FlutterMethodChannel?

  /// Creates the BGTask handler.
  init() {}

  // MARK: - Registration (unconditional — Apple contract)

  /// Registers the BGTask handler with `BGTaskScheduler`.
  ///
  /// MUST be called before `didFinishLaunchingWithOptions` returns (Apple
  /// contract). Called unconditionally — registration is harmless when the
  /// task is never submitted (flag-OFF builds, Simulator).
  ///
  /// The `launchHandler` reschedules first (so the floor persists even if the
  /// handler is killed early), runs the Dart catch-up, then calls
  /// `setTaskCompleted`.
  func registerBGTask() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      using: nil
    ) { [weak self] task in
      guard let self = self, let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.handleBGTask(refreshTask)
    }
  }

  // MARK: - Channel registration

  /// Registers the MethodChannel and the teardown channel.
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

    // Teardown channel: Dart calls "cancelAllBGTasks" when the user disables
    // background sharing, wired in disableBackgroundScheduling().
    let teardownChannel = FlutterMethodChannel(
      name: Self.teardownChannelName,
      binaryMessenger: messenger
    )
    teardownChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "unavailable", message: "BGTask handler deallocated", details: nil))
        return
      }
      switch call.method {
      case "cancelAllBGTasks":
        BGTaskScheduler.shared.cancelAllTaskRequests()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Enable predicate

  /// Returns true only when BOTH flags are true in UserDefaults.
  ///
  /// On this ship `backgroundCatchupEnabled = false` so the Dart side writes
  /// false to `kBgCatchupEnabledKey` at startup → always returns false →
  /// no BGTask is ever submitted.
  private func isEnabled() -> Bool {
    let defaults = UserDefaults.standard
    let bgSharing = defaults.bool(forKey: Self.kBgSharingKey)
    let catchupEnabled = defaults.bool(forKey: Self.kBgCatchupEnabledKey)
    return bgSharing && catchupEnabled
  }

  // MARK: - Scheduling

  /// Submits a BGAppRefreshTask request when the enable predicate holds.
  ///
  /// Safe to call multiple times — `BGTaskScheduler.submit` with the same
  /// identifier replaces any pending request.
  ///
  /// In the Simulator `submit()` throws `BGTaskScheduler.Error.notPermitted`;
  /// this is swallowed so CI (e2e-ios) does not fail.
  func scheduleNextCatchup() {
    guard isEnabled() else {
      // Inert: backgroundCatchupEnabled=false → Dart writes false to
      // kBgCatchupEnabledKey → this guard always fires on this ship.
      return
    }

    let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumFetchInterval)

    do {
      try BGTaskScheduler.shared.submit(request)
      debugLog("BGTask scheduled")
    } catch {
      // BGTaskScheduler.Error.notPermitted in Simulator — swallow silently.
      // Other errors (e.g. taskNotPermittedInBackground) are also swallowed
      // so a scheduling failure never propagates to the caller.
      debugLog("BGTask submit error: \(type(of: error))")
    }
  }

  // MARK: - Task handler

  /// Handles an incoming `BGAppRefreshTask`.
  ///
  /// Order:
  ///   1. Reschedule the next task first so the floor persists even if the
  ///      handler is killed by the OS before completion.
  ///   2. Set the expiration handler so `setTaskCompleted` is always called.
  ///   3. Re-check the enable predicate (C2 durable-intent re-check).
  ///   4. Trigger Dart catch-up via MethodChannel.
  ///   5. Call `setTaskCompleted(success:)`.
  private func handleBGTask(_ task: BGAppRefreshTask) {
    // 1. Reschedule first so the floor persists.
    scheduleNextCatchup()

    // 2. Expiration handler — always marks the task completed so iOS doesn't
    //    penalise Haven for leaving a task unfinished.
    task.expirationHandler = { [weak task] in
      task?.setTaskCompleted(success: false)
    }

    // 3. Durable-intent re-check (C2).
    guard isEnabled() else {
      task.setTaskCompleted(success: true)
      return
    }

    // 4. Trigger Dart catch-up.
    guard let channel = self.channel else {
      task.setTaskCompleted(success: false)
      return
    }

    channel.invokeMethod("runCatchup", arguments: nil) { [weak task] result in
      if let flutterError = result as? FlutterError {
        // Dart threw — log type only.
        #if DEBUG
        NSLog("[HavenBGTask] Dart error: %@", flutterError.code)
        #endif
        task?.setTaskCompleted(success: false)
      } else {
        // Success or FlutterMethodNotImplemented (Dart not ready).
        // Both are treated as "completed" so the floor is not penalised.
        task?.setTaskCompleted(success: true)
      }
    }
  }

  // MARK: - Logging

  private func debugLog(_ message: String) {
    #if DEBUG
    NSLog("[HavenBGTask] %@", message)
    #endif
  }
}
