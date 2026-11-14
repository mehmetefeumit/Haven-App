package com.oblivioustech.haven.mesh.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The words are the Dart side's (`haven/lib/src/services/mesh_radio.dart`), letter for letter: it reads no other. */
class ChannelWordsTest {
    private val copy = mapOf(
        "channel" to "Mesh", "on" to "On", "paused" to "Paused", "reminder" to "Off at 9", "keepOn" to "Keep on", "stopped" to "Off",
    )

    @Test
    fun theChannelsWordsAreTheseAndTheStatusIsOneFunction() {
        assertEquals("haven.app/mesh_radio", ChannelWords.METHOD_CHANNEL)
        assertEquals("haven.app/mesh_radio_state", ChannelWords.STATE_CHANNEL)
        assertEquals(
            listOf(
                "permission", "requestPermission", "bluetoothOn", "bluetoothName", "openBluetoothSettings",
                "start", "sync", "stop", "status", "supported", "takeAction",
            ),
            ChannelWords.METHODS,
        )
        assertEquals(listOf("started", "noPermission", "unsupported", "failed"), MeshStart.entries.map { it.word })
        assertEquals(listOf("openStats", "keepOn"), listOf(ChannelWords.OPEN_STATS, ChannelWords.KEEP_ON))
        assertEquals("failed", ChannelWords.ERROR)

        // The permission: granted; refused and the dialog can still be shown; refused for good.
        assertEquals("granted", ChannelWords.permission(granted = true, asked = false, rationale = false))
        assertEquals("granted", ChannelWords.permission(granted = true, asked = true, rationale = false))
        assertEquals("denied", ChannelWords.permission(granted = false, asked = false, rationale = false))
        assertEquals("denied", ChannelWords.permission(granted = false, asked = true, rationale = true))
        assertEquals("deniedForGood", ChannelWords.permission(granted = false, asked = true, rationale = false))

        // The status: three keys, three states. With no service nothing runs, whatever Bluetooth does.
        fun status(serving: Boolean, radioUp: Boolean) = ChannelWords.status(serving, radioUp, wanted = true, canSearch = false)
        assertEquals(mapOf("state" to "running", "wanted" to true, "canSearch" to false), status(serving = true, radioUp = true))
        assertEquals(mapOf("state" to "paused", "wanted" to true, "canSearch" to false), status(serving = true, radioUp = false))
        for (radioUp in listOf(true, false)) assertEquals("stopped", status(serving = false, radioUp)["state"])
        assertEquals(
            mapOf("state" to "stopped", "wanted" to false, "canSearch" to true),
            ChannelWords.status(serving = false, radioUp = false, wanted = false, canSearch = true),
        )

        // The six strings of a start and a sync, by these keys and no other; anything else is no argument.
        assertEquals(listOf("channel", "on", "paused", "reminder", "keepOn", "stopped"), ChannelWords.COPY)
        assertEquals(listOf("Mesh", "On", "Paused", "Off at 9", "Keep on", "Off"), ChannelWords.copy(copy))
        assertEquals(listOf("Mesh", "On", "Paused", "Off at 9", "Keep on", "Off"), ChannelWords.copy(copy.entries.reversed().associate { it.toPair() }))
        for (other in listOf(null, "start", copy.values.toList(), copy - "paused", copy + ("more" to "x"), copy + ("on" to 7), copy + ("on" to null))) {
            assertNull(ChannelWords.copy(other), "read as the six strings: $other")
        }
    }

    /**
     * §N.1.4: the platform logs from the first Bluetooth object a process makes. Three methods make one, and each is
     * answered only behind the lever; the handler asks this set.
     */
    @Test
    fun onlyThreeChannelMethodsAreBehindTheLever() {
        assertEquals(setOf("bluetoothOn", "bluetoothName", "start"), ChannelWords.BEHIND_THE_LEVER)
        assertEquals(
            listOf("permission", "requestPermission", "openBluetoothSettings", "sync", "stop", "status", "supported", "takeAction"),
            ChannelWords.METHODS - ChannelWords.BEHIND_THE_LEVER,
        )
    }

    /**
     * §O.1.6: `MainActivity` is exported, and Keep on restarts the twelve hours: read from any intent, a tap could
     * be made by every app on the phone, for ever. A notice's tap comes through an alias that is not exported, and
     * is read from nowhere else — off the alias the extra is not even looked at. And it is read once: an activity
     * the system makes again is handed the intent that first made it.
     */
    @Test
    fun aTapIsReadOnlyFromTheAlias() {
        fun tap(viaAlias: Boolean, extra: String?, replayed: Boolean = false) = ChannelWords.tapOf(viaAlias, replayed) { extra }
        assertEquals(true, tap(viaAlias = true, extra = "keepOn"))
        assertEquals(false, tap(viaAlias = true, extra = "openStats"))
        // Through the alias and no tap: Haven opened by something else of its own.
        for (extra in listOf(null, "", "KEEPON", "keepOn ", "stop")) assertNull(tap(viaAlias = true, extra = extra), "read as a tap: '$extra'")
        // The same extra on the activity's own name.
        for (extra in listOf("keepOn", "openStats")) {
            assertNull(tap(viaAlias = false, extra = extra), "the extra was honoured off the alias")
            assertNull(tap(viaAlias = true, extra = extra, replayed = true), "a tap was taken twice")
            assertNull(tap(viaAlias = false, extra = extra, replayed = true))
        }
        for ((viaAlias, replayed) in listOf(false to false, false to true, true to true)) {
            ChannelWords.tapOf(viaAlias, replayed) { error("the extra was read where no tap can be") }
        }
        // The two words are the state channel's own, and the alias is of the mesh's package.
        assertEquals(listOf("openStats", "keepOn"), listOf(ChannelWords.OPEN_STATS, ChannelWords.KEEP_ON))
        assertEquals("com.oblivioustech.haven.mesh.MeshTap", ChannelWords.TAP_ALIAS)
        assertEquals("com.oblivioustech.haven.mesh.TAP", ChannelWords.TAP_EXTRA)
    }

    /**
     * N-4: the Dart side drops a message nobody listens for, and the tap may be what started the app. So a tap is
     * held until that engine asks, and what it is then told stands for all of them: Keep on opens the statistics too.
     */
    @Test
    fun theTapHeldForAnEngineIsKeepOnIfAnyWas() {
        fun held(vararg keepOn: Boolean): String? {
            val taps = HeldTaps()
            for (tap in keepOn) assertNull(taps.tap(tap), "a tap was sent before the engine asked")
            return taps.take().also { assertNull(taps.take(), "a held tap was told twice") }
        }
        assertNull(held())
        assertEquals("openStats", held(false))
        assertEquals("openStats", held(false, false))
        assertEquals("keepOn", held(true))
        assertEquals("keepOn", held(true, false))
        assertEquals("keepOn", held(false, true, false))

        // Once the engine has asked, a tap is sent as it comes and nothing is held.
        val taps = HeldTaps()
        assertNull(taps.take())
        assertEquals(listOf("keepOn", "openStats"), listOf(taps.tap(keepOn = true), taps.tap(keepOn = false)))
        assertNull(taps.take())
        assertTrue(taps.tap(keepOn = false) == "openStats")
    }
}
