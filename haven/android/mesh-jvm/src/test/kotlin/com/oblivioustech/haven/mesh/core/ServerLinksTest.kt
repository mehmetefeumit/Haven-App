package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MTU_NOTES_MAX
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ServerLinksTest {
    private val frame = byteArrayOf(7, 8, 9)
    private val enable = byteArrayOf(1, 0)
    private val disable = byteArrayOf(0, 0)

    /** A device that subscribes now: whether its connection's MTU was known, so that it is a link at once. */
    private fun Radios.linksAtOnce(address: String): Boolean {
        fresh()
        subscribes(address)
        return events.calls.single().startsWith("linkUp(")
    }

    /**
     * §M.1: a GATT server is told of every LE connection of the phone — the user's watch, another app's. Nothing
     * of Haven's is done to one that never enabled notifications on Haven's characteristic.
     */
    @Test
    fun aConnectionThatNeverWritesHavensDescriptorIsNeverKnown() {
        val radios = Radios()
        radios.links.onMtu(ADDRESS, 517)
        radios.writes(ADDRESS, frame)
        radios.links.onWrite(ADDRESS, 4, prepared = true, responseNeeded = true, offset = 0, value = frame)
        radios.links.onWrite(ADDRESS, 5, prepared = false, responseNeeded = true, offset = 3, value = frame)
        radios.links.onNotified(ADDRESS, ok = true)
        radios.links.onBond(ADDRESS)
        for (link in 0..3L) {
            radios.links.close(link)
            assertFalse(radios.links.send(link, frame))
        }
        radios.links.onDisconnected(ADDRESS)
        assertTrue(radios.order.isEmpty(), "something was done to a connection that is not Haven's: ${radios.order}")
        // It was given no number either: the first subscriber has the first.
        radios.subscribes(address(1))
        assertEquals(listOf("connected(0)"), radios.events.calls)
    }

    /**
     * An MTU is agreed once a connection, and may be agreed before the subscription — by this phone's own dial, or
     * by a peer as it connects — when no callback tells it again. A subscriber that waited for one would never link.
     */
    @Test
    fun aSubscriberLinksAtOnceWhereItsConnectionsMtuIsKnownAndAtItsNextMtuWhereNot() {
        val radios = Radios()
        // The last one told is the connection's.
        radios.links.onMtu(ADDRESS, 23)
        radios.links.onMtu(ADDRESS, 185)
        radios.subscribes(ADDRESS, request = 9)
        // An inbound link has no address: a central's is not the one it advertises under.
        assertEquals(listOf("answer($ADDRESS,9,true)", "linkUp(0,false,185,null)"), radios.order)
        // Once a connection: a second subscription, or a later MTU, is no second link.
        radios.subscribes(ADDRESS, request = 10)
        radios.links.onMtu(ADDRESS, 517)
        assertEquals(listOf("linkUp(0,false,185,null)"), radios.events.calls)
        assertEquals("answer($ADDRESS,10,true)", radios.server.calls.last())

        // Not known yet: one of the core's four not yet linked, and a link at the first MTU that carries one.
        val late = address(1)
        radios.fresh()
        radios.subscribes(late)
        assertEquals(listOf("connected(1)"), radios.events.calls)
        radios.links.onMtu(late, 50)
        assertEquals(1, radios.events.calls.size, "a link under the smallest MTU that carries a frame")
        radios.links.onMtu(late, 51)
        radios.links.onMtu(late, 517)
        assertEquals(listOf("connected(1)", "linkUp(1,false,51,null)"), radios.events.calls)
        // Known, and too small: no link at the subscription either.
        radios.links.onMtu(address(2), 50)
        assertFalse(radios.linksAtOnce(address(2)))

        // Down when notifications are disabled and at the disconnect, and nobody is cancelled: the peer chose, or left.
        radios.fresh()
        radios.links.onDescriptorWrite(ADDRESS, 11, prepared = false, responseNeeded = true, offset = 0, value = disable)
        radios.links.onDisconnected(late)
        assertEquals(listOf("answer($ADDRESS,11,true)", "linkDown(0)", "linkDown(1)"), radios.order)
        radios.writes(ADDRESS, frame)
        radios.links.onDisconnected(late)
        assertEquals(3, radios.order.size, "a device that is no longer Haven's was still acted on")
        // Subscribed again it is a new link, under a number never used before.
        radios.subscribes(ADDRESS, request = 12)
        assertEquals("linkUp(3,false,517,null)", radios.events.calls.last())

        // What is no subscription is answered with the plain failure, and makes nobody Haven's.
        val stranger = address(3)
        radios.fresh()
        radios.links.onDescriptorWrite(stranger, 20, prepared = true, responseNeeded = true, offset = 0, value = enable)
        radios.links.onDescriptorWrite(stranger, 21, prepared = false, responseNeeded = true, offset = 1, value = enable)
        radios.links.onDescriptorWrite(stranger, 22, prepared = false, responseNeeded = true, offset = 0, value = byteArrayOf(1))
        radios.links.onDescriptorWrite(stranger, 23, prepared = false, responseNeeded = true, offset = 0, value = byteArrayOf(2, 0))
        radios.links.onDescriptorWrite(stranger, 24, prepared = false, responseNeeded = true, offset = 0, value = byteArrayOf(1, 1))
        assertEquals((20..24).map { "answer($stranger,$it,false)" }, radios.order)
        // A write that wants no answer gets none, and counts all the same.
        radios.fresh()
        radios.links.onDescriptorWrite(stranger, 25, prepared = false, responseNeeded = false, offset = 0, value = enable)
        assertEquals(listOf("connected(4)"), radios.order)
    }

    /**
     * Two phones that dial each other can share one connection, and a server is told nothing of the MTU its own
     * phone's client agreed on it.
     */
    @Test
    fun theMtuThisPhonesOwnDialWasToldServesThatDevicesSubscription() {
        val dialledFirst = Radios()
        dialledFirst.dialled(ADDRESS, mtu = 247)
        dialledFirst.fresh()
        dialledFirst.subscribes(ADDRESS)
        assertEquals(listOf("linkUp(1,false,247,null)"), dialledFirst.events.calls)

        // The peer subscribed first: it links when the dial is told.
        val subscribedFirst = Radios()
        subscribedFirst.subscribes(ADDRESS)
        val dial = subscribedFirst.dials(ADDRESS)
        subscribedFirst.steps.onConnection(dial, connected = true)
        subscribedFirst.fresh()
        subscribedFirst.steps.onMtu(dial, 247, ok = true)
        assertEquals(listOf("linkUp(0,false,247,null)"), subscribedFirst.events.calls)

        // An exchange that failed told nothing of the connection.
        val failed = Radios()
        failed.subscribes(ADDRESS)
        val refused = failed.dials(ADDRESS)
        failed.steps.onConnection(refused, connected = true)
        failed.steps.onMtu(refused, 247, ok = false)
        assertTrue(failed.events.called("linkUp").isEmpty())
    }

    /** The one thing kept of a device that is not Haven's is kept no longer than its connection, and never past the radio. */
    @Test
    fun anMtuNoteGoesAtDisconnectAtTheCapAndWithTheRadio() {
        val radios = Radios()
        radios.links.onMtu(ADDRESS, 517)
        assertTrue(Radios().apply { links.onMtu(ADDRESS, 517) }.linksAtOnce(ADDRESS), "premise: a note serves a subscription")
        radios.links.onDisconnected(ADDRESS)
        assertFalse(radios.linksAtOnce(ADDRESS), "the note outlived the server's word of the disconnect")

        // The dial's word of it too — and that ends no subscription, which is the server's to end.
        val dialled = Radios()
        dialled.subscribes(address(1))
        dialled.links.onMtu(address(1), 517)
        val link = dialled.dialled(address(2))
        dialled.fresh()
        dialled.steps.onConnection(link, connected = false)
        dialled.links.onDialDown(address(1))
        assertEquals(listOf("linkDown($link)", "close($link)"), dialled.order)
        dialled.links.onDisconnected(address(1))
        assertFalse(dialled.linksAtOnce(address(1)))
        assertFalse(dialled.linksAtOnce(address(2)), "the note outlived the dial's word of the disconnect")

        // The cap: a note more pushes the eldest out, and one told again takes no place.
        val full = Radios()
        for (n in 0 until MTU_NOTES_MAX) full.links.onMtu(address(n), 517)
        full.links.onMtu(address(0), 185)
        full.links.onMtu(address(MTU_NOTES_MAX - 1), 185)
        full.links.onMtu(address(100), 517)
        assertFalse(full.linksAtOnce(address(0)), "the eldest note was kept past the cap")
        for (n in listOf(1, MTU_NOTES_MAX - 1, 100)) assertTrue(full.linksAtOnce(address(n)), "note $n was pushed out")

        // With the radio: every note and every subscriber, and nobody is told or cancelled — the adapters close all.
        val stopped = Radios()
        stopped.links.onMtu(ADDRESS, 517)
        stopped.links.onMtu(address(1), 517)
        stopped.subscribes(address(1))
        stopped.fresh()
        stopped.links.clear()
        stopped.writes(address(1), frame)
        assertFalse(stopped.links.send(0, frame))
        assertTrue(stopped.order.isEmpty(), "${stopped.order}")
        assertFalse(stopped.linksAtOnce(ADDRESS))
        assertFalse(stopped.linksAtOnce(address(1)))
    }

    /** §B.3: a frame is one whole write that wants no answer. Anything else from a link is refused, and the link ended. */
    @Test
    fun aLongAnOffsetOrAnAnsweredWriteIsRefusedAndItsLinkClosed() {
        /** A subscriber, linked or still waiting for its MTU, after one write. */
        fun after(linked: Boolean, prepared: Boolean, responseNeeded: Boolean, offset: Int): List<String> {
            val radios = Radios()
            if (linked) radios.links.onMtu(ADDRESS, 517)
            radios.subscribes(ADDRESS)
            radios.fresh()
            radios.links.onWrite(ADDRESS, 6, prepared, responseNeeded, offset, frame)
            val did = radios.order.toList()
            // Ended, its frames are a stranger's.
            if ("cancel($ADDRESS)" in did) {
                radios.writes(ADDRESS, frame)
                assertEquals(did, radios.order)
            }
            return did
        }
        val refused = listOf("answer($ADDRESS,6,false)", "linkDown(0)", "cancel($ADDRESS)")
        assertEquals(refused, after(linked = true, prepared = true, responseNeeded = true, offset = 0))
        assertEquals(refused, after(linked = true, prepared = false, responseNeeded = true, offset = 0))
        assertEquals(refused, after(linked = true, prepared = false, responseNeeded = true, offset = 3))
        // The engine before the adapter, and no answer where none is wanted.
        assertEquals(listOf("linkDown(0)", "cancel($ADDRESS)"), after(linked = true, prepared = false, responseNeeded = false, offset = 3))
        assertEquals(listOf("linkDown(0)", "cancel($ADDRESS)"), after(linked = true, prepared = true, responseNeeded = false, offset = 0))
        assertEquals(listOf("frame(0,[7, 8, 9])"), after(linked = true, prepared = false, responseNeeded = false, offset = 0))

        // A subscriber with no link yet: its frame is dropped, its other writes refused, and the core's ten seconds end it.
        assertEquals(emptyList(), after(linked = false, prepared = false, responseNeeded = false, offset = 0))
        assertEquals(listOf("answer($ADDRESS,6,false)"), after(linked = false, prepared = false, responseNeeded = true, offset = 0))
    }

    /** §M.4: a bond would hand a stranger this phone's identity address. Owner question Q-15, option (a), is what is built. */
    @Test
    fun aDeviceThatStartsToBondIsDroppedOnlyIfItIsHavens() {
        val radios = Radios()
        val (linked, waiting, headphones, dialled, dialling) = List(5) { address(it) }
        radios.links.onMtu(linked, 517)
        radios.subscribes(linked)
        radios.subscribes(waiting)
        // The user's own headphones, as the server knows of them: connected, an MTU agreed, never subscribed.
        radios.links.onMtu(headphones, 517)
        val link = radios.dialled(dialled)
        val dial = radios.dials(dialling)

        radios.fresh()
        for (role in listOf(radios.links::onBond, radios.steps::onBond)) role(headphones)
        assertTrue(radios.order.isEmpty(), "option (b) is built, not (a): a device that is not Haven's was ended: ${radios.order}")

        radios.links.onBond(linked)
        radios.links.onBond(waiting)
        assertEquals(listOf("linkDown(0)", "cancel($linked)", "linkDown(1)", "cancel($waiting)"), radios.order)
        radios.fresh()
        radios.steps.onBond(dialled)
        radios.steps.onBond(dialling)
        assertEquals(
            listOf("linkDown($link)", "disconnect($link)", "close($link)", "disconnect($dial)", "close($dial)", "connectFailed($dialling)"),
            radios.order,
        )
        // Each is ended once, and is nobody's after.
        radios.fresh()
        for (address in listOf(linked, waiting, dialled, dialling)) {
            radios.links.onBond(address)
            radios.steps.onBond(address)
            radios.writes(address, frame)
        }
        assertTrue(radios.order.isEmpty() && radios.client.open.isEmpty(), "${radios.order}")

        // A dial that has no client yet has none to close.
        val early = Radios()
        early.steps.connect(ADDRESS)
        early.fresh()
        early.steps.onBond(ADDRESS)
        assertEquals(listOf("connectFailed($ADDRESS)"), early.order)
    }

    @Test
    fun aCloseForgetsASubscriberAndAFrameGoesToItsDeviceAlone() {
        val radios = Radios()
        val (first, second) = address(1) to address(2)
        for (address in listOf(first, second)) {
            radios.links.onMtu(address, 517)
            radios.subscribes(address)
        }
        radios.fresh()
        assertTrue(radios.links.send(1, frame))
        radios.server.takes = false
        assertFalse(radios.links.send(1, frame), "a notification the platform did not take was reported taken")
        assertFalse(radios.links.send(7, frame))
        radios.links.onNotified(second, ok = true)
        radios.links.onNotified(second, ok = false)
        radios.links.onNotified(ADDRESS, ok = true)
        assertEquals(
            listOf("notify($second,[7, 8, 9])", "notify($second,[7, 8, 9])", "sendDone(1,true)", "sendDone(1,false)"),
            radios.order,
        )

        // The core's close: the device is forgotten and cancelled, and the core, which asked, is told nothing.
        radios.fresh()
        radios.links.close(0)
        radios.links.close(0)
        radios.links.close(7)
        radios.writes(first, frame)
        radios.links.onDisconnected(first)
        assertEquals(listOf("cancel($first)"), radios.order)
    }
}
