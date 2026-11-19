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

    /** What the lock is held to, and how much of that a hold of the core's asked for. */
    private var heldUntil = 0L
    private var owedUntil = 0L

    /** The alarms whose bodies have not run yet. */
    private var waking = 0

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
     * `RadioPort.holdAwake`: [take] is the lock's timed acquire. On a lock
     * that does not count it replaces the hold before it, a longer one too —
     * so only for a hold that outlasts it.
     *
     * This and the three below are one at a time, [take] and the release
     * included: an alarm's hold is the main thread's, the rest the mesh
     * thread's.
     */
    @Synchronized
    fun hold(ms: Long, take: (Long) -> Unit) {
        val until = clock() + ms
        if (until > owedUntil) owedUntil = until
        held(until, ms, take)
    }

    /**
     * An alarm came. The platform keeps the phone awake for a broadcast only
     * until its receiver returns: the lock is what holds it until the bodies
     * the alarm posts have run, [ms] at most.
     */
    @Synchronized
    fun wakeHold(ms: Long, take: (Long) -> Unit) {
        waking++
        held(clock() + ms, ms, take)
    }

    /**
     * The bodies an alarm posted have run: the phone was held for as long as
     * they took, not for a time. Once no alarm's bodies wait, the lock goes
     * back to what a frame's hold still owes, or is released.
     */
    @Synchronized
    fun wakeDone(take: (Long) -> Unit, release: () -> Unit) {
        waking--
        val now = clock()
        if (waking > 0 || heldUntil - maxOf(owedUntil, now) <= HOLD_SLACK_MS) return
        if (owedUntil > now) take(owedUntil - now) else release()
        heldUntil = maxOf(owedUntil, now)
    }

    /**
     * A radio's end: the lock is released and what was held forgotten in one
     * step, so that a hold taken on the other thread comes wholly before it
     * or wholly behind, never counted as held on a lock that is not. An
     * alarm's bodies still to come are still counted: they run, and end.
     */
    @Synchronized
    fun release(release: () -> Unit) {
        release()
        heldUntil = 0
        owedUntil = 0
    }

    private fun held(until: Long, ms: Long, take: (Long) -> Unit) {
        if (until - heldUntil <= HOLD_SLACK_MS) return
        heldUntil = until
        take(ms)
    }
}
