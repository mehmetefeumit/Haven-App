package com.oblivioustech.haven

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.PreferencesKey
import com.pravera.flutter_foreground_task.models.ForegroundServiceAction
import com.pravera.flutter_foreground_task.models.ForegroundServiceStatus
import com.pravera.flutter_foreground_task.models.NotificationContent
import com.pravera.flutter_foreground_task.service.ForegroundService

/** The location grants the resume rule reads, live from the OS. */
object LocationGrants {
    fun foreground(context: Context): Boolean =
        granted(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)

    /** Android 10 has no while-in-use restriction on a location service. */
    val backgroundRequired: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    fun background(context: Context): Boolean =
        !backgroundRequired ||
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED
}

/** Applies [decideResume] at a boot or an app update. */
object BootResume {
    fun run(context: Context) {
        val prefs = HavenPrefs.open(context)
        val decision = decideResume(
            uiVisible = UiVisibility.visible,
            serviceRunning = ForegroundService.isRunningServiceState.value,
            serviceStopped = ForegroundServiceStatus.getData(context).isCorrectlyStopped(),
            sharingOn = HavenPrefs.sharingOn(prefs),
            disclosureCurrent = HavenPrefs.resumeDisclosureAccepted(prefs),
            locationGranted = LocationGrants.foreground(context),
            backgroundRequired = LocationGrants.backgroundRequired,
            backgroundGranted = LocationGrants.background(context),
        )
        when (decision) {
            ResumeDecision.START -> start(context)
            ResumeDecision.NOTIFY -> ResumeNotice.post(context)
            ResumeDecision.NOTHING -> Unit
        }
    }

    /**
     * The plugin's own `RebootReceiver` start, so the task sees
     * `TaskStarter.system`. The stored notification text is repainted first:
     * the last one saved may read "Haven is open" or "paused", both false for
     * a service nobody opened.
     */
    private fun start(context: Context) {
        try {
            NotificationContent.updateData(
                context,
                mapOf(
                    PreferencesKey.NOTIFICATION_CONTENT_TEXT to
                        ResumeNotice.localized(context).getString(R.string.fgs_notification_sharing),
                ),
            )
            ForegroundServiceStatus.setData(context, ForegroundServiceAction.REBOOT)
            ContextCompat.startForegroundService(
                context,
                Intent(context, ForegroundService::class.java),
            )
        } catch (_: Exception) {
            // A restricted battery bucket or an OEM refusal: tell the user
            // rather than leave sharing silently stopped.
            ResumeNotice.post(context)
        }
    }
}

/**
 * Whether any Haven activity is started (visible). Counted on the main looper,
 * where the boot receiver also runs, so the count needs no synchronization.
 */
object UiVisibility : Application.ActivityLifecycleCallbacks {
    private var started = 0

    val visible: Boolean
        get() = started > 0

    override fun onActivityStarted(activity: Activity) {
        started += 1
    }

    override fun onActivityStopped(activity: Activity) {
        started = (started - 1).coerceAtLeast(0)
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

    override fun onActivityResumed(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) = Unit
}
