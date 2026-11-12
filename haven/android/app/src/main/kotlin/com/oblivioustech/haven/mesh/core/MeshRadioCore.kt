package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_CAP_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_MARGIN_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MAX_LINKS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MAX_UNLINKED
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.PUMP_BUDGET
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SEND_RETRIES
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SEND_RETRY_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SEND_TIMEOUT_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.UNLINKED_TIMEOUT_MS

/**
 * The radio's one operation queue: every decision between the platform's
 * Bluetooth callbacks and the engine (`docs/BLUETOOTH_MESH_M3_DESIGN.md`
 * §B.2). It runs on the mesh thread alone, inside [MeshThread.run].
 *
 * Every input reads the engine's time left before anything else, and ends by
 * taking what the engine has for the radio and asking for the next wake. The
 * engine's timers run nowhere else.
 *
 * [clock] is milliseconds that keep counting while the phone sleeps.
 */
class MeshRadioCore(
    private val engine: MeshEngineApi,
    private val port: RadioPort,
    private val clock: () -> Long,
) {
    /** False once the engine is gone, or has answered what is no output: the service stops. */
    var running = true
        private set

    private class Link {
        /** When the frame in flight is given up, or [refused] offered again; null when the link can take a frame. */
        var due: Long? = null

        /** A frame the platform did not take. */
        var refused: ByteArray? = null
        var refusals = 0
    }

    private var up = false
    private val peers = PeerTable()
    private val scan = ScanPolicy()
    private val deadline = DeadlinePolicy()
    private val links = LinkedHashMap<Long, Link>()

    /** Connections that are not links yet, each with when it is cancelled. */
    private val unlinked = LinkedHashMap<Long, Long>()

    /** The connects the port has not answered: the address dialled, and the engine's number for it. */
    private val dialing = LinkedHashMap<String, Long>()

    /** Bluetooth is on and the adapters are up. */
    fun startRadio() = input {
        up = true
        false
    }

    /**
     * Bluetooth went off, or the service ends: the adapters close everything
     * themselves, and nothing is asked of the port but the deadline's wake.
     */
    fun stopRadio() {
        val left = left()
        down()
        if (left != null) pump(left, hold = false)
    }

    fun onSighting(address: String, rssi: Int) = input {
        if (up) engine.sighting(peers.seen(address), rssi)
        false
    }

    /** A central connected to the server: not a link until it subscribes. */
    fun onConnected(link: Long) = input {
        if (!up) return@input false
        if (unlinked.size < MAX_UNLINKED) unlinked[link] = clock() + UNLINKED_TIMEOUT_MS else port.close(link)
        false
    }

    /**
     * [address] is the one dialled, for a link this phone made. A link taken
     * has no peer: a central's address is not the one it advertises under.
     */
    fun onLinkUp(link: Long, central: Boolean, attMtu: Int, address: String?) = input {
        if (!up) return@input false
        unlinked.remove(link)
        val peer = (if (central) address?.let(dialing::remove) else null) ?: NO_PEER
        if (links.size == MAX_LINKS) {
            if (peer != NO_PEER) engine.connectFailed(peer)
            port.close(link)
            return@input false
        }
        links[link] = Link()
        engine.linkUp(link, central, attMtu, peer)
        true
    }

    fun onLinkDown(link: Long) = input {
        unlinked.remove(link)
        if (links.remove(link) != null) engine.linkDown(link)
        false
    }

    fun onConnectFailed(address: String) = input {
        dialing.remove(address)?.let(engine::connectFailed)
        false
    }

    fun onFrame(link: Long, frame: ByteArray) = input {
        if (link !in links) return@input false
        engine.receive(link, frame)
        true
    }

    /** The platform's completion of the frame it took for [link]. */
    fun onSendDone(link: Long, ok: Boolean) = input {
        val state = links[link] ?: return@input false
        if (ok && state.refused == null) state.due = null else drop(link)
        false
    }

    fun onWake() = input { false }

    /** [act] answers whether the phone is held awake for what follows: an inbound frame, a link coming up. */
    private fun input(act: () -> Boolean) {
        val left = left() ?: return
        pump(left, hold = act())
    }

    /** The engine's time left, or null when the service is to stop. */
    private fun left(): Long? {
        if (!running) return null
        val left = engine.leftMs()
        when (deadline.at(left)) {
            DeadlineStep.STOP -> {
                running = false
                return null
            }
            DeadlineStep.REMINDER -> port.remind()
            DeadlineStep.NOTHING -> {}
        }
        return left
    }

    private fun pump(left: Long, hold: Boolean) {
        if (!up) {
            // No radio: the engine is not driven, and only the deadline wakes the phone.
            port.wakeAt(deadline.reminderIn(left) ?: left)
            return
        }
        val now = clock()
        expire(now)
        if (scan.dueIn(now) == 0L) {
            port.scan()
            scan.started(now)
        }
        var budget = PUMP_BUDGET
        while (budget > 0) {
            val polled = engine.poll(ready()) ?: break
            when (val output = RadioOutput.decode(polled)) {
                is RadioOutput.Send -> offer(output.link, links.getValue(output.link), output.frame, now)
                is RadioOutput.Close -> {
                    links.remove(output.link)
                    port.close(output.link)
                }
                is RadioOutput.Connect -> connect(output.peer)
                null -> {
                    // The two sides disagree about the encoding: nothing the engine says can be acted on.
                    running = false
                    down()
                    return
                }
            }
            budget--
        }
        // A spent budget gives the thread back and comes again at once.
        val wake = if (budget == 0) 0 else engine.wakeInMs()
        if (wake < 0) {
            running = false
            return
        }
        val own = links.values.mapNotNull { it.due } + unlinked.values
        val terms = own.map { it - now } + listOfNotNull(scan.dueIn(now), deadline.reminderIn(left), wake)
        port.wakeAt(terms.min())
        if (hold) port.holdAwake(minOf(wake + HOLD_MARGIN_MS, HOLD_CAP_MS))
    }

    /** The links that can take a frame now: only for these does the engine hand one over. */
    private fun ready(): LongArray = links.filterValues { it.due == null }.keys.toLongArray()

    private fun expire(now: Long) {
        for ((link, at) in unlinked.entries.toList()) {
            if (at > now) continue
            unlinked.remove(link)
            port.close(link)
        }
        for ((link, state) in links.entries.toList()) {
            val due = state.due
            if (due == null || due > now) continue
            // No frame held: the one in flight never completed, and nothing else would free the link.
            val refused = state.refused
            if (refused == null) drop(link) else offer(link, state, refused, now)
        }
    }

    /** A polled frame is spent: it is delivered — the same bytes, offered again — or its link is closed. */
    private fun offer(link: Long, state: Link, frame: ByteArray, now: Long) {
        if (port.send(link, frame)) {
            state.refused = null
            state.refusals = 0
            state.due = now + SEND_TIMEOUT_MS
        } else if (state.refusals == SEND_RETRIES) {
            drop(link)
        } else {
            state.refused = frame
            state.refusals++
            state.due = now + SEND_RETRY_MS
        }
    }

    /** The engine first, here as in [down]: a close that throws leaves it no link the table has forgotten. */
    private fun drop(link: Long) {
        links.remove(link)
        engine.linkDown(link)
        port.close(link)
    }

    private fun connect(peer: Long) {
        val address = peers.addressOf(peer)
        if (address == null) {
            engine.connectFailed(peer)
        } else {
            dialing[address] = peer
            port.connect(address)
        }
    }

    /** The engine is told and the port is not: whatever the port throws next, the engine holds no link. */
    private fun down() {
        up = false
        scan.stopped()
        unlinked.clear()
        for (link in links.keys) engine.linkDown(link)
        links.clear()
        for (peer in dialing.values) engine.connectFailed(peer)
        dialing.clear()
    }

    private companion object {
        const val NO_PEER = -1L
    }
}
