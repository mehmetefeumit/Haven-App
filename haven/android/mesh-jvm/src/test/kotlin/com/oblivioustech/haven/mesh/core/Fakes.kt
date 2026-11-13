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

/** The log lever, scripted. [onCall] runs as each call comes in: what must not have happened by then. */
class FakeLever : LogLever {
    val calls = mutableListOf<String>()
    var installs = true
    var holds = true
    var onCall: () -> Unit = {}
    var throwsIn: String? = null
    var threw = false

    private fun record(name: String) {
        onCall()
        calls += "$name()"
        if (throwsIn == name) {
            threw = true
            throw Thrown()
        }
    }

    override fun leverInstall(): Boolean {
        record("leverInstall")
        return installs
    }

    override fun leverHolds(): Boolean {
        record("leverHolds")
        return holds
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
    val lever = FakeLever()
    val port = RecordingPort()
    var now = 0L

    /** Whom a full peer table forgets, of [it] candidates in the order they were first seen, and what it was asked. */
    var pick: (Int) -> Int = { 0 }
    val pickedAmong = mutableListOf<Int>()
    val core = MeshRadioCore(engine, lever, port, { now }) { among ->
        pickedAmong += among
        pick(among)
    }

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
        lever.calls.clear()
        port.calls.clear()
        port.frames.clear()
    }
}

/**
 * The core as the two GATT roles tell it, recording; [order] is the one list the three fakes of a [Radios] share.
 * [then] runs inside each call: what the core does in its pump.
 */
class RecordingEvents(private val order: MutableList<String> = mutableListOf()) : LinkEvents {
    val calls = mutableListOf<String>()
    var then: (String) -> Unit = {}

    private fun record(call: String) {
        calls += call
        order += call
        then(call)
    }

    fun called(name: String): List<String> = calls.filter { it.startsWith("$name(") }

    override fun onConnected(link: Long) = record("connected($link)")

    override fun onLinkUp(link: Long, central: Boolean, attMtu: Int, address: String?) =
        record("linkUp($link,$central,$attMtu,$address)")

    override fun onLinkDown(link: Long) = record("linkDown($link)")

    override fun onConnectFailed(address: String) = record("connectFailed($address)")

    override fun onFrame(link: Long, frame: ByteArray) = record("frame($link,${frame.toList()})")

    override fun onSendDone(link: Long, ok: Boolean) = record("sendDone($link,$ok)")
}

/** The GATT server's adapter, recording. */
class RecordingServerPort(private val order: MutableList<String> = mutableListOf()) : ServerPort {
    val calls = mutableListOf<String>()

    /** Whether the platform takes a notification. */
    var takes = true

    private fun record(call: String) {
        calls += call
        order += call
    }

    override fun answer(address: String, request: Int, ok: Boolean) = record("answer($address,$request,$ok)")

    override fun cancel(address: String) = record("cancel($address)")

    override fun notify(address: String, frame: ByteArray): Boolean {
        record("notify($address,${frame.toList()})")
        return takes
    }
}

/**
 * The GATT client's adapter, recording, and holding the pure half to its word: a client is asked something only
 * between the connect that made it and its close, and no number makes two.
 */
class RecordingClientPort(private val order: MutableList<String> = mutableListOf()) : GattClientPort {
    val calls = mutableListOf<String>()

    /** The clients made and not yet closed. */
    val open = mutableSetOf<Long>()

    /** Every client ever made, with the address it was made for. */
    val made = mutableMapOf<Long, String>()

    /** The steps the platform does not begin. */
    val refuses = mutableSetOf<String>()

    private fun record(call: String) {
        calls += call
        order += call
    }

    fun called(name: String): List<String> = calls.filter { it.startsWith("$name(") }

    private fun step(name: String, link: Long, vararg more: Any): Boolean {
        check(link in open) { "$name was asked of client $link, which is not open" }
        record("$name(${(listOf(link) + more).joinToString(",")})")
        return name !in refuses
    }

    override fun connect(link: Long, address: String): Boolean {
        check(link !in made) { "the number $link made two clients" }
        record("connect($link,$address)")
        if ("connect" in refuses) return false
        made[link] = address
        open += link
        return true
    }

    override fun requestMtu(link: Long, mtu: Int) = step("requestMtu", link, mtu)

    override fun discover(link: Long) = step("discover", link)

    override fun subscribe(link: Long) = step("subscribe", link)

    override fun lowPower(link: Long) {
        step("lowPower", link)
    }

    override fun write(link: Long, frame: ByteArray) = step("write", link, frame.toList())

    override fun disconnect(link: Long) {
        step("disconnect", link)
    }

    override fun close(link: Long) {
        step("close", link)
        open -= link
    }

    override fun timer(inMs: Long) = record("timer($inMs)")
}

/** The two GATT roles' pure halves over recording adapters, one counter of link numbers and a clock the test moves. */
class Radios {
    /** Every call of the three fakes, in the order made. */
    val order = mutableListOf<String>()
    val events = RecordingEvents(order)
    val server = RecordingServerPort(order)
    val client = RecordingClientPort(order)
    var now = 0L
    private var next = 0L
    val links = ServerLinks(server, events) { next++ }
    val steps = GattClientSteps(client, events, links, { now }) { next++ }

    /** [ms] pass and the client's timer comes. */
    fun pass(ms: Long) {
        now += ms
        steps.onTimer()
    }

    /** A device enables notifications on Haven's characteristic, as request [request]. */
    fun subscribes(address: String, request: Int = 1) =
        links.onDescriptorWrite(address, request, prepared = false, responseNeeded = true, offset = 0, value = byteArrayOf(1, 0))

    /** A frame as a peer writes one: whole, and wanting no answer. */
    fun writes(address: String, frame: ByteArray) =
        links.onWrite(address, request = 0, prepared = false, responseNeeded = false, offset = 0, value = frame)

    /** Dials [address]: the connection is made, under the number answered. */
    fun dials(address: String): Long {
        steps.connect(address)
        steps.onTimer()
        return client.made.entries.last { it.value == address }.key
    }

    /** Dials [address] up to its link, at [mtu]; answers the link's number. */
    fun dialled(address: String, mtu: Int = 517): Long {
        val link = dials(address)
        steps.onConnection(link, connected = true)
        steps.onMtu(link, mtu, ok = true)
        steps.onDiscovered(link, ok = true)
        steps.onSubscribed(link, ok = true)
        return link
    }

    /** Forgets what was recorded so far. */
    fun fresh() {
        order.clear()
        events.calls.clear()
        server.calls.clear()
        client.calls.clear()
    }
}
