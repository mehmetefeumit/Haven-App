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
  // The app's one engine, run from didFinishLaunching on every launch: a
  // location or BGTask wake reaches Dart before any scene connects, or with
  // none at all. The registry overrides below hand every registrar out from
  // it, so no second engine — a second main() beside this one (Rule 14) — is
  // ever started. `@objc`: RunnerTests reads it through the runtime.
  @objc let flutterEngine = FlutterEngine(name: "io.flutter")

  // The one view controller on that engine, kept for the app's lifetime and
  // shown by every scene's window (SceneDelegate); no scene builds its own.
  // A controller freed with a disconnected scene would make the engine send
  // Dart `detached`, stopping live sync in a process that is still sharing.
  @objc private(set) lazy var flutterViewController: FlutterViewController = {
    let controller = FlutterViewController(engine: self.flutterEngine, nibName: nil, bundle: nil)
    // The launch screen until Flutter's first frame: a storyboard controller
    // loaded it by itself, an engine-attached one only when asked.
    controller.loadDefaultSplashScreenView()
    return controller
  }()

  // Whether a scene of this process has entered the foreground. Until one
  // has, the user has not opened it.
  private var foregroundSeen = false

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

  // Tells Dart the default network changed, so the live-sync engine re-dials
  // sockets the old network carried.
  private let networkChangeHandler = HavenNetworkChangeHandler()

  // The QR scanner's channel and camera view (no Google code: AVFoundation +
  // Vision). Retained so the factory outlives didFinishLaunching.
  private let qrScannerHandler = HavenQrScannerHandler()

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

    // Before any registration: a handler set on an engine that is not yet
    // running is dropped (asserted only in a debug engine), so every channel
    // below would be silently missing.
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "HavenQrScanner") {
      qrScannerHandler.register(with: registrar)
    }

    let messenger = flutterEngine.binaryMessenger

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

    networkChangeHandler.register(with: messenger)

    // In place before startMonitoring() below, whose restart makes
    // CoreLocation deliver the event a location relaunch is for.
    slcHandler.onLocationEvent = { [weak self] in
      self?.noteLocationLaunch()
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
    // so they no-op here and are re-armed by sceneDidEnterBackground below
    // once Dart has written the mirror (A3).
    //
    // Location launch (D4): iOS starts a terminated Haven in the background
    // for a significant-change or region event, or for a background refresh.
    // Monitoring restarts on every launch, so CoreLocation delivers a fix to
    // the SLC delegate (which triggers the Dart catch-up and
    // noteLocationLaunch), and the BGTask floor stays scheduled on such a
    // launch too. Both are no-ops while either UserDefaults flag is false.
    slcHandler.startMonitoring()
    bgTaskHandler.scheduleNextCatchup()

    // Arm the CoreLocation background sessions SYNCHRONOUSLY, on EVERY
    // launch: a session held when the app was previously terminated can be
    // retaken only for a few seconds after a background relaunch, and a
    // normal-launch session simply stays inactive until foreground. The
    // handler re-reads the background-sharing consent predicate and disarms
    // when it is off.
    backgroundSessionHandler.arm()

    return result
  }

  // FlutterAppDelegate answers these from its own window, which stays nil
  // under scenes, by starting an engine of its own.
  override func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
    flutterEngine.registrar(forPlugin: pluginKey)
  }

  override func hasPlugin(_ pluginKey: String) -> Bool {
    flutterEngine.hasPlugin(pluginKey)
  }

  override func valuePublished(byPlugin pluginKey: String) -> NSObject? {
    flutterEngine.valuePublished(byPlugin: pluginKey)
  }

  // OD-R1's location launch, by the owner's rule (D4, 2026-11-28): the first
  // location event CoreLocation delivers to a process no scene has brought to
  // the front. Under scenes UIKit passes no launch options and every launch
  // starts in .background, so the event is the only witness; iOS delivers one
  // at every start of significant-change monitoring, so a background-refresh
  // launch counts too, as the owner accepted. Once per process. On a user's
  // cold launch that first fix can land before the scene's foreground:
  // sceneWillEnterForeground clears it, and Dart heals at its first lifecycle
  // message. `@objc`: RunnerTests calls it through the runtime.
  @objc func noteLocationLaunch() {
    let noted = locationStreamHandler.launchedForLocation
    guard Self.startsLocationLaunch(foregroundSeen: foregroundSeen, noted: noted) else { return }
    // The one fact that lets the stream handler start a background-capable
    // session from the background (OD-R1, owner-directed 2026-11-26); its
    // own predicate still needs Always and the current disclosure.
    locationStreamHandler.launchedForLocation = true
    locationStreamHandler.beginLaunchWindow()
    // Dart may already have read status() and settled its start-up on it.
    locationStreamHandler.notifyLocationLaunch()
  }

  // noteLocationLaunch()'s rule apart from the process state it reads, so
  // RunnerTests can drive the half a process the user opened never reaches.
  @objc(startsLocationLaunchWithForegroundSeen:noted:)
  static func startsLocationLaunch(foregroundSeen: Bool, noted: Bool) -> Bool {
    !foregroundSeen && !noted
  }

  // For RunnerTests, which reads it through the runtime.
  @objc var isLocationLaunch: Bool {
    locationStreamHandler.launchedForLocation
  }

  /// From `SceneDelegate.sceneWillEnterForeground`.
  func sceneWillEnterForeground() {
    // The user is in front: this is no longer a background launch, and no
    // later location event in this process makes it one.
    foregroundSeen = true
    locationStreamHandler.launchedForLocation = false
    locationStreamHandler.endLaunchWindow()
    // Re-arm on every foreground return: covers a toggle-enable whose Dart
    // arm call raced engine teardown, and drops a held .always service
    // session if authorization was downgraded in Settings while backgrounded
    // (the handler checks both). Idempotent no-op otherwise.
    backgroundSessionHandler.arm()
  }

  /// From `SceneDelegate.sceneDidEnterBackground`.
  func sceneDidEnterBackground() {
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
}
