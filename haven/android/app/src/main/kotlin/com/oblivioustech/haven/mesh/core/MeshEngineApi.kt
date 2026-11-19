package com.oblivioustech.haven.mesh.core

/**
 * The mesh engine as the radio drives it: nine of the eleven native methods
 * pinned in `haven/rust_builder/fixtures/mesh_radio_exports.txt`, each with
 * the types its JNI descriptor names; [LogLever] is the other two.
 * `MeshNative` is the one real implementation.
 *
 * A link's and a peer's number are this side's own counters, never negative
 * and never an address.
 */
interface MeshEngineApi {
    /** Starts an engine with no session for [leftMs]; answers whether one runs. */
    fun resume(leftMs: Long): Boolean

    /** How long the engine still runs; 0 when none does. */
    fun leftMs(): Long

    fun sighting(peer: Long, rssi: Int)

    /** A [peer] below zero is no peer. */
    fun linkUp(link: Long, central: Boolean, attMtu: Int, peer: Long)

    fun linkDown(link: Long)

    fun connectFailed(peer: Long)

    fun receive(link: Long, frame: ByteArray)

    /** The next [RadioOutput], encoded; null when there is none. */
    fun poll(ready: LongArray): ByteArray?

    /** Milliseconds until the engine next has work; -1 when none runs. */
    fun wakeInMs(): Long
}
