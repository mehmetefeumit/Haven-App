package com.oblivioustech.haven.mesh.core

/**
 * The log lever: the two native methods, of the eleven pinned in
 * `haven/rust_builder/fixtures/mesh_radio_exports.txt`, that are not the
 * engine's. `MeshNative` is the one real implementation.
 *
 * Android's Bluetooth classes log from this process the address of whatever
 * connects. With the lever in, a release build writes no log line at all and
 * a debug build only Haven's own. No Bluetooth object is to be made without
 * it: [StartPolicy] asks before the first, [MeshRadioCore] at every input.
 */
interface LogLever {
    /** Puts the lever in, or back; false where this Android has none (below API 30). */
    fun leverInstall(): Boolean

    /** Whether the lever is in force now. */
    fun leverHolds(): Boolean
}
