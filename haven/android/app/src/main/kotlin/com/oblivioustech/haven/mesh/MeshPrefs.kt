package com.oblivioustech.haven.mesh

import android.content.Context
import com.oblivioustech.haven.mesh.core.ChannelWords

/**
 * What the service keeps to come back by itself after the process died or
 * the phone restarted (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.5, §B.7,
 * §O.1.7): whether the mesh is wanted, the wall-clock deadline it runs to,
 * and the six strings of its notices, which a notice posted with no Dart
 * isolate has no other source of.
 *
 * Nothing here can identify anyone: a flag, a time, and fixed copy the Dart
 * side localized. One file, private to the app, in the storage that opens
 * with the phone's first unlock.
 *
 * Written with `commit()`: a stop the service made is at rest before the
 * process can die. The mesh thread may block; the channel's two writes are
 * the main thread's.
 */
class MeshPrefs(context: Context) {
    private val file = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** A start ran and nothing has stopped it since. */
    val wanted: Boolean get() = file.getBoolean(WANTED, false)

    /** The wall-clock time the mesh runs to, milliseconds; 0 when there is none. */
    val deadlineMs: Long get() = file.getLong(DEADLINE, 0)

    /** One of the six strings, by its key of [ChannelWords.COPY]; null where none was ever stored. */
    fun copy(key: String): String? = file.getString(key, null)

    /** The six strings of a `start` or a `sync`, in [ChannelWords.COPY]'s order. */
    fun words(copy: List<String>) {
        val edit = file.edit()
        ChannelWords.COPY.forEachIndexed { at, key -> edit.putString(key, copy[at]) }
        edit.commit()
    }

    /** The mesh runs until [deadlineMs]. */
    fun run(deadlineMs: Long) {
        file.edit().putBoolean(WANTED, true).putLong(DEADLINE, deadlineMs).commit()
    }

    /** Any stop: nothing brings the radio back by itself. The words stay, for the stopped notice. */
    fun forget() {
        file.edit().putBoolean(WANTED, false).putLong(DEADLINE, 0).commit()
    }

    private companion object {
        const val FILE = "haven_mesh"
        const val WANTED = "wanted"
        const val DEADLINE = "deadline"
    }
}
