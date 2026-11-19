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

    /** The notices' words changed and the service took the reminder down: one still owed is given again, in the new words. */
    fun reworded() {
        reminded = false
    }

    /** Milliseconds until the reminder is due; null when it is due already — given by [at] or not — or past. */
    fun reminderIn(leftMs: Long): Long? = (leftMs - MeshRadioConstants.REMINDER_MS).takeIf { it > 0 }
}
