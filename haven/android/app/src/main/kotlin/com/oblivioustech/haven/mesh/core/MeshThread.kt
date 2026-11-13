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
 * And nothing runs in it while the log lever does not hold: every body is a
 * platform callback or ends in a platform call, and the platform logs in
 * each. This is the one place the lever is asked once the radio runs, so what
 * holds every body to it is what holds every body inside [run].
 *
 * [steps] are what any stop does — the radio down, the on flag and the
 * deadline copy cleared, the notification removed, the service ended —
 * [notice] the stopped notice, which only the user's own stop leaves out.
 * [running] is false once the engine is gone.
 */
class MeshThread(
    private val lever: LogLever,
    private val running: () -> Boolean,
    private val steps: List<() -> Unit>,
    private val notice: () -> Unit,
) {
    /** A stop is final: a start after it is a new thread's. */
    var stopped = false
        private set

    /**
     * Every body but the start's, the user's stop among them. With a lever
     * that does not hold the body is not run: the lever is put back — the
     * stop's own steps close what the platform logs of, and its callbacks
     * outlive the stop — and the radio stops.
     */
    fun run(body: () -> Unit) = guarded {
        if (lever.leverHolds()) {
            body()
            running()
        } else {
            lever.leverInstall()
            false
        }
    }

    /**
     * The service's start, and no other body. It must reach its foreground
     * start whatever the lever does, and it is what puts the lever in and
     * asks it ([StartPolicy.start]) before the radio's first object.
     */
    fun start(body: () -> Unit) = guarded {
        body()
        running()
    }

    private fun guarded(goesOn: () -> Boolean) {
        if (stopped) return
        val on = try {
            goesOn()
        } catch (_: Throwable) {
            false
        }
        if (!on) stop(notice = true)
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

    companion object {
        /**
         * A stop's steps, in their order. [stopRadio] is
         * [MeshRadioCore.stopRadio], a step of its own before the adapters
         * are closed: a close that throws must not leave the engine links
         * nobody tells it are down. It asks for the deadline's wake, so an
         * alarm cancelled before it would be armed again behind it.
         */
        fun steps(
            stopRadio: () -> Unit,
            closeAdapters: () -> Unit,
            cancelAlarm: () -> Unit,
            forget: () -> Unit,
            unpost: () -> Unit,
            end: () -> Unit,
        ): List<() -> Unit> = listOf(stopRadio, closeAdapters, cancelAlarm, forget, unpost, end)
    }
}
