package com.oblivioustech.haven.mesh.core

/** What starting the radio did: `MeshRadioStart` of `haven/lib/src/services/mesh_radio.dart`, each by its word there. */
enum class MeshStart(val word: String) {
    STARTED("started"),
    NO_PERMISSION("noPermission"),
    UNSUPPORTED("unsupported"),
    FAILED("failed"),
}

/**
 * The two channels as the Dart side has them (`mesh_radio.dart`;
 * `docs/BLUETOOTH_MESH_M3_DESIGN.md` §N.2.8): every name the handler reads
 * and every word it answers, so that it holds none of its own.
 */
object ChannelWords {
    const val METHOD_CHANNEL = "haven.app/mesh_radio"
    const val STATE_CHANNEL = "haven.app/mesh_radio_state"

    const val PERMISSION = "permission"
    const val REQUEST_PERMISSION = "requestPermission"
    const val BLUETOOTH_ON = "bluetoothOn"
    const val BLUETOOTH_NAME = "bluetoothName"
    const val OPEN_BLUETOOTH_SETTINGS = "openBluetoothSettings"
    const val START = "start"
    const val SYNC = "sync"
    const val STOP = "stop"
    const val STATUS = "status"
    const val SUPPORTED = "supported"
    const val TAKE_ACTION = "takeAction"

    val METHODS = listOf(
        PERMISSION, REQUEST_PERMISSION, BLUETOOTH_ON, BLUETOOTH_NAME, OPEN_BLUETOOTH_SETTINGS,
        START, SYNC, STOP, STATUS, SUPPORTED, TAKE_ACTION,
    )

    /**
     * The methods that make a Bluetooth object. The platform logs from the
     * first one made, so each is answered only behind [StartPolicy.refusal];
     * no other method, and nothing the channel does when it is made, may
     * touch Bluetooth.
     */
    val BEHIND_THE_LEVER = setOf(BLUETOOTH_ON, BLUETOOTH_NAME, START)

    /** The keys of the six strings a `start` and a `sync` carry. */
    val COPY = listOf("channel", "on", "paused", "reminder", "keepOn", "stopped")

    /** A tap on a notice, as the state channel carries it. */
    const val OPEN_STATS = "openStats"
    const val KEEP_ON = "keepOn"

    /**
     * The activity alias a notice's tap is sent through, and the extra that
     * says which tap: [OPEN_STATS] or [KEEP_ON]. Declared not exported, with
     * the service, so that only a notice of Haven's own reaches the activity
     * under its name; until it is declared no intent does, and no tap is
     * read.
     */
    const val TAP_ALIAS = "com.oblivioustech.haven.mesh.MeshTap"
    const val TAP_EXTRA = "com.oblivioustech.haven.mesh.TAP"

    /** The code of every failure. The platform's own text never crosses: it can name a device. */
    const val ERROR = "failed"

    /** The six strings of a `start` or a `sync`, in [COPY]'s order; null for arguments of any other shape. */
    fun copy(arguments: Any?): List<String>? {
        val strings = arguments as? Map<*, *> ?: return null
        if (strings.size != COPY.size) return null
        return COPY.map { strings[it] as? String ?: return null }
    }

    /**
     * Whether the system's dialog has been answered in this process, after a
     * request came back with [results] answers. With none the platform
     * cancelled the request — another dialog was open, or the activity went
     * — and nobody was asked: read as answered, that would be "refused for
     * good".
     */
    fun answered(before: Boolean, results: Int): Boolean = before || results > 0

    /**
     * The answer to `permission` and `requestPermission`. [asked]: the system
     * dialog has been answered before, now included ([answered]).
     * [rationale]: the platform says the user refused and may be asked again.
     * Never asked, the platform says nothing, and the dialog can still be
     * shown.
     */
    fun permission(granted: Boolean, asked: Boolean, rationale: Boolean): String = when {
        granted -> "granted"
        !asked || rationale -> "denied"
        else -> "deniedForGood"
    }

    /**
     * A tap read from the intent an activity was handed: whether it is Keep
     * on, or null — no tap. Only [viaAlias]: `MainActivity` is exported, and
     * the same extra sent to it under its own name, by any app, would
     * restart the twelve hours for ever. Off the alias [extra] is not read
     * at all: a stranger's extras need not unpack. And not [replayed]: an
     * activity the system makes again is handed the intent that first made
     * it, and a tap is the user's once.
     */
    fun tapOf(viaAlias: Boolean, replayed: Boolean, extra: () -> String?): Boolean? {
        if (!viaAlias || replayed) return null
        return when (extra()) {
            KEEP_ON -> true
            OPEN_STATS -> false
            else -> null
        }
    }

    /**
     * The answer to `status`, and the message of every change. [serving]: the
     * service runs; [radioUp]: with Bluetooth on. [wanted] is the service's
     * own flag. No address and no count.
     */
    fun status(serving: Boolean, radioUp: Boolean, wanted: Boolean, canSearch: Boolean): Map<String, Any> = mapOf(
        "state" to when {
            !serving -> "stopped"
            radioUp -> "running"
            else -> "paused"
        },
        "wanted" to wanted,
        "canSearch" to canSearch,
    )
}

/**
 * The taps on a notice, for one Flutter engine. The Dart side drops a message
 * nobody listens for, and a tap can be what started it: every tap is held
 * until that engine has asked `takeAction`, and sent as it comes from then on.
 */
class HeldTaps {
    private var asked = false
    private var held: String? = null

    /** A tap. The word to send on the state channel now, or null: it is held. */
    fun tap(keepOn: Boolean): String? {
        val word = if (keepOn) ChannelWords.KEEP_ON else ChannelWords.OPEN_STATS
        if (asked) return word
        // Keep on opens the statistics too, so it stands for both.
        if (held != ChannelWords.KEEP_ON) held = word
        return null
    }

    /** `takeAction`: what is held, once. */
    fun take(): String? {
        asked = true
        return held.also { held = null }
    }
}
