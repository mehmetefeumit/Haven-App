import Flutter
import UIKit
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
private let HAVEN_RUNNER_LOG = OSLog(subsystem: "haven_ios", category: "runner")

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Privacy: a blur overlay shown while the app is inactive so the OS-captured
  // app-switcher snapshot does not reveal member locations or avatars. It is
  // removed once the app becomes active again. iOS has no FLAG_SECURE
  // equivalent, so this snapshot blur is the available protection for the
  // recents thumbnail (it does not block in-app screenshots).
  private var privacyBlurView: UIVisualEffectView?

  // Bridges CoreLocation "Always" authorization to Flutter. Retained for the
  // app's lifetime so its CLLocationManager and pending result survive.
  // geolocator can only request "When In Use" on iOS; Haven's background
  // sharing needs "Always", which this handler requests natively.
  private let locationAuthHandler = HavenLocationAuthHandler()

  // M7-D: BGTask handler. Retained as a property so its CLLocationManager,
  // channel reference, and registration state survive for the app's lifetime.
  // `registerBGTask()` MUST run before `super.application(_:didFinish...)`
  // returns — Apple's hard contract for BGTaskScheduler.register.
  private let bgTaskHandler = HavenBGTaskHandler()

  // M7-D: SLC handler. Retained as a property (mirrors locationAuthHandler
  // pattern). Holds a strong FlutterMethodChannel reference so neither the
  // CLLocationManager nor the channel deallocate while the app is running or
  // during a background SLC relaunch.
  private lazy var slcHandler: HavenSLCHandler = HavenSLCHandler(bgTaskHandler: bgTaskHandler)

  // CoreLocation background session objects (CLBackgroundActivitySession /
  // CLServiceSession). Retained for the app's lifetime: DEALLOCATION
  // INVALIDATES the held sessions, ending background location access.
  private let backgroundSessionHandler = HavenBackgroundSessionHandler()

  // Haven's own CLLocationManager for the position stream, with the two live
  // accuracy profiles. Retained for the app's lifetime: the manager, its
  // delegate and the live event sink must survive every background
  // transition, and a local would deallocate the stream when
  // didFinishLaunching returns.
  private let locationStreamHandler = HavenLocationStreamHandler()


  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // M7-D: Register the BGTask handler BEFORE super returns (Apple contract).
    // This is unconditional — registering the handler is always safe; only
    // scheduling tasks (scheduleNextCatchup) is gated by the enable predicate.
    bgTaskHandler.registerBGTask()

    // Positive control for the runtime log-privacy scanner (`tooling/logscan`,
    // Phase 0b): proves the `ios` (`log show`) sink is reached this early in
    // the launch path. Undeclared (no host proxy channel reaches this
    // process) and matched by shape; literal token only — see
    // `scripts/ci/native_log_allowlist.txt`.
    //
    // `#if DEBUG` is a compile-time condition, not the `DEBUG=1` preprocessor
    // macro the project sets for C/ObjC: it is true only while the Runner
    // target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS` names DEBUG. That setting
    // was absent until CI run 35280144455 showed this plant missing from ALL
    // FIVE iOS lanes' captures while the Rust one was present — every `#if
    // DEBUG` in this target, here and in the two wake handlers, was compiling
    // to nothing. Deleting it from the Debug configuration puts them all back
    // to always-off, silently.
    //
    // `os_log` with no `type:` is OS_LOG_TYPE_DEFAULT, which logd PERSISTS.
    // The Rust plant next door is a `log::debug!`, which the `oslog` crate maps
    // to OS_LOG_TYPE_INFO — memory-only, and evicted before `log collect` in
    // the two lanes of that run whose app lived longest. A control whose
    // survival depends on how long the lane ran is not a control.
    #if DEBUG
    os_log("logscan-plant-swift-open-N48X2CR93Y", log: HAVEN_RUNNER_LOG)
    #endif

    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let messenger = controller.binaryMessenger

      // Existing handler: CoreLocation "Always" authorization bridge.
      locationAuthHandler.register(with: messenger)

      // M7-D: Register the BGTask catch-up channel (strong channel capture).
      bgTaskHandler.register(with: messenger)

      // M7-D: Register the SLC catch-up channel (strong channel capture).
      slcHandler.register(with: messenger)

      // Register the background-session arm/disarm/status channel.
      backgroundSessionHandler.register(with: messenger)

      // The two handlers share one tier decision: the session handler owns the
      // Always-confirmed predicate, the stream handler applies the indicator
      // half of it and re-arms from its authorization delegate. Both wirings
      // are assigned AFTER the session handler is registered, so the
      // authorization callback CoreLocation fires when the stream handler's
      // manager was created (before this method ran) finds nothing to call and
      // the synchronous arm() below keeps its documented meaning.
      locationStreamHandler.sessionHandler = backgroundSessionHandler
      backgroundSessionHandler.onAlwaysConfirmedChanged = { [weak self] in
        self?.locationStreamHandler.applyIndicatorPolicy()
      }
      locationStreamHandler.register(with: messenger)
      locationStreamHandler.onAuthorizationChanged = { [weak self] in
        self?.backgroundSessionHandler.arm()
      }
    }

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // M7-D/E: Enable predicate gates ALL scheduling:
    //
    //   isEnabled() = UserDefaults["flutter.haven.background_sharing"]
    //               AND UserDefaults["flutter.background_catchup_enabled"]
    //
    // LIVE since M7-E: Dart writes backgroundCatchupEnabled=true to
    // "flutter.background_catchup_enabled" at main() startup. On a cold
    // launch the key may not yet exist when this block runs (first launch of
    // this build) — both startMonitoring() and scheduleNextCatchup() read the
    // key at call time, guarded by isEnabled() → guard bgSharing && enabled,
    // so they no-op here and are re-armed by applicationDidEnterBackground
    // below once Dart has written the mirror (A3).
    //
    // SLC relaunch detection: when the OS relaunches Haven due to a
    // Significant-Location-Change event, launchOptions[.location] is non-nil
    // AND applicationState is .background. In that case we re-start SLC
    // monitoring to ensure CLLocationManager redelivers the event to our
    // delegate (SLC delivery semantics require the manager to be running).
    let isRelaunchedForSLC = launchOptions?[.location] != nil
      && application.applicationState == .background
    if isRelaunchedForSLC {
      // Re-start SLC monitoring so the OS delivers the pending location event
      // to our delegate, which then triggers the Dart catch-up. The enable
      // predicate inside startMonitoring() still guards against running when
      // either UserDefaults flag is false.
      slcHandler.startMonitoring()
    } else {
      // Normal foreground launch: start monitoring + schedule the BGTask floor.
      // Both are no-ops while either UserDefaults flag is false.
      slcHandler.startMonitoring()
      bgTaskHandler.scheduleNextCatchup()
    }

    // Arm the CoreLocation background sessions SYNCHRONOUSLY, on BOTH launch
    // branches: a session held when the app was previously terminated can be
    // retaken only for a few seconds after a background relaunch, and a
    // normal-launch session simply stays inactive until foreground. The
    // handler re-reads the background-sharing consent predicate and disarms
    // when it is off.
    backgroundSessionHandler.arm()

    return result
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    // Re-arm on every foreground return: covers a toggle-enable whose Dart
    // arm call raced engine teardown, and drops a held .always service
    // session if authorization was downgraded in Settings while backgrounded
    // (the handler checks both). Idempotent no-op otherwise.
    backgroundSessionHandler.arm()
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    // M7-E (A3): re-arm the background wake paths on every backgrounding.
    // The didFinishLaunching block above runs BEFORE Dart writes the
    // backgroundCatchupEnabled mirror in main(), so on the FIRST launch of an
    // upgraded build — or in the very session where the user just enabled
    // background sharing — the launch-time arm was a no-op and nothing would
    // be scheduled until the SECOND launch. There is no Dart→Swift "arm"
    // channel (the channels are teardown-only), so this hook closes that
    // one-launch lag: by the time the app backgrounds, Dart has written both
    // UserDefaults keys. Both callees are idempotent and re-read isEnabled()
    // at call time, so this stays a no-op while background sharing (or the
    // mirror) is off — user opt-out is unaffected.
    slcHandler.startMonitoring()
    bgTaskHandler.scheduleNextCatchup()
  }

  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }
}
