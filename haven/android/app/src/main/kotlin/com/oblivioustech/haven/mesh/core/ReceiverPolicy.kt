package com.oblivioustech.haven.mesh.core

enum class ReceiverStep { START, END, NONE }

/**
 * What `MeshReceiver` does with a broadcast (`docs/BLUETOOTH_MESH_M3_DESIGN.md`
 * §B.5, §O.1.5, §O.1.8).
 */
object ReceiverPolicy {
    /**
     * [boot]: the phone booted or Haven was replaced; else the service's
     * alarm, which [taken] hands to the live start, answering whether there
     * is one. [wanted] and [deadlineMs] are the service's stored flag and
     * copy.
     *
     * A mesh whose time is up is ended, at a boot as at an alarm that found
     * no service: flag and copy cleared and the stopped notice posted —
     * nothing else will say so, and a flag left set would bring the mesh
     * back, without the user, should the clock ever be set behind the
     * deadline. Only a boot starts the service: an alarm is no licence for
     * a foreground service. And [refusal], `StartPolicy.refusal`, is asked
     * last and only for a mesh that is owed: it puts the log lever in, and
     * a process nobody turned the mesh on in keeps its log.
     */
    fun step(
        boot: Boolean,
        taken: () -> Boolean,
        wanted: Boolean,
        deadlineMs: Long,
        wallClockMs: Long,
        refusal: () -> MeshStart?,
    ): ReceiverStep = when {
        !boot && taken() -> ReceiverStep.NONE
        ended(wanted, deadlineMs, wallClockMs) -> ReceiverStep.END
        wanted && boot && refusal() == null -> ReceiverStep.START
        else -> ReceiverStep.NONE
    }

    /**
     * Whether what is stored is a mesh whose time is up. Asked again by
     * whoever acts on [ReceiverStep.END], under the lock a start command
     * takes and with the flag and the copy read afresh there: a start made
     * since the broadcast was read has stored its own.
     */
    fun ended(wanted: Boolean, deadlineMs: Long, wallClockMs: Long): Boolean = wanted && deadlineMs <= wallClockMs
}
