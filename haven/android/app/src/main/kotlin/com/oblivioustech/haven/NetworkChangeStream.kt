package com.oblivioustech.haven

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Tells Dart (`PlatformNetworkChangeSource`) that the device's DEFAULT network
 * changed, with an empty event: which network it was never crosses the
 * channel, and nothing here logs.
 *
 * A change is a [Network] other than the one last seen. The baseline is the
 * network in use at the listen, so a listen (whose callback fires at once for
 * the current default) emits nothing; a loss clears it, so whatever comes back
 * emits once. A capabilities update is not a change: it fires on every signal
 * tick, and a socket survives it.
 *
 * Listened to only while the app is in front (MapShell stops it at a pause), so
 * it never wakes anything in the background.
 */
class NetworkChangeStream(context: Context) : EventChannel.StreamHandler {
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun register(messenger: BinaryMessenger) {
        EventChannel(messenger, CHANNEL_NAME).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        unregister()
        val cm = connectivity ?: return
        val listening = object : ConnectivityManager.NetworkCallback() {
            private var current: Network? = cm.activeNetwork

            // Delivered on a binder thread; the sink must be used on the main
            // looper, and only while this callback is still the listening one.
            override fun onAvailable(network: Network) {
                main.post {
                    if (callback !== this || network == current) return@post
                    current = network
                    events.success(null)
                }
            }

            override fun onLost(network: Network) {
                main.post {
                    if (callback === this && network == current) current = null
                }
            }
        }
        // Some Android 11 builds throw SecurityException here; without the
        // callback the pool's own ping is the only recovery, as before.
        try {
            cm.registerDefaultNetworkCallback(listening)
            callback = listening
        } catch (e: RuntimeException) {
        }
    }

    override fun onCancel(arguments: Any?) = unregister()

    /** Also called when the engine is cleaned up, which cancels no stream. */
    fun unregister() {
        val registered = callback ?: return
        callback = null
        try {
            connectivity?.unregisterNetworkCallback(registered)
        } catch (e: RuntimeException) {
        }
    }

    private companion object {
        const val CHANNEL_NAME = "haven.app/network_change"
    }
}
