package com.oblivioustech.haven.mesh

import android.Manifest
import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import com.oblivioustech.haven.mesh.core.BluetoothState
import com.oblivioustech.haven.mesh.core.BluetoothSwitch
import com.oblivioustech.haven.mesh.core.ChannelWords
import com.oblivioustech.haven.mesh.core.MeshRadioConstants
import com.oblivioustech.haven.mesh.core.MeshRadioCore
import com.oblivioustech.haven.mesh.core.MeshStart
import com.oblivioustech.haven.mesh.core.MeshThread
import com.oblivioustech.haven.mesh.core.Notice
import com.oblivioustech.haven.mesh.core.NoticePlan
import com.oblivioustech.haven.mesh.core.PermissionMatrix
import com.oblivioustech.haven.mesh.core.RadioEnd
import com.oblivioustech.haven.mesh.core.RadioMove
import com.oblivioustech.haven.mesh.core.RadioPort
import com.oblivioustech.haven.mesh.core.ServiceStarts
import com.oblivioustech.haven.mesh.core.Start
import com.oblivioustech.haven.mesh.core.StartPolicy
import com.oblivioustech.haven.mesh.core.WakePlan
import java.util.concurrent.atomic.AtomicLong

/**
 * The mesh's foreground service (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.5,
 * §B.6, §O.1): the radio for as long as the mesh is on, under a notice that
 * says so. An adapter: what it does at a start, at a stop, with Bluetooth
 * switched off, at an alarm and with a start command is each a pure
 * function's answer, in `core/`.
 *
 * It shares its process with the path that publishes to relays, and two
 * things here end a process. An exception out of the mesh thread: so every
 * body runs inside `MeshThread`, and this file catches nothing itself. And a
 * service brought down while a start command still owes its foreground
 * start: so [onStartCommand] evaluates nothing that can throw, the start's
 * first act is the foreground start, and a stop lets go of the service
 * before it takes anything down (`ServiceStarts`).
 *
 * No Bluetooth object exists before `StartPolicy.start` has answered `Run`:
 * the platform logs from the first one made, and the log lever goes in
 * there.
 */
class MeshService : Service() {
    private val prefs by lazy { MeshPrefs(this) }
    private val notices by lazy { MeshNotices(this, prefs) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        starts.command(startId) { Live() }
        return START_STICKY
    }

    override fun onDestroy() {
        starts.live()?.stop()
    }

    /**
     * One start of the service: its thread, its core, and while Bluetooth is
     * on its radio. A stop is final; a start command behind it makes another.
     */
    // The radio starts on Android 11 and later (`StartPolicy`), and whoever would start this service asks that
    // first: a foreground start with a type is Android 10's. Not the whole class: the channel calls the companion's
    // reads on every level Haven installs on.
    @TargetApi(Build.VERSION_CODES.R)
    private inner class Live : RadioPort {
        private val mesh: MeshThread = MeshThread(
            lever = native,
            running = { ::core.isInitialized && core.running },
            steps = MeshThread.steps(
                detach = { joined = starts.detach() },
                stopRadio = { if (::core.isInitialized) core.stopRadio() },
                closeAdapters = {
                    closeRadio()
                    RadioEnd.each({ unregisterReceiver(bluetooth) }, { unregisterReceiver(screenOff) }, { unregisterReceiver(bond) })
                },
                cancelAlarm = { alarms.cancel(alarm) },
                forget = {
                    prefs.forget()
                    over()
                },
                unpost = {
                    starts.idle {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        notices.cancel(NoticePlan.ONGOING)
                        notices.cancel(NoticePlan.ALERT)
                    }
                },
                end = {
                    stopSelfResult(joined)
                    loop.quit()
                },
            ),
            notice = { starts.idle { notices.post(Notice.STOPPED) } },
        )
        private val loop: MeshLoop = MeshLoop(mesh)
        private val wake = WakePlan(SystemClock::elapsedRealtime)

        // Only ever held for a time, and not counted: an acquire replaces the hold before it.
        private val lock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK)
            .apply { setReferenceCounted(false) }
        private val alarms by lazy { getSystemService(AlarmManager::class.java) }

        // To `MeshReceiver` by name, sent as Haven itself: the receiver need not be exported. Immutable: nothing in it is anybody's to fill in.
        private val alarm by lazy {
            PendingIntent.getBroadcast(this@MeshService, 0, Intent(this@MeshService, MeshReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        }
        private val manager by lazy { getSystemService(BluetoothManager::class.java) }
        private lateinit var core: MeshRadioCore

        private var server: GattServerAdapter? = null
        private var client: GattClientAdapter? = null
        private var advertiser: AdvertiserAdapter? = null
        private var scanner: ScannerAdapter? = null

        /** The start command to end the service by: the last that joined this start. */
        private var joined = 0

        /** Whoever waits for this start's stop, and whether it has come. */
        private val waiting = ArrayList<() -> Unit>()
        private var over = false

        /** The radio runs, and with Bluetooth on: read by the channel's `status`, on the main thread. */
        @Volatile
        var serving = false

        @Volatile
        var up = false

        private val bluetooth = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = loop.post {
                switched(intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR))
            }
        }

        // On Android 14 and later the user can swipe the ongoing notice away: it is back when the screen next goes dark.
        private val screenOff = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = loop.post {
                notices.post(NoticePlan.ongoing(up))
            }
        }

        // Haven never bonds (§M.4). A peer can make the platform start a pairing all the same, and this is what ends
        // it: the address of a device that is no longer "not bonded", to each role in a body of its own.
        private val bond = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = loop.post {
                val address = bonding(intent) ?: return@post
                server?.links?.onBond(address)
                loop.post { client?.steps?.onBond(address) }
            }
        }

        /**
         * The start: the first body of the thread, and the one that is not
         * asked the lever — `StartPolicy.start` puts it in. Every input is
         * handed over unread; the foreground start comes before any is.
         */
        // The adapter's state needs no permission from Android 12, and before it the one a build with the mesh declares.
        @SuppressLint("MissingPermission")
        private fun begin() = loop.start {
            val start = StartPolicy.start(
                Build.VERSION.SDK_INT,
                foreground = {
                    // Said to be on: a turn-on asked that Bluetooth be. Where it is not, the notice is put right below.
                    notices.channel()
                    startForeground(NoticePlan.ONGOING, notices.notice(Notice.ON), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                },
                bluetoothLe = { bluetoothLe(this@MeshService) },
                lever = native,
                wipePending = { getSharedPreferences(FLUTTER_PREFS, MODE_PRIVATE).getBoolean(WIPE_PENDING, false) },
                permission = { permitted(this@MeshService) },
                engine = native,
                storedDeadlineMs = { prefs.deadlineMs },
                wallClockMs = { System.currentTimeMillis() },
            )
            when (start) {
                is Start.Refused -> {
                    mesh.stop(start.notice)
                    onStarted?.invoke(start.word)
                }
                is Start.Run -> {
                    prefs.run(start.deadlineMs)
                    core = MeshRadioCore(native(), this, SystemClock::elapsedRealtime)
                    // Before the adapter is read: a switch in between is a body queued behind this one.
                    listen(bluetooth, BluetoothAdapter.ACTION_STATE_CHANGED)
                    listen(screenOff, Intent.ACTION_SCREEN_OFF)
                    listen(bond, BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                    serving = true
                    switched(manager.adapter.state)
                    if (!up) {
                        // With no radio the core arms the deadline's wake alone.
                        core.onWake()
                        shown()
                    }
                    onStarted?.invoke(MeshStart.STARTED)
                }
            }
        }

        /**
         * All three exported, where the platform has the choice. Each is a
         * broadcast only the system may send, so no app can; and a receiver
         * that is not exported hears nothing of a sender that is not the
         * system's own user — as the Bluetooth app, which sends the bond
         * state, is not.
         */
        // Below Android 13 the call has no such flag to give.
        @SuppressLint("UnspecifiedRegisterReceiverFlag")
        private fun listen(receiver: BroadcastReceiver, action: String) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(receiver, IntentFilter(action))
            }
        }

        private fun switched(state: Int) {
            val bluetooth = when (state) {
                BluetoothAdapter.STATE_ON -> BluetoothState.ON
                BluetoothAdapter.STATE_TURNING_OFF -> BluetoothState.TURNING_OFF
                BluetoothAdapter.STATE_OFF -> BluetoothState.OFF
                else -> BluetoothState.OTHER
            }
            when (BluetoothSwitch.at(bluetooth, up)) {
                RadioMove.UP -> radioUp()
                RadioMove.DOWN -> radioDown()
                RadioMove.NONE -> {}
            }
        }

        /** Each adapter is held from the moment it is made: one that throws leaves those before it to the stop's closes. */
        private fun radioUp() {
            val adapter = manager.adapter
            val server = GattServerAdapter(this@MeshService, manager, loop, core, links::incrementAndGet).also { server = it }
            client = GattClientAdapter(this@MeshService, adapter, loop, core, server.links, SystemClock::elapsedRealtime, links::incrementAndGet)
            advertiser = AdvertiserAdapter(adapter)
            scanner = ScannerAdapter(adapter, loop, core) { canSearch(this@MeshService) }
            core.startRadio()
            up = true
            shown()
        }

        /** Bluetooth went off: a pause. The engine is told first, and the twelve hours run on. */
        private fun radioDown() {
            core.stopRadio()
            closeRadio()
            shown()
        }

        /** With Bluetooth off two of these throw; none may keep the next from running, or make a pause a stop. */
        private fun closeRadio() {
            RadioEnd.each({ client?.stop() }, { server?.stop() }, { advertiser?.stop() }, { scanner?.stop() }, { lock.release() })
            client = null
            server = null
            advertiser = null
            scanner = null
            up = false
            wake.released()
        }

        /** The ongoing notice and the status, after a change of either. */
        private fun shown() {
            notices.post(NoticePlan.ongoing(up))
            onStatus?.invoke(status(this@MeshService))
        }

        /** The address of the device a bond-state broadcast tells of, where its state is no longer "not bonded"; nothing else of it is read. */
        private fun bonding(intent: Intent): String? {
            if (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE) == BluetoothDevice.BOND_NONE) return null
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            return device?.address
        }

        /** The stop the service did not make: the user's, or the platform's end of the service. A body like any other. */
        fun stop() = loop.post { mesh.stop(notice = false) }

        /** [done] once this start has stopped and its flag is cleared; at once where it has. */
        @Synchronized
        fun whenOver(done: () -> Unit) {
            if (over) done() else waiting += done
        }

        @Synchronized
        private fun over() {
            over = true
            waiting.forEach { it() }
            waiting.clear()
            onStatus?.invoke(status(this@MeshService))
        }

        /**
         * The channel's `sync`: the deadline moved or the words changed. The
         * copy is stored again, the notices are taken in the new words, and
         * the core reads the time left: it asks for the reminder again where
         * one is still owed.
         */
        fun sync() = loop.post {
            prefs.run(System.currentTimeMillis() + native().leftMs())
            notices.channel()
            notices.cancel(NoticePlan.ALERT)
            notices.post(NoticePlan.ongoing(up))
            core.onSync()
        }

        /**
         * The alarm, on the main thread. The platform keeps the phone awake
         * for a broadcast only until its receiver returns: the lock is what
         * holds it for the two bodies. The dial's timer does not count while
         * the phone sleeps, so it is asked here too — second, and dropped if
         * the wake stopped the radio.
         */
        fun alarm() {
            holdAwake(MeshRadioConstants.WAKE_HOLD_MS)
            loop.post { core.onWake() }
            loop.post { client?.steps?.onTimer() }
        }

        override fun connect(address: String) {
            client?.steps?.connect(address)
        }

        override fun close(link: Long) {
            client?.steps?.close(link)
            server?.links?.close(link)
        }

        override fun send(link: Long, frame: ByteArray): Boolean =
            client?.steps?.send(link, frame) == true || server?.links?.send(link, frame) == true

        override fun scan() {
            scanner?.scan()
        }

        override fun remind() = notices.post(Notice.REMINDER)

        override fun holdAwake(ms: Long) = wake.hold(ms, lock::acquire)

        /** The thread's timer serves a phone that is awake on time; the alarm is what wakes one that sleeps, late. Inexact: it needs no permission. */
        override fun wakeAt(inMs: Long) {
            loop.timer(this, inMs) { core.onWake() }
            wake.alarm(inMs)?.let { alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, it, alarm) }
        }

        // Last: the start may run before this constructor returns, and reads everything above.
        init {
            begin()
        }
    }

    companion object {
        private const val LOCK = "Haven:mesh"

        /** The logout's marker, as the `shared_preferences` plugin keeps `kPendingMlsWipeKey` (`pending_mls_wipe_service.dart`). */
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val WIPE_PENDING = "flutter.haven.security.pending_mls_wipe"

        private val starts = ServiceStarts<Live>()

        /** One counter of link numbers for both GATT roles, never reset while the process lives. */
        private val links = AtomicLong()

        /**
         * The engine and the lever. Naming the class loads the native
         * library, so it is named here alone, unevaluated, and first asked
         * for behind the foreground start.
         */
        private val native = { MeshNative }

        /** Told the status at every change of it, on the mesh thread: the channel, while an activity has one. */
        @Volatile
        var onStatus: ((Map<String, Any>) -> Unit)? = null

        /** Told how a start that was made ended, on the mesh thread. A command that joined a live start is told nothing. */
        @Volatile
        var onStarted: ((MeshStart) -> Unit)? = null

        fun bluetoothLe(context: Context): Boolean = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

        /** The Bluetooth runtime permissions, read here: the platform cannot be trusted to refuse a `connectedDevice` start without them. */
        fun permitted(context: Context): Boolean =
            PermissionMatrix.asked(Build.VERSION.SDK_INT).all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

        /** Whether a scan is given results. Location is read for Android 11 alone, and never asked for. */
        fun canSearch(context: Context): Boolean {
            fun holds(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            return PermissionMatrix.canSearch(
                Build.VERSION.SDK_INT,
                holds(Manifest.permission.ACCESS_FINE_LOCATION),
                holds(Manifest.permission.ACCESS_COARSE_LOCATION),
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && holds(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && context.getSystemService(LocationManager::class.java).isLocationEnabled,
            )
        }

        /** The channel's `status`. No address and no count. */
        fun status(context: Context): Map<String, Any> {
            val live = starts.live()
            return ChannelWords.status(live?.serving == true, live?.up == true, MeshPrefs(context).wanted, canSearch(context))
        }

        /** The channel's `sync`, once it has stored the words. */
        fun sync() {
            starts.live()?.sync()
        }

        /**
         * The channel's `stop`, and a logout's: flag and copy cleared whether
         * or not a service runs. [done] once the radio is down, so that the
         * engine is turned off behind a service that has stopped and posts
         * no notice of a stop the user made.
         */
        fun stop(context: Context, done: () -> Unit) {
            val live = starts.live()
            live?.stop()
            MeshPrefs(context).forget()
            live?.whenOver(done) ?: done()
        }

        /** The alarm: whether a live start took it. */
        fun alarm(): Boolean {
            val live = starts.live() ?: return false
            live.alarm()
            return true
        }
    }
}
