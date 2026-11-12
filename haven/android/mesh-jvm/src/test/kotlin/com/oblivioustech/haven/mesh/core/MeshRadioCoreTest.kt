package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_CAP_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MAX_LINKS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MAX_PEERS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SCAN_RESTART_MS
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MeshRadioCoreTest {
    private val frame = byteArrayOf(7, 8, 9)

    /** A started radio with [links] inbound links up, numbered from 1, and nothing recorded. */
    private fun linked(links: Int = 1): Rig = Rig().started().apply {
        for (link in 1..links) core.onLinkUp(link.toLong(), central = false, attMtu = 517, address = null)
        fresh()
    }

    /** R-1: a frame the engine handed over is delivered, the same bytes, or its link is closed. */
    @Test
    fun aPolledFrameIsSentOrItsLinkIsClosed() {
        val refused = linked()
        refused.port.refuses = Int.MAX_VALUE
        refused.engine.outputs += sendOf(1, frame)
        refused.engine.outputs += sendOf(1, byteArrayOf(1))
        refused.core.onWake()
        assertEquals(listOf("send(1)"), refused.port.called("send"))
        assertEquals(50, refused.port.wakes.last(), "the refused frame is not offered again in 50 ms")
        refused.pass(49)
        assertEquals(1, refused.port.called("send").size, "offered again early")
        repeat(3) { refused.pass(50) }
        assertEquals(List(4) { frame.toList() }, refused.port.frames, "not the same bytes, once and three times more")
        assertEquals(listOf("close(1)"), refused.port.called("close"))
        assertEquals(listOf("linkDown(1)"), refused.engine.called("linkDown"))
        assertTrue(
            refused.engine.readies.drop(1).none { 1L in it },
            "the engine was polled for a link that still held a frame: ${refused.engine.readies}",
        )
        refused.pass(50)
        assertEquals(4, refused.port.frames.size, "a frame was sent on a closed link")

        val taken = linked()
        taken.port.refuses = 2
        taken.engine.outputs += sendOf(1, frame)
        taken.core.onWake()
        repeat(2) { taken.pass(50) }
        assertEquals(List(3) { frame.toList() }, taken.port.frames)
        taken.core.onSendDone(1, ok = true)
        assertTrue(taken.port.called("close").isEmpty() && taken.engine.called("linkDown").isEmpty())
        assertEquals(listOf(1L), taken.engine.readies.last(), "a link whose frame was delivered is not ready again")
        // The count of refusals is each frame's own.
        taken.port.refuses = 3
        taken.engine.outputs += sendOf(1, frame)
        taken.core.onWake()
        repeat(3) { taken.pass(50) }
        assertTrue(taken.port.called("close").isEmpty(), "a link was closed for the refusals of an earlier frame")

        val failed = linked()
        failed.engine.outputs += sendOf(1, frame)
        failed.core.onWake()
        failed.core.onSendDone(1, ok = false)
        assertEquals(listOf("close(1)"), failed.port.called("close"))
        assertEquals(listOf("linkDown(1)"), failed.engine.called("linkDown"))
    }

    @Test
    fun aLinkWithAFrameInFlightIsNotReady() {
        val rig = linked(links = 2)
        rig.engine.outputs += sendOf(1, frame)
        rig.core.onWake()
        assertEquals(listOf(listOf(1L, 2L), listOf(2L)), rig.engine.readies)
        rig.core.onSighting(ADDRESS, -40)
        assertEquals(listOf(2L), rig.engine.readies.last(), "ready before its frame completed")
        rig.core.onSendDone(1, ok = true)
        assertEquals(listOf(1L, 2L), rig.engine.readies.last())
    }

    /** T-AUTO-4. */
    @Test
    fun everyInputChecksTheDeadlineBeforeAnythingElse() {
        val inputs = mapOf<String, (MeshRadioCore) -> Unit>(
            "startRadio" to { it.startRadio() },
            "stopRadio" to { it.stopRadio() },
            "onSighting" to { it.onSighting(ADDRESS, -40) },
            "onConnected" to { it.onConnected(2) },
            "onLinkUp" to { it.onLinkUp(2, central = false, attMtu = 517, address = null) },
            "onLinkDown" to { it.onLinkDown(1) },
            "onConnectFailed" to { it.onConnectFailed(ADDRESS) },
            "onFrame" to { it.onFrame(1, frame) },
            "onSendDone" to { it.onSendDone(1, ok = true) },
            "onWake" to { it.onWake() },
        )
        for ((name, input) in inputs) {
            val rig = linked()
            rig.engine.outputs += sendOf(1, frame)
            rig.engine.left = 0
            input(rig.core)
            assertEquals("leftMs()", rig.engine.calls.first(), "$name did something before it read the time left")
            assertTrue(rig.engine.called("poll").isEmpty(), "$name polled an engine whose time is up")
            assertTrue(rig.port.called("send").isEmpty() && rig.port.called("wakeAt").isEmpty(), name)
            assertFalse(rig.core.running, "$name left the radio running")
            // What is left of a stop is the engine told of its links, whatever the port does.
            if (name != "stopRadio") assertEquals(listOf("leftMs()"), rig.engine.calls, name)
            rig.fresh()
            input(rig.core)
            if (name != "stopRadio") assertTrue(rig.engine.calls.isEmpty(), "$name went on after the stop")
            assertTrue(rig.port.calls.isEmpty(), "$name went on after the stop")
        }
    }

    @Test
    fun anAddressNeverReachesTheEngine() {
        val rig = Rig().started()
        val addresses = List(5) { address(it) }
        for (address in addresses) rig.core.onSighting(address, -40)
        rig.core.onSighting(addresses[2], -50)
        assertEquals(
            listOf("sighting(0,-40)", "sighting(1,-40)", "sighting(2,-40)", "sighting(3,-40)", "sighting(4,-40)", "sighting(2,-50)"),
            rig.engine.called("sighting"),
        )
        rig.engine.outputs += connectOf(3)
        rig.engine.outputs += connectOf(1)
        rig.core.onWake()
        assertEquals(listOf("connect(${addresses[3]})", "connect(${addresses[1]})"), rig.port.called("connect"))
        rig.core.onLinkUp(10, central = true, attMtu = 185, address = addresses[3])
        // A central's address is not the one it advertises under: even told one, and one being dialled, an
        // inbound link has no peer, and the dial is still the port's to answer.
        rig.core.onLinkUp(11, central = false, attMtu = 517, address = addresses[1])
        // A link nobody asked the port to make has no peer either.
        rig.core.onLinkUp(12, central = true, attMtu = 517, address = addresses[4])
        assertEquals(
            listOf("linkUp(10,true,185,3)", "linkUp(11,false,517,-1)", "linkUp(12,true,517,-1)"),
            rig.engine.called("linkUp"),
        )
        rig.core.onConnectFailed(addresses[1])
        rig.core.onConnectFailed(addresses[1])
        rig.core.onConnectFailed(addresses[0])
        assertEquals(listOf("connectFailed(1)"), rig.engine.called("connectFailed"))
        val told = rig.engine.calls.joinToString()
        for (address in addresses) {
            assertFalse(address in told || address.hashCode().toString() in told, "the engine was told of an address: $told")
        }
    }

    @Test
    fun aConnectForAPeerNoLongerKnownFailsAtOnce() {
        val rig = Rig().started()
        for (n in 0..MAX_PEERS) rig.core.onSighting(address(n), -40)
        rig.engine.outputs += connectOf(0)
        rig.engine.outputs += connectOf(1)
        rig.core.onWake()
        assertEquals(listOf("connectFailed(0)"), rig.engine.called("connectFailed"))
        assertEquals(listOf("connect(${address(1)})"), rig.port.called("connect"))
    }

    @Test
    fun thePumpStopsAtItsBudgetAndComesBack() {
        val rig = linked()
        repeat(100) { rig.engine.outputs += closeOf(40 + it.toLong()) }
        rig.core.onFrame(1, frame)
        assertEquals(64, rig.port.called("close").size)
        assertEquals(64, rig.engine.called("poll").size, "the pump polled past its budget")
        assertEquals(listOf(0L), rig.port.wakes, "a pump that stopped at its budget does not come back at once")
        assertTrue(rig.engine.called("wakeInMs").isEmpty())
        rig.core.onWake()
        assertEquals(100, rig.port.called("close").size)
        assertEquals(listOf(0L, rig.engine.wake), rig.port.wakes)
    }

    /** T-PWR-3 with it: with no peer nothing is sent and no lock is taken. */
    @Test
    fun theWakeIsTheEnginesAndTheLockIsCapped() {
        val alone = Rig().started()
        repeat(3) { alone.pass(5_000) }
        alone.core.onSighting(ADDRESS, -40)
        assertEquals(List(5) { 5_000L }, alone.port.wakes)
        assertTrue(alone.port.called("holdAwake").isEmpty() && alone.port.called("send").isEmpty())

        val rig = Rig().started()
        rig.core.onLinkUp(1, central = false, attMtu = 517, address = null)
        assertEquals(listOf("holdAwake(5250)"), rig.port.called("holdAwake"))
        rig.engine.wake = 120
        rig.core.onFrame(1, frame)
        assertEquals(120, rig.port.wakes.last())
        assertEquals("holdAwake(370)", rig.port.called("holdAwake").last())
        rig.engine.wake = HOLD_CAP_MS - 250
        rig.core.onFrame(1, frame)
        rig.engine.wake = HOLD_CAP_MS - 249
        rig.core.onFrame(1, frame)
        rig.engine.wake = 90_000
        rig.core.onFrame(1, frame)
        assertEquals(List(3) { "holdAwake($HOLD_CAP_MS)" }, rig.port.called("holdAwake").takeLast(3))
        // Nothing else holds the phone awake: not a sighting, a wake, a completion, a link lost or one refused.
        val holds = rig.port.called("holdAwake").size
        rig.core.onSighting(ADDRESS, -40)
        rig.core.onWake()
        rig.core.onSendDone(1, ok = true)
        rig.core.onFrame(99, frame)
        rig.core.onConnected(2)
        rig.core.onLinkDown(1)
        assertEquals(holds, rig.port.called("holdAwake").size)
    }

    @Test
    fun bluetoothOffTellsEveryLinkDownAndSendsNothing() {
        val rig = linked(links = 2)
        rig.core.onSighting(ADDRESS, -40)
        rig.engine.outputs += connectOf(0)
        rig.core.onConnected(5)
        rig.engine.outputs += sendOf(1, frame)
        rig.fresh()
        rig.engine.left = 3 * HOUR
        rig.core.stopRadio()
        assertEquals(listOf("leftMs()", "linkDown(1)", "linkDown(2)", "connectFailed(0)"), rig.engine.calls)
        // Only the deadline wakes a phone with no radio: here its reminder, half an hour before.
        assertEquals(listOf("wakeAt(${3 * HOUR - 30 * MINUTE})"), rig.port.calls)

        rig.fresh()
        rig.core.onWake()
        rig.core.onSighting(ADDRESS, -40)
        rig.core.onConnected(6)
        rig.core.onLinkUp(7, central = false, attMtu = 517, address = null)
        rig.core.onFrame(1, frame)
        rig.core.onSendDone(1, ok = true)
        rig.core.onLinkDown(1)
        rig.core.onConnectFailed(ADDRESS)
        assertTrue(rig.engine.calls.all { it == "leftMs()" }, "the engine was driven with Bluetooth off: ${rig.engine.calls}")
        assertTrue(rig.port.calls.all { it.startsWith("wakeAt(") }, "the port was used with Bluetooth off: ${rig.port.calls}")
        rig.now += 11_000
        rig.core.onWake()
        assertTrue(rig.port.called("close").isEmpty(), "a connection of before was cancelled after Bluetooth went off")

        rig.fresh()
        rig.core.startRadio()
        assertEquals(listOf("leftMs()", "poll()", "wakeInMs()"), rig.engine.calls)
        assertEquals(listOf("scan()", "wakeAt(5000)"), rig.port.calls)
    }

    @Test
    fun unlinkedConnectionsAreCappedAndTimedOut() {
        val rig = Rig().started()
        rig.engine.wake = HOUR
        for (link in 1..4L) {
            rig.core.onConnected(link)
            rig.now += 1_000
        }
        assertTrue(rig.port.called("close").isEmpty())
        rig.core.onConnected(5)
        assertEquals(listOf("close(5)"), rig.port.called("close"))
        assertEquals(6_000, rig.port.wakes.last(), "the wake is not the first connection's ten seconds")
        // One of the four becomes a link, one is lost; the other two run out, each ten seconds after it connected.
        rig.core.onLinkUp(2, central = false, attMtu = 517, address = null)
        rig.core.onLinkDown(3)
        rig.pass(5_999)
        assertEquals(1, rig.port.called("close").size)
        rig.pass(1)
        assertEquals(listOf("close(5)", "close(1)"), rig.port.called("close"))
        rig.pass(2_999)
        assertEquals(2, rig.port.called("close").size)
        rig.pass(1)
        assertEquals(listOf("close(5)", "close(1)", "close(4)"), rig.port.called("close"))
        // The places are free again, and the engine heard of the link alone.
        for (link in 6..9L) rig.core.onConnected(link)
        assertEquals(3, rig.port.called("close").size)
        rig.core.onConnected(10)
        assertEquals("close(10)", rig.port.called("close").last())
        assertEquals(listOf("linkUp(2,false,517,-1)"), rig.engine.calls.filter { "ink" in it })
    }

    @Test
    fun aFrameWhoseCompletionNeverComesClosesItsLink() {
        val rig = linked(links = 2)
        rig.engine.wake = HOUR
        rig.engine.outputs += sendOf(1, frame)
        rig.core.onWake()
        assertEquals(10_000, rig.port.wakes.last())
        rig.pass(9_999)
        assertTrue(rig.port.called("close").isEmpty())
        assertEquals(listOf(2L), rig.engine.readies.last())
        rig.pass(1)
        assertEquals(listOf("close(1)"), rig.port.called("close"))
        assertEquals(listOf("linkDown(1)"), rig.engine.called("linkDown"))
        // A completion that comes after all is no one's.
        rig.core.onSendDone(1, ok = true)
        assertEquals(1, rig.port.called("close").size)
    }

    @Test
    fun theScanRestartIsATermOfTheAlarm() {
        val rig = Rig()
        rig.engine.wake = 11 * HOUR
        rig.core.startRadio()
        assertEquals(listOf("scan()", "wakeAt($SCAN_RESTART_MS)"), rig.port.calls)
        rig.pass(SCAN_RESTART_MS)
        assertEquals(2, rig.port.called("scan").size)
        assertEquals(SCAN_RESTART_MS, rig.port.wakes.last())
    }

    /** §B.4: the table holds the engine's eight; a ninth link is closed and the engine not asked. */
    @Test
    fun aLinkBeyondTheEnginesEightIsClosed() {
        val rig = linked(links = MAX_LINKS)
        rig.core.onSighting(ADDRESS, -40)
        rig.engine.outputs += connectOf(0)
        rig.core.onWake()
        rig.fresh()
        rig.core.onLinkUp(20, central = false, attMtu = 517, address = null)
        rig.core.onLinkUp(21, central = true, attMtu = 517, address = ADDRESS)
        assertEquals(listOf("close(20)", "close(21)"), rig.port.called("close"))
        assertTrue(rig.engine.called("linkUp").isEmpty())
        assertEquals(listOf("connectFailed(0)"), rig.engine.called("connectFailed"), "the engine goes on waiting for its connect")
        assertTrue(rig.port.called("holdAwake").isEmpty())
        rig.core.onLinkDown(3)
        rig.core.onLinkUp(22, central = false, attMtu = 517, address = null)
        assertEquals(listOf("linkUp(22,false,517,-1)"), rig.engine.called("linkUp"))
    }

    /** What the engine closes is closed, and a link the radio lost is told once. */
    @Test
    fun aLinkTheEngineClosesIsClosedAndALinkLostIsToldDown() {
        val rig = linked(links = 2)
        rig.engine.outputs += closeOf(1)
        rig.core.onWake()
        assertEquals(listOf("close(1)"), rig.port.called("close"))
        rig.core.onLinkDown(1)
        assertTrue(rig.engine.called("linkDown").isEmpty(), "the engine was told of a link it closed itself")
        rig.core.onLinkDown(2)
        rig.core.onLinkDown(2)
        assertEquals(listOf("linkDown(2)"), rig.engine.called("linkDown"))
        rig.core.onFrame(2, frame)
        assertTrue(rig.engine.called("receive").isEmpty(), "a frame of no link reached the engine")
    }

    /** An engine that went in the middle of an input — a panic the shim caught — stops the radio. */
    @Test
    fun anEngineThatAnswersNoWakeIsGone() {
        val rig = linked()
        rig.engine.wake = -1
        rig.core.onWake()
        assertFalse(rig.core.running)
        assertTrue(rig.port.calls.isEmpty())
    }
}
