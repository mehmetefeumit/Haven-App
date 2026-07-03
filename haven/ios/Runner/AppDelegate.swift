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

    // M7-D: Enable predicate gates ALL scheduling:
    //
    //   isEnabled() = UserDefaults["flutter.haven.background_sharing"]
    //               AND UserDefaults["flutter.background_catchup_enabled"]
    //
    // On this ship, Dart writes backgroundCatchupEnabled=false to
    // "flutter.background_catchup_enabled" at main() startup. So on a cold
    // launch, the key may not yet exist when this block runs (first launch).
    // Both startMonitoring() and scheduleNextCatchup() read the key at call
    // time, and they are guarded by isEnabled() → guard bgSharing && enabled.
    // Until the Dart side writes `true`, they are no-ops.
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
      // backgroundCatchupEnabled=false (inert on this ship).
      slcHandler.startMonitoring()
    } else {
      // Normal foreground launch: start monitoring + schedule the BGTask floor.
      // Both are no-ops while backgroundCatchupEnabled=false.
      slcHandler.startMonitoring()
      bgTaskHandler.scheduleNextCatchup()
    }

    return result
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
