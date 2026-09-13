package com.oblivioustech.haven

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import io.crates.keyring.Keyring

/**
 * Process-wide setup that must run before any Activity, Service or worker: the
 * app-wide screenshot block, the [PublishWakeLock] task-lifecycle listener, and
 * the Android context the Rust `ndk_context` crate needs.
 *
 * The Rust keyring backend
 * (`android_native_keyring_store::Store::from_ndk_context()`) reads this context
 * to open the platform Keystore, and `ndk_context::android_context()` panics
 * "android context was not initialized" when it was never registered — a panic
 * that then poisons the one-shot keyring-init lock (`KEYRING_INIT` in
 * `rust_builder/src/api.rs`), failing every retry with "Keyring lock poisoned".
 *
 * [Application.onCreate] runs exactly once per process, before any Activity,
 * Service, or WorkManager worker — including a HEADLESS cold wake (the M7-E
 * background catch-up worker after the app process was killed or the device
 * rebooted, which is its primary use case). Registering here rather than only in
 * [MainActivity] — which never runs during such a wake — is what lets that
 * worker open the circle DB. Mirrors WhiteNoise's `WhitenoiseApplication`.
 *
 * `ndk_context::initialize_android_context` asserts single-initialization
 * (`assert!(previous.is_none())`), so this MUST be the only call site per
 * process — the old [MainActivity] call was removed, not duplicated. The
 * try/catch is defensive: a keyring-registration failure must never crash the
 * whole app at startup; the worker instead surfaces a handled error and retries.
 */
class HavenApplication : Application() {
    override fun onCreate() {
        // Positive control for the runtime log-privacy scanner
        // (`tooling/logscan`, Phase 0b): proves the `logcat` sink is reached
        // this early in the process lifecycle, before anything else in this
        // method can run or fail. Undeclared (no host proxy channel reaches
        // this process) and matched by shape; literal token only — see
        // `scripts/ci/native_log_allowlist.txt`.
        if (BuildConfig.DEBUG) {
            Log.d(TAG, "logscan-plant-kotlin-open-K2AM7DR9FT")
        }
        super.onCreate()
        registerActivityLifecycleCallbacks(SecureWindowCallbacks)
        // The foreground-service task engine is created without an Activity
        // (boot restart, headless wake), and its `onEngineCreate` is the only
        // hook that hands that engine over before the Dart entrypoint runs. A
        // listener registered from MainActivity would therefore miss exactly
        // the process starts background sharing depends on.
        PublishWakeLock.attach(applicationContext)
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PublishWakeLock)
        try {
            Keyring.initializeNdkContext(applicationContext)
        } catch (t: Throwable) {
            // Class name only, the Kotlin twin of the repo's Dart
            // `${e.runtimeType}` convention (Security Rule 8): android.util.Log
            // is NOT stripped from release builds, so the call is also gated on
            // BuildConfig.DEBUG (Security Rule 15) — passing `t` here would
            // otherwise print a keyring/JNI message and stack trace into every
            // user's logcat. The class is what says which failure this was.
            if (BuildConfig.DEBUG) {
                Log.e(TAG, "onCreate: Keyring.initializeNdkContext failed: ${t::class.java.simpleName}")
            }
        }
    }

    companion object {
        private const val TAG = "HavenApplication"
    }
}

/**
 * Sets `FLAG_SECURE` on EVERY Activity in the process, which is what makes the
 * app's stated promise ("Haven blocks screenshots and screen recording
 * everywhere in the app") true.
 *
 * Setting the flag per Activity only covers the Activities we write. Haven also
 * shows the user's picked photo full-screen in
 * `com.yalantis.ucrop.UCropActivity` — a dependency's Activity, whose
 * `onCreate` we cannot touch — so the promise held for [MainActivity] and
 * nowhere else. Registering here covers every Activity hosted in this process,
 * including ones added by a future plugin.
 *
 * [Application.ActivityLifecycleCallbacks.onActivityCreated] is the earliest
 * hook available at minSdk 23 (`onActivityPreCreated` is API 29+), and it still
 * runs before the window is added to the WindowManager — the deadline for
 * `FLAG_SECURE` to take effect — and again on every recreation.
 */
private object SecureWindowCallbacks : Application.ActivityLifecycleCallbacks {
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        activity.window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityResumed(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) = Unit
}
