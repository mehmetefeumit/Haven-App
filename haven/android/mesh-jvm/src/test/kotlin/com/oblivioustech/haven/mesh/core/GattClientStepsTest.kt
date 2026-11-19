package com.oblivioustech.haven.mesh.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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

        // The smallest MTU that carries a frame is a link's.
        val smallest = Radios()
        smallest.dialled(ADDRESS, mtu = 51)
        assertEquals(listOf("linkUp(0,true,51,$ADDRESS)"), smallest.events.calls)

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

        // Every connection of a pass is made before the core is told of a failure in it: told, the core may find
        // its own time up, and nothing is dialled behind that.
        val pass = Radios()
        pass.dials(address(1))
        pass.now = 25_000
        pass.steps.connect(address(2))
        pass.fresh()
        pass.steps.onTimer()
        assertEquals(
            listOf("connect(1,${address(2)})", "disconnect(0)", "close(0)", "connectFailed(${address(1)})"),
            pass.order.filterNot { it.startsWith("timer(") },
        )

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
        // Nor when the timer itself comes late — a phone that slept — and finds both due: the first connection of a
        // dial, or its second.
        val late = Radios()
        late.steps.connect(ADDRESS)
        late.pass(30_000)
        val lateAgain = Radios()
        lateAgain.dials(ADDRESS)
        lateAgain.now = 24_800
        lateAgain.steps.onConnection(0, connected = false)
        lateAgain.pass(5_000)
        assertTrue(late.client.called("connect").isEmpty() && lateAgain.client.called("connect").size == 1, "a connection after the dial's time")
        for (radios in listOf(late, lateAgain)) assertEquals(listOf("connectFailed($ADDRESS)"), radios.events.calls)
    }

    /**
     * The dial's timer is the thread's, which stops counting while the phone sleeps; the clock does not. A peer that
     * answers each step only just in time must not hold a dial, and its client, past the dial's twenty-five seconds.
     */
    @Test
    fun aCallbackPastADialsTimeGivesItUpAsTheTimerWould() {
        val goesOn = listOf(
            listOf("requestMtu(0,517)"),
            listOf("discover(0)"),
            listOf("subscribe(0)"),
            listOf("linkUp(0,true,517,$ADDRESS)", "lowPower(0)"),
        )
        for (steps in 0..3) {
            /** A dial taken through [steps] callbacks at once, and its next one at [at] with no timer between. */
            fun next(at: Long): Radios {
                val radios = Radios()
                radios.dials(ADDRESS)
                callbacksOf(radios).take(steps).forEach { it(0) }
                radios.now = at
                radios.fresh()
                callbacksOf(radios)[steps](0)
                return radios
            }
            // The last millisecond is the dial's still.
            assertEquals(goesOn[steps], next(24_999).order, "after $steps step(s)")

            // At its time the callback is where the dial ends: closed once, told once, and the step not begun.
            val late = next(25_000)
            assertEquals(listOf("disconnect(0)", "close(0)", "connectFailed($ADDRESS)"), late.order, "after $steps step(s)")
            assertTrue(late.client.open.isEmpty(), "a client was left open")
            // The timer that comes afterwards, and whatever else still arrives, finds nothing to give up.
            callbacksOf(late).forEach { it(0) }
            late.steps.onConnection(0, connected = false)
            late.pass(60_000)
            assertEquals(listOf("connectFailed($ADDRESS)"), late.events.calls, "after $steps step(s)")
            assertEquals(3, late.order.filterNot { it.startsWith("timer(") }.size, "a dial given up went on: ${late.order}")
        }
    }

    /** The same for a connection that ends: its second is the timer's to make, and past the dial's time there is none. */
    @Test
    fun aConnectionLostPastADialsTimeIsNotMadeAgain() {
        /** A dial whose connection ends at [at], after [steps] callbacks and with no timer between. */
        fun lost(steps: Int, at: Long): Radios {
            val radios = Radios()
            radios.dials(ADDRESS)
            callbacksOf(radios).take(steps).forEach { it(0) }
            radios.now = at
            radios.fresh()
            radios.steps.onConnection(0, connected = false)
            return radios
        }
        for (steps in 0..3) {
            // In time, the second connection is still owed: nobody is told yet.
            assertEquals(listOf("close(0)", "timer(1)"), lost(steps, 24_999).order, "after $steps step(s)")

            // Past it the dial is answered there and then, not when a timer next runs.
            val late = lost(steps, 25_000)
            assertEquals(listOf("close(0)", "connectFailed($ADDRESS)"), late.order, "after $steps step(s)")
            late.pass(60_000)
            assertTrue(late.client.called("connect").isEmpty() && late.events.calls.size == 1, "a dial given up went on: ${late.order}")
        }

        // A link is no dial: lost however late, it is told down and never as a failed connect.
        val link = lost(4, 3_600_000)
        assertEquals(listOf("linkDown(0)", "close(0)"), link.order)
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
        // The stop is final: a radio that comes back has steps of its own, and these dial nobody.
        stopped.steps.connect(address(5))
        assertEquals(3, stopped.order.size, "a dial outlived the radio: ${stopped.order}")

        for (radios in listOf(lost, closed, stopped)) assertTrue(radios.client.open.isEmpty(), "a client was left open")
    }

    /**
     * A call to the port may throw — the adapter changed under it — and what is thrown stops the radio. A client
     * must be closed all the same: forgotten and not closed, it is one nothing closes again.
     */
    @Test
    fun aClientIsClosedThoughAPortCallThrows() {
        // A dial given up, the core's close, a bond: the disconnect throws, and the close is made behind it.
        val endings = mapOf<String, Radios.() -> Unit>(
            "a dial given up" to { steps.onDiscovered(0, ok = false) },
            "the core's close" to { steps.close(0) },
            "a bond" to { steps.onBond(ADDRESS) },
        )
        for ((name, ends) in endings) {
            val radios = Radios()
            if (name == "a dial given up") {
                radios.dials(ADDRESS)
                radios.steps.onConnection(0, connected = true)
                radios.steps.onMtu(0, 517, ok = true)
            } else {
                radios.dialled(ADDRESS)
            }
            radios.client.throws += "disconnect"
            radios.fresh()
            assertFailsWith<Thrown>(name) { radios.ends() }
            assertEquals(listOf("disconnect(0)", "close(0)"), radios.client.calls, name)
            assertTrue(radios.client.open.isEmpty(), "$name left its client open")
        }

        // The core throws as it is told a link is down — its own port, the engine: the client is closed behind that.
        for (ends in listOf<Radios.() -> Unit>({ steps.onConnection(0, connected = false) }, { steps.onBond(ADDRESS) })) {
            val radios = Radios()
            radios.dialled(ADDRESS)
            radios.events.then = { if (it.startsWith("linkDown(")) throw Thrown() }
            assertFailsWith<Thrown> { radios.ends() }
            assertTrue(radios.client.open.isEmpty(), "a client was left open behind what the core threw")
        }

        // The radio's stop: a close that throws skips no other client, and is thrown on once every one was asked.
        val stopped = Radios()
        for (n in 1..3) stopped.dials(address(n))
        stopped.client.throws += "close(0)"
        stopped.fresh()
        assertFailsWith<Thrown> { stopped.steps.stop() }
        assertEquals(listOf("close(0)", "close(1)", "close(2)"), stopped.order)
        // All three are forgotten: the one that would not close is not asked again.
        stopped.steps.stop()
        stopped.steps.onConnection(1, connected = true)
        assertEquals(3, stopped.order.size)
        assertEquals(setOf(0L), stopped.client.open)
    }
}
