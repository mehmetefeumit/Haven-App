import Flutter
import UIKit

/// Haven's one scene. Its window shows the view controller `AppDelegate`
/// keeps on the engine it runs from launch, and it carries the UI-state
/// hooks UIKit stops sending the app delegate once the app adopts scenes.
/// Every override calls `super`, which is what forwards the event to the
/// plugins.
class SceneDelegate: FlutterSceneDelegate {
  // Privacy: a blur overlay shown while the scene is not active so the
  // OS-captured app-switcher snapshot does not reveal member locations or
  // avatars. It is removed once the scene becomes active again. iOS has no
  // FLAG_SECURE equivalent, so this snapshot blur is the available protection
  // for the recents thumbnail (it does not block in-app screenshots).
  private var privacyBlurView: UIVisualEffectView?

  private var appDelegate: AppDelegate {
    UIApplication.shared.delegate as! AppDelegate
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    // Shown, never built here: a scene that reconnects after iOS disconnected
    // it must find the controller, and the engine, the process already runs.
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = appDelegate.flutterViewController
    self.window = window
    window.makeKeyAndVisible()
    // After the window: super registers its root controller's engine with
    // this scene, which is how plugins receive scene events.
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Covered until sceneDidBecomeActive: a scene reconnected in the
    // background shows the kept controller's last frame, which iOS can
    // snapshot before the scene is ever active. Unconditional: at connect a
    // user's launch and a background one look alike.
    coverWithPrivacyBlur()
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    super.sceneWillEnterForeground(scene)
    appDelegate.sceneWillEnterForeground()
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    appDelegate.sceneDidEnterBackground()
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    coverWithPrivacyBlur()
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyBlurView?.removeFromSuperview()
    privacyBlurView = nil
  }

  private func coverWithPrivacyBlur() {
    guard let window = window, privacyBlurView == nil else { return }
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blur.frame = window.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(blur)
    privacyBlurView = blur
  }
}
