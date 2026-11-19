package com.oblivioustech.haven.mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import com.oblivioustech.haven.mesh.core.LinkEvents
import com.oblivioustech.haven.mesh.core.MeshRadioConstants
import com.oblivioustech.haven.mesh.core.ServerLinks
import com.oblivioustech.haven.mesh.core.ServerPort

/**
 * Haven's GATT server, for as long as one radio is up
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.3, §N.2.3): one service, one
 * characteristic a peer writes frames to and is notified of frames on, and
 * the descriptor it subscribes by. What a callback means is [links]' to say;
 * this maps each to one of its inputs and each of its asks to one call.
 *
 * Haven asks for no security here (§M.4): no attribute asks for encryption
 * or authentication, and a request is answered success or "request not
 * supported", never a status that names either. A central can still ask to
 * pair. The bond receiver tells [links] of a device that starts to bond, and
 * [links] ends one that has subscribed; one that has not is left to the
 * system's dialog (owner question Q-15). No attribute can be read, so the
 * platform refuses a read itself and none is left waiting for an answer.
 *
 * A server the platform does not open, or a service it will not begin to
 * add, is thrown like anything else it throws: into `MeshThread.run`.
 */
// As the scanner: the service holds the permissions, and a refusal throws into `MeshThread.run`.
@SuppressLint("MissingPermission")
class GattServerAdapter(
    context: Context,
    private val manager: BluetoothManager,
    private val loop: MeshLoop,
    events: LinkEvents,
    number: () -> Long,
) : ServerPort {
    /** Made with this server and stopped with it: its callbacks reach no other. */
    val links = ServerLinks(this, events, number)

    private val characteristic = BluetoothGattCharacteristic(
        MeshRadioConstants.CHARACTERISTIC_UUID,
        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
        BluetoothGattCharacteristic.PERMISSION_WRITE,
    ).apply {
        addDescriptor(BluetoothGattDescriptor(MeshRadioConstants.CCCD_UUID, BluetoothGattDescriptor.PERMISSION_WRITE))
    }

    // A connection is the phone's, not Haven's (§M.1): only its end is told,
    // for the note `links` keeps of it. The server has one service, so no
    // request names another attribute than Haven's two.
    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) = loop.post {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) links.onDisconnected(device.address)
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) = loop.post {
            links.onMtu(device.address, mtu)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) = loop.post {
            links.onDescriptorWrite(device.address, requestId, preparedWrite, responseNeeded, offset, value)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) = loop.post {
            links.onWrite(device.address, requestId, preparedWrite, responseNeeded, offset, value)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) = loop.post {
            links.onNotified(device.address, status == BluetoothGatt.GATT_SUCCESS)
        }
    }

    private val server = checkNotNull(manager.openGattServer(context, callback))

    init {
        val service = BluetoothGattService(MeshRadioConstants.SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(characteristic)
        if (!server.addService(service)) {
            // This adapter is never made, so nobody else would close what it opened.
            server.close()
            throw IllegalStateException()
        }
    }

    override fun answer(address: String, request: Int, ok: Boolean) {
        // A code of ATT's own, 0x06: the platform's "failure" is 257, and what goes out for it is a cast's doing.
        val status = if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
        server.sendResponse(device(address), request, status, 0, null)
    }

    override fun cancel(address: String) = server.cancelConnection(device(address))

    override fun notify(address: String, frame: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device(address), characteristic, false, frame) == BluetoothStatusCodes.SUCCESS
        } else {
            // Before Android 13 a notification's value is the characteristic's own, read inside the call.
            @Suppress("DEPRECATION")
            characteristic.setValue(frame) && server.notifyCharacteristicChanged(device(address), characteristic, false)
        }

    /** The radio stops: [links] first, so that what the closed server still calls back finds nobody. */
    fun stop() {
        links.stop()
        server.close()
    }

    private fun device(address: String) = manager.adapter.getRemoteDevice(address)
}
