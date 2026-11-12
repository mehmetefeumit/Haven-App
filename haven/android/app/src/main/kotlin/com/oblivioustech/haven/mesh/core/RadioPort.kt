package com.oblivioustech.haven.mesh.core

/**
 * Every platform effect [MeshRadioCore] has, implemented by the adapters. Each
 * is called on the mesh thread and may throw: [MeshThread] is what catches it.
 */
interface RadioPort {
    /** Dials [address]; answered by one `onLinkUp(central = true)` or one `onConnectFailed`, with that address. */
    fun connect(address: String)

    fun close(link: Long)

    /**
     * Hands [frame] to the platform as one write or notification. `true`: it
     * was taken, and `onSendDone` follows. `false`: it was not, and nothing
     * follows.
     */
    fun send(link: Long, frame: ByteArray): Boolean

    /** Starts the filtered scan, ending the one that runs. */
    fun scan()

    /** Posts the reminder notice. */
    fun remind()

    /** Holds a wake lock for [ms], replacing the hold before it. */
    fun holdAwake(ms: Long)

    /** Calls `onWake` in [inMs], by the thread's timer and by the one alarm; replaces the wake before it. */
    fun wakeAt(inMs: Long)
}
