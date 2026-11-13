package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MIN_ATT_MTU
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MTU_NOTES_MAX

/** What [ServerLinks] has the GATT server's adapter do. Each is called on the mesh thread and may throw. */
interface ServerPort {
    /**
     * Answers the write [request] of [address]: success, or the plain
     * failure. There is no third answer: one that names authentication or
     * encryption starts the peer's pairing.
     */
    fun answer(address: String, request: Int, ok: Boolean)

    /** Cancels the connection of [address]. */
    fun cancel(address: String)

    /**
     * Notifies [address] of [frame] on Haven's characteristic. `true`: it was
     * taken, and `onNotified` follows. `false`: it was not, and nothing does.
     */
    fun notify(address: String, frame: ByteArray): Boolean
}

/**
 * What the GATT server knows of the phone's connections
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §N.2.3). The server is told of every
 * LE connection of the phone — the user's watch, another app's — so a device
 * is Haven's only from the moment it enables notifications on Haven's
 * characteristic, and nothing is ever done to one that has not.
 *
 * One thing is kept of a device that is not Haven's: the last MTU this
 * process was told for its connection, by the server or by this phone's own
 * dial. A link's MTU is agreed once a connection and may be agreed before the
 * subscription, when no callback will tell it again. It is kept in memory
 * while the connection lives and read by a subscriber's link alone.
 *
 * Addresses stay here and in the adapter: the core is told a link's [number].
 */
class ServerLinks(
    private val port: ServerPort,
    private val events: LinkEvents,
    private val number: () -> Long,
) {
    private class Subscriber(val link: Long, var linked: Boolean)

    private val mtus = LinkedHashMap<String, Int>()
    private val subscribers = LinkedHashMap<String, Subscriber>()

    /** The MTU of [address]'s connection, as the server's callback or the dial's told it. */
    fun onMtu(address: String, mtu: Int) {
        if (address !in mtus && mtus.size == MTU_NOTES_MAX) mtus.remove(mtus.keys.first())
        mtus[address] = mtu
        val subscriber = subscribers[address] ?: return
        if (subscriber.linked || mtu < MIN_ATT_MTU) return
        subscriber.linked = true
        events.onLinkUp(subscriber.link, central = false, attMtu = mtu, address = null)
    }

    /** The server was told [address] disconnected. */
    fun onDisconnected(address: String) {
        mtus.remove(address)
        subscribers.remove(address)?.let { events.onLinkDown(it.link) }
    }

    /** This phone's dial of [address] was told its disconnect. A subscription ends by the server's word alone. */
    fun onDialDown(address: String) {
        mtus.remove(address)
    }

    /** A write to the descriptor of Haven's characteristic: the one way a device becomes Haven's. */
    fun onDescriptorWrite(
        address: String,
        request: Int,
        prepared: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray,
    ) {
        val enable = when {
            prepared || offset != 0 || value.size != 2 || value[1] != NONE -> null
            value[0] == NOTIFICATIONS -> true
            value[0] == NONE -> false
            else -> null
        }
        if (responseNeeded) port.answer(address, request, ok = enable != null)
        when (enable) {
            true -> subscribe(address)
            false -> subscribers.remove(address)?.let { events.onLinkDown(it.link) }
            null -> {}
        }
    }

    /**
     * A write to Haven's characteristic. A frame is one write that wants no
     * answer; anything else from a subscriber is refused, and its link ended.
     */
    fun onWrite(
        address: String,
        request: Int,
        prepared: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray,
    ) {
        val subscriber = subscribers[address] ?: return
        if (prepared || responseNeeded || offset != 0) {
            if (responseNeeded) port.answer(address, request, ok = false)
            if (subscriber.linked) end(address)
        } else if (subscriber.linked) {
            events.onFrame(subscriber.link, value)
        }
    }

    /** The platform's completion of the notification it took for [address]. */
    fun onNotified(address: String, ok: Boolean) {
        subscribers[address]?.let { events.onSendDone(it.link, ok) }
    }

    /** The bond state of [address] is no longer "none": it has begun to pair, or has. Haven never bonds. */
    fun onBond(address: String) {
        if (endsAtBond(address)) end(address)
    }

    /**
     * Owner question Q-15, option (a): only a device that is Haven's is
     * ended. A stranger who connects and asks to pair before subscribing is
     * left to the system's dialog, as the user's own headphones are.
     *
     * Option (b) is `address in mtus` here, with the adapter noting every
     * device the server is told connected (`onMtu(address, 0)`) and telling
     * [onBond] only of one that was not bonded before.
     */
    private fun endsAtBond(address: String): Boolean = address in subscribers

    /** The core closes [link]: a number that is no subscriber's does nothing. */
    fun close(link: Long) {
        val address = addressOf(link) ?: return
        subscribers.remove(address)
        port.cancel(address)
    }

    /** Hands [frame] to the subscriber numbered [link]; false for any other number. */
    fun send(link: Long, frame: ByteArray): Boolean = addressOf(link)?.let { port.notify(it, frame) } ?: false

    /** The radio stops: the adapter closes the server, and nothing outlives it here. */
    fun clear() {
        mtus.clear()
        subscribers.clear()
    }

    private fun addressOf(link: Long): String? = subscribers.entries.firstOrNull { it.value.link == link }?.key

    private fun subscribe(address: String) {
        if (address in subscribers) return
        val link = number()
        val mtu = mtus[address]
        if (mtu != null && mtu >= MIN_ATT_MTU) {
            subscribers[address] = Subscriber(link, linked = true)
            events.onLinkUp(link, central = false, attMtu = mtu, address = null)
        } else {
            // One of the core's four not yet linked, for ten seconds: its MTU may still come.
            subscribers[address] = Subscriber(link, linked = false)
            events.onConnected(link)
        }
    }

    /** The core first, as [MeshRadioCore] drops a link: a cancel that throws leaves it none the table forgot. */
    private fun end(address: String) {
        subscribers.remove(address)?.let { events.onLinkDown(it.link) }
        port.cancel(address)
    }

    private companion object {
        /** The descriptor's value, least significant byte first: bit 0 asks for notifications. */
        const val NOTIFICATIONS: Byte = 1
        const val NONE: Byte = 0
    }
}
