package com.oblivioustech.haven.mesh.core

/** The Bluetooth adapter's state as the radio reads it; [OTHER] is every state the platform has beside these three. */
enum class BluetoothState { ON, TURNING_OFF, OFF, OTHER }

enum class RadioMove { UP, DOWN, NONE }

/** What the adapter's state asks of the radio (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.6, §O.1.3): a pause, never a stop. */
object BluetoothSwitch {
    /**
     * Down at "turning off" already, not only at "off": two of the closes
     * throw once Bluetooth LE is off. Up only at "on", and only with no
     * radio: a state told twice makes none twice.
     */
    fun at(state: BluetoothState, radioUp: Boolean): RadioMove = when (state) {
        BluetoothState.ON -> if (radioUp) RadioMove.NONE else RadioMove.UP
        BluetoothState.TURNING_OFF, BluetoothState.OFF -> if (radioUp) RadioMove.DOWN else RadioMove.NONE
        BluetoothState.OTHER -> RadioMove.NONE
    }
}
