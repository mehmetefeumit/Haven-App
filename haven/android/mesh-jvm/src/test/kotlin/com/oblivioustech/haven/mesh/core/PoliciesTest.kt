package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MAX_PEERS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SCAN_MIN_GAP_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SCAN_RESTART_MS
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PoliciesTest {
    private val wallClock = 1_800_000_000_000L

    private class Start(val deadline: Long?, val inForeground: Boolean, val engine: FakeEngine)

    private fun start(permission: Boolean, left: Long, stored: Long, resumes: Boolean = true): Start {
        val engine = FakeEngine().apply {
            this.left = left
            this.resumes = resumes
        }
        var inForeground = false
        val deadline = StartPolicy.start(permission, engine, stored, wallClock) {
            assertTrue(engine.calls.isEmpty(), "the engine was touched before the service was in the foreground")
            inForeground = true
        }
        return Start(deadline, inForeground, engine)
    }

    @Test
    fun aStartWithoutTheBluetoothPermissionIsAStopWithTheNotice() {
        // Not left to the platform to refuse: no foreground start is tried, and no engine is started.
        val unpermitted = start(permission = false, left = 0, stored = wallClock + HOUR)
        assertNull(unpermitted.deadline)
        assertTrue(!unpermitted.inForeground && unpermitted.engine.calls.isEmpty())

        for (stored in listOf(0, wallClock - 1, wallClock)) {
            val passed = start(permission = true, left = 0, stored = stored)
            assertNull(passed.deadline, "a deadline that passed started the radio")
            assertTrue(passed.engine.called("resume").isEmpty(), "an engine was asked for after its deadline")
        }

        val owed = start(permission = true, left = 0, stored = wallClock + HOUR, resumes = false)
        assertNull(owed.deadline, "an engine that would not start left the radio on")
        assertEquals(listOf("resume($HOUR)"), owed.engine.called("resume"))

        // An engine the session started is left alone; the copy becomes its word.
        val running = start(permission = true, left = 5 * HOUR, stored = wallClock + HOUR)
        assertEquals(wallClock + 5 * HOUR, running.deadline)
        assertTrue(running.inForeground && running.engine.called("resume").isEmpty())

        val resumed = start(permission = true, left = 0, stored = wallClock + HOUR)
        assertEquals(wallClock + HOUR, resumed.deadline)
        assertEquals(listOf("resume($HOUR)"), resumed.engine.called("resume"))

        // A wall clock set back while Haven was not running: twelve hours from this start, no more.
        val setBack = start(permission = true, left = 0, stored = wallClock + 30 * 24 * HOUR)
        assertEquals(listOf("resume(${12 * HOUR})"), setBack.engine.called("resume"))
        assertEquals(wallClock + 12 * HOUR, setBack.deadline)
    }

    @Test
    fun theScanIsRestartedBeforeThirtyMinutesAndNeverTwiceInSixSeconds() {
        val scan = ScanPolicy()
        assertEquals(0, scan.dueIn(1_000))
        scan.started(1_000)
        assertEquals(SCAN_RESTART_MS, scan.dueIn(1_000))
        assertTrue(SCAN_RESTART_MS < 30 * MINUTE)
        assertEquals(1, scan.dueIn(1_000 + SCAN_RESTART_MS - 1))
        assertEquals(0, scan.dueIn(1_000 + SCAN_RESTART_MS))
        scan.stopped()
        assertEquals(SCAN_MIN_GAP_MS, scan.dueIn(1_000))
        assertTrue(SCAN_MIN_GAP_MS >= 6_000)
        assertEquals(0, scan.dueIn(1_000 + SCAN_MIN_GAP_MS))

        // Bluetooth off and on again within the six seconds: the second start waits them out, as a term of the wake.
        val rig = Rig().started()
        rig.now = 2_000
        rig.core.stopRadio()
        rig.core.startRadio()
        assertEquals(1, rig.port.called("scan").size, "two scan starts two seconds apart")
        assertEquals(4_000, rig.port.wakes.last())
        rig.pass(3_999)
        assertEquals(1, rig.port.called("scan").size)
        rig.pass(1)
        assertEquals(2, rig.port.called("scan").size)
        rig.pass(SCAN_RESTART_MS - 1)
        assertEquals(2, rig.port.called("scan").size)
        rig.pass(1)
        assertEquals(3, rig.port.called("scan").size)
    }

    /** T-AUTO-1 and -2. */
    @Test
    fun theReminderComesOnceAtThirtyMinutesAndTheStopAtZero() {
        val deadline = DeadlinePolicy()
        val steps = listOf(12 * HOUR, 30 * MINUTE + 1, 30 * MINUTE, 30 * MINUTE - 1, 1, 0, -1).map(deadline::at)
        assertEquals(
            listOf(
                DeadlineStep.NOTHING, DeadlineStep.NOTHING, DeadlineStep.REMINDER, DeadlineStep.NOTHING,
                DeadlineStep.NOTHING, DeadlineStep.STOP, DeadlineStep.STOP,
            ),
            steps,
        )
        // Kept on, and the half hour comes round again.
        assertEquals(listOf(DeadlineStep.NOTHING, DeadlineStep.REMINDER), listOf(12 * HOUR, 10 * MINUTE).map(deadline::at))
        assertEquals(HOUR, deadline.reminderIn(90 * MINUTE))
        assertNull(deadline.reminderIn(30 * MINUTE))

        // In the radio: the reminder's time is a term of the wake, with Bluetooth on or off, and it is given once.
        for (bluetooth in listOf(true, false)) {
            val rig = Rig()
            rig.engine.left = 31 * MINUTE
            rig.engine.wake = 31 * MINUTE
            if (bluetooth) rig.core.startRadio() else rig.core.onWake()
            assertEquals(MINUTE, rig.port.wakes.last())
            assertTrue(rig.port.called("remind").isEmpty())
            rig.engine.left = 30 * MINUTE
            rig.engine.wake = 30 * MINUTE
            repeat(3) { rig.core.onWake() }
            rig.core.onSighting(ADDRESS, -40)
            assertEquals(1, rig.port.called("remind").size, "Bluetooth on: $bluetooth")
            // Then the deadline itself wakes a phone with no radio.
            if (!bluetooth) assertEquals(30 * MINUTE, rig.port.wakes.last())
            rig.engine.left = 0
            rig.core.onWake()
            assertTrue(!rig.core.running && rig.port.called("remind").size == 1)
        }
    }

    @Test
    fun whatIsAskedAndWhetherItCanSearchPerApiLevel() {
        val nearbyDevices = listOf(
            "android.permission.BLUETOOTH_SCAN",
            "android.permission.BLUETOOTH_ADVERTISE",
            "android.permission.BLUETOOTH_CONNECT",
        )
        for (api in listOf(23, 28, 29, 30)) assertEquals(emptyList(), PermissionMatrix.asked(api), "API $api")
        for (api in listOf(31, 35)) assertEquals(nearbyDevices, PermissionMatrix.asked(api), "API $api")
        for (api in 23..36) {
            assertTrue(PermissionMatrix.asked(api).none { "LOCATION" in it }, "location asked for on API $api")
        }

        fun searches(api: Int, fine: Boolean, coarse: Boolean, background: Boolean, on: Boolean) =
            PermissionMatrix.canSearch(api, fine, coarse, background, on)
        // From Android 12 the scan needs no location at all.
        for (api in listOf(31, 35)) assertTrue(searches(api, fine = false, coarse = false, background = false, on = false))
        // Android 10 and 11: fine location, in the background too, and Location switched on.
        for (api in listOf(29, 30)) {
            assertTrue(searches(api, fine = true, coarse = true, background = true, on = true))
            assertTrue(!searches(api, fine = false, coarse = true, background = true, on = true), "coarse is enough on API $api")
            assertTrue(!searches(api, fine = true, coarse = true, background = false, on = true), "API $api")
            assertTrue(!searches(api, fine = true, coarse = true, background = true, on = false), "API $api")
        }
        // Before: coarse or fine, and no background permission exists.
        for (api in listOf(23, 28)) {
            assertTrue(searches(api, fine = false, coarse = true, background = false, on = true), "API $api")
            assertTrue(searches(api, fine = true, coarse = false, background = false, on = true), "API $api")
            assertTrue(!searches(api, fine = false, coarse = false, background = true, on = true), "API $api")
            assertTrue(!searches(api, fine = true, coarse = true, background = true, on = false), "API $api")
        }
    }

    /** T-PRIV-5, the half a constant can hold: what has a switch is off. */
    @Test
    fun theAdvertisementIsTheServiceUuidAlone() {
        assertTrue(!MeshRadioConstants.ADVERTISE_DEVICE_NAME, "the advertisement carries the phone's Bluetooth name")
        assertTrue(!MeshRadioConstants.ADVERTISE_POWER_LEVEL, "the advertisement carries a power level")
        assertTrue(!MeshRadioConstants.ADVERTISE_DISCOVERABLE)
        assertTrue(MeshRadioConstants.ADVERTISE_CONNECTABLE)
        assertEquals(0, MeshRadioConstants.ADVERTISE_TIMEOUT_MS)
    }

    /** T-PWR-1: the values of design §G. The Android integers are those of the platform's reference pages. */
    @Test
    fun theRadioModesComeFromOneSite() {
        assertEquals(0, MeshRadioConstants.SCAN_MODE, "not SCAN_MODE_LOW_POWER")
        assertEquals(0, MeshRadioConstants.ADVERTISE_MODE, "not ADVERTISE_MODE_LOW_POWER")
        assertEquals(2, MeshRadioConstants.ADVERTISE_TX_POWER, "not ADVERTISE_TX_POWER_MEDIUM")
        assertEquals(2, MeshRadioConstants.CONNECTION_PRIORITY, "not CONNECTION_PRIORITY_LOW_POWER")
        assertEquals(8, MeshRadioConstants.MAX_LINKS)
        assertEquals(250, MeshRadioConstants.HOLD_MARGIN_MS)
        assertEquals(10_000, MeshRadioConstants.HOLD_CAP_MS)
    }

    @Test
    fun thePeerTableHoldsSixtyFourAndForgetsTheLeastRecentlySeen() {
        val table = PeerTable()
        for (n in 0 until MAX_PEERS) assertEquals(n.toLong(), table.seen(address(n)))
        // Seen again: the same number, and no longer the oldest.
        assertEquals(0, table.seen(address(0)))
        assertEquals(64, table.seen(address(64)))
        assertNull(table.addressOf(1), "the least recently seen was kept")
        assertEquals(address(0), table.addressOf(0))
        assertEquals(address(64), table.addressOf(64))
        for (n in 2 until MAX_PEERS) assertEquals(address(n), table.addressOf(n.toLong()))
        // Forgotten and seen again, an address is a new peer: a number is never used twice.
        assertEquals(65, table.seen(address(1)))
        assertNull(table.addressOf(2))
    }
}
