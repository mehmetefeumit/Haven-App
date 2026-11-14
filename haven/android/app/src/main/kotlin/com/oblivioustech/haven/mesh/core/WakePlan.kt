package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.ALARM_AHEAD_MAX_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.ALARM_MIN_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.ALARM_SLACK_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.HOLD_SLACK_MS
import kotlin.math.abs

/**
 * When the service asks the platform for its alarm and its wake lock
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §O.1.5). Every input of the core ends
 * by asking for the wake, and a frame's for the lock: asked of the platform
 * at each, the two would cost more than the radio.
 *
 * [clock] is the alarm's own: milliseconds that keep counting while the
 * phone sleeps.
 */
class WakePlan(private val clock: () -> Long) {
    private var armedAt = 0L
    private var heldUntil = 0L

    /**
     * `RadioPort.wakeAt`: the time on [clock] to arm the alarm for, or null
     * where the one armed serves. On the mesh thread alone.
     *
     * An alarm is always armed ahead once this has answered: the thread's
     * timer does not count while the phone sleeps, and a phone with no alarm
     * would sleep through its deadline.
     */
    fun alarm(inMs: Long): Long? {
        val now = clock()
        val at = now + inMs.coerceIn(ALARM_MIN_MS, ALARM_AHEAD_MAX_MS)
        // Armed ahead, and the wake is the timer's alone or no change that
        // matters. Either way of the one armed: what is asked for is counted
        // from a reading of the clock a moment old, so the same wake comes
        // out a little earlier or later each time.
        if (armedAt > now && (inMs < ALARM_MIN_MS || abs(at - armedAt) <= ALARM_SLACK_MS)) return null
        armedAt = at
        return at
    }

    /**
     * `RadioPort.holdAwake`, and the hold at an alarm: [take] is the lock's
     * timed acquire. On a lock that does not count it replaces the hold
     * before it, a longer one too — so only for a hold that outlasts it.
     *
     * On the mesh thread and, at an alarm, on the main one: one at a time,
     * [take] included.
     */
    @Synchronized
    fun hold(ms: Long, take: (Long) -> Unit) {
        val until = clock() + ms
        if (until - heldUntil <= HOLD_SLACK_MS) return
        heldUntil = until
        take(ms)
    }

    /** The lock was released, at a radio's end: the next hold is taken. */
    @Synchronized
    fun released() {
        heldUntil = 0
    }
}
