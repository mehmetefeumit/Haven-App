package com.oblivioustech.haven.mesh

import com.oblivioustech.haven.mesh.core.LogLever
import com.oblivioustech.haven.mesh.core.MeshEngineApi

/**
 * The eleven native methods pinned in
 * `haven/rust_builder/fixtures/mesh_radio_exports.txt`. JNI finds each by this
 * class's name and the method's own when it is first called, never when
 * either side is compiled: `scripts/ci/check_mesh_radio.sh` holds both to
 * that list.
 */
object MeshNative : MeshEngineApi, LogLever {
    init {
        // JNI looks a native method up in the libraries this class's loader
        // loaded. The bridge opens the same file from Dart, which is not that.
        System.loadLibrary("rust_lib_haven")
    }

    external override fun resume(leftMs: Long): Boolean

    external override fun leftMs(): Long

    external override fun sighting(peer: Long, rssi: Int)

    external override fun linkUp(link: Long, central: Boolean, attMtu: Int, peer: Long)

    external override fun linkDown(link: Long)

    external override fun connectFailed(peer: Long)

    external override fun receive(link: Long, frame: ByteArray)

    external override fun poll(ready: LongArray): ByteArray?

    external override fun wakeInMs(): Long

    external override fun leverInstall(): Boolean

    external override fun leverHolds(): Boolean
}
