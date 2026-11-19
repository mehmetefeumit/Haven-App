package com.oblivioustech.haven.mesh.core

/** What a start of the service comes to. */
sealed interface Start {
    /** A stop the service makes, from the foreground, answered with [word]; with the stopped notice unless a logout is behind it. */
    class Refused(val word: MeshStart, val notice: Boolean) : Start

    /** The radio runs; [deadlineMs] is the wall-clock deadline to keep as the service's copy. */
    class Run(val deadlineMs: Long) : Start
}

/**
 * Whether the radio may start, and a start of the service, whatever caused
 * it: the channel, a sticky restart, boot (`docs/BLUETOOTH_MESH_M3_DESIGN.md`
 * §M.3, §N.1.5).
 */
object StartPolicy {
    /** Android 11: below it a process cannot keep the platform's Bluetooth lines out of its log. */
    private const val ANDROID_11 = 30

    /** Whether this phone can ever run the mesh. Reads no Bluetooth object and no lever. */
    fun supported(api: Int, bluetoothLe: Boolean): Boolean = api >= ANDROID_11 && bluetoothLe

    /**
     * Why the radio may not start, or null. Asked before any Bluetooth object
     * is made, and by whoever would start the service before it does: a
     * service started and ended with no foreground start takes the process
     * down, and the process is the relay path's.
     *
     * The lever is not touched where it cannot exist. A lever that is missing
     * is as fixed as the phone; one that is in and does not hold is not.
     */
    fun refusal(api: Int, bluetoothLe: Boolean, lever: LogLever, permission: Boolean): MeshStart? = when {
        !supported(api, bluetoothLe) || !lever.leverInstall() -> MeshStart.UNSUPPORTED
        !lever.leverHolds() -> MeshStart.FAILED
        !permission -> MeshStart.NO_PERMISSION
        else -> null
    }

    /**
     * The service's own start. [foreground] comes before anything can refuse:
     * between the caller's [refusal] and here the lever can stop holding or a
     * permission go, and a refusal is then a stop from the foreground.
     *
     * And before anything is read. Every input but the level is a function,
     * none called until [foreground] has returned: a service ended while it
     * still owes its foreground start takes the process down, so a stored
     * copy that does not read, or a native library that does not load — the
     * first naming of the class [lever] and [engine] answer loads it — must
     * throw behind it, where it is a stop like any other.
     *
     * [permission] is the service's own reading of the Bluetooth runtime
     * permissions: the platform cannot be trusted to refuse a
     * `connectedDevice` start without them. [wipePending] is the logout's
     * marker: a process that died between the marker and the radio's stop
     * must not come back with a keyless engine. [storedDeadlineMs] is the copy
     * an earlier start kept, 0 when there is none.
     */
    fun start(
        api: Int,
        foreground: () -> Unit,
        bluetoothLe: () -> Boolean,
        lever: () -> LogLever,
        wipePending: () -> Boolean,
        permission: () -> Boolean,
        engine: () -> MeshEngineApi,
        storedDeadlineMs: () -> Long,
        wallClockMs: () -> Long,
    ): Start {
        foreground()
        // The user who logged out is told nothing, whatever refuses.
        val behindLogout = wipePending()
        refusal(api, bluetoothLe(), lever(), permission())?.let { return Start.Refused(it, notice = !behindLogout) }
        if (behindLogout) return Start.Refused(MeshStart.FAILED, notice = false)
        // No engine in this process — after boot, or a restart — and the copy
        // is ahead: a keyless engine until then, twelve hours at most. The
        // first session entry overrules it.
        val radio = engine()
        val now = wallClockMs()
        val ahead = storedDeadlineMs() - now
        if (radio.leftMs() == 0L && ahead > 0) {
            radio.resume(minOf(ahead, MeshRadioConstants.MESH_ON_MAX_MS))
        }
        val left = radio.leftMs()
        return if (left == 0L) Start.Refused(MeshStart.FAILED, notice = true) else Start.Run(now + left)
    }
}
