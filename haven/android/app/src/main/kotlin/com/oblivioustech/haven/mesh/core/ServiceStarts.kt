package com.oblivioustech.haven.mesh.core

/**
 * The service's one reference to its live start, and which start command a
 * stop ends the service by (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §O.1.2,
 * §O.1.8).
 *
 * A service ended while a start command still owes its foreground start
 * takes the process down, and the process is the relay path's. A command
 * arrives on the main thread while a stop runs on the mesh thread, so each
 * member is one step under one lock.
 */
class ServiceStarts<Live : Any> {
    private var live: Live? = null
    private var last = 0

    /** The live start, for an alarm or a call of the channel's; null where there is none. */
    @Synchronized
    fun live(): Live? = live

    /**
     * A start command, [id] its number. With a live start it joins that one
     * and nothing more is done: a service in the foreground owes a second
     * command nothing. With none, [fresh] makes the live start.
     */
    @Synchronized
    fun command(id: Int, fresh: () -> Live) {
        last = id
        if (live == null) live = fresh()
    }

    /**
     * A stop's first step. The start is let go of — a command from here on
     * makes its own — and the answer is the last command that joined it,
     * the one to end the service by: ended by an older one, the platform
     * leaves the service to the command that came since.
     */
    @Synchronized
    fun detach(): Int {
        live = null
        return last
    }

    /**
     * [leave] — out of the foreground, a notice down or the stopped one up —
     * unless a start made since [detach] is live: the foreground and the
     * notices are that one's now. Under the lock, so none is made in the
     * middle of it.
     */
    @Synchronized
    fun idle(leave: () -> Unit) {
        if (live == null) leave()
    }
}
