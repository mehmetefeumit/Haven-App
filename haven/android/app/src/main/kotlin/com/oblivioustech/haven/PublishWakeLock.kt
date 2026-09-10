package com.oblivioustech.haven

import android.content.Context
import android.os.PowerManager
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The scoped `Haven:publish` partial wake lock, held by the foreground-service
 * isolate across ONE publish cycle (fix -> encrypt -> publish -> ack -> fetch).
 *
 * `flutter_foreground_task` already holds a PERMANENT, untimed
 * `PARTIAL_WAKE_LOCK` (`ForegroundService.acquireLockMode`) for the whole
 * background session, and Haven keeps it: it is the only wake source for the
 * no-fix watchdog and for the "armed but never delivered" recovery. So this
 * lock saves no power today. What it buys is a CPU hold Haven owns and that is
 * BOUNDED — every acquire expires after [MAX_TIMEOUT_MS] whatever Dart does
 * next — so that removing the permanent one, once a replacement wake source is
 * proven, is a deletion rather than a redesign (`docs/POWER_EFFICIENCY_PLAN.md`
 * D4).
 *
 * Registered from [HavenApplication.onCreate] rather than from an Activity: the
 * task engine is also created without one (boot restart, headless wake), and
 * [onEngineCreate] fires before the Dart entrypoint runs, so the channel is
 * installed before the isolate can call it.
 *
 * Everything here runs on the main looper — `Application.onCreate`, the
 * plugin's lifecycle callbacks and the method-channel handler alike — so the
 * two fields need no synchronization.
 */
object PublishWakeLock :
    FlutterForegroundTaskLifecycleListener,
    MethodChannel.MethodCallHandler {
    private const val CHANNEL_NAME = "haven.app/publish_wake_lock"
    private const val LOCK_TAG = "Haven:publish"

    /**
     * The hard ceiling on one hold, in milliseconds. Twin of Dart's
     * `kPublishWakeLockTimeout`, pinned against it in `location_test.dart` and
     * `fgs_plugin_wake_lock_policy_test.dart`.
     *
     * Coerced NATIVELY: a Dart caller — including a future one that forgets the
     * constant — must not be able to ask for a longer hold than this.
     */
    private const val MAX_TIMEOUT_MS = 30_000L

    private var powerManager: PowerManager? = null
    private var lock: PowerManager.WakeLock? = null

    /** Supplies the process [Context] the lock is created from. */
    fun attach(context: Context) {
        powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    }

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> {
                val requested = (call.arguments as? Number)?.toLong() ?: MAX_TIMEOUT_MS
                acquire(requested.coerceIn(1L, MAX_TIMEOUT_MS))
                result.success(null)
            }
            "release" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    // The two destroy hooks below are deliberately EMPTY, and that is the whole
    // release-ownership rule. The plugin invokes Dart's `onDestroy`
    // ASYNCHRONOUSLY and then calls these listeners SYNCHRONOUSLY
    // (`ForegroundTask.destroy`), i.e. before the isolate's bounded teardown
    // drain — the last publish of the session — has even started. Releasing
    // here would drop the CPU out from under that drain; detaching the channel
    // handler here would leave its final `release` with nowhere to land. Both
    // belong to Dart's `onDestroy` `finally`, with [MAX_TIMEOUT_MS] as the
    // backstop for a process that never gets there.
    override fun onTaskDestroy() = Unit

    override fun onEngineWillDestroy() = Unit

    private fun acquire(timeoutMs: Long) {
        val held = lock ?: powerManager
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)
            ?.apply { setReferenceCounted(false) }
            ?.also { lock = it }
        // Re-posting the timer on an already-held, non-reference-counted lock
        // is what makes the guarantee "never held more than MAX_TIMEOUT_MS past
        // the last acquire" hold across a cycle that re-acquires per circle.
        held?.acquire(timeoutMs)
    }

    private fun release() {
        lock?.let { if (it.isHeld) it.release() }
    }
}
