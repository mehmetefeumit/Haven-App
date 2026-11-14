package com.oblivioustech.haven.mesh.core

/**
 * A radio's end, at Bluetooth off as in a stop (`docs/BLUETOOTH_MESH_M3_DESIGN.md`
 * §N.7, §O.1.3): with Bluetooth off the platform throws from the very calls
 * that close what it left open.
 */
object RadioEnd {
    /** Each of [closes], whatever one before it threw. Nothing is thrown on, kept or rendered: a pause is not a stop. */
    fun each(vararg closes: () -> Unit) {
        for (close in closes) {
            try {
                close()
            } catch (_: Throwable) {
            }
        }
    }
}
