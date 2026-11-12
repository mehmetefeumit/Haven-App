package com.oblivioustech.haven.mesh.core

/**
 * What every message and callback of the mesh thread runs inside, and the one
 * stop of the service (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.1, §B.5).
 *
 * The service shares its process with the path that publishes to relays, and
 * Android's Bluetooth calls throw when the adapter changes under them. So
 * nothing thrown leaves [run]: it becomes a stop the user did not make.
 * Nothing caught is rendered or kept.
 *
 * [steps] are what any stop does — the radio down, the on flag and the
 * deadline copy cleared, the notification removed, the service ended —
 * [notice] the stopped notice, which only the user's own stop leaves out.
 * [running] is false once the engine is gone.
 */
class MeshThread(
    private val running: () -> Boolean,
    private val steps: List<() -> Unit>,
    private val notice: () -> Unit,
) {
    /** A stop is final: a start after it is a new thread's. */
    var stopped = false
        private set

    fun run(body: () -> Unit) {
        if (stopped) return
        val goesOn = try {
            body()
            running()
        } catch (_: Throwable) {
            false
        }
        if (!goesOn) stop(notice = true)
    }

    fun stop(notice: Boolean) {
        if (stopped) return
        stopped = true
        for (step in if (notice) steps + this.notice else steps) {
            // What made the stop may throw in each step of it too, and the
            // steps after still run: mesh is never left on with no notice.
            try {
                step()
            } catch (_: Throwable) {
            }
        }
    }
}
