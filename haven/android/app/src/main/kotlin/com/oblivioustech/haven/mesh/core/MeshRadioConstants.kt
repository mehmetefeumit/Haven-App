package com.oblivioustech.haven.mesh.core

import java.util.UUID

/**
 * Every mode, interval and cap of the radio, at one site
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §G; nothing here is measured).
 *
 * This package compiles without Android, so a platform mode is held as the
 * integer of the Android constant named beside it, and the adapters pass it on
 * as it is: no other file names one.
 */
object MeshRadioConstants {
    /** `ScanSettings.SCAN_MODE_LOW_POWER`: the lowest duty the platform offers. */
    const val SCAN_MODE = 0

    /** `AdvertiseSettings.ADVERTISE_MODE_LOW_POWER`: the lowest rate. */
    const val ADVERTISE_MODE = 0

    /** `AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM`: lower costs range. */
    const val ADVERTISE_TX_POWER = 2

    /** `BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER`. */
    const val CONNECTION_PRIORITY = 2

    // The advertisement is the service UUID, and below API 34 the flags the
    // platform adds. A name is the phone's own, and a power level narrows who
    // it could be.
    const val ADVERTISE_DEVICE_NAME = false
    const val ADVERTISE_POWER_LEVEL = false

    /** Hides the phone's Bluetooth name from a peer that connects in, and takes the flags away. */
    const val ADVERTISE_DISCOVERABLE = false

    /** The first API level that has the setting; below it the advertiser is not asked. */
    const val ADVERTISE_DISCOVERABLE_FROM_API = 34
    const val ADVERTISE_CONNECTABLE = true

    /** No time limit. */
    const val ADVERTISE_TIMEOUT_MS = 0

    /**
     * The GATT service and its one characteristic: two random UUIDs, drawn
     * once, each kept as the two halves a [UUID] is built from — written out
     * whole in a tracked file, one fails `check_no_committed_secrets.sh`.
     *
     * FIXED FOR GOOD from the first release that has the mesh on: a phone
     * that differs in one bit finds nobody. iOS takes the same numbers.
     */
    const val SERVICE_UUID_MSB = -0x72BA_D7A1_5C56_BB88L
    const val SERVICE_UUID_LSB = -0x64CD_9C17_9A57_406EL
    const val CHARACTERISTIC_UUID_MSB = 0x5882_B206_3487_45F9L
    const val CHARACTERISTIC_UUID_LSB = -0x41B1_3657_AF24_137FL

    /** Bluetooth's own: the Client Characteristic Configuration descriptor, 0x2902. */
    const val CCCD_UUID_MSB = 0x0000_2902_0000_1000L
    const val CCCD_UUID_LSB = -0x7FFF_FF7F_A064_CB05L

    val SERVICE_UUID = UUID(SERVICE_UUID_MSB, SERVICE_UUID_LSB)
    val CHARACTERISTIC_UUID = UUID(CHARACTERISTIC_UUID_MSB, CHARACTERISTIC_UUID_LSB)
    val CCCD_UUID = UUID(CCCD_UUID_MSB, CCCD_UUID_LSB)

    /** The ATT MTU a dial asks for. */
    const val REQUEST_MTU = 517

    /**
     * The smallest ATT MTU a link can have: three bytes over the engine's
     * shortest frame (`MIN_FRAME_LEN`, `haven-core/src/mesh/frame.rs`). The
     * engine closes a link below its own, so the two cannot disagree for long.
     */
    const val MIN_ATT_MTU = 51

    /** A dial that is no link by then is given up; a connection that failed is made once more, this long after. */
    const val DIAL_TIMEOUT_MS = 25_000L
    const val DIAL_RETRY_MS = 300L

    /**
     * The connections whose MTU is kept: more than a phone holds at once, as
     * far as is known — no controller's limit was read — the eldest out first.
     */
    const val MTU_NOTES_MAX = 64

    /** One ATT attribute value: the longest frame the engine hands over. */
    const val MAX_FRAME = 512

    /** The engine's `max_outgoing` + `max_incoming`: it closes what it does not admit. */
    const val MAX_LINKS = 8

    /** The engine's `max_peers`. */
    const val MAX_PEERS = 64

    /**
     * The engine's `rssi_floor` (`Config::default`, `haven-core/src/mesh/engine.rs`):
     * below it the engine takes in no peer it does not know, so such an
     * address is given no number. Were the two to differ, the higher would
     * decide and nothing would break: an address numbered here and refused
     * there costs a place of this table, and one refused here is not dialled.
     */
    const val RSSI_FLOOR = -85

    /** Connections that have not become links, and how long one may take to. */
    const val MAX_UNLINKED = 4
    const val UNLINKED_TIMEOUT_MS = 10_000L

    /** Outputs taken in one pump before the thread is given back. */
    const val PUMP_BUDGET = 64

    /** A frame the platform refused is offered again after this long, this many times. */
    const val SEND_RETRY_MS = 50L
    const val SEND_RETRIES = 3

    /** How long a frame the platform took may go without its completion. */
    const val SEND_TIMEOUT_MS = 10_000L

    /** Android takes a scan down a step at 30 minutes, and ignores a sixth start in 30 seconds. */
    const val SCAN_RESTART_MS = 25 * 60_000L
    const val SCAN_MIN_GAP_MS = 6_000L

    /** The timed wake lock: until the engine's next work and this much more, never longer than the cap. */
    const val HOLD_MARGIN_MS = 250L
    const val HOLD_CAP_MS = 10_000L

    /** The reminder notice comes when this much or less is left. */
    const val REMINDER_MS = 30 * 60_000L

    /** The longest the mesh stays on from one start: Rust's `MESH_ON_MAX_MS`. */
    const val MESH_ON_MAX_MS = 12 * 3_600_000L
}
