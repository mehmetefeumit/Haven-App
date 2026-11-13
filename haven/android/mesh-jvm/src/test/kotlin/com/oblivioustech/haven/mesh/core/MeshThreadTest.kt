package com.oblivioustech.haven.mesh.core

import java.io.ByteArrayOutputStream
import java.io.PrintStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MeshThreadTest {
    /** A service over a [Rig]: its flag, its notices, and the thread whose stop takes the radio down first. */
    private class Service(val rig: Rig = Rig()) {
        var flag = true
        var stoppedNotices = 0
        val thread = MeshThread(
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
        user.thread.stop(notice = false)
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
     * §B.2: the radio-down step asks for the deadline's wake, as every stop of the radio does. An alarm cancelled
     * before it would be armed again behind it, and wake a service that is gone.
     */
    @Test
    fun theStopCancelsTheAlarmAfterTheRadioIsDown() {
        for (notice in listOf(true, false)) {
            val rig = Rig().started()
            val done = mutableListOf<String>()
            val thread = MeshThread(
                running = { rig.core.running },
                steps = MeshThread.steps(
                    radioDown = { rig.core.stopRadio() },
                    cancelAlarm = { rig.port.calls += "cancelAlarm()" },
                    forget = { done += "forget" },
                    unpost = { done += "unpost" },
                    end = { done += "end" },
                ),
                notice = { done += "notice" },
            )
            rig.fresh()
            thread.stop(notice)
            val alarm = rig.port.calls.filter { it.startsWith("wakeAt(") || it == "cancelAlarm()" }
            assertTrue(alarm.size == 2 && alarm.last() == "cancelAlarm()", "the alarm was left armed behind the stop: $alarm")
            assertEquals(listOf("forget", "unpost", "end") + if (notice) listOf("notice") else emptyList(), done)
        }
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
