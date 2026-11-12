package com.oblivioustech.haven.mesh.core

import java.io.File

const val MINUTE = 60_000L
const val HOUR = 60 * MINUTE

/** An address as a scan reports one. It must never be an engine argument, or be written anywhere. */
const val ADDRESS = "C4:7A:11:5E:90:2B"

fun address(n: Int): String = "C4:7A:11:5E:%02X:%02X".format(n / 256, n % 256)

/** A file of `haven/rust_builder/fixtures`: the one the Rust tests read. */
fun fixture(name: String): List<List<String>> =
    File(System.getProperty("mesh.fixtures"), name).readLines()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }
        .map { it.split(Regex("\\s+")) }

private fun encoded(kind: Int, id: Long, bytes: ByteArray = ByteArray(0)): ByteArray =
    byteArrayOf(kind.toByte()) + ByteArray(8) { (id ushr (56 - 8 * it)).toByte() } + bytes

fun sendOf(link: Long, frame: ByteArray) = encoded(1, link, frame)

fun closeOf(link: Long) = encoded(2, link)

fun connectOf(peer: Long) = encoded(3, peer)

class Thrown : RuntimeException("device $ADDRESS is gone")

/** The engine as the radio sees it, scripted: every call recorded in order, with its arguments. */
class FakeEngine : MeshEngineApi {
    val calls = mutableListOf<String>()
    var left = 12 * HOUR
    var wake = 5_000L

    /** Whether [resume] starts an engine: false is one that ended and is not yet paid for. */
    var resumes = true

    /** What [poll] answers, in order. As the engine does, it holds a frame back until its link is ready. */
    val outputs = mutableListOf<ByteArray>()

    /** The `ready` of every poll. */
    val readies = mutableListOf<List<Long>>()
    var throwsIn: String? = null
    var threw = false

    private fun record(name: String, vararg arguments: Any) {
        calls += "$name(${arguments.joinToString(",")})"
        if (throwsIn == name) {
            threw = true
            throw Thrown()
        }
    }

    fun called(name: String): List<String> = calls.filter { it.startsWith("$name(") }

    override fun resume(leftMs: Long): Boolean {
        record("resume", leftMs)
        if (resumes) left = leftMs
        return resumes
    }

    override fun leftMs(): Long {
        record("leftMs")
        return left
    }

    override fun sighting(peer: Long, rssi: Int) = record("sighting", peer, rssi)

    override fun linkUp(link: Long, central: Boolean, attMtu: Int, peer: Long) =
        record("linkUp", link, central, attMtu, peer)

    override fun linkDown(link: Long) = record("linkDown", link)

    override fun connectFailed(peer: Long) = record("connectFailed", peer)

    override fun receive(link: Long, frame: ByteArray) = record("receive", link, frame.size)

    override fun poll(ready: LongArray): ByteArray? {
        record("poll")
        readies += ready.toList()
        val next = outputs.indexOfFirst { (RadioOutput.decode(it) as? RadioOutput.Send)?.let { send -> send.link in ready } ?: true }
        return if (next < 0) null else outputs.removeAt(next)
    }

    override fun wakeInMs(): Long {
        record("wakeInMs")
        return wake
    }
}

/** The adapters, recording: every call in order, with its arguments. */
class RecordingPort : RadioPort {
    val calls = mutableListOf<String>()
    val frames = mutableListOf<List<Byte>>()

    /** How many of the next sends the platform does not take. */
    var refuses = 0
    var throwsIn: String? = null
    var threw = false

    private fun record(name: String, vararg arguments: Any) {
        calls += "$name(${arguments.joinToString(",")})"
        if (throwsIn == name) {
            threw = true
            throw Thrown()
        }
    }

    fun called(name: String): List<String> = calls.filter { it.startsWith("$name(") }

    /** The arguments of every [wakeAt], in order. */
    val wakes: List<Long> get() = called("wakeAt").map { it.substringAfter('(').dropLast(1).toLong() }

    override fun connect(address: String) = record("connect", address)

    override fun close(link: Long) = record("close", link)

    override fun send(link: Long, frame: ByteArray): Boolean {
        record("send", link)
        frames += frame.toList()
        return refuses-- <= 0
    }

    override fun scan() = record("scan")

    override fun remind() = record("remind")

    override fun holdAwake(ms: Long) = record("holdAwake", ms)

    override fun wakeAt(inMs: Long) = record("wakeAt", inMs)
}

/** A core over the two fakes and a clock the test moves. */
class Rig {
    val engine = FakeEngine()
    val port = RecordingPort()
    var now = 0L
    val core = MeshRadioCore(engine, port) { now }

    /** With Bluetooth on and the adapters up. */
    fun started(): Rig = apply { core.startRadio() }

    /** [ms] pass and the wake comes. */
    fun pass(ms: Long) {
        now += ms
        core.onWake()
    }

    /** Forgets what was recorded so far. */
    fun fresh() {
        engine.calls.clear()
        engine.readies.clear()
        port.calls.clear()
        port.frames.clear()
    }
}
