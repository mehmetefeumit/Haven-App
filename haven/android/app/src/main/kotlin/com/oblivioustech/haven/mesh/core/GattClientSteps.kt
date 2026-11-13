package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.DIAL_RETRY_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.DIAL_TIMEOUT_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MIN_ATT_MTU
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.REQUEST_MTU

/**
 * What [GattClientSteps] has the GATT client's adapter do, each for the
 * connection numbered `link`. Each is called on the mesh thread and may
 * throw. A step that answers `false` was not begun, and no callback follows.
 */
interface GattClientPort {
    /** Makes a client for [address]: no auto-connect, the LE transport. */
    fun connect(link: Long, address: String): Boolean

    fun requestMtu(link: Long, mtu: Int): Boolean

    fun discover(link: Long): Boolean

    /** Enables notifications of Haven's characteristic and writes its descriptor; false too where the peer has neither. */
    fun subscribe(link: Long): Boolean

    /** Asks for the connection priority of [MeshRadioConstants.CONNECTION_PRIORITY]. */
    fun lowPower(link: Long)

    /**
     * Writes [frame] to Haven's characteristic, wanting no answer. `true`: it
     * was taken, and `onWritten` follows. `false`: it was not, and nothing does.
     */
    fun write(link: Long, frame: ByteArray): Boolean

    fun disconnect(link: Long)

    /** Releases the client, whatever state it is in. Nothing is asked of [link] after. */
    fun close(link: Long)

    /** Calls `onTimer` in [inMs] on the mesh thread, replacing the timer before; 0 is "post now". */
    fun timer(inMs: Long)
}

/**
 * This phone's dials, step by step (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.3,
 * §N.2.4): connect, the MTU, discovery, the subscription, and only then a
 * link. Each step waits for its callback. A dial is answered once: by its
 * link, or as failed.
 *
 * Every connection made has a number of its own — the link's, once it is
 * one — and every callback comes back under it: one that arrives after its
 * client was closed names a number nobody holds, and does nothing. A client
 * opened is closed, on every path, whatever a call to the port throws on the
 * way: a leaked one is what exhausts Android's.
 *
 * One of these serves one radio: [stop] is final, and a radio that comes back
 * has a new one. [clock] is milliseconds that keep counting while the phone
 * sleeps.
 */
class GattClientSteps(
    private val port: GattClientPort,
    private val events: LinkEvents,
    private val links: ServerLinks,
    private val clock: () -> Long,
    private val number: () -> Long,
) {
    private enum class Step { WAITING, CONNECTING, MTU, DISCOVERING, SUBSCRIBING, LINKED }

    /** [giveUpAt] is the whole dial's, a second connection included. A [Step.WAITING] one has no client yet. */
    private class Dial(val address: String, val giveUpAt: Long, val opensAt: Long, val retried: Boolean) {
        var step = Step.WAITING
        var mtu = 0
    }

    private val dials = LinkedHashMap<Long, Dial>()
    private var stopped = false

    /**
     * The core dials [address]. The connection is made at the timer, not
     * here: this is a call from inside the core's pump, where it cannot be
     * answered.
     */
    fun connect(address: String) {
        if (stopped) return
        val now = clock()
        dials[number()] = Dial(address, giveUpAt = now + DIAL_TIMEOUT_MS, opensAt = now, retried = false)
        arm()
    }

    /**
     * What is due is done: a dial past its time is given up — and its second
     * connection, if that was still to come, never made — and a connection
     * whose moment has come is made. Every connection of the pass is made
     * before the core is told of any failure: told, it may find its own time
     * up, and nothing is dialled behind that.
     */
    fun onTimer() {
        val now = clock()
        val (spent, live) = dials.toList().filter { it.second.step != Step.LINKED }.partition { it.second.giveUpAt <= now }
        val unmade = live.filter { (link, dial) -> dial.step == Step.WAITING && dial.opensAt <= now && !open(link, dial) }
        for ((link, dial) in spent + unmade) fail(link, dial)
        arm()
    }

    /** Makes the connection a dial waited for; false where the platform made no client. */
    private fun open(link: Long, dial: Dial): Boolean {
        val made = port.connect(link, dial.address)
        if (made) dial.step = Step.CONNECTING
        return made
    }

    /** [connected]: the platform reports success and the connected state. Anything else is a connection that is gone. */
    fun onConnection(link: Long, connected: Boolean) {
        val dial = dials[link] ?: return
        if (connected) {
            if (dial.step == Step.CONNECTING) begin(link, dial, Step.MTU, port.requestMtu(link, REQUEST_MTU))
            return
        }
        dials.remove(link)
        val linked = dial.step == Step.LINKED
        try {
            // The core first, as it drops a link itself: a close that throws leaves it none.
            if (linked) events.onLinkDown(link)
        } finally {
            port.close(link)
        }
        links.onDialDown(dial.address)
        when {
            linked -> {}
            dial.retried -> events.onConnectFailed(dial.address)
            else -> {
                dials[number()] = Dial(dial.address, dial.giveUpAt, opensAt = clock() + DIAL_RETRY_MS, retried = true)
                arm()
            }
        }
    }

    /** The MTU is the connection's, whoever asked: [ServerLinks] is told it for a device that subscribes over the same one. */
    fun onMtu(link: Long, mtu: Int, ok: Boolean) {
        val dial = dials[link] ?: return
        if (ok) links.onMtu(dial.address, mtu)
        if (dial.step != Step.MTU) return
        dial.mtu = mtu
        begin(link, dial, Step.DISCOVERING, ok && mtu >= MIN_ATT_MTU && port.discover(link))
    }

    fun onDiscovered(link: Long, ok: Boolean) {
        val dial = dials[link]?.takeIf { it.step == Step.DISCOVERING } ?: return
        begin(link, dial, Step.SUBSCRIBING, ok && port.subscribe(link))
    }

    /** The descriptor's write completed. */
    fun onSubscribed(link: Long, ok: Boolean) {
        val dial = dials[link]?.takeIf { it.step == Step.SUBSCRIBING } ?: return
        if (!ok) return fail(link, dial)
        dial.step = Step.LINKED
        events.onLinkUp(link, central = true, attMtu = dial.mtu, address = dial.address)
        // The core may have closed it as it came up.
        if (link in dials) port.lowPower(link)
    }

    fun onFrame(link: Long, frame: ByteArray) {
        if (linked(link)) events.onFrame(link, frame)
    }

    /** The platform's completion of the write it took. */
    fun onWritten(link: Long, ok: Boolean) {
        if (linked(link)) events.onSendDone(link, ok)
    }

    /** The bond state of [address] is no longer "none". Haven never bonds: whatever is being dialled or linked there ends. */
    fun onBond(address: String) {
        for ((link, dial) in dials.entries.toList()) {
            if (dial.address != address) continue
            if (dial.step != Step.LINKED) {
                fail(link, dial)
            } else {
                dials.remove(link)
                try {
                    events.onLinkDown(link)
                } finally {
                    shut(link)
                }
            }
        }
    }

    /** The core closes [link]: a number that is no dial's does nothing. */
    fun close(link: Long) {
        if (dials.remove(link) != null) shut(link)
    }

    /** Hands [frame] to the link numbered [link]; false for any other number. */
    fun send(link: Long, frame: ByteArray): Boolean = linked(link) && port.write(link, frame)

    /**
     * The radio stops. The core has told the engine of every dial and link, so
     * nobody is told here. Every client is closed though one's close throws;
     * what was thrown first is thrown on once all are, for [MeshThread].
     */
    fun stop() {
        stopped = true
        var thrown: Throwable? = null
        for ((link, dial) in dials) {
            if (dial.step == Step.WAITING) continue
            try {
                port.close(link)
            } catch (caught: Throwable) {
                if (thrown == null) thrown = caught
            }
        }
        dials.clear()
        thrown?.let { throw it }
    }

    private fun linked(link: Long) = dials[link]?.step == Step.LINKED

    /** The step that was [begun] is waited for, or the dial is given up. */
    private fun begin(link: Long, dial: Dial, step: Step, begun: Boolean) {
        if (begun) dial.step = step else fail(link, dial)
    }

    private fun fail(link: Long, dial: Dial) {
        dials.remove(link)
        if (dial.step != Step.WAITING) shut(link)
        events.onConnectFailed(dial.address)
    }

    private fun shut(link: Long) {
        try {
            port.disconnect(link)
        } finally {
            port.close(link)
        }
    }

    /** One timer for the earliest thing due: a connection to make, or a dial to give up. */
    private fun arm() {
        val due = dials.values.filter { it.step != Step.LINKED }
            .minOfOrNull { if (it.step == Step.WAITING) minOf(it.opensAt, it.giveUpAt) else it.giveUpAt }
        if (due != null) port.timer((due - clock()).coerceAtLeast(0))
    }
}
