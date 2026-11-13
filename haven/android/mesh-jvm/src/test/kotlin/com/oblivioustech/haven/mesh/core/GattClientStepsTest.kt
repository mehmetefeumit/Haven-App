package com.oblivioustech.haven.mesh.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GattClientStepsTest {
    private val frame = byteArrayOf(7, 8, 9)

    /** §B.3: the MTU before discovery, and a link only at the subscription. Each step waits for its callback. */
    @Test
    fun anOutgoingLinkIsMtuThenDiscoveryThenSubscription() {
        val radios = Radios()
        radios.steps.connect(ADDRESS)
        // The core calls this from inside its pump, where it can be answered nothing: the connection is the timer's.
        assertEquals(listOf("timer(0)"), radios.order)
        radios.steps.onTimer()
        radios.steps.onConnection(0, connected = true)
        radios.steps.onMtu(0, 185, ok = true)
        radios.steps.onDiscovered(0, ok = true)
        assertTrue(radios.events.calls.isEmpty(), "a link before its subscription")
        radios.steps.onSubscribed(0, ok = true)
        assertEquals(
            listOf(
                "timer(0)", "connect(0,$ADDRESS)", "timer(25000)", "requestMtu(0,517)", "discover(0)", "subscribe(0)",
                "linkUp(0,true,185,$ADDRESS)", "lowPower(0)",
            ),
            radios.order,
        )

        // A link: its frames and its completions are told under its number, and a frame goes out on it alone.
        radios.fresh()
        radios.steps.onFrame(0, frame)
        radios.steps.onWritten(0, ok = true)
        assertTrue(radios.steps.send(0, frame))
        radios.client.refuses += "write"
        assertFalse(radios.steps.send(0, frame), "a write the platform did not take was reported taken")
        assertFalse(radios.steps.send(5, frame))
        assertEquals(listOf("frame(0,[7, 8, 9])", "sendDone(0,true)", "write(0,[7, 8, 9])", "write(0,[7, 8, 9])"), radios.order)

        // A callback out of its turn, or come twice, begins nothing; before the link no frame and no send is one.
        val early = Radios()
        val link = early.dials(ADDRESS)
        early.fresh()
        early.steps.onMtu(link, 517, ok = true)
        early.steps.onDiscovered(link, ok = true)
        early.steps.onSubscribed(link, ok = true)
        repeat(2) { early.steps.onConnection(link, connected = true) }
        early.steps.onDiscovered(link, ok = true)
        early.steps.onSubscribed(link, ok = true)
        repeat(2) { early.steps.onMtu(link, 517, ok = true) }
        early.steps.onSubscribed(link, ok = true)
        repeat(2) { early.steps.onDiscovered(link, ok = true) }
        early.steps.onFrame(link, frame)
        early.steps.onWritten(link, ok = true)
        assertFalse(early.steps.send(link, frame))
        repeat(2) { early.steps.onSubscribed(link, ok = true) }
        assertEquals(
            listOf("requestMtu(0,517)", "discover(0)", "subscribe(0)", "linkUp(0,true,517,$ADDRESS)", "lowPower(0)"),
            early.order,
        )

        // A link the core closes as it comes up — the engine's ninth — is asked nothing after its close.
        val ninth = Radios()
        ninth.events.then = { if (it.startsWith("linkUp(")) ninth.steps.close(0) }
        ninth.dialled(ADDRESS)
        assertEquals(listOf("linkUp(0,true,517,$ADDRESS)", "disconnect(0)", "close(0)"), ninth.order.takeLast(3))
    }

    /** A dial is answered once. One that fails is disconnected and closed first: a client left open is never got back. */
    @Test
    fun aStepThatFailsOrTwentyFiveSecondsIsOneFailedConnect() {
        /** A dial taken through [steps] of its callbacks, then [fails]; what that did. */
        fun failed(steps: Int, refuses: String? = null, fails: Radios.(Long) -> Unit): List<String> {
            val radios = Radios()
            val link = radios.dials(ADDRESS)
            val callbacks = listOf<() -> Unit>(
                { radios.steps.onConnection(link, connected = true) },
                { radios.steps.onMtu(link, 517, ok = true) },
                { radios.steps.onDiscovered(link, ok = true) },
            )
            callbacks.take(steps).forEach { it() }
            radios.fresh()
            if (refuses != null) radios.client.refuses += refuses
            radios.fails(link)
            val did = radios.order.filterNot { it.startsWith("timer(") }
            // Answered: whatever still arrives, and however long it is waited, nothing more is done or told.
            radios.client.refuses.clear()
            callbacks.forEach { it() }
            radios.steps.onSubscribed(link, ok = true)
            radios.steps.onConnection(link, connected = false)
            radios.pass(60_000)
            assertEquals(did, radios.order.filterNot { it.startsWith("timer(") }, "a failed dial went on")
            assertTrue(radios.client.open.isEmpty(), "a client was left open")
            return did
        }
        val gaveUp = listOf("disconnect(0)", "close(0)", "connectFailed($ADDRESS)")
        assertEquals(listOf("requestMtu(0,517)") + gaveUp, failed(0, refuses = "requestMtu") { steps.onConnection(it, connected = true) })
        assertEquals(gaveUp, failed(1) { steps.onMtu(it, 517, ok = false) })
        assertEquals(gaveUp, failed(1) { steps.onMtu(it, 50, ok = true) }, "a link under the smallest MTU that carries a frame")
        assertEquals(listOf("discover(0)") + gaveUp, failed(1, refuses = "discover") { steps.onMtu(it, 517, ok = true) })
        assertEquals(gaveUp, failed(2) { steps.onDiscovered(it, ok = false) })
        // Not Haven's service, or a descriptor the platform would not write.
        assertEquals(listOf("subscribe(0)") + gaveUp, failed(2, refuses = "subscribe") { steps.onDiscovered(it, ok = true) })
        assertEquals(gaveUp, failed(3) { steps.onSubscribed(it, ok = false) })

        // Twenty-five seconds, at whichever step they run out.
        for (steps in 0..3) {
            val late = failed(steps) {
                pass(24_999)
                assertTrue(order.all { it.startsWith("timer(") }, "given up early, after $steps step(s): $order")
                pass(1)
            }
            assertEquals(gaveUp, late, "after $steps step(s)")
        }

        // One timer for every dial there is: the earliest's.
        val two = Radios()
        two.dials(address(1))
        two.now = 10_000
        two.dials(address(2))
        assertEquals("timer(15000)", two.order.last())
        two.pass(15_000)
        assertEquals(listOf("connectFailed(${address(1)})") to "timer(10000)", two.events.calls to two.order.last())
        two.pass(10_000)
        assertEquals(listOf(address(1), address(2)).map { "connectFailed($it)" }, two.events.calls)

        // A client the platform did not make has nothing to close, and its dial is answered at the timer all the same.
        val unmade = Radios()
        unmade.client.refuses += "connect"
        unmade.steps.connect(ADDRESS)
        assertEquals(listOf("timer(0)"), unmade.order)
        unmade.steps.onTimer()
        assertEquals(listOf("timer(0)", "connect(0,$ADDRESS)", "connectFailed($ADDRESS)"), unmade.order)

        // A link is no dial: its twenty-five seconds mean nothing.
        val linked = Radios()
        linked.dialled(ADDRESS)
        linked.fresh()
        linked.pass(60_000)
        assertTrue(linked.order.isEmpty() && linked.client.open == setOf(0L), "${linked.order}")
    }

    /** §B.3: Android's status 133, and any connection lost before its link. Closed, always; then once more, 300 ms on. */
    @Test
    fun aConnectionThatFailsBeforeItsLinkIsTriedOnceMore() {
        for (steps in 0..3) {
            val radios = Radios()
            radios.dials(ADDRESS)
            val callbacks = listOf<(Long) -> Unit>(
                { radios.steps.onConnection(it, connected = true) },
                { radios.steps.onMtu(it, 517, ok = true) },
                { radios.steps.onDiscovered(it, ok = true) },
            )
            callbacks.take(steps).forEach { it(0) }
            radios.now = 1_000
            radios.fresh()
            radios.steps.onConnection(0, connected = false)
            assertEquals(listOf("close(0)", "timer(300)"), radios.order, "after $steps step(s)")
            radios.pass(299)
            assertTrue(radios.client.called("connect").isEmpty(), "tried again early")
            radios.pass(1)
            // A new client under a new number: what still arrives under the first is nobody's.
            assertEquals(listOf("connect(1,$ADDRESS)"), radios.client.called("connect"))
            radios.fresh()
            callbacks.forEach { it(0) }
            radios.steps.onSubscribed(0, ok = true)
            radios.steps.onConnection(0, connected = false)
            assertTrue(radios.order.isEmpty(), "a callback of the closed client was acted on: ${radios.order}")

            // The second fails as far in: failed, and no third.
            callbacks.take(steps).forEach { it(1) }
            radios.fresh()
            radios.steps.onConnection(1, connected = false)
            radios.pass(300)
            radios.pass(60_000)
            assertEquals(listOf("close(1)", "connectFailed($ADDRESS)"), radios.order.filterNot { it.startsWith("timer(") })
            assertTrue(radios.client.open.isEmpty())
        }

        // The second can be the link.
        val second = Radios()
        second.dials(ADDRESS)
        second.steps.onConnection(0, connected = false)
        second.pass(300)
        callbacksOf(second).forEach { it(1) }
        assertEquals(listOf("linkUp(1,true,517,$ADDRESS)"), second.events.calls)

        // The twenty-five seconds are the whole dial's: a second connection does not start them again …
        val slow = Radios()
        slow.dials(ADDRESS)
        slow.now = 10_000
        slow.steps.onConnection(0, connected = false)
        slow.pass(300)
        slow.pass(14_699)
        assertTrue(slow.events.calls.isEmpty())
        slow.pass(1)
        assertEquals(listOf("disconnect(1)", "close(1)", "connectFailed($ADDRESS)"), slow.order.takeLast(4).filterNot { it.startsWith("timer(") })
        // … and one that would come after them is not made.
        val spent = Radios()
        spent.dials(ADDRESS)
        spent.now = 24_800
        spent.steps.onConnection(0, connected = false)
        assertEquals("timer(200)", spent.order.last())
        spent.pass(200)
        spent.pass(60_000)
        assertEquals(listOf("connect(0,$ADDRESS)"), spent.client.called("connect"))
        assertEquals(listOf("connectFailed($ADDRESS)"), spent.events.calls)
    }

    private fun callbacksOf(radios: Radios) = listOf<(Long) -> Unit>(
        { radios.steps.onConnection(it, connected = true) },
        { radios.steps.onMtu(it, 517, ok = true) },
        { radios.steps.onDiscovered(it, ok = true) },
        { radios.steps.onSubscribed(it, ok = true) },
    )

    /** §B.3: `close()` after every disconnect, always. A client that leaks is one of the few Android has. */
    @Test
    fun aClientIsClosedAfterEveryDisconnectAndAtTheRadiosStop() {
        // A link that is lost: the core is told, the client closed, and nothing is dialled again.
        val lost = Radios()
        lost.dialled(ADDRESS)
        lost.fresh()
        lost.steps.onConnection(0, connected = false)
        lost.pass(60_000)
        assertEquals(listOf("linkDown(0)", "close(0)"), lost.order)

        // The core's close: disconnected and closed, and the core, which asked, is told nothing.
        val closed = Radios()
        closed.dialled(ADDRESS)
        closed.fresh()
        closed.steps.close(0)
        closed.steps.close(0)
        closed.steps.close(7)
        closed.steps.onConnection(0, connected = false)
        closed.steps.onFrame(0, frame)
        assertEquals(listOf("disconnect(0)", "close(0)"), closed.order)

        // The radio stops: every client there is, at whatever step, and nobody is told — the core has told the engine.
        val stopped = Radios()
        stopped.dialled(address(1))
        val connecting = stopped.dials(address(2))
        val discovering = stopped.dials(address(3))
        stopped.steps.onConnection(discovering, connected = true)
        stopped.steps.onMtu(discovering, 517, ok = true)
        stopped.steps.connect(address(4))
        stopped.fresh()
        stopped.steps.stop()
        assertEquals(listOf("close(0)", "close($connecting)", "close($discovering)"), stopped.order)
        stopped.steps.onDiscovered(discovering, ok = true)
        stopped.steps.onConnection(connecting, connected = false)
        stopped.pass(60_000)
        assertEquals(3, stopped.order.size, "a dial outlived the radio: ${stopped.order}")

        for (radios in listOf(lost, closed, stopped)) assertTrue(radios.client.open.isEmpty(), "a client was left open")
    }
}
