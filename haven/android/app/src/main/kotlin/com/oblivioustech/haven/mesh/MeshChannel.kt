package com.oblivioustech.haven.mesh

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.provider.Settings
import com.oblivioustech.haven.mesh.core.ChannelWords
import com.oblivioustech.haven.mesh.core.HeldTaps
import com.oblivioustech.haven.mesh.core.PermissionMatrix
import com.oblivioustech.haven.mesh.core.StartPolicy
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec

/**
 * The radio's two channels as the Dart side has them
 * (`haven/lib/src/services/mesh_radio.dart`; `docs/BLUETOOTH_MESH_M3_DESIGN.md`
 * §N.2.8, §O.3), for one Flutter engine. Every name and word is
 * `ChannelWords`'; this reads the platform and answers.
 *
 * Nothing here makes a Bluetooth object, and nothing here can start the
 * service. The three methods that would — `bluetoothOn`, `bluetoothName`,
 * `start`, each behind the log lever — are not answered: they come with the
 * service's manifest entries and the lane that proves the lever, and until
 * then a turn-on fails at the first of them, as it did with no native end.
 *
 * Every method is answered on every path, a failure with one fixed code:
 * what the platform threw is neither sent nor written anywhere.
 */
class MeshChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val state = BasicMessageChannel(messenger, ChannelWords.STATE_CHANNEL, StandardMessageCodec.INSTANCE)
    private val taps = HeldTaps()

    /** The system's dialog has been answered in this process: before that, "refused" may still be asked again. */
    private var asked = false

    /** The `requestPermission` the dialog on screen will answer. */
    private var waiting: MethodChannel.Result? = null

    /** The service tells it on the mesh thread; the channel is the main thread's. */
    private val told: (Map<String, Any>) -> Unit = { status -> activity.runOnUiThread { state.send(status) } }

    init {
        MethodChannel(messenger, ChannelWords.METHOD_CHANNEL).setMethodCallHandler(this)
        MeshService.onStatus = told
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            answer(call, result)
        } catch (_: Throwable) {
            result.error(ChannelWords.ERROR, null, null)
        }
    }

    private fun answer(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            ChannelWords.PERMISSION -> result.success(permission())
            ChannelWords.REQUEST_PERMISSION -> request(result)
            ChannelWords.OPEN_BLUETOOTH_SETTINGS -> {
                activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                result.success(null)
            }
            ChannelWords.SYNC -> {
                MeshPrefs(activity).words(checkNotNull(ChannelWords.copy(call.arguments)))
                MeshService.sync()
                result.success(null)
            }
            ChannelWords.STOP -> MeshService.stop(activity) { activity.runOnUiThread { result.success(null) } }
            ChannelWords.STATUS -> result.success(MeshService.status(activity))
            ChannelWords.SUPPORTED -> result.success(StartPolicy.supported(Build.VERSION.SDK_INT, MeshService.bluetoothLe(activity)))
            ChannelWords.TAKE_ACTION -> result.success(taps.take())
            else -> result.notImplemented()
        }
    }

    private fun permission(): String = ChannelWords.permission(
        MeshService.permitted(activity),
        asked,
        PermissionMatrix.asked(Build.VERSION.SDK_INT).any(activity::shouldShowRequestPermissionRationale),
    )

    private fun request(result: MethodChannel.Result) {
        val permissions = PermissionMatrix.asked(Build.VERSION.SDK_INT)
        // Before Android 12 there is nothing to ask, and the platform refuses a request for nothing.
        if (permissions.isEmpty()) return result.success(permission())
        // One dialog at a time: asked for again under it, the platform answers "cancelled" at once, which would
        // read as refused for good. The call before is given up — the Dart side has, by its bound — and the
        // dialog still on screen answers this one.
        val open = waiting != null
        waiting?.error(ChannelWords.ERROR, null, null)
        waiting = result
        if (!open) activity.requestPermissions(permissions.toTypedArray(), REQUEST)
    }

    /**
     * The activity's `onRequestPermissionsResult`, with how many answers it
     * carries: none where the platform cancelled the request — a dialog of
     * another plugin's was open — which is nobody asked, not a refusal.
     */
    fun permissionResult(requestCode: Int, results: Int) {
        if (requestCode != REQUEST) return
        asked = ChannelWords.answered(asked, results)
        waiting?.success(permission())
        waiting = null
    }

    /**
     * An intent the activity was made with or handed. A tap on a notice is
     * read only from one that came through the alias, and once: [replayed]
     * is an activity the system made again with the intent that first made
     * it. Held until the Dart side has asked `takeAction`; sent as it comes
     * from then on.
     */
    fun intent(intent: Intent, replayed: Boolean) {
        val keepOn = ChannelWords.tapOf(
            viaAlias = intent.component?.className == ChannelWords.TAP_ALIAS,
            replayed = replayed || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0,
        ) { intent.getStringExtra(ChannelWords.TAP_EXTRA) } ?: return
        taps.tap(keepOn)?.let(state::send)
    }

    /** The engine goes: nothing more is sent to it. */
    fun close() {
        if (MeshService.onStatus === told) MeshService.onStatus = null
    }

    private companion object {
        /** The request code of the permission dialog: this channel's own, among whatever the plugins ask under. */
        const val REQUEST = 0x4D53
    }
}
