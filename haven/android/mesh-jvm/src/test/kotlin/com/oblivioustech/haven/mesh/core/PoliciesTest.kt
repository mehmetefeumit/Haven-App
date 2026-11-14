package com.oblivioustech.haven.mesh.core

import com.oblivioustech.haven.mesh.core.MeshRadioConstants.MAX_PEERS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SCAN_MIN_GAP_MS
import com.oblivioustech.haven.mesh.core.MeshRadioConstants.SCAN_RESTART_MS
import kotlin.test.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PoliciesTest {
    private val wallClock = 1_800_000_000_000L

    private class Started(val start: Start, val inForeground: Boolean, val engine: FakeEngine, val lever: FakeLever) {
        val deadline: Long? get() = (start as? Start.Run)?.deadlineMs
        val word: MeshStart? get() = (start as? Start.Refused)?.word
        val notice: Boolean? get() = (start as? Start.Refused)?.notice
    }

    /** A start of the service on a phone that can run the mesh, but for what the arguments say. */
    private fun start(
        left: Long,
        stored: Long,
        resumes: Boolean = true,
        api: Int = 34,
        bluetoothLe: Boolean = true,
        permission: Boolean = true,
        wipePending: Boolean = false,
        lever: FakeLever = FakeLever(),
    ): Started {
        val engine = FakeEngine().apply {
            this.left = left
            this.resumes = resumes
        }
        var inForeground = false
        lever.onCall = { assertTrue(inForeground, "the lever was asked before the service was in the foreground") }
        val start = StartPolicy.start(
            api,
            foreground = {
                assertTrue(engine.calls.isEmpty(), "the engine was touched before the service was in the foreground")
                inForeground = true
            },
            bluetoothLe = { bluetoothLe },
            lever = { lever },
            wipePending = { wipePending },
            permission = { permission },
            engine = { engine },
            storedDeadlineMs = { stored },
            wallClockMs = { wallClock },
        )
        return Started(start, inForeground, engine, lever)
    }

    @Test
    fun aStartWithoutTheBluetoothPermissionIsAStopWithTheNotice() {
        // Not left to the platform to refuse: the service reads the permission itself, and no engine is started.
        val unpermitted = start(permission = false, left = 0, stored = wallClock + HOUR)
        assertEquals(MeshStart.NO_PERMISSION, unpermitted.word)
        assertTrue(unpermitted.notice == true && unpermitted.engine.calls.isEmpty())

        for (stored in listOf(0, wallClock - 1, wallClock)) {
            val passed = start(left = 0, stored = stored)
            assertEquals(MeshStart.FAILED, passed.word, "a deadline that passed started the radio")
            assertEquals(true, passed.notice)
            assertTrue(passed.engine.called("resume").isEmpty(), "an engine was asked for after its deadline")
        }

        val owed = start(left = 0, stored = wallClock + HOUR, resumes = false)
        assertEquals(MeshStart.FAILED, owed.word, "an engine that would not start left the radio on")
        assertEquals(true, owed.notice)
        assertEquals(listOf("resume($HOUR)"), owed.engine.called("resume"))

        // An engine the session started is left alone; the copy becomes its word.
        val running = start(left = 5 * HOUR, stored = wallClock + HOUR)
        assertEquals(wallClock + 5 * HOUR, running.deadline)
        assertTrue(running.inForeground && running.engine.called("resume").isEmpty())

        val resumed = start(left = 0, stored = wallClock + HOUR)
        assertEquals(wallClock + HOUR, resumed.deadline)
        assertEquals(listOf("resume($HOUR)"), resumed.engine.called("resume"))

        // A wall clock set back while Haven was not running: twelve hours from this start, no more.
        val setBack = start(left = 0, stored = wallClock + 30 * 24 * HOUR)
        assertEquals(listOf("resume(${12 * HOUR})"), setBack.engine.called("resume"))
        assertEquals(wallClock + 12 * HOUR, setBack.deadline)
    }

    /**
     * A service started with `startForegroundService` that ends before its foreground start takes the process
     * down, and the process is the relay path's. So nothing refuses before it, and every refusal is a stop from
     * the foreground.
     */
    @Test
    fun inTheServiceTheForegroundComesBeforeAnyRefusal() {
        val refusals = mapOf(
            "an Android below 11" to start(left = 5 * HOUR, stored = 0, api = 29),
            "no Bluetooth LE" to start(left = 5 * HOUR, stored = 0, bluetoothLe = false),
            "no lever" to start(left = 5 * HOUR, stored = 0, lever = FakeLever().apply { installs = false }),
            "a lever that does not hold" to start(left = 5 * HOUR, stored = 0, lever = FakeLever().apply { holds = false }),
            "no permission" to start(left = 5 * HOUR, stored = 0, permission = false),
            "a logout" to start(left = 5 * HOUR, stored = 0, wipePending = true),
            "no engine" to start(left = 0, stored = 0),
        )
        for ((why, refused) in refusals) {
            assertNotNull(refused.word, "$why did not stop the service")
            assertTrue(refused.inForeground, "$why refused the start before the service was in the foreground")
        }
        assertEquals(
            listOf(
                MeshStart.UNSUPPORTED, MeshStart.UNSUPPORTED, MeshStart.UNSUPPORTED, MeshStart.FAILED,
                MeshStart.NO_PERMISSION, MeshStart.FAILED, MeshStart.FAILED,
            ),
            refusals.values.map { it.word },
        )
        // What the caller asked just before is asked again here: a lever can stop holding in between.
        assertEquals(listOf("leverInstall()", "leverHolds()"), start(left = 5 * HOUR, stored = 0).lever.calls)
    }

    /**
     * §O.1.2: a service ended while it still owes its foreground start takes the process down. What the start
     * reads — the stored copy, the logout's marker, a permission — and the class whose first naming loads the
     * native library can each throw, so each is handed over as a function and none is called before the
     * foreground start has returned: thrown behind it, it is a stop like any other.
     */
    @Test
    fun nothingIsReadAndNoLibraryNamedBeforeTheForegroundStart() {
        val inputs = listOf("bluetoothLe", "lever", "wipePending", "permission", "engine", "storedDeadlineMs", "wallClockMs")
        fun started(api: Int, throwing: String?): Pair<Boolean, List<String>> {
            var inForeground = false
            val read = mutableListOf<String>()
            fun <T> input(name: String, value: T): () -> T = {
                assertTrue(inForeground, "$name was read before the service was in the foreground")
                read += name
                if (name == throwing) throw Thrown()
                value
            }
            val engine = FakeEngine().apply { left = 0 }
            try {
                StartPolicy.start(
                    api,
                    foreground = {
                        assertTrue(read.isEmpty(), "read before the foreground start: $read")
                        inForeground = true
                    },
                    bluetoothLe = input("bluetoothLe", true),
                    lever = input("lever", FakeLever()),
                    wipePending = input("wipePending", false),
                    permission = input("permission", true),
                    engine = input("engine", engine),
                    storedDeadlineMs = input("storedDeadlineMs", wallClock + HOUR),
                    wallClockMs = input("wallClockMs", wallClock),
                )
            } catch (_: Thrown) {
            }
            return inForeground to read
        }
        // A start that runs reads every one of them, each once, and each behind the foreground start.
        val (inForeground, read) = started(api = 34, throwing = null)
        assertTrue(inForeground)
        assertEquals(inputs.sorted(), read.sorted())
        // Whichever of them throws, the service is in the foreground by then.
        for (input in inputs) assertTrue(started(api = 34, input).first, "$input threw ahead of the foreground start")
        // And on a level the radio never starts on: the foreground start all the same.
        assertTrue(started(api = 29, throwing = null).first)
    }

    /** One broadcast through `ReceiverPolicy`: its step, how often the refusal was asked, and whether the alarm was offered to a live start. */
    private fun received(
        boot: Boolean,
        wanted: Boolean,
        deadline: Long,
        refusal: MeshStart? = null,
        live: Boolean = false,
    ): Triple<ReceiverStep, Int, Int> {
        var asked = 0
        var offered = 0
        val step = ReceiverPolicy.step(
            boot,
            taken = {
                offered++
                live
            },
            wanted,
            deadline,
            wallClock,
        ) {
            asked++
            refusal
        }
        return Triple(step, asked, offered)
    }

    /**
     * §B.5, §O.1.8: after a reboot or an update the mesh comes back by itself only while the user's turn-on still
     * stands. The refusal — which puts the log lever in — is asked only then: a boot is no reason for a process
     * nobody turned the mesh on in to lose its log. And a boot that finds the twelve hours gone ends the mesh and
     * says so: a flag left set would bring it back, without the user, were the clock ever set behind the deadline.
     */
    @Test
    fun afterBootTheServiceIsStartedOnlyWithTheFlagADeadlineAheadAndNoRefusal() {
        fun boots(wanted: Boolean, deadline: Long, refusal: MeshStart?) = received(boot = true, wanted, deadline, refusal)
        assertEquals(Triple(ReceiverStep.START, 1, 0), boots(wanted = true, deadline = wallClock + 1, refusal = null))
        assertEquals(Triple(ReceiverStep.START, 1, 0), boots(wanted = true, deadline = wallClock + 12 * HOUR, refusal = null))
        // The flag clear: a stop the service or the user made is final, whatever the copy says.
        for (deadline in listOf(0, wallClock - 1, wallClock + HOUR)) {
            assertEquals(Triple(ReceiverStep.NONE, 0, 0), boots(wanted = false, deadline = deadline, refusal = null), "deadline $deadline")
        }
        // The twelve hours ran out while the phone was off: ended, with its notice, and the lever not touched.
        for (deadline in listOf(0, wallClock - 1, wallClock)) {
            assertEquals(Triple(ReceiverStep.END, 0, 0), boots(wanted = true, deadline = deadline, refusal = null), "deadline $deadline")
        }
        // Whatever would refuse the start refuses it here, before a service exists to end without its foreground.
        // The flag stays: the time is not up, and what refuses may pass.
        for (refusal in listOf(MeshStart.UNSUPPORTED, MeshStart.FAILED, MeshStart.NO_PERMISSION)) {
            assertEquals(Triple(ReceiverStep.NONE, 1, 0), boots(wanted = true, deadline = wallClock + HOUR, refusal = refusal), "$refusal")
        }
    }

    /**
     * §O.1.5: the alarm outlives the process. One that finds no service starts none — an alarm is no licence for a
     * foreground service — and where the twelve hours are up it ends the mesh the dead process left: flag and copy
     * cleared, the stopped notice.
     */
    @Test
    fun anAlarmThatFindsNoServiceStartsNoneAndEndsAMeshWhoseTimeIsUp() {
        fun alarm(wanted: Boolean, deadline: Long, live: Boolean = false) = received(boot = false, wanted, deadline, live = live)
        assertEquals(Triple(ReceiverStep.END, 0, 1), alarm(wanted = true, deadline = wallClock))
        assertEquals(Triple(ReceiverStep.END, 0, 1), alarm(wanted = true, deadline = wallClock - HOUR))
        // Time left: the restart the platform owes a sticky service finds the copy and goes on. Nothing is started
        // here, and the refusal — the lever — is not asked.
        assertEquals(Triple(ReceiverStep.NONE, 0, 1), alarm(wanted = true, deadline = wallClock + 1))
        assertEquals(Triple(ReceiverStep.NONE, 0, 1), alarm(wanted = true, deadline = wallClock + 12 * HOUR))
        // No mesh was left on: nothing to end, and no notice of a stop that was told already.
        for (deadline in listOf(0, wallClock - 1, wallClock + HOUR)) {
            assertEquals(Triple(ReceiverStep.NONE, 0, 1), alarm(wanted = false, deadline = deadline))
        }
        // A live start takes its alarm, and nothing is read of what is stored: the deadline is the engine's to keep.
        for (deadline in listOf(wallClock - HOUR, wallClock + HOUR)) {
            assertEquals(Triple(ReceiverStep.NONE, 0, 1), alarm(wanted = true, deadline = deadline, live = true))
        }
        // No alarm starts a service, whatever is stored.
        for (wanted in listOf(true, false)) {
            for (deadline in listOf(0, wallClock, wallClock + HOUR)) {
                for (live in listOf(true, false)) assertNotEquals(ReceiverStep.START, alarm(wanted, deadline, live).first)
            }
        }
    }

    /**
     * §B.6, §O.1.3: Bluetooth switched off is a pause — the radio down, the service and its twelve hours going on —
     * and switched on again a radio. Down at "turning off" already: two of the closes throw once LE is off.
     */
    @Test
    fun bluetoothOffPausesAndOnResumesAndNothingElseMovesTheRadio() {
        fun at(state: BluetoothState, radioUp: Boolean) = BluetoothSwitch.at(state, radioUp)
        assertEquals(RadioMove.DOWN, at(BluetoothState.TURNING_OFF, radioUp = true))
        assertEquals(RadioMove.DOWN, at(BluetoothState.OFF, radioUp = true))
        assertEquals(RadioMove.UP, at(BluetoothState.ON, radioUp = false))
        // Told twice, or told of a radio that is already as asked: nothing. A radio is never made beside one.
        assertEquals(RadioMove.NONE, at(BluetoothState.ON, radioUp = true))
        assertEquals(RadioMove.NONE, at(BluetoothState.TURNING_OFF, radioUp = false))
        assertEquals(RadioMove.NONE, at(BluetoothState.OFF, radioUp = false))
        // "Turning on" and whatever else the platform has: no radio yet, and none taken down.
        for (radioUp in listOf(true, false)) assertEquals(RadioMove.NONE, at(BluetoothState.OTHER, radioUp))
        // Three moves and no fourth: nothing here is a stop.
        assertEquals(listOf(RadioMove.UP, RadioMove.DOWN, RadioMove.NONE), RadioMove.entries)
    }

    /**
     * §B.5, §O.1.6: two ids. The service is in the foreground under one, on or paused; the reminder is under the
     * other, and the stopped notice takes its place there, so that no Keep on outlives the stop.
     */
    @Test
    fun theOngoingNoticeIsOnOrPausedAndTheStoppedNoticeTakesTheRemindersId() {
        assertEquals(Notice.ON, NoticePlan.ongoing(radioUp = true))
        assertEquals(Notice.PAUSED, NoticePlan.ongoing(radioUp = false))
        assertEquals(listOf(NoticePlan.ONGOING, NoticePlan.ONGOING), listOf(Notice.ON.id, Notice.PAUSED.id))
        assertEquals(listOf(NoticePlan.ALERT, NoticePlan.ALERT), listOf(Notice.REMINDER.id, Notice.STOPPED.id))
        assertNotEquals(NoticePlan.ONGOING, NoticePlan.ALERT)
        // The location service's notice is 4831: the mesh's are not that one.
        assertTrue(4831 !in listOf(NoticePlan.ONGOING, NoticePlan.ALERT))
        // Keep on is the reminder's alone.
        assertEquals(listOf(Notice.REMINDER), Notice.entries.filter { it.keepOn })
        // Each text is one of the six strings, by its key, and no two notices share one.
        assertEquals(listOf("on", "paused", "reminder", "stopped"), Notice.entries.map { it.copy })
        assertTrue((Notice.entries.map { it.copy } + NoticePlan.CHANNEL + NoticePlan.KEEP_ON).all { it in ChannelWords.COPY })
        assertEquals(ChannelWords.COPY.sorted(), (Notice.entries.map { it.copy } + NoticePlan.CHANNEL + NoticePlan.KEEP_ON).sorted())
    }

    /** §M.3: below Android 11 no process can keep the platform's Bluetooth lines out of its own log. */
    @Test
    fun belowApiThirtyAStartIsUnsupportedAndTouchesNothing() {
        for (api in 23..29) {
            val lever = FakeLever()
            assertFalse(StartPolicy.supported(api, bluetoothLe = true), "API $api")
            assertEquals(MeshStart.UNSUPPORTED, StartPolicy.refusal(api, bluetoothLe = true, lever, permission = true), "API $api")
            assertTrue(lever.calls.isEmpty(), "the lever was looked up on API $api, where it cannot exist")
            val service = start(left = 5 * HOUR, stored = wallClock + HOUR, api = api)
            assertEquals(MeshStart.UNSUPPORTED, service.word)
            assertTrue(service.engine.calls.isEmpty() && service.lever.calls.isEmpty(), "API $api")
        }
        for (api in listOf(30, 31, 34, 36)) {
            val lever = FakeLever()
            assertTrue(StartPolicy.supported(api, bluetoothLe = true), "API $api")
            assertNull(StartPolicy.refusal(api, bluetoothLe = true, lever, permission = true), "API $api")
            // A phone with no Bluetooth LE is as fixed.
            assertFalse(StartPolicy.supported(api, bluetoothLe = false))
            assertEquals(MeshStart.UNSUPPORTED, StartPolicy.refusal(api, bluetoothLe = false, FakeLever(), permission = true))
        }
    }

    /** §M.3 in its order: the lever before the permission, and each of its two answers its own word. */
    @Test
    fun aLeverThatIsMissingIsUnsupportedAndOneThatDoesNotHoldIsFailed() {
        fun refusal(installs: Boolean, holds: Boolean, permission: Boolean): Pair<MeshStart?, List<String>> {
            val lever = FakeLever().apply {
                this.installs = installs
                this.holds = holds
            }
            return StartPolicy.refusal(30, bluetoothLe = true, lever, permission) to lever.calls
        }
        // Missing: this Android has none, for good. What is not there is not asked whether it holds.
        assertEquals(MeshStart.UNSUPPORTED to listOf("leverInstall()"), refusal(installs = false, holds = false, permission = true))
        // In, and not in force: something that may pass.
        assertEquals(MeshStart.FAILED to listOf("leverInstall()", "leverHolds()"), refusal(installs = true, holds = false, permission = true))
        assertEquals(MeshStart.FAILED, refusal(installs = true, holds = false, permission = false).first, "the permission was read first")
        assertEquals(MeshStart.UNSUPPORTED, refusal(installs = false, holds = true, permission = false).first)
        assertEquals(MeshStart.NO_PERMISSION, refusal(installs = true, holds = true, permission = false).first)
        assertNull(refusal(installs = true, holds = true, permission = true).first)
    }

    /**
     * A logout sets its marker and then stops the radio. A process that died between the two must not come back,
     * at a sticky restart or at boot, with an engine that has no keys — and the user who logged out is told nothing.
     */
    @Test
    fun aStartBehindALogoutIsAStopWithNoNotice() {
        for (left in listOf(0, 5 * HOUR)) {
            val behind = start(left = left, stored = wallClock + HOUR, wipePending = true)
            assertEquals(MeshStart.FAILED, behind.word)
            assertEquals(false, behind.notice)
            assertTrue(behind.engine.calls.isEmpty(), "an engine was asked for behind a logout: ${behind.engine.calls}")
        }
        // Whatever else refuses the start behind a logout says nothing either.
        val unpermitted = start(left = 0, stored = wallClock + HOUR, wipePending = true, permission = false)
        assertEquals(MeshStart.NO_PERMISSION to false, unpermitted.word to unpermitted.notice)
        assertEquals(wallClock + HOUR, start(left = 0, stored = wallClock + HOUR, wipePending = false).deadline)
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
        // Its words changed: given again while it is owed, and not past the stop.
        deadline.reworded()
        assertEquals(listOf(DeadlineStep.REMINDER, DeadlineStep.NOTHING), listOf(9 * MINUTE, 8 * MINUTE).map(deadline::at))
        deadline.reworded()
        assertEquals(DeadlineStep.STOP, deadline.at(0))
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
            // A sync is a wake that asks for the reminder again where it is still owed: the service took it down,
            // for the words or the time it tells are no longer true. Kept on, none is owed, and none is asked for.
            rig.core.onSync()
            assertEquals(2, rig.port.called("remind").size, "Bluetooth on: $bluetooth")
            rig.engine.left = 12 * HOUR
            rig.core.onSync()
            assertEquals(2, rig.port.called("remind").size, "a mesh kept on was reminded")
            if (!bluetooth) assertEquals(12 * HOUR - 30 * MINUTE, rig.port.wakes.last())
            rig.engine.left = 0
            rig.core.onSync()
            assertTrue(!rig.core.running && rig.port.called("remind").size == 2)
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
        // Android 14 is the first that can be told so; with it the platform adds no flags either.
        assertEquals(34, MeshRadioConstants.ADVERTISE_DISCOVERABLE_FROM_API)
        assertTrue(MeshRadioConstants.ADVERTISE_CONNECTABLE)
        assertEquals(0, MeshRadioConstants.ADVERTISE_TIMEOUT_MS)
    }

    /**
     * The service and its characteristic are fixed for good from the first release that has the mesh on: a
     * phone with another number finds nobody, and nothing fails. Six numbers, here a second time.
     */
    @Test
    fun theUuidsAreTheOnesDrawn() {
        assertEquals(-0x72BA_D7A1_5C56_BB88L, MeshRadioConstants.SERVICE_UUID_MSB)
        assertEquals(-0x64CD_9C17_9A57_406EL, MeshRadioConstants.SERVICE_UUID_LSB)
        assertEquals(0x5882_B206_3487_45F9L, MeshRadioConstants.CHARACTERISTIC_UUID_MSB)
        assertEquals(-0x41B1_3657_AF24_137FL, MeshRadioConstants.CHARACTERISTIC_UUID_LSB)
        assertEquals(0x0000_2902_0000_1000L, MeshRadioConstants.CCCD_UUID_MSB)
        assertEquals(-0x7FFF_FF7F_A064_CB05L, MeshRadioConstants.CCCD_UUID_LSB)

        val service = MeshRadioConstants.SERVICE_UUID
        val characteristic = MeshRadioConstants.CHARACTERISTIC_UUID
        assertEquals(UUID(MeshRadioConstants.SERVICE_UUID_MSB, MeshRadioConstants.SERVICE_UUID_LSB), service)
        assertEquals(UUID(MeshRadioConstants.CHARACTERISTIC_UUID_MSB, MeshRadioConstants.CHARACTERISTIC_UUID_LSB), characteristic)
        // Random ones: version 4, in the standard layout, and two of them.
        for (drawn in listOf(service, characteristic)) assertEquals(4 to 2, drawn.version() to drawn.variant())
        assertNotEquals(service, characteristic)
        // The descriptor is Bluetooth's own 0x2902, on its base UUID: spelt in parts, as no UUID is written whole here.
        assertEquals(
            listOf("00002902", "0000", "1000", "8000", "00805f9b34fb").joinToString("-"),
            MeshRadioConstants.CCCD_UUID.toString(),
        )
    }

    /** T-PWR-1: the values of design §G. The Android integers are those of the platform's reference pages. */
    @Test
    fun theRadioModesComeFromOneSite() {
        assertEquals(0, MeshRadioConstants.SCAN_MODE, "not SCAN_MODE_LOW_POWER")
        assertEquals(0, MeshRadioConstants.ADVERTISE_MODE, "not ADVERTISE_MODE_LOW_POWER")
        assertEquals(2, MeshRadioConstants.ADVERTISE_TX_POWER, "not ADVERTISE_TX_POWER_MEDIUM")
        assertEquals(2, MeshRadioConstants.CONNECTION_PRIORITY, "not CONNECTION_PRIORITY_LOW_POWER")
        assertEquals(8, MeshRadioConstants.MAX_LINKS)
        assertEquals(517, MeshRadioConstants.REQUEST_MTU)
        // Rust's `radio_frame_len` answers a frame from 51 up, and none below.
        assertEquals(51, MeshRadioConstants.MIN_ATT_MTU)
        assertEquals(64, MeshRadioConstants.MTU_NOTES_MAX)
        assertEquals(250, MeshRadioConstants.HOLD_MARGIN_MS)
        assertEquals(10_000, MeshRadioConstants.HOLD_CAP_MS)
    }

    @Test
    fun thePeerTableHoldsSixtyFourAndForgetsOnePickedAmongThoseNotHeld() {
        val asked = mutableListOf<Int>()
        var pick = 0
        val table = PeerTable { among ->
            asked += among
            pick
        }
        val nobody = { _: String -> false }
        for (n in 0 until MAX_PEERS) assertEquals(n.toLong(), table.seen(address(n), -40, nobody))
        // Seen again: the same number, and nobody is forgotten for it.
        assertEquals(0, table.seen(address(0), -40, nobody))
        assertTrue(asked.isEmpty())

        // The sixty-fifth takes the place of the one picked: here the third of those first seen.
        pick = 2
        assertEquals(64, table.seen(address(64), -40, nobody))
        assertEquals(listOf(MAX_PEERS), asked)
        assertNull(table.addressOf(2))
        for (n in (0..64) - 2) assertEquals(address(n), table.addressOf(n.toLong()))

        // One held, being dialled or linked, is not among those picked from: the first of the others goes.
        pick = 0
        assertEquals(65, table.seen(address(65), -40) { it == address(0) })
        assertEquals(listOf(MAX_PEERS, MAX_PEERS - 1), asked)
        assertEquals(address(0), table.addressOf(0))
        assertNull(table.addressOf(1))

        // Forgotten and seen again, an address is a new peer: a number is never used twice.
        assertEquals(66, table.seen(address(2), -40, nobody))
        // With every address held, which the engine's eight links and one dial rule out, nobody new is taken in.
        assertNull(table.seen(address(150), -40) { true })
        assertEquals(3, asked.size)
    }
}
