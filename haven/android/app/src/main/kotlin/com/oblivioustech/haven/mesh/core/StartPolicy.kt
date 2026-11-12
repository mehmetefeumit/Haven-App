package com.oblivioustech.haven.mesh.core

/** A start of the service, whatever caused it: the channel, a sticky restart, boot. */
object StartPolicy {
    /**
     * The wall-clock deadline to keep as the service's copy, or null: a stop
     * the service makes.
     *
     * [permission] is the service's own reading of the Bluetooth runtime
     * permissions, taken before [foreground]: the platform cannot be trusted
     * to refuse a `connectedDevice` start without them. The engine is touched
     * only once the service is in the foreground. [storedDeadlineMs] is the
     * copy an earlier start kept, 0 when there is none.
     */
    fun start(
        permission: Boolean,
        engine: MeshEngineApi,
        storedDeadlineMs: Long,
        wallClockMs: Long,
        foreground: () -> Unit,
    ): Long? {
        if (!permission) return null
        foreground()
        // No engine in this process — after boot, or a restart — and the copy
        // is ahead: a keyless engine until then, twelve hours at most. The
        // first session entry overrules it.
        val ahead = storedDeadlineMs - wallClockMs
        if (engine.leftMs() == 0L && ahead > 0) {
            engine.resume(minOf(ahead, MeshRadioConstants.MESH_ON_MAX_MS))
        }
        val left = engine.leftMs()
        return if (left == 0L) null else wallClockMs + left
    }
}
