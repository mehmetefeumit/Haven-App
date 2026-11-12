package com.oblivioustech.haven.mesh.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The two files of `haven/rust_builder/fixtures` that Rust's tests and guard read too. */
class FixtureTest {
    private fun bytes(hex: String): ByteArray =
        if (hex == "-") ByteArray(0) else hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun id(hex: String): Long = hex.toULong(16).toLong()

    @Test
    fun outputsDecodeAsTheFixtureSays() {
        val seen = mutableMapOf<String, Int>()
        for (fields in fixture("mesh_radio_outputs.txt")) {
            val line = fields.joinToString(" ").take(60)
            seen.merge(fields[0], 1, Int::plus)
            val output = RadioOutput.decode(bytes(fields.last()))
            when (fields[0]) {
                "send" -> {
                    assertEquals(4, fields.size, line)
                    output as? RadioOutput.Send ?: error("not read as a send: $line")
                    assertEquals(id(fields[1]), output.link, line)
                    assertEquals(bytes(fields[2]).toList(), output.frame.toList(), line)
                }
                "close" -> {
                    assertEquals(3, fields.size, line)
                    output as? RadioOutput.Close ?: error("not read as a close: $line")
                    assertEquals(id(fields[1]), output.link, line)
                }
                "connect" -> {
                    assertEquals(3, fields.size, line)
                    output as? RadioOutput.Connect ?: error("not read as a connect: $line")
                    assertEquals(id(fields[1]), output.peer, line)
                }
                "reject" -> {
                    assertEquals(2, fields.size, line)
                    assertNull(output, "bytes that are no output were read as one: $line")
                }
                else -> error("a fixture line of no known form: $line")
            }
        }
        assertEquals(
            mapOf("send" to 4, "close" to 3, "connect" to 3, "reject" to 12),
            seen,
            "the fixture lost a case, or gained one Rust's test does not count",
        )

        // An answer that is no output stops the radio: the engine is told of its links, and nothing is sent.
        for (answer in listOf(ByteArray(0), byteArrayOf(2, 0, 0, 0), bytes("040102030405060708"), sendOf(1, ByteArray(513)))) {
            val rig = Rig().started()
            rig.core.onLinkUp(1, central = false, attMtu = 517, address = null)
            rig.fresh()
            rig.engine.outputs += answer
            rig.engine.outputs += closeOf(1)
            rig.core.onWake()
            assertFalse(rig.core.running)
            assertEquals(listOf("leftMs()", "poll()", "linkDown(1)"), rig.engine.calls)
            assertTrue(rig.port.calls.isEmpty(), "the radio went on after an answer it could not read: ${rig.port.calls}")
        }
    }

    /** A name or a type JNI does not find is a run-time error: the interface is the pinned exports, and no other method. */
    @Test
    fun theEngineInterfaceIsTheNineExportsOfTheFixture() {
        val letters = mapOf<Class<*>, String>(
            Long::class.java to "J",
            Int::class.java to "I",
            Boolean::class.java to "Z",
            LongArray::class.java to "[J",
            ByteArray::class.java to "[B",
            Void.TYPE to "V",
        )
        val declared = MeshEngineApi::class.java.declaredMethods.map { method ->
            val taken = method.parameterTypes.joinToString("") { letters.getValue(it) }
            "${method.name} ($taken)${letters.getValue(method.returnType)}"
        }
        val pinned = fixture("mesh_radio_exports.txt").map { "${it[0]} ${it[1]}" }
        assertEquals(9, pinned.size)
        assertEquals(pinned.sorted(), declared.sorted())
    }
}
