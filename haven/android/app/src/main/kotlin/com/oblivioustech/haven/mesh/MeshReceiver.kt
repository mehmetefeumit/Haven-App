package com.oblivioustech.haven.mesh

import android.annotation.TargetApi
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.oblivioustech.haven.mesh.core.Notice
import com.oblivioustech.haven.mesh.core.RadioEnd
import com.oblivioustech.haven.mesh.core.ReceiverPolicy
import com.oblivioustech.haven.mesh.core.ReceiverStep
import com.oblivioustech.haven.mesh.core.StartPolicy

/**
 * Boot, Haven replaced, and the service's alarm
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.5, §O.1.5, §O.1.8). Not exported:
 * the two broadcasts are the system's, and the alarm is sent as Haven
 * itself, by name and with no action.
 *
 * What to do is `ReceiverPolicy`'s to say. It is asked before a start: a
 * service started here and refused there would have to reach its foreground
 * start first. An alarm starts none — the platform gives it no licence to.
 *
 * All of it runs on the main thread of the process that also publishes to
 * relays, at boot among other times, so all of it is inside `RadioEnd.each`:
 * a native library that does not load, a stored copy that does not read and
 * a start the platform refuses each throw, and none may end the process.
 */
// A foreground service is started as one from Android 8. Below Android 11 none is: no start ever set the flag there.
@TargetApi(Build.VERSION_CODES.R)
class MeshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = RadioEnd.each({
        val prefs = MeshPrefs(context)
        // The alarm has no action; whatever has one is boot, or Haven replaced.
        val step = ReceiverPolicy.step(intent.action != null, MeshService::alarm, prefs.wanted, prefs.deadlineMs, System.currentTimeMillis()) {
            StartPolicy.refusal(Build.VERSION.SDK_INT, MeshService.bluetoothLe(context), MeshNative, MeshService.permitted(context))
        }
        when (step) {
            ReceiverStep.START -> context.startForegroundService(Intent(context, MeshService::class.java))
            ReceiverStep.END -> {
                prefs.forget()
                MeshNotices(context, prefs).post(Notice.STOPPED)
            }
            ReceiverStep.NONE -> {}
        }
    })
}
