import Flutter
import UIKit

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

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // M7-D: Register the BGTask handler BEFORE super returns (Apple contract).
    // This is unconditional — registering the handler is always safe; only
    // scheduling tasks (scheduleNextCatchup) is gated by the enable predicate.
    bgTaskHandler.registerBGTask()

    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let messenger = controller.binaryMessenger

      // Existing handler: CoreLocation "Always" authorization bridge.
      locationAuthHandler.register(with: messenger)

      // M7-D: Register the BGTask catch-up channel (strong channel capture).
      bgTaskHandler.register(with: messenger)

      // M7-D: Register the SLC catch-up channel (strong channel capture).
      slcHandler.register(with: messenger)
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

    return result
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
