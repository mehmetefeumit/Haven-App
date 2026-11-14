package com.oblivioustech.haven.mesh

import android.annotation.TargetApi
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.oblivioustech.haven.mesh.core.Notice
import com.oblivioustech.haven.mesh.core.RadioEnd
import com.oblivioustech.haven.mesh.core.ReceiverPolicy
import com.oblivioustech.haven.mesh.core.StartPolicy

/**
 * Boot, Haven replaced, and the service's alarm
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.5, §O.1.5, §O.1.8). Not exported:
 * the two broadcasts are the system's, and the alarm is sent as Haven
 * itself, by name and with no action.
 *
 * Whether to start the service is `ReceiverPolicy`'s to say, and it is asked
 * before the start: a service started here and refused there would have to
 * reach its foreground start first. An alarm starts none — the platform
 * gives it no licence to — and the start itself is the one call here the
 * platform may still refuse, with an exception that must end nothing.
 */
// A foreground service is started as one from Android 8. Below Android 11 none is: no start ever set the flag there.
@TargetApi(Build.VERSION_CODES.R)
class MeshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = MeshPrefs(context)
        val now = System.currentTimeMillis()
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                val starts = ReceiverPolicy.startsAtBoot(prefs.wanted, prefs.deadlineMs, now) {
                    StartPolicy.refusal(Build.VERSION.SDK_INT, MeshService.bluetoothLe(context), MeshNative, MeshService.permitted(context))
                }
                if (starts) RadioEnd.each({ context.startForegroundService(Intent(context, MeshService::class.java)) })
            }
            null -> if (!MeshService.alarm() && ReceiverPolicy.endsAtAlarm(prefs.wanted, prefs.deadlineMs, now)) {
                prefs.forget()
                MeshNotices(context, prefs).post(Notice.STOPPED)
            }
        }
    }
}
