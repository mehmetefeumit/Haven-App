package com.oblivioustech.haven.mesh.core

/** What the engine asks of the radio. */
sealed interface RadioOutput {
    /** One frame, spent by the poll that answered it: delivered, or its link is closed. */
    class Send(val link: Long, val frame: ByteArray) : RadioOutput

    class Close(val link: Long) : RadioOutput

    class Connect(val peer: Long) : RadioOutput

    companion object {
        private const val HEADER = 9
        private const val SEND: Byte = 1
        private const val CLOSE: Byte = 2
        private const val CONNECT: Byte = 3

        /**
         * What [MeshEngineApi.poll] answered — `kind ‖ id, big-endian ‖ bytes`,
         * as `haven/rust_builder/fixtures/mesh_radio_outputs.txt` has it — or
         * null for bytes that are no output.
         */
        fun decode(bytes: ByteArray): RadioOutput? {
            if (bytes.size < HEADER) return null
            var id = 0L
            for (at in 1 until HEADER) id = (id shl 8) or (bytes[at].toLong() and 0xff)
            val carried = bytes.size - HEADER
            return when {
                bytes[0] == SEND && carried in 1..MeshRadioConstants.MAX_FRAME ->
                    Send(id, bytes.copyOfRange(HEADER, bytes.size))
                bytes[0] == CLOSE && carried == 0 -> Close(id)
                bytes[0] == CONNECT && carried == 0 -> Connect(id)
                else -> null
            }
        }
    }
}
