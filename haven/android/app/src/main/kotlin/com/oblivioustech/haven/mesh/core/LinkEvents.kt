package com.oblivioustech.haven.mesh.core

/**
 * What [MeshRadioCore] is told of a link. [ServerLinks] and [GattClientSteps]
 * tell it, never from inside a call the core made: the core is in the middle
 * of its pump then.
 */
interface LinkEvents {
    fun onConnected(link: Long)

    fun onLinkUp(link: Long, central: Boolean, attMtu: Int, address: String?)

    fun onLinkDown(link: Long)

    fun onConnectFailed(address: String)

    fun onFrame(link: Long, frame: ByteArray)

    fun onSendDone(link: Long, ok: Boolean)
}
