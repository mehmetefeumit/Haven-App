package com.oblivioustech.haven.mesh.core

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

    // The advertisement is its flags and the service UUID. A name is the
    // phone's own, and a power level narrows who it could be.
    const val ADVERTISE_DEVICE_NAME = false
    const val ADVERTISE_POWER_LEVEL = false

    /** Hides the phone's Bluetooth name from a peer that connects in, where the platform can (API 34). */
    const val ADVERTISE_DISCOVERABLE = false
    const val ADVERTISE_CONNECTABLE = true

    /** No time limit. */
    const val ADVERTISE_TIMEOUT_MS = 0

    /** One ATT attribute value: the longest frame the engine hands over. */
    const val MAX_FRAME = 512

    /** The engine's `max_outgoing` + `max_incoming`: it closes what it does not admit. */
    const val MAX_LINKS = 8

    /** The engine's `max_peers`. */
    const val MAX_PEERS = 64

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
