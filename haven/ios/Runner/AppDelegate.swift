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

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
