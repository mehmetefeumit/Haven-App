package com.oblivioustech.haven.mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.os.Build
import android.os.ParcelUuid
import com.oblivioustech.haven.mesh.core.MeshRadioConstants

/**
 * The advertisement, for as long as one radio is up
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.3, §M.3, §M.7): Haven's service UUID
 * and nothing else. No name, no power level, no service or manufacturer data
 * and no scan response — each would tell whoever is in range more than that
 * this phone runs the mesh.
 *
 * Made after the GATT server, which a peer that answers it looks for.
 */
// As the scanner: the service holds the permissions, and a refusal throws into `MeshThread.run`.
@SuppressLint("MissingPermission")
class AdvertiserAdapter(adapter: BluetoothAdapter) {
    /** Null where Bluetooth went off under the radio's start: the service is told of that itself. */
    private val advertiser = adapter.bluetoothLeAdvertiser

    // Nobody is told how the start went. One that failed is made again with
    // the next radio, never in a loop, and a phone that cannot advertise
    // dials and is not dialled (§B.3).
    private val callback = object : AdvertiseCallback() {}

    init {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(MeshRadioConstants.ADVERTISE_MODE)
            .setTxPowerLevel(MeshRadioConstants.ADVERTISE_TX_POWER)
            .setConnectable(MeshRadioConstants.ADVERTISE_CONNECTABLE)
            .setTimeout(MeshRadioConstants.ADVERTISE_TIMEOUT_MS)
        // Keeps the phone's Bluetooth name from a peer that connects in (§M.7). The setting is Android 14's.
        if (Build.VERSION.SDK_INT >= MeshRadioConstants.ADVERTISE_DISCOVERABLE_FROM_API) {
            settings.setDiscoverable(MeshRadioConstants.ADVERTISE_DISCOVERABLE)
        }
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(MeshRadioConstants.ADVERTISE_DEVICE_NAME)
            .setIncludeTxPowerLevel(MeshRadioConstants.ADVERTISE_POWER_LEVEL)
            .addServiceUuid(ParcelUuid(MeshRadioConstants.SERVICE_UUID))
            .build()
        advertiser?.startAdvertising(settings.build(), data, callback)
    }

    fun stop() {
        advertiser?.stopAdvertising(callback)
    }
}
