package com.oblivioustech.haven.mesh.core

/**
 * When the scan is started: again before Android takes a long scan down a
 * step, and never twice in the time Android counts starts over.
 */
class ScanPolicy {
    private var startedAt: Long? = null
    private var scanning = false

    /** Milliseconds from [now] until the scan is to be started; 0 is now. */
    fun dueIn(now: Long): Long {
        val started = startedAt ?: return 0
        val wait = if (scanning) MeshRadioConstants.SCAN_RESTART_MS else MeshRadioConstants.SCAN_MIN_GAP_MS
        return (started + wait - now).coerceAtLeast(0)
    }

    fun started(now: Long) {
        startedAt = now
        scanning = true
    }

    /** The radio went down, and the scan with it. */
    fun stopped() {
        scanning = false
    }
}
