import Flutter
import UIKit
import XCTest

// Hosted in the app under test (TEST_HOST = Runner), which the OS launches
// like a user's tap: these read the live scene, window and engine, not a mock
// of them. No @testable import, so the bundle also runs against the Release
// build the iOS launch gate ships; AppDelegate's members are reached through
// the Objective-C runtime instead.
final class RunnerTests: XCTestCase {

  /// The one scene, once UIKit has brought it to the front: a scene-based app
  /// launches in the background, so it can still be on its way when a test
  /// starts.
  private func activeScene() throws -> UIWindowScene {
    let active = NSPredicate { _, _ in
      UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }
    wait(for: [XCTNSPredicateExpectation(predicate: active, object: nil)], timeout: 60)
    let scenes = UIApplication.shared.connectedScenes
    XCTAssertEqual(scenes.count, 1)
    return try XCTUnwrap(scenes.first as? UIWindowScene)
  }

  private func sceneDelegate(of scene: UIWindowScene) throws -> UIWindowSceneDelegate {
    try XCTUnwrap(scene.delegate as? UIWindowSceneDelegate)
  }

  private func sceneWindow(of scene: UIWindowScene) throws -> UIWindow {
    try XCTUnwrap(try sceneDelegate(of: scene).window ?? nil)
  }

  /// A missing key would raise rather than fail, so it is asked about first.
  private func appDelegateValue<T>(_ key: String, as type: T.Type) throws -> T {
    let app = try XCTUnwrap(UIApplication.shared.delegate as? NSObject)
    let value = app.responds(to: NSSelectorFromString(key)) ? app.value(forKey: key) : nil
    return try XCTUnwrap(value as? T, "AppDelegate exposes no \(key) of type \(T.self)")
  }

  /// UIKit built the scene from the manifest's delegate, and its window shows
  /// the controller AppDelegate keeps on the engine it ran and registered
  /// every plugin on: a controller built per scene, or one that started an
  /// engine of its own (a storyboard's, a second main()), fails here.
  func testTheSceneShowsTheKeptControllerOnTheOneEngine() throws {
    let scene = try activeScene()
    let delegate = try XCTUnwrap(scene.delegate as? NSObject)
    XCTAssertEqual(NSStringFromClass(type(of: delegate)), "Runner.SceneDelegate")

    let window = try sceneWindow(of: scene)
    let controller = try XCTUnwrap(window.rootViewController as? FlutterViewController)
    let kept = try appDelegateValue("flutterViewController", as: FlutterViewController.self)
    let engine = try appDelegateValue("flutterEngine", as: FlutterEngine.self)
    XCTAssertTrue(controller === kept)
    XCTAssertTrue(controller.engine === engine)
    XCTAssertTrue(engine.viewController === controller)
    XCTAssertTrue(engine.hasPlugin("HavenQrScanner"))
  }

  /// The engine started while the app was still in the background, where its
  /// GPU starts disabled; a frame on screen proves the foreground re-enabled
  /// it. The launch gate's UI test cannot see this: it reads semantics, which
  /// do not need a frame.
  func testTheSceneRendersAFlutterFrame() throws {
    let window = try sceneWindow(of: try activeScene())
    let controller = try XCTUnwrap(window.rootViewController as? FlutterViewController)
    // Created before the read, so a frame landing between the two is seen.
    let rendered = XCTKVOExpectation(
      keyPath: "displayingFlutterUI", object: controller, expectedValue: true)
    if !controller.isDisplayingFlutterUI {
      wait(for: [rendered], timeout: 60)
    }
    XCTAssertTrue(controller.isDisplayingFlutterUI)
  }

  /// The app-switcher blur covers the scene's whole window from resign until
  /// active again, is gone afterwards, and comes back on the next resign.
  func testPrivacyBlurCoversTheWindowWhileInactive() throws {
    let scene = try activeScene()
    let delegate = try sceneDelegate(of: scene)
    let window = try sceneWindow(of: scene)

    delegate.sceneWillResignActive?(scene)
    let blur = try XCTUnwrap(window.subviews.last as? UIVisualEffectView)
    XCTAssertEqual(blur.frame, window.bounds)
    XCTAssertTrue(blur.effect is UIBlurEffect)
    XCTAssertEqual(blur.alpha, 1)
    XCTAssertFalse(blur.isHidden)

    delegate.sceneDidBecomeActive?(scene)
    XCTAssertFalse(window.subviews.contains { $0 is UIVisualEffectView })

    delegate.sceneWillResignActive?(scene)
    XCTAssertTrue(window.subviews.last is UIVisualEffectView)
    delegate.sceneDidBecomeActive?(scene)
    XCTAssertFalse(window.subviews.contains { $0 is UIVisualEffectView })
  }

  /// A location event reaching a process whose scene has come to the front is
  /// not a location launch: only a process no one has opened may start
  /// sharing from the background (OD-R1).
  func testALocationEventAfterTheForegroundIsNoLocationLaunch() throws {
    _ = try activeScene()
    let app = try XCTUnwrap(UIApplication.shared.delegate as? NSObject)
    let note = NSSelectorFromString("noteLocationLaunch")
    XCTAssertTrue(app.responds(to: note))
    XCTAssertFalse(try appDelegateValue("isLocationLaunch", as: Bool.self))

    _ = app.perform(note)

    XCTAssertFalse(try appDelegateValue("isLocationLaunch", as: Bool.self))
  }

  /// The manifest that makes UIKit deliver scene events at all, naming
  /// Haven's delegate, with no storyboard that would build a second engine.
  func testSceneManifestNamesHavenSceneDelegateAndNoStoryboard() throws {
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    XCTAssertNil(info["UIMainStoryboardFile"])
    let manifest = try XCTUnwrap(info["UIApplicationSceneManifest"] as? [String: Any])
    XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
    let configurations = try XCTUnwrap(manifest["UISceneConfigurations"] as? [String: Any])
    let roles = try XCTUnwrap(
      configurations["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])
    XCTAssertEqual(roles.count, 1)
    XCTAssertEqual(roles[0]["UISceneClassName"] as? String, "UIWindowScene")
    XCTAssertEqual(roles[0]["UISceneDelegateClassName"] as? String, "Runner.SceneDelegate")
    XCTAssertNil(roles[0]["UISceneStoryboardFile"])
  }
}
