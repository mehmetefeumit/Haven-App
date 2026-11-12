package com.oblivioustech.haven.mesh.core

/**
 * The advertisers seen, each under a number of this table's own. The engine is
 * told the number; the address stays here, in memory.
 *
 * [pick] answers a number from 0 up to its argument, at random: it chooses
 * whom a full table forgets.
 */
class PeerTable(private val pick: (Int) -> Int) {
    private val peers = LinkedHashMap<String, Long>()
    private var next = 0L

    /**
     * The number of [address], seen at [rssi] dBm; null when it gets none.
     *
     * An address not yet known gets none below the floor under which the
     * engine takes in no new peer, so far-off advertisers fill no place. In a
     * full table a new address takes the place of one picked at random among
     * those not [held]: the oldest would be whoever was here before a crowd of
     * addresses arrived, and one advertiser can be that crowd. A number is
     * never used twice.
     */
    fun seen(address: String, rssi: Int, held: (String) -> Boolean): Long? {
        peers[address]?.let { return it }
        if (rssi < MeshRadioConstants.RSSI_FLOOR) return null
        if (peers.size == MeshRadioConstants.MAX_PEERS) {
            val idle = peers.keys.filterNot(held)
            // As the engine: with nobody to forget, nobody new is taken in.
            if (idle.isEmpty()) return null
            peers.remove(idle[pick(idle.size)])
        }
        return next++.also { peers[address] = it }
    }

    /** The address numbered [peer]; null once it was forgotten. */
    fun addressOf(peer: Long): String? = peers.entries.firstOrNull { it.value == peer }?.key
}
