package com.oblivioustech.haven.mesh.core

/**
 * The advertisers seen, each under a number of this table's own. The engine is
 * told the number; the address stays here, in memory.
 */
class PeerTable {
    // In the order last seen: a sighting moves its address to the end.
    private val peers = LinkedHashMap<String, Long>()
    private var next = 0L

    /** The number of [address], seen now. A new address takes the place of the least recently seen. */
    fun seen(address: String): Long {
        val peer = peers.remove(address) ?: next++
        if (peers.size == MeshRadioConstants.MAX_PEERS) {
            val oldest = peers.keys.iterator()
            oldest.next()
            oldest.remove()
        }
        peers[address] = peer
        return peer
    }

    /** The address numbered [peer]; null once it was forgotten. */
    fun addressOf(peer: Long): String? = peers.entries.firstOrNull { it.value == peer }?.key
}
