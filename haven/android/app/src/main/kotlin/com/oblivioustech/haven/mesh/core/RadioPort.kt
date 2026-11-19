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

    /**
     * Calls `onWake` in [inMs] by the thread's timer, which serves a phone
     * that is awake, and in [asleepInMs] by the one alarm, which wakes one
     * that sleeps; replaces the wake before it. [asleepInMs] is never the
     * earlier: only what must come though nothing else wakes the phone is a
     * term of it.
     */
    fun wakeAt(inMs: Long, asleepInMs: Long)
}
