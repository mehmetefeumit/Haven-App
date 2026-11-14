package com.oblivioustech.haven.mesh.core

import java.io.ByteArrayOutputStream
import java.io.PrintStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MeshThreadTest {
    /** A service over a [Rig]: its flag, its notices, and the thread whose stop takes the radio down first. */
    private class Service(val rig: Rig = Rig()) {
        var flag = true
        var stoppedNotices = 0
        val thread = MeshThread(
            lever = { rig.lever },
            running = { rig.core.running },
            steps = listOf({ rig.core.stopRadio() }, { flag = false }),
            notice = { stoppedNotices++ },
        )
    }

    /** What both standard streams were written while [body] ran. */
    private fun written(body: () -> Unit): String {
        val (out, err) = System.out to System.err
        val captured = ByteArrayOutputStream()
        val stream = PrintStream(captured, true)
        System.setOut(stream)
        System.setErr(stream)
        try {
            body()
        } finally {
            System.setOut(out)
            System.setErr(err)
        }
        return captured.toString()
    }

    /** F-14: the process is also the relay path's. */
    @Test
    fun aRadioPortThatThrowsStopsTheRadioAndNothingEscapes() {
        val throwers = listOf("connect", "close", "send", "scan", "remind", "holdAwake", "wakeAt").map { "port" to it } +
            listOf("leftMs", "sighting", "linkUp", "linkDown", "connectFailed", "receive", "poll", "wakeInMs").map { "engine" to it } +
            // A native method JNI does not find throws at its first call.
            ("lever" to "leverHolds")
        for ((side, method) in throwers) {
            val service = Service()
            val (rig, thread) = service.rig to service.thread
            when (side) {
                "port" -> rig.port.throwsIn = method
                "engine" -> rig.engine.throwsIn = method
                else -> rig.lever.throwsIn = method
            }
            val frame = byteArrayOf(1, 2, 3)
            val output = written {
                thread.run { rig.core.startRadio() }
                thread.run { rig.core.onSighting(ADDRESS, -40) }
                thread.run { rig.core.onLinkUp(1, central = false, attMtu = 517, address = null) }
                rig.engine.outputs += connectOf(0)
                thread.run { rig.core.onWake() }
                thread.run { rig.core.onConnectFailed(ADDRESS) }
                rig.engine.outputs += sendOf(1, frame)
                thread.run { rig.core.onFrame(1, frame) }
                thread.run { rig.core.onSendDone(1, ok = false) }
                rig.engine.left = 20 * MINUTE
                thread.run { rig.core.onWake() }
            }
            val name = "$side.$method"
            assertTrue(rig.port.threw || rig.engine.threw || rig.lever.threw, "premise: $name was never called")
            assertTrue(thread.stopped, "$name threw and the radio was not stopped")
            assertFalse(service.flag, "$name threw and the on flag was left set")
            assertEquals(1, service.stoppedNotices, "$name threw and the stopped notice was not posted once")
            assertEquals("", output, "something was written when $name threw")
            if (side == "port") {
                val ups = rig.engine.called("linkUp").size
                assertEquals(ups, rig.engine.called("linkDown").size, "$name threw and the engine was left a link")
            }
            // A stop is final: what still arrives is dropped unrun.
            var ran = false
            thread.run { ran = true }
            assertFalse(ran, name)
        }
    }

    /** §B.5: every stop but the user's own posts the stopped notice, and each clears the flag, once. */
    @Test
    fun aStopTheUserDidNotMakeIsAStopWithTheNoticeAndIsFinal() {
        val user = Service()
        user.thread.run { user.rig.core.startRadio() }
        assertTrue(user.flag && !user.thread.stopped, "a body that ended well stopped the radio")
        // A body like any other: what it closes is the platform's to log of.
        user.thread.run { user.thread.stop(notice = false) }
        assertTrue(!user.flag && user.stoppedNotices == 0)
        // The engine is turned off right after: a wake that still arrives is not a second stop, with a notice.
        user.rig.engine.left = 0
        user.thread.run { user.rig.core.onWake() }
        user.thread.stop(notice = true)
        assertEquals(0, user.stoppedNotices)

        val refused = Service()
        refused.thread.stop(notice = true)
        refused.thread.stop(notice = true)
        assertTrue(!refused.flag && refused.stoppedNotices == 1)
    }

    /**
     * §B.2: stopping the radio asks for the deadline's wake, as every stop of it does. An alarm cancelled before
     * that would be armed again behind it, and wake a service that is gone. And the engine is told its links are
     * down before an adapter is closed: a close that throws — the dead adapter that made the stop — skips nothing.
     */
    @Test
    fun theStopCancelsTheAlarmAfterTheRadioIsDown() {
        for (notice in listOf(true, false)) {
            val rig = Rig().started()
            rig.core.onLinkUp(1, central = false, attMtu = 517, address = null)
            val done = mutableListOf<String>()
            val thread = MeshThread(
                lever = { rig.lever },
                running = { rig.core.running },
                steps = MeshThread.steps(
                    detach = { done += "detach" },
                    stopRadio = { rig.core.stopRadio() },
                    closeAdapters = {
                        assertEquals(listOf("linkDown(1)"), rig.engine.called("linkDown"), "an adapter was closed before the engine was told")
                        done += "close"
                        throw Thrown()
                    },
                    cancelAlarm = { rig.port.calls += "cancelAlarm()" },
                    tell = { done += "tell" },
                    unpost = { done += "unpost" },
                    end = { done += "end" },
                ),
                notice = { done += "notice" },
            )
            rig.fresh()
            thread.stop(notice)
            val alarm = rig.port.calls.filter { it.startsWith("wakeAt(") || it == "cancelAlarm()" }
            assertTrue(alarm.size == 2 && alarm.last() == "cancelAlarm()", "the alarm was left armed behind the stop: $alarm")
            assertEquals(listOf("detach", "close", "tell", "unpost", "end") + if (notice) listOf("notice") else emptyList(), done)
        }
    }

    /**
     * §O.1.8: a service brought down while a start command still owes its foreground start takes the process down.
     * A command can arrive at any step of a stop; it is owed a foreground once the service has left it. So the stop
     * lets go of the service before anything else: a command from then on finds no live start and makes its own,
     * which makes the foreground start itself — whatever a later step of the old one throws.
     */
    @Test
    fun aStopLetsGoOfTheServiceBeforeAnythingElse() {
        for (thrower in listOf(null, "stopRadio", "closeAdapters", "cancelAlarm", "tell", "unpost", "end")) {
            val starts = ServiceStarts<String>()
            starts.command(1) { "first" }
            var wanted = true
            val done = mutableListOf<String>()
            fun step(name: String): () -> Unit = {
                // What a command arriving now would find.
                done += "$name:${starts.live()}"
                if (name == thrower) throw Thrown()
            }
            val thread = MeshThread(
                lever = { FakeLever() },
                running = { true },
                steps = MeshThread.steps(
                    detach = { starts.detach { wanted = false } },
                    stopRadio = step("stopRadio"),
                    closeAdapters = step("closeAdapters"),
                    cancelAlarm = step("cancelAlarm"),
                    tell = step("tell"),
                    unpost = step("unpost"),
                    end = step("end"),
                ),
                notice = step("notice"),
            )
            thread.stop(notice = true)
            assertEquals(
                listOf("stopRadio", "closeAdapters", "cancelAlarm", "tell", "unpost", "end", "notice").map { "$it:null" },
                done,
                "a step of the stop still saw the start it was stopping (thrown in: $thrower)",
            )
            assertFalse(wanted, "the stop let go of the service and left its flag set")
            // The command that arrives behind it is a start of its own.
            var made = false
            starts.command(2) { "second".also { made = true } }
            assertTrue(made && starts.live() == "second")
        }
    }

    /**
     * §O.1.2: one thread and one radio a service. A start command that finds a live start joins it — a service in
     * the foreground owes a second command nothing — and one that finds none makes the live start, after a stop too.
     */
    @Test
    fun aStartThatFindsALiveOneJoinsItAndOneThatFindsNoneIsFresh() {
        val starts = ServiceStarts<String>()
        val made = mutableListOf<String>()
        fun command(id: Int, name: String) = starts.command(id) { name.also { made += it } }
        assertNull(starts.live())
        command(1, "first")
        assertEquals("first", starts.live())
        // The sticky restart's, the boot's, a second turn-on's: no second thread beside the live one.
        command(2, "second")
        command(3, "third")
        assertEquals(listOf("first"), made)
        assertEquals("first", starts.live())
        // After the stop the next command is not dropped: it is the fresh start.
        starts.detach {}
        assertNull(starts.live())
        command(4, "fourth")
        assertEquals(listOf("first", "fourth"), made)
        assertEquals("fourth", starts.live())
    }

    /**
     * §O.1.8: the platform leaves a service up when it is ended by a command older than its last. So a stop ends
     * the service by the last command that joined the start it stops — not by none, which ends it whatever came
     * since, nor by the first, which never would — and a start made behind the stop keeps the service, the
     * foreground and the notices.
     */
    @Test
    fun theStopNamesTheLastStartThatJoined() {
        val starts = ServiceStarts<String>()
        starts.command(7) { "first" }
        assertEquals(7, starts.detach {})

        starts.command(8) { "second" }
        starts.command(9) { error("a second start beside a live one") }
        starts.command(12) { error("a second start beside a live one") }
        assertEquals(12, starts.detach {}, "not the last command that joined")

        // A command behind the stop is the next start's: the stop that is still running names the one before it,
        // and leaves the foreground and the notices alone.
        var left = 0
        starts.idle { left++ }
        assertEquals(1, left, "a stop with no start behind it did not leave the foreground")
        starts.command(13) { "third" }
        starts.idle { left++ }
        assertEquals(1, left, "a stop took the foreground from the start made behind it")
        assertEquals(13, starts.detach {})
        starts.idle { left++ }
        assertEquals(2, left)
    }

    /**
     * A stop the service made is final: nothing may ask for the radio back while it still runs. What would ask is
     * whoever reads "no service, and the mesh wanted" — so the flag is cleared in the very step that lets go of the
     * start, with no start to be found by then and none made before it is done. And a start the user asks for
     * behind the stop is its own: the flag it sets, the alarm it arms and the foreground it takes are not the
     * stopping one's to clear, cancel or leave.
     */
    @Test
    fun aStartMadeBehindAStopKeepsItsFlagItsAlarmAndTheForeground() {
        val starts = ServiceStarts<String>()
        starts.command(1) { "first" }
        var wanted = true
        var foundWhileClearing: String? = "unread"
        starts.detach {
            foundWhileClearing = starts.live()
            wanted = false
        }
        assertNull(foundWhileClearing, "the flag was cleared while the start it belonged to could still be found")
        assertFalse(wanted, "a start was let go of with its flag left set: read now, it is a mesh to bring back")
        assertNull(starts.live())

        // The old stop goes on: with nobody behind it, it cancels the alarm and leaves the foreground.
        val did = mutableListOf<String>()
        starts.idle { did += "cancelAlarm" }
        assertEquals(listOf("cancelAlarm"), did)

        // The user turns the mesh on again in the middle of it. That start sets the flag and arms the alarm …
        starts.command(2) { "second" }
        wanted = true
        // … and the rest of the old stop touches none of it.
        for (step in listOf("cancelAlarm", "unpost", "notice")) starts.idle { did += "old:$step" }
        assertEquals(listOf("cancelAlarm"), did, "a stop reached into the start made behind it")
        assertTrue(wanted && starts.live() == "second")
    }

    /**
     * §N.7, §O.1.3: with Bluetooth off the platform throws from the calls that close a radio. Each close runs
     * whatever the one before it threw, and nothing is thrown on: a pause must not become a stop.
     */
    @Test
    fun everyCloseOfARadiosEndRunsThoughOneThrows() {
        val closes = listOf("client", "server", "advertiser", "scanner", "lock")
        for (throwers in listOf(emptySet(), setOf("client"), setOf("server", "scanner"), closes.toSet())) {
            val ran = mutableListOf<String>()
            val output = written {
                RadioEnd.each(
                    *closes.map { name ->
                        {
                            ran += name
                            if (name in throwers) throw Thrown()
                            // What a native library that does not load throws is no exception: an error, as this is.
                            if (name == "lock" && "scanner" in throwers) throw UnsatisfiedLinkError("no $ADDRESS")
                            if (name == "advertiser" && "server" in throwers) throw ExceptionInInitializerError()
                        }
                    }.toTypedArray(),
                )
            }
            assertEquals(closes, ran, "a close was skipped behind one that threw ($throwers)")
            assertEquals("", output, "something was written of what a close threw")
        }
        RadioEnd.each()
    }

    /**
     * §M.3, §N.1.3: the platform logs the address of whatever connects, in every call made of it and in every
     * callback it makes. So nothing of the radio runs once the lever stopped holding — not the core, not a dial's
     * next step, not the server's answer — and the one place that asks is the one every body passes through.
     */
    @Test
    fun aLeverThatStopsHoldingIsPutBackAndStopsTheRadio() {
        val frame = byteArrayOf(7, 8, 9)
        // What can arrive next, each on a radio made for it, and the platform call it would make.
        val arrivals = mapOf<String, Pair<Radios.() -> Unit, Radios.() -> Unit>>(
            "connect(0,$ADDRESS)" to ({ r: Radios -> r.steps.connect(ADDRESS) } to { r: Radios -> r.steps.onTimer() }),
            "requestMtu(0,517)" to ({ r: Radios -> r.dials(ADDRESS).let {} } to { r: Radios -> r.steps.onConnection(0, connected = true) }),
            "discover(0)" to (
                { r: Radios ->
                    r.dials(ADDRESS)
                    r.steps.onConnection(0, connected = true)
                } to { r: Radios -> r.steps.onMtu(0, 517, ok = true) }
                ),
            "subscribe(0)" to (
                { r: Radios ->
                    r.dials(ADDRESS)
                    r.steps.onConnection(0, connected = true)
                    r.steps.onMtu(0, 517, ok = true)
                } to { r: Radios -> r.steps.onDiscovered(0, ok = true) }
                ),
            // The second connection of a dial whose first failed, 300 ms on.
            "connect(1,$ADDRESS)" to (
                { r: Radios ->
                    r.dials(ADDRESS)
                    r.steps.onConnection(0, connected = false)
                    r.now += 300
                } to { r: Radios -> r.steps.onTimer() }
                ),
            "answer($ADDRESS,1,true)" to ({ _: Radios -> } to { r: Radios -> r.subscribes(ADDRESS) }),
            "cancel($ADDRESS)" to (
                { r: Radios ->
                    r.links.onMtu(ADDRESS, 517)
                    r.subscribes(ADDRESS)
                } to { r: Radios -> r.links.onWrite(ADDRESS, 2, prepared = false, responseNeeded = true, offset = 0, value = frame) }
                ),
            "write(0,[7, 8, 9])" to ({ r: Radios -> r.dialled(ADDRESS).let {} } to { r: Radios -> r.steps.send(0, frame).let {} }),
        )
        for ((call, arrival) in arrivals) {
            for (holds in listOf(true, false)) {
                val radios = Radios()
                arrival.first(radios)
                radios.fresh()
                val lever = FakeLever().apply { this.holds = holds }
                val done = mutableListOf<String>()
                val thread = MeshThread({ lever }, { true }, listOf({ done += "steps" })) { done += "notice" }
                var ran = false
                lever.onCall = { assertFalse(ran, "the lever was asked after the body began") }
                thread.run {
                    ran = true
                    arrival.second(radios)
                }
                if (holds) {
                    // One question a body, and the body's call is made.
                    assertEquals(listOf("leverHolds()"), lever.calls)
                    assertTrue(call in radios.order && !thread.stopped, "premise: $call is what this body makes: ${radios.order}")
                } else {
                    assertFalse(ran, "a body ran with no lever")
                    assertTrue(radios.order.isEmpty(), "$call was made with no lever: ${radios.order}")
                    // Put back: the stop's steps close what the platform logs of, and its callbacks outlive the stop.
                    assertEquals(listOf("leverHolds()", "leverInstall()"), lever.calls)
                    assertEquals(listOf("steps", "notice"), done, "not a stop with its notice")
                }
            }
        }

        // The core's inputs are bodies too, and what the stop does is the service's: the engine is left no link.
        val service = Service()
        service.thread.run { service.rig.core.startRadio() }
        service.thread.run { service.rig.core.onLinkUp(1, central = false, attMtu = 517, address = null) }
        service.rig.engine.outputs += sendOf(1, frame)
        service.rig.fresh()
        service.rig.lever.holds = false
        service.thread.run { service.rig.core.onFrame(1, frame) }
        assertTrue(service.thread.stopped && !service.flag && service.stoppedNotices == 1)
        // Not the frame: only what the stop's own step asks of it.
        assertEquals(listOf("leftMs()", "linkDown(1)"), service.rig.engine.calls)
        assertEquals(listOf("leverHolds()", "leverInstall()"), service.rig.lever.calls)
        // Stopped, nothing asks again.
        service.thread.run { service.rig.core.onWake() }
        assertEquals(2, service.rig.lever.calls.size)

        // The user's own stop is a body: with no lever it is still a stop, put back first, and says so.
        val user = Service()
        user.rig.lever.holds = false
        user.thread.run { user.thread.stop(notice = false) }
        assertTrue(user.thread.stopped && !user.flag && user.stoppedNotices == 1)
        assertEquals(listOf("leverHolds()", "leverInstall()"), user.rig.lever.calls)
    }

    /**
     * N-5: a service started in the foreground that ends before its foreground start takes the process down. Its
     * start is the one body that runs whatever the lever does — it is what puts the lever in — and is held like
     * any other.
     */
    @Test
    fun theServicesStartRunsBeforeTheLeverIsAsked() {
        val started = Service()
        started.rig.lever.holds = false
        var ran = false
        started.thread.start { ran = true }
        assertTrue(ran && !started.thread.stopped, "the start did not run")
        assertTrue(started.rig.lever.calls.isEmpty(), "the wrapper asked the lever at the start: ${started.rig.lever.calls}")

        // What it throws is a stop with the notice, and a start that ends with no engine is one too.
        val thrown = Service()
        thrown.thread.start { throw Thrown() }
        assertTrue(thrown.thread.stopped && !thrown.flag && thrown.stoppedNotices == 1)
        val ended = Service()
        ended.rig.engine.left = 0
        ended.thread.start { ended.rig.core.onWake() }
        assertTrue(ended.thread.stopped && ended.stoppedNotices == 1)
        // A refusal is the start's own stop, with the notice it names, once.
        val refused = Service()
        refused.thread.start { refused.thread.stop(notice = false) }
        assertTrue(refused.thread.stopped && !refused.flag && refused.stoppedNotices == 0)
        ran = false
        refused.thread.start { ran = true }
        assertFalse(ran, "a start ran on a thread that had stopped")
    }

    /** T-AUTO-2: at the deadline the service stops itself, with the notice, at the first input after it. */
    @Test
    fun anEngineWhoseTimeIsUpStopsTheServiceWithTheNotice() {
        val service = Service()
        service.thread.run { service.rig.core.startRadio() }
        service.thread.run { service.rig.core.onLinkUp(1, central = false, attMtu = 517, address = null) }
        service.rig.engine.left = 0
        service.thread.run { service.rig.core.onSighting(ADDRESS, -40) }
        assertTrue(service.thread.stopped && !service.flag)
        assertEquals(1, service.stoppedNotices)
        assertTrue(service.rig.engine.called("sighting").isEmpty())
    }
}
