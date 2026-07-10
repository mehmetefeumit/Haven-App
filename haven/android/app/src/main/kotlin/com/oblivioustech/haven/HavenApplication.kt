package com.oblivioustech.haven

import android.app.Application
import android.util.Log
import io.crates.keyring.Keyring

/**
 * Registers the Android context with the Rust `ndk_context` crate on every
 * process start.
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
        super.onCreate()
        try {
            Keyring.initializeNdkContext(applicationContext)
        } catch (t: Throwable) {
            Log.e(TAG, "onCreate: Keyring.initializeNdkContext failed", t)
        }
    }

    companion object {
        private const val TAG = "HavenApplication"
    }
}
