package com.oblivioustech.haven.mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import com.oblivioustech.haven.mesh.core.GattClientPort
import com.oblivioustech.haven.mesh.core.GattClientSteps
import com.oblivioustech.haven.mesh.core.LinkEvents
import com.oblivioustech.haven.mesh.core.MeshRadioConstants
import com.oblivioustech.haven.mesh.core.ServerLinks

/**
 * This phone's GATT clients, for as long as one radio is up
 * (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.3, §N.2.4): one for each connection
 * [steps] makes, kept under that connection's number from its `connect` to
 * its `close`. What comes next in a dial is [steps]' to say; this maps each
 * callback to one of its inputs and each of its asks to one call.
 *
 * Nothing here can start a pairing (§M.4): the transport is LE, no
 * characteristic is read, and a frame is a write that has no answer. The one
 * write that has one is the descriptor's.
 */
// As the scanner: the service holds the permissions, and a refusal throws into `MeshThread.run`.
@SuppressLint("MissingPermission")
class GattClientAdapter(
    private val context: Context,
    private val adapter: BluetoothAdapter,
    private val loop: MeshLoop,
    events: LinkEvents,
    links: ServerLinks,
    clock: () -> Long,
    number: () -> Long,
) : GattClientPort {
    /** Made with this radio and stopped with it. */
    val steps = GattClientSteps(this, events, links, clock, number)

    private val clients = HashMap<Long, BluetoothGatt>()

    /** One a connection: a callback that comes after its client was closed names a number [steps] no longer holds. */
    private inner class Callback(private val link: Long) : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) = loop.post {
            steps.onConnection(link, status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) = loop.post {
            steps.onMtu(link, mtu, status == BluetoothGatt.GATT_SUCCESS)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = loop.post {
            steps.onDiscovered(link, status == BluetoothGatt.GATT_SUCCESS)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = loop.post {
            steps.onSubscribed(link, status == BluetoothGatt.GATT_SUCCESS)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = loop.post {
            steps.onWritten(link, status == BluetoothGatt.GATT_SUCCESS)
        }

        // From Android 13 a notification comes with its value, and the platform calls this form alone.
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) = loop.post {
            steps.onFrame(link, value)
        }

        // Before it the value lives in the characteristic, and the next
        // notification overwrites it: read here, on the platform's thread,
        // before the post. The one thing an adapter does outside the loop.
        @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val value = characteristic.value
            loop.post { steps.onFrame(link, value) }
        }
    }

    override fun connect(link: Long, address: String): Boolean {
        clients[link] = adapter.getRemoteDevice(address).connectGatt(context, false, Callback(link), BluetoothDevice.TRANSPORT_LE)
            ?: return false
        return true
    }

    override fun requestMtu(link: Long, mtu: Int): Boolean = clients.getValue(link).requestMtu(mtu)

    override fun discover(link: Long): Boolean = clients.getValue(link).discoverServices()

    override fun subscribe(link: Long): Boolean {
        val client = clients.getValue(link)
        val characteristic = characteristic(client) ?: return false
        val descriptor = characteristic.getDescriptor(MeshRadioConstants.CCCD_UUID) ?: return false
        if (!client.setCharacteristicNotification(characteristic, true)) return false
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            client.writeDescriptor(descriptor, enable) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.setValue(enable) && client.writeDescriptor(descriptor)
        }
    }

    override fun lowPower(link: Long) {
        clients.getValue(link).requestConnectionPriority(MeshRadioConstants.CONNECTION_PRIORITY)
    }

    override fun write(link: Long, frame: ByteArray): Boolean {
        val client = clients.getValue(link)
        val characteristic = characteristic(client) ?: return false
        val noAnswer = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            client.writeCharacteristic(characteristic, frame, noAnswer) == BluetoothStatusCodes.SUCCESS
        } else {
            // Before Android 13 the platform reads the frame back out of the
            // characteristic, where a notification that arrives on its own
            // thread puts its value too: the two can cross, and nothing here
            // can keep them apart (design §N.7).
            characteristic.writeType = noAnswer
            @Suppress("DEPRECATION")
            characteristic.setValue(frame) && client.writeCharacteristic(characteristic)
        }
    }

    override fun disconnect(link: Long) = clients.getValue(link).disconnect()

    override fun close(link: Long) {
        clients.remove(link)?.close()
    }

    override fun timer(inMs: Long) = loop.timer(this, inMs, steps::onTimer)

    /** The radio stops: every client is closed, and what a close threw is thrown on once all are. */
    fun stop() = steps.stop()

    private fun characteristic(client: BluetoothGatt): BluetoothGattCharacteristic? =
        client.getService(MeshRadioConstants.SERVICE_UUID)?.getCharacteristic(MeshRadioConstants.CHARACTERISTIC_UUID)
}
