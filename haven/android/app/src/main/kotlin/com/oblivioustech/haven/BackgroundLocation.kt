package com.oblivioustech.haven

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private const val CHANNEL_NAME = "haven.app/background_location"

/**
 * The background-location state both engines read: `required` (Android 11+),
 * `granted` (true when not required), the OS's own localized label for
 * "Allow all the time", and the foreground grant the resume rule also needs.
 */
private fun status(context: Context): Map<String, Any?> = mapOf(
    "required" to LocationGrants.backgroundRequired,
    "granted" to LocationGrants.background(context),
    "optionLabel" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.packageManager.backgroundPermissionOptionLabel.toString()
    } else {
        null
    },
    "foregroundGranted" to LocationGrants.foreground(context),
)

/**
 * `haven.app/background_location` on the UI engine: `status`, `request` (the
 * background permission alone, owner-directed 2026-11-26, OD-R2) and
 * `openAppSettings`.
 *
 * `request` answers whether the OS showed its page. Android gives no direct
 * signal, so the answer is read from `shouldShowRequestPermissionRationale`
 * before and after: a request the OS refuses without UI (the user has denied
 * it for good) leaves it `false` on both sides, while a page the user saw and
 * declined turns it `true`, or `true` to `false` on the denial that makes it
 * final. The one misreading — a first-ever page left with Back — reads as
 * "not shown", and the caller's fallback opens the app's settings page, which
 * is where the user can still choose. No clock is involved.
 */
class BackgroundLocation(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var rationaleBefore = false

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .also { it.setMethodCallHandler(this) }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
        pending?.success(false)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status(activity))
            "request" -> request(result)
            "openAppSettings" -> {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", activity.packageName, null),
                    ),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun request(result: MethodChannel.Result) {
        val askable = LocationGrants.backgroundRequired &&
            !LocationGrants.background(activity) &&
            LocationGrants.foreground(activity) &&
            pending == null
        if (!askable) {
            result.success(false)
            return
        }
        pending = result
        rationaleBefore = rationale()
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
            REQUEST_CODE,
        )
    }

    /** Forwarded from [MainActivity.onRequestPermissionsResult]. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_CODE) return
        val result = pending ?: return
        pending = null
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        result.success(granted || rationaleBefore || rationale())
    }

    private fun rationale(): Boolean = ActivityCompat.shouldShowRequestPermissionRationale(
        activity,
        Manifest.permission.ACCESS_BACKGROUND_LOCATION,
    )

    /**
     * The same channel on the foreground-service engine: `status` for the
     * system-start gate, and `postResumeNotice` for a start it refuses.
     * Registered from [HavenApplication] because that engine is created
     * without an activity (boot, sticky restart).
     */
    object ServiceEngine :
        FlutterForegroundTaskLifecycleListener,
        MethodChannel.MethodCallHandler {
        private var context: Context? = null

        fun attach(context: Context) {
            this.context = context
        }

        override fun onEngineCreate(flutterEngine: FlutterEngine?) {
            val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
            MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler(this)
        }

        override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
            val ctx = context ?: return result.error("unavailable", null, null)
            when (call.method) {
                "status" -> result.success(status(ctx))
                "postResumeNotice" -> {
                    ResumeNotice.post(ctx)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

        override fun onTaskRepeatEvent() = Unit

        override fun onTaskDestroy() = Unit

        override fun onEngineWillDestroy() = Unit
    }

    private companion object {
        // Distinct from QrScanner's camera request code.
        const val REQUEST_CODE = 0x4842
    }
}
