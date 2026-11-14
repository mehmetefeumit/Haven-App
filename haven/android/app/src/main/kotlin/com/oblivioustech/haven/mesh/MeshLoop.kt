package com.oblivioustech.haven.mesh

import android.os.Handler
import android.os.HandlerThread
import android.os.Message
import android.os.SystemClock
import com.oblivioustech.haven.mesh.core.MeshThread

/**
 * The mesh's one thread, for one start of the service
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.1, §N.2.2). The platform calls back
 * on binder threads and on the main one; each callback posts its body here,
 * and the core, the two GATT roles' steps and every native call run here and
 * nowhere else. No adapter makes a `Handler`.
 *
 * Every body runs inside [mesh]: a start's own [MeshThread]. A callback that
 * outlives its start posts to one that has stopped, and is dropped.
 */
class MeshLoop(private val mesh: MeshThread) {
    private val thread = HandlerThread(NAME).apply { start() }

    /**
     * Whatever is handed to it runs inside [MeshThread.run] — and a dial
     * hands it to the platform, for its client's callbacks. Given a handler
     * the platform no longer catches what one of its own runnables throws,
     * and here that would end the thread and the process with it. And before
     * Android 13 such a runnable is also what puts a notification's value
     * into the characteristic a frame is about to be written from: on this
     * thread the two cannot cross.
     */
    val handler: Handler = object : Handler(thread.looper) {
        override fun dispatchMessage(message: Message) = mesh.run { super.dispatchMessage(message) }
    }

    /**
     * The service's start, and no other body: the first on the thread, and
     * the one not asked the lever. A body posted before it would find no
     * lever in a fresh process and stop the thread, and the start behind it
     * would never reach the foreground.
     */
    fun start(body: () -> Unit) {
        Handler(thread.looper).post { mesh.start(body) }
    }

    /** What every adapter posts a callback's body with. */
    fun post(body: () -> Unit) {
        handler.post(body)
    }

    /**
     * [body] in [inMs], in place of what [slot] still waited for; 0 is "post
     * now". The wait does not count while the phone sleeps: what must not
     * come late is a term of the service's alarm.
     */
    fun timer(slot: Any, inMs: Long, body: () -> Unit) {
        handler.removeCallbacksAndMessages(slot)
        handler.postAtTime(body, slot, SystemClock.uptimeMillis() + inMs)
    }

    /** The last step of a stop. What is queued, and what a late callback posts, is dropped. */
    fun quit() {
        thread.quit()
    }

    private companion object {
        const val NAME = "HavenMesh"
    }
}
