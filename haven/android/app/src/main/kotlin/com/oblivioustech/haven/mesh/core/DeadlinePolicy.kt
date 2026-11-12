package com.oblivioustech.haven.mesh.core

enum class DeadlineStep { NOTHING, REMINDER, STOP }

/** What the time the engine has left asks of the service: the reminder, once, and the stop. */
class DeadlinePolicy {
    private var reminded = false

    fun at(leftMs: Long): DeadlineStep = when {
        leftMs <= 0 -> DeadlineStep.STOP
        // Kept on: the reminder is owed again.
        leftMs > MeshRadioConstants.REMINDER_MS -> DeadlineStep.NOTHING.also { reminded = false }
        reminded -> DeadlineStep.NOTHING
        else -> DeadlineStep.REMINDER.also { reminded = true }
    }

    /** Milliseconds until the reminder is due; null once [at] has given it. */
    fun reminderIn(leftMs: Long): Long? = (leftMs - MeshRadioConstants.REMINDER_MS).takeIf { it > 0 }
}
