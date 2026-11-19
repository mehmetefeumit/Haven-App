package com.oblivioustech.haven.mesh.core

/**
 * The mesh's four notices (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.5, §O.1.6):
 * under which of the two ids each is posted, which of the six strings is its
 * text — by its key of [ChannelWords.COPY] — and whether it carries the Keep
 * on action.
 *
 * The stopped notice takes the reminder's id: no Keep on outlives the stop.
 */
enum class Notice(val id: Int, val copy: String, val keepOn: Boolean = false) {
    ON(NoticePlan.ONGOING, "on"),
    PAUSED(NoticePlan.ONGOING, "paused"),
    REMINDER(NoticePlan.ALERT, "reminder", keepOn = true),
    STOPPED(NoticePlan.ALERT, "stopped"),
}

object NoticePlan {
    /** The notice the service is in the foreground under. */
    const val ONGOING = 4832

    /** The reminder, and then the stopped notice. */
    const val ALERT = 4833

    /** The keys of the channel's name and of the action's label. */
    const val CHANNEL = "channel"
    const val KEEP_ON = "keepOn"

    /** The ongoing notice: paused while Bluetooth is off. */
    fun ongoing(radioUp: Boolean): Notice = if (radioUp) Notice.ON else Notice.PAUSED
}
