package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.ALARM_AHEAD_MAX_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.ALARM_MIN_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.ALARM_SLACK_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_CAP_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_MARGIN_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_SLACK_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MESH_ON_MAX_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.REMINDER_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SCAN_RESTART_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.WAKE_HOLD_MS
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** §O.1.5: every input of the core ends by asking for the wake, and a frame's for the lock. Neither may cost a call of the platform's each time. */
class WakePlanTest {
    private var now = 1_000_000L
    private val plan = WakePlan { now }

    /** What [WakePlan.hold] took the lock for, or null where it took none. */
    private fun held(ms: Long): Long? {
        var taken: Long? = null
        plan.hold(ms) { taken = it }
        return taken
    }

    @Test
    fun theAlarmIsArmedOnlyForAChangeThatMatters() {
        assertEquals(now + 90_000, plan.alarm(90_000), "the first wake armed no alarm")
        // The same wake, asked again at every sighting and every frame as the time to it runs down — and counted
        // from a reading of the clock a moment old, so a little to either side of what is armed.
        val armed = now + 90_000
        for (passed in listOf(0L, 40, 1_000, 30_000, 80_000)) {
            now = 1_000_000 + passed
            for (off in listOf(0L, -3, 3, -ALARM_SLACK_MS, ALARM_SLACK_MS)) {
                assertNull(plan.alarm(armed + off - now), "the alarm was armed again for the wake it is armed for ($passed ms on, $off off)")
            }
        }
        // A wake that is earlier by more than the slack moves it.
        now = 1_000_000
        assertEquals(now + 90_000 - ALARM_SLACK_MS - 1, plan.alarm(90_000 - ALARM_SLACK_MS - 1))
        assertEquals(now + 20_000, plan.alarm(20_000))
        // So does one that is later by more: an alarm left where it was would wake the phone for nothing, every time.
        assertEquals(now + 20_000 + ALARM_SLACK_MS + 1, plan.alarm(20_000 + ALARM_SLACK_MS + 1))
        assertEquals(now + 10 * MINUTE, plan.alarm(10 * MINUTE))
        // The one armed has passed — it is on its way, or was delivered: whatever is asked for next is armed.
        now += 10 * MINUTE
        assertEquals(now + 10 * MINUTE, plan.alarm(10 * MINUTE))
        now += 10 * MINUTE + 1
        assertEquals(now + 60_000, plan.alarm(60_000))
    }

    /**
     * The platform may deliver an inexact alarm three quarters of its wait late. Armed eleven hours ahead, the
     * reminder of a paused mesh could come an hour late: after the deadline it announces.
     */
    @Test
    fun theAlarmIsNeverArmedFurtherAheadThanItsCap() {
        // A paused mesh, just turned on: its one wake is the reminder's.
        val reminder = now + MESH_ON_MAX_MS - REMINDER_MS
        var alarms = 0
        while (now < reminder) {
            val at = plan.alarm(reminder - now)
            assertTrue(at != null && at - now <= ALARM_AHEAD_MAX_MS && at <= reminder, "armed ${at?.minus(now)} ms ahead")
            alarms++
            // Its arrival arms the next.
            now = at
        }
        assertEquals(reminder, now, "the chain of alarms did not end at the wake asked for")
        assertEquals((MESH_ON_MAX_MS - REMINDER_MS) / ALARM_AHEAD_MAX_MS, alarms.toLong())
        // Late by three quarters of the cap and a doze's quarter of an hour, the reminder is still ahead of the stop.
        assertTrue(ALARM_AHEAD_MAX_MS * 3 / 4 + 15 * MINUTE < REMINDER_MS)
        // And with the radio up no alarm is as far ahead as the scan's restart, the longest wake there is.
        assertTrue(ALARM_AHEAD_MAX_MS < SCAN_RESTART_MS)
    }

    @Test
    fun aHoldIsTakenOnlyWhenItOutlastsTheOneHeld() {
        assertEquals(2_000, held(2_000))
        // A frame after a frame: the same engine wake, a little nearer. On a lock that does not count the acquire
        // replaces the hold before it, so a shorter one would also let the phone sleep early.
        now += 40
        assertNull(held(1_960))
        assertNull(held(1_960 + HOLD_SLACK_MS), "a hold was taken for less than the slack")
        assertNull(held(500), "a shorter hold took the place of a longer one")
        // One that outlasts it is taken, for its whole length.
        assertEquals(1_960 + HOLD_SLACK_MS + 1, held(1_960 + HOLD_SLACK_MS + 1))
        assertEquals(HOLD_CAP_MS, held(HOLD_CAP_MS))
        // Once it has run out, the next is taken whatever its length.
        now += HOLD_CAP_MS
        assertEquals(HOLD_SLACK_MS + 1, held(HOLD_SLACK_MS + 1))
        // The radio's end releases the lock: a hold counted as still held would leave the next frame none.
        assertEquals(HOLD_CAP_MS, held(HOLD_CAP_MS))
        plan.released()
        assertEquals(300, held(300))
        // The slack is less than the margin a hold has over the engine's next work, or it would give that away;
        // and the hold at an alarm is within the cap of every hold.
        assertTrue(HOLD_SLACK_MS < HOLD_MARGIN_MS)
        assertTrue(WAKE_HOLD_MS in 1..HOLD_CAP_MS)
    }

    /**
     * The platform delivers no alarm in the next instant: such a wake is the thread's timer's. But that timer does
     * not count while the phone sleeps, so no wake leaves the phone with no alarm ahead at all.
     */
    @Test
    fun aWakeTooSoonForAnAlarmIsTheTimersAlone() {
        // With one armed ahead: nothing is asked of the platform, however often, and the one armed stays.
        assertEquals(now + 10 * MINUTE, plan.alarm(10 * MINUTE))
        for (soon in listOf(0L, 50, 300, ALARM_MIN_MS - 1)) {
            assertNull(plan.alarm(soon), "an alarm was armed for a wake $soon ms ahead")
            now += 7
        }
        assertNull(plan.alarm(10 * MINUTE - 28), "the alarm armed before did not stay")
        // At the least an alarm is armed for, it is.
        assertEquals(now + ALARM_MIN_MS, WakePlan { now }.alarm(ALARM_MIN_MS))
        // With none ahead — a start's first wake, or the one armed just came — one is armed as soon as it can be.
        val fresh = WakePlan { now }
        assertEquals(now + ALARM_MIN_MS, fresh.alarm(0))
        assertNull(fresh.alarm(50))
        now += ALARM_MIN_MS
        assertEquals(now + ALARM_MIN_MS, fresh.alarm(50), "a phone that sleeps now has no alarm to wake it")
        assertTrue(ALARM_MIN_MS < ALARM_AHEAD_MAX_MS)
    }
}
