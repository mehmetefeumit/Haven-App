package com.oblivioustech.haven.mesh.core

/**
 * What `MeshReceiver` does with a broadcast (`docs/BLUETOOTH_MESH_M3_DESIGN.md`
 * §B.5, §O.1.5, §O.1.8). [wanted] and [deadlineMs] are the service's stored
 * flag and copy.
 */
object ReceiverPolicy {
    /**
     * Boot, or Haven replaced: whether the service is started. [refusal] is
     * `StartPolicy.refusal`, asked last and only for a mesh that is owed: it
     * puts the log lever in, and a process nobody turned the mesh on in keeps
     * its log.
     */
    fun startsAtBoot(wanted: Boolean, deadlineMs: Long, wallClockMs: Long, refusal: () -> MeshStart?): Boolean =
        wanted && deadlineMs > wallClockMs && refusal() == null

    /**
     * The alarm found no live start — the process died under the mesh.
     * Whether the mesh ends here, flag and copy cleared and the stopped
     * notice posted: its time is up and nothing else will say so. Never a
     * start: an alarm is no licence for a foreground service.
     */
    fun endsAtAlarm(wanted: Boolean, deadlineMs: Long, wallClockMs: Long): Boolean = wanted && deadlineMs <= wallClockMs
}
