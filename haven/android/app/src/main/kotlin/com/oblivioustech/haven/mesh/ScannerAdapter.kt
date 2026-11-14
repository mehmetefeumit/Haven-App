package com.oblivioustech.haven.mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.ParcelUuid
import com.oblivioustech.haven.mesh.core.MeshRadioConstants
import com.oblivioustech.haven.mesh.core.MeshRadioCore

/**
 * The scan for Haven's service (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.3): one
 * filter on its UUID, so that it runs with the screen off, in the mode of
 * [MeshRadioConstants], every match reported as it comes. When it starts is
 * the core's to say (`RadioPort.scan`).
 *
 * [canSearch] is `PermissionMatrix.canSearch` over what the service reads:
 * where it is false a scan would be given nothing.
 */
// The service holds the runtime permissions before a radio is made (`StartPolicy`),
// and a call the platform still refuses throws into `MeshThread.run`.
@SuppressLint("MissingPermission")
class ScannerAdapter(
    private val adapter: BluetoothAdapter,
    private val loop: MeshLoop,
    private val core: MeshRadioCore,
    private val canSearch: () -> Boolean,
) {
    private val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(MeshRadioConstants.SERVICE_UUID)).build())
    private val settings = ScanSettings.Builder().setScanMode(MeshRadioConstants.SCAN_MODE).build()

    // A scan that fails or dies is not started again from here: the core restarts it, late (§B.3).
    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = loop.post {
            core.onSighting(result.device.address, result.rssi)
        }
    }

    /** `RadioPort.scan`: ends the scan that runs and starts one. */
    fun scan() {
        stop()
        if (canSearch()) adapter.bluetoothLeScanner?.startScan(filters, settings, callback)
    }

    /** With Bluetooth off there is no scanner, and no scan to end. */
    fun stop() {
        adapter.bluetoothLeScanner?.stopScan(callback)
    }
}
