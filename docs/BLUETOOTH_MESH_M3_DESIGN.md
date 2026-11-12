# M3 design — the Android radio, its Rust interface, and everything on screen

> Status: **DESIGN for milestone M3 of `docs/BLUETOOTH_MESH_PLAN.md` — drafted
> by one agent and confirmed with changes by an independent review, both
> 2026-11-11.** The review's changes are folded in and listed in §L, with
> the one premise of it that the code contradicts. Built so far, each with
> its departures from this text in plan §16: M3a; M3b; M3c; M3d in English
> only; M3e; M3f.
> The radio's pure Kotlin is built and tested on the JVM (M3f). No Android
> adapter is, and no `MeshNative`: the shim's exports (M3b) have no caller.
> **Revised 2026-11-12 for M3g's first step** — what Android itself logs,
> the device name, and what Haven does about them: §M, researched in the
> platform's source and confirmed by an independent pass, with §0, §1,
> §B, §F, §H to §L and §12 brought into line. Paper only: nothing of §M
> is built, and nothing of it has run on an emulator or a device.

Studied at `132f5ca` (this file is in the tree since `8a76cf0`), with another
agent's uncommitted work in `haven-core/`,
`tooling/soak/` and `docs/BLUETOOTH_MESH_PLAN.md` §16 (M2g-2b, the soak
plane); nothing here depends on it. Read-only study: no build, no test run.
Abbreviations: `api` = `haven/rust_builder/src/api.rs`, `eng` =
`haven-core/src/mesh/engine.rs`, `plan` = `docs/BLUETOOTH_MESH_PLAN.md`,
`aura` = `docs/BLUETOOTH_MESH_AURA_DESIGN.md`, `kt/` =
`haven/android/app/src/main/kotlin/com/oblivioustech/haven/`, `bc:` =
`permissionlesstech/bitchat-android@14ab73c4`,
`app/src/main/java/com/bitchat/android/mesh/` (GPL-3.0: read for pitfalls,
nothing copied). `[An]` is a URL in §12.

**Where a claim is proved.** Every test and every platform claim below
carries one of:

| Tag | Proved by | Runs here today |
|---|---|---|
| **[L]** | a Rust test in `rust_builder` or `haven-core` | yes |
| **[D]** | a Dart unit or widget test | yes |
| **[G]** | a bash guard with a self-test | yes |
| **[J]** | a JVM unit test of Kotlin | yes, since M3f: `haven/android/mesh-jvm`, a Gradle build of the pure package alone, needs a JDK and no Android SDK. Its lane, `android-unit.yml`, has never run |
| **[C]** | compiling for Android (`build-check.yml`, `cross-check.yml`) | **no** — CI only |
| **[E]** | an emulator lane | **no** — CI only, **and its feasibility is unproven** (G-1, G-6) |
| **[H]** | a real device | **no** — DEFERRED; the project has none |
| **[U]** | nothing: unverified. What the confirming review read on an AOSP mirror or from memory, and what either pass has only from a search summary, stays [U] and says which | — |
| **[V]**, **[V1]** | §M, and where another section cites §M: a platform source file or reference page, fetched and read by the confirming pass ([V]) or by the research pass alone ([V1]). A reading of source, not a run; from API 33 always on a LineageOS mirror, never on the AOSP host (§M.0) | — |

CI (`ci.yml`) runs on pushes to `main` and pull requests to `main`
(`.github/workflows/ci.yml:22-26`); this branch has no pull request. So
**today [C] and [E] are proved by nothing**, and no Kotlin that imports
Android — every adapter — can be compiled before a pull request exists
(Q-1). [J] is proved where the JVM build is run by hand (as built, M3f; the
draft had it CI-only). The M0 spikes of plan §10 were never run: G-1, G-6
and G-10 are unanswered.

---

## 0. Findings that change the plan's text (decide before coding)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F-1 | **No engine can exist in a process that has opened no session.** The engine is created only by `mesh_open(session, …)` (`api:12957-12982`); the radio's entry, `with_mesh(None, …)`, answers `None` when the home is `Off` (`api:12905-12907`). Plan §0.4 item 3, §7.7 R4 and T-BG-1 ("process killed, the service returns; reboot with mesh on, mesh resumes") need an engine in exactly that process. | — | M3a adds a session-less start, `radio_resume(left_ms)`. It needs the deadline from somewhere that is not the session's store. Q-2. |
| F-2 | **The deadline lives behind the session.** `user_settings.mesh_on_until` is in `circles-v2.db`, read through `SessionManager` (`haven-core/src/nostr/mls/manager/mesh.rs:1109`). Plan §7.1 says the boot receiver "checks the persisted flag" and §7.6 arms an alarm in `MeshService`; neither can read that store without opening the session (Rule 14). | — | The service keeps its own copy of the deadline, derived from the engine, in app-private preferences. The session's store stays the authority: the first session entry overrules the copy (§A.4). |
| F-3 | **"Keep on … without opening Haven" (plan §7.6) is impossible when no session-owning isolate is alive**: restarting the twelve hours is a write to the session's store (`mesh_keep_on` → `mesh_on_until`, `api:13044-13050`). | — | Q-3: the notification's Keep on opens Haven, or does so only when no Dart isolate is alive. |
| F-4 | **A stopped service has nothing to bring it back when Bluetooth returns.** Android 12+ refuses a foreground-service start from the background outside a fixed list [A5]. One entry on it is "the user turns off battery optimizations for your app", which Haven asks for and a user may decline (`background_location_manager.dart:181-186`); but a Bluetooth state change reaches no manifest receiver (**[U]**, the review's word), so in a stopped state nothing would hear it. Plan §7.1 has the service "wait for Bluetooth to come on". | [A5] | The service stays in the foreground, radio idle, while Bluetooth is off: a state "paused" that the plan does not name (§B.6, Q-8). |
| F-5 | **The timed wake lock of plan §7.7 R2 is expected to hold in Doze, so its cost is real.** The Doze page says the system "ignores wake locks" [A7], with no exception. AOSP disables an app's partial wake lock in device idle only when its process state is worse than bound-foreground-service and it is not allowlisted (`PowerManagerService.setWakeLockDisabledStateLocked`; read by the review on a LineageOS 22.1 mirror, by the draft from memory — **[U]** here). | [A7]; mirror | A phone with a foreground service keeps the lock while dozing: R2 works as planned on AOSP, and a busy mesh keeps such a phone awake (§G, §H, Q-13). Vendor builds: [H]. The draft had this the other way round. |
| F-6 | **A connected peer can read the phone's Bluetooth name, and sees more than Haven's service.** "No characteristic exposes a name" (plan §6.1) holds for Haven's service only. Android's Generic Access service carries Device Name. Per AOSP change `5fc5174` ("Selectively hide Device Name characteristic", bug 254314964) it is readable without encryption by a peer that connected through a *discoverable* advertisement, **or that this phone connected to**; earlier stacks let anyone read it (**[U]** as to the text: the review had it from search summaries). Advertisements are discoverable by default; `setDiscoverable(false)` exists from API 34 [A15, A16]. And Android keeps one attribute table a device, shared by every app (**[U]**, both passes' memory), so a peer also sees other apps' services. | [A15], [A16]; rest [U] | An attacker who advertises Haven's service UUID — public in the APK — is dialled by every Haven phone in range and reads each one's Bluetooth name, on every API level: a stable identifier across address rotation, often the owner's name. Plan §0.4 item 6 ("identity stay[s] hidden") is false. §B.3 hides the name from inbound peers on API 34+; nothing hides it from a peer Haven dials. §D discloses it; Q-6, Q-11. **As researched, 2026-11-12 (§M.7):** the stack's rule is read, in a mirror, from 14 QPR3; it does not hold on a controller with neither extended nor multi advertising; and from Android 16 a peer's stack reads the name on every link, no app asking. |
| F-7 | **The plan's button placement cites code that is elsewhere.** `MapControls` is positioned in `haven/lib/src/pages/map/map_page.dart:659-667`, inside the `map` layer, not in `MapShell.buildLayers` (`map_shell.dart:1013-1073`); the collapsed height is a private constant there (`map_page.dart:181`, `:645`) with a twin in the sheet (`circles_bottom_sheet.dart:43`). | — | The button takes its rect from `aura` §2's `meshButtonRect`; the 0.12 becomes one shared constant (§E.1). |
| F-8 | **`rust_builder` has no `unsafe_code` lint**, and `frb_generated.rs` holds 223 `unsafe`s (`haven/rust_builder/src/lib.rs:1-19`, `Cargo.toml` has no `[lints]`). "`unsafe` confined to the shim" (plan §3) is not checkable today. | — | M3b denies `unsafe_code` crate-wide and allows it on two modules (§A.6). |
| F-9 | **`jni` is already resolved**: `jni 0.21.1`, through `android-native-keyring-store` (`haven/rust_builder/Cargo.lock:76-82`, `:2085`), and that crate already exports a JNI function from this library (`kt/HavenApplication.kt:57`;
`haven/android/app/src/main/kotlin/io/crates/keyring/Keyring.kt`). It is in neither other lockfile, and need not be. `jni 0.22.4` is current and changes the API [A11]. | — | Direct dependency on the 0.21 line: one line in one lockfile, no new package (§A.7). |
| F-10 | **Notification text has no native l10n pipeline.** The location notification's text is localized in Dart and handed over (`background_location_manager.dart:295-301`). | — | Mesh notices do the same; a notice posted after a reboot uses the copy of the last start (§B.7). |
| F-11 | **`permission_handler` is deliberately not a dependency** (`haven/pubspec.yaml:72-74`), and `MainActivity` is one line. | — | The Bluetooth prompt is asked by Haven's own channel in `MainActivity` (§C). |
| F-12 | **The emulator's peripheral role may hold one inbound link at a time.** A third party found on emulator 37.1.11 / API 35 that an advertising emulator "stops advertising, so a second central cannot see it until the first disconnects" [A9]. G-6 asks for 2+2 links. | [A9], one report | The netsim lane may be unable to show two inbound links whatever Haven does (§F). |
| F-13 | **Android's own Bluetooth classes log peer addresses from inside Haven's process, in every build.** `android.bluetooth.BluetoothGatt` and `BluetoothGattServer` run in the app's process with `DBG = true` and call `Log.d` with the raw address: `onSearchComplete() = Device=` + address, `onDescriptorWrite() - Device=` + address (client, lines 419, 708), `onMtuChanged() - device=` + address (server, line 360) — LineageOS 22.1 mirror of `packages/modules/Bluetooth/framework/java/android/bluetooth/`, fetched 2026-11-11 [A20]; the review reports Android 11 the same. `BluetoothDevice.toString()` is redacted only for apps targeting 34+, and those three lines do not use it. | [A20] | Every link, in either role, writes a peer's address to logcat under Haven's pid. No public API avoids it. Rule 15 as written forbids it; the logscan of any radio lane would flag it. An owner decision before M3g, not a discovery on the lane: Q-10. **As researched, 2026-11-12 (§M.1–§M.3):** "no public API avoids it" holds for the calls and not for the lines — from API 30 a process decides what its own log calls write. What the lines hold differs by release, and a GATT server is told of every LE connection of the phone, not of Haven's peers alone. |
| F-14 | **The mesh service shares Haven's one process with the UI and the location service**, and the manifest disables the plugin's `RestartReceiver` (`AndroidManifest.xml`, `android:enabled="false"`). Android's Bluetooth calls throw when the adapter changes state under them. | — | An exception that escapes a mesh callback kills background sharing over relays until a reboot or a launch. §B.1: nothing thrown leaves the mesh thread. |
| F-15 | **`HAVEN_MESH` is a Dart define; a manifest is not gated by it**, and nothing in Gradle reads a define today: `haven/android/app/build.gradle.kts` reads `key.properties` and the environment variable `HAVEN_RELEASE_WRAPPER` (`:126`) and nothing else. | — | From M3g every release would declare three Bluetooth permissions, a `connectedDevice` service and a boot receiver for a feature that is off, with G-4 (Play's declaration) open. §B.8 gates the manifest; Q-12. |
| F-16 | **`mesh_open` adopts and installs under two lock acquisitions** (`api:12967-12973`): it adopts (no engine), then locks again and answers `Off` if the home is no longer `Off`. Harmless today; with `radio_resume` an engine installed in between leaves the session answered `Off` beside a running engine whose hand-off nobody fills, and Dart remembers a resume's answer for the session (`mesh_service.dart:127-136`). | — | §A.3: adopt-or-install under one acquisition. |

Smaller disagreements, each designed as stated: plan §3 pins "Kotlin, Swift
and Rust declarations" — M3 builds the JNI surface only, and the C surface
for Swift is M4's (an unused export is code nobody tests). Plan §7.1's
1022.5 ms advertising interval needs the advertising-set API, a second code
path; M3 uses the one legacy path (§B.3, Q-9). Plan §7.1's "grouped with the
location notification" needs a group key on a notification the plugin owns
— **[U]** whether `flutter_foreground_task` takes one; not built unless it
does. T-STAT-3's iOS clause is M4's. Plan §7.6's "time left" is shown as a
clock time (§E.3, Q-7). Plan §0.4 item 3 does not say that after a reboot
mesh resumes only once the phone has been unlocked (§B.5).

---

## 1. Work units

Ordered so that everything this machine can verify lands first. Each lands
complete with its tests, behind `HAVEN_MESH` (default off).

| Unit | Scope | Proved where |
|---|---|---|
| **M3a** | Rust: the radio's entries over `MESH`, session-less start, output encoding | [L] |
| **M3b** | Rust: the JNI shim, `jni` direct, `unsafe` confinement, parity guard | [L] type-check, [G]; linking and calling: [C], [E] |
| **M3c** | Dart: `MeshRadio` seam, turn-on / turn-off ordering, reconcile | [D] |
| **M3d** | l10n: every string, 13 locales | [D], parity tool, `gen-l10n` |
| **M3e** | UI: button, intro sheet, statistics sheet, Settings row, aura | [D] |
| **M3f** | Kotlin: pure radio logic, JVM tests, the `android-unit` lane | [J], [G]; the lane itself [U] until a pull request runs it |
| **M3g** | Kotlin: `MeshService`, GATT adapters, notices, manifest, channel; and what §M requires before any of them: the process's log lever with its checks, the API 30 answer, the bond watch | [C]; behaviour [E]/[H] |
| **M3h** | The L4 lane: loopback radio first, then netsim | [E] |
| **M3i** | Documents, privacy manifest, device matrix | [G] |

Between M3e and M3g a flag-on Android build shows a button whose start
answers "Couldn't turn mesh on": the channel has no native end yet. No
script or workflow passes the flag. M3d does not wait on Q-6: the sentence
about the Bluetooth name is written (§D) before any copy is translated.

**M3g's first step is done on paper (§M).** Q-10 asked for the inventory
and the levers before any adapter; they are researched and independently
confirmed in source, unproved on any device. What M3g builds because of
them, beside the adapters:

- the log lever of §M.2 — a logger for the process and the floor behind
  it — installed before any Bluetooth object exists, kept for the life of
  the process, checked at every radio start and while the radio runs.
  Where it lives is M3g's to settle within §M.2's constraints;
- the rule of §M.3: no radio below API 30, answered `unsupported`; no
  radio without the lever in force;
- the bond watch of §M.4, and no call or permission that could pair;
- `setDiscoverable(false)` from API 34 (§B.3, §M.7), as designed before;
- nothing for a peer's address type (§M.6), and no renaming of the phone.

M3h owes the proofs of §M.9, and a mesh lane that does not pass on a
capture Haven's process wrote nothing to (§M.8).

---

## A. The radio ↔ engine interface in Rust (M3a, M3b)

### A.1 What the radio must drive

The engine takes `link_up`, `link_down`, `receive`, `sighting`,
`connect_failed` (`eng:550-637`), hands out `Output::{Frame, Close, Connect}`
through `poll_output_ready` (`eng:717`) and names its next timer in
`next_wake_ms` (`eng:753`). Three facts of it bind the radio:

- **A frame is one write.** `receive` takes "one frame … whole and in order"
  (`eng:588`), and an open link accepts only `bytes.len() == sealed_len`
  (`eng:1104`). So a frame is exactly one ATT write or notification, and both
  ends must compute one frame length.
- **A polled frame is a spent frame.** A link frame is sealed by the poll
  that returns it, advancing the link's nonce, and the last chunk's poll
  counts the packet as sent (`eng:1411-1428`). A frame the radio took and did
  not deliver breaks the link. **Invariant R-1: a link is offered in `ready`
  only when its radio can take one frame now; a polled frame is delivered or
  its link is closed.**
- **`poll` runs the timers** (`eng:721-725`), so the radio needs no `advance`.

### A.2 Frame length — one formula, in Rust

`frame_len(att_mtu) = min(att_mtu − 3, 512)`: an ATT write or notification
carries `MTU − 3` bytes, and an attribute value is at most 512 (Core
spec Vol 3 Part F §3.2.9; Android's cap went from 600 to 512 in commit
`f25b742c` — the review's citations, not fetched here). The
engine refuses a link below `MIN_FRAME_LEN` = 48
(`haven-core/src/mesh/frame.rs:33`), so a link needs **ATT MTU ≥ 51**; the
default MTU of 23 gives no link. The radio hands Rust the MTU, never a frame
length, so Kotlin now and Swift in M4 cannot disagree.

| ATT MTU | frame | `PKT` frames per packet | ids per `HAVE` |
|---|---|---|---|
| 23 | — refused | | |
| 51 | 48 | 37 | 1 |
| 185 (typical iOS [U]) | 182 | 7 | 9 |
| 517 | 512 | 3 | 29 |

(`FrameSize`, `frame.rs:57-113`: plaintext = frame − 16; chunk = plaintext − 4.)

### A.3 The entries

In `api`, in the "Bluetooth mesh FFI" section, all `pub(crate)`, none
`async`, none taking a `CircleManagerFfi` or a session:

```rust
/// The longest frame a radio carries: one ATT attribute value.
pub(crate) const RADIO_MAX_FRAME: usize = 512;

/// The radio frame length of a link, or `None` when the MTU carries no link.
pub(crate) const fn radio_frame_len(att_mtu: u16) -> Option<usize>;

/// Starts an engine for a mesh an earlier process left on, with no session:
/// `left_ms` is the service's word, cut to `MESH_ON_MAX_MS`. Starts nothing
/// when one runs, when `left_ms` is 0, or over an engine that ended and is
/// not yet paid for. Answers whether an engine runs.
pub(crate) fn radio_resume(left_ms: u64) -> bool;

/// How long the engine still runs; 0 when none does.
pub(crate) fn radio_left_ms() -> u64;

pub(crate) fn radio_sighting(peer: u64, rssi: i8);
pub(crate) fn radio_link_up(link: u64, central: bool, att_mtu: u16, peer: Option<u64>);
pub(crate) fn radio_link_down(link: u64);
pub(crate) fn radio_connect_failed(peer: u64);
/// A frame longer than `RADIO_MAX_FRAME` closes its link unread.
pub(crate) fn radio_receive(link: u64, frame: &[u8]);

/// The next thing for the radio to do, encoded (§A.5); `ready` beyond
/// `MAX_LINKS` entries is cut.
pub(crate) fn radio_poll(ready: &[u64]) -> Option<Vec<u8>>;

/// Milliseconds until the engine next has work or its deadline passes;
/// `None` when no engine runs.
pub(crate) fn radio_wake_in_ms() -> Option<u64>;
```

Each is `with_mesh(None, |slot, now_ms| …)` and nothing else, except
`radio_resume`. Consequences, all existing behaviour of `with_mesh`
(`api:12900-12921`):

- **The deadline is checked on every entry**, before anything runs. An entry
  that finds it passed drops the engine with every packet and leaves
  `MeshHome::Ended(passed_on)` (`api:12912-12916`).
- **The hand-off is applied on every entry** (`api:12919`), so a location
  the session left reaches the outbox at the radio's next poll, with no Dart
  entry in between.
- **Only these entries run the engine's timers** (R1, after the review of
  M3a): an entry that holds a session applies the hand-off and runs none —
  `MeshEngine::offer` and `purge` name no time — so nothing the engine does
  on air falls at the instant of a relay send (plan §5.1).
- **No clock crosses**: `mesh_clock_ms` is read inside.
- A link with `att_mtu` that gives no frame is answered `Output::Close` by
  the engine (`eng:546-548`, `:568-570`): `radio_link_up` passes 0.

**One function installs or adopts, under one lock acquisition (F-16).**
`with_mesh`'s body after the lock becomes `mesh_run(&mut MeshHome, …)`,
which takes no lock; `with_mesh` is the lock and that. `mesh_open`'s two
acquisitions and its call of `mesh_adopt` become:

```rust
enum Taker { Session { handoff: Arc<Handoff>, left_ms: u64, confirmed: bool, install: bool },
             Radio { left_ms: u64 } }
/// Locks once: a session adopts a running engine (and, `confirmed`, moves
/// its deadline first); with none running, `install` or a radio starts one
/// when `left_ms` is not 0 and no ended engine is owed.
fn mesh_take(taker: Taker) -> MeshStartFfi;
```

`mesh_open` calls it with `install: true`, the session's open
(`api:3255`) with `install: false`, `radio_resume` with `Taker::Radio` and
an empty hand-off (`Arc::new(Handoff::default())`,
`haven-core/src/mesh/handoff.rs:38-41`). A radio never adopts: it leaves a
running engine's hand-off alone. **The pinned set of lock holders stays
four** — `with_mesh`, `mesh_owed`, `mesh_empty` and `mesh_take`, which
replaces `mesh_open` in it — and the gate at `api:25523-25564` is updated
with the name and gains: `mesh_take` names `mesh_home()` once;
`mesh_jni.rs` names none of `MESH`, `mesh_home`, `with_mesh`, `mesh_run`.

### A.4 With no session, exactly

The service runs in Haven's one process — the manifest gives it no
`android:process`, and a guard holds that — so the JNI entries and the
bridge's entries reach the same `MESH`. What an engine can and cannot do
while no session is open in that process (after boot; after the system
killed and restarted it; after the user swiped Haven away, when the engine
that session started lives on, its `Arc<Handoff>` filled by nobody):

| | With no session |
|---|---|
| Links, handshakes, inventory, carried packets | yes — the engine is keyless (`eng:4`) |
| Cover packets at each slot | yes (`eng:877-882`) |
| This device's own location | **no**: nothing seals, the hand-off stays empty. With background sharing on, the location service's isolate opens a session, `CircleManagerFfi::new` adopts the engine (`api:3255`), and its sends are handed off |
| Reading a packet | **no**: up to 8192 wait unread (`Config::unread_packets`, `eng:240`) for the first drive of the next session; the oldest beyond that are dropped |
| "Passed on" | counted in the engine only once a drive has marked a packet not ours (`haven-core/src/mesh/store.rs:427-436`, `:464-490`); what the engine counted is owed to the next session entry, and is lost if the process dies first (plan §7.5) |
| The deadline | enforced: the entry after it drops the engine. **The keys are not deleted** — that needs the session (`api:12990-13003`) — and go at the next open of the store or the next session entry (`haven-core/SECURITY.md` "Every deletion") |
| Keep on | **no** (F-3) |
| A process restart | loses the store, records and unread queue (memory only) |

**The session overrules the service.** A session that opens adopts the
running engine and brings its deadline no later than its own
(`api:12909-12911`). If its mesh is off, that is zero: the engine ends
there, the service's next entry reads `radio_left_ms() == 0` and stops the
radio. So the service's copy of the deadline can keep a keyless engine
relaying only from a process start until the first session entry, and only
when a turn-off stopped Rust and failed to stop the service (§C.3 orders
turn-off against that).

**One process.** A panic is caught at the shim (§A.6); an exception in
Kotlin must be caught as surely (F-14, §B.1).

**Rule 14.** No radio entry takes or reaches a session; `mesh_jni.rs`
names nothing of `api` but `radio_*`. Held by a source gate [L] and, for
T-INDEP-4, by the lane [E].

### A.5 Bytes across the boundary

- **In.** `receive(link, frame: ByteArray)`: the shim reads the array's
  length first and copies only a frame of at most `RADIO_MAX_FRAME`
  (`JNIEnv::convert_byte_array`, at most 512 bytes). **As built (M3b):** for
  a longer one it does not return — that would leave the link up with a frame
  lost — but hands `radio_receive` 513 bytes of nothing, which closes the
  link as the frame itself would. `poll(ready: LongArray)`: length cut to
  `MAX_LINKS` = 32 (`store.rs:42`), then read into a stack array. Rust owns
  every copy; Java keeps its arrays.
- **Out.** `poll` returns a new `ByteArray` or `null`:
  `kind:1 ‖ id:8 big-endian ‖ bytes`, kind 1 = send `bytes` on link `id`,
  2 = close link `id`, 3 = connect to peer `id`. At most 9 + 512 bytes. One
  fixture file of encodings is read by a Rust test and by a Kotlin test.
- `LinkId` and `PeerRef` are Kotlin's numbers (a counter each, never an
  address — §B.2), passed as `jlong` and reinterpreted, never interpreted.

### A.6 The shim (M3b)

`haven/rust_builder/src/mesh_jni.rs`, `#[cfg(any(target_os = "android",
test))]`, nine exports for `com.oblivioustech.haven.mesh.MeshNative`:

```
resume(leftMs: Long): Boolean        leftMs(): Long
sighting(peer: Long, rssi: Int)      linkUp(link: Long, central: Boolean, attMtu: Int, peer: Long)
linkDown(link: Long)                 connectFailed(peer: Long)
receive(link: Long, frame: ByteArray)
poll(ready: LongArray): ByteArray?   wakeInMs(): Long      // −1: none
```

- **Logic-free.** Each export converts its arguments, calls one `radio_*`
  function, converts the answer. `peer < 0` is `None`; `rssi` and `attMtu`
  are clamped into their types. **As built (M3b):** also, a negative
  `leftMs` is none left; a link's number crosses bit for bit; a peer below
  zero is no peer in every call that names one — `sighting` and
  `connectFailed` make no entry for it — so that no peer is dialled that a
  link could not be bound to (the review of M3b; Kotlin numbers both from
  zero); a JNI call that fails (a null array, an array the JVM cannot allocate) is
  answered as no engine would answer, with the exception it left cleared;
  and the second parameter of an export is typed `JObject` — the receiver,
  since `MeshNative` implements `MeshEngineApi` (§B.1), or the class if the
  methods are made static: the same pointer, never read. The exports, their
  JNI descriptors and Rust types are pinned in
  `haven/rust_builder/fixtures/mesh_radio_exports.txt`.
- **Two files, after the review of M3b.** The allowance on `mod mesh_jni`
  covers the whole module, so inside it the compiler reports neither an
  `unsafe` block nor a second exported symbol (`#[export_name]`, a bare
  `extern fn`), and a guard that reads names was the only control. So
  `mesh_jni.rs` holds `use`s and the nine exports and nothing else, each
  export one call that hands its parameters on, in the order declared, to
  the function of `mesh_radio.rs` named for it; the conversions, the guarded
  call and their tests are in `mesh_radio.rs`, under the deny. The guard
  reads every line of the first file and holds it to exactly that, and the
  Rust gate `every_export_is_one_guarded_call` reads it too. **After the
  re-review of `bd7ff48` and the review of `de152a2`:** the guard takes
  comments out with a lexer of its own that knows strings, raw strings and
  character literals (a `//` or `/*` in a string hides nothing), takes a
  `use` on one line with no rename and no glob, takes no quote in the file
  but an export's `"system"`, fails `path =` and `include!` anywhere in the
  crate's source, and pins the attribute lines above the two modules'
  declarations in `lib.rs`, with neither name anywhere else in that file.
  **What the guard is:** a reader of text, not the compiler. It stops
  ordinary and careless erosion and makes a deliberate one conspicuous in
  review; it is no proof against code written to be hidden from it, it
  reads nothing outside `src/`, and it does not see a lint level set
  elsewhere (`[lints]`, `RUSTFLAGS`, `--cap-lints`, a `build.rs` — today
  the crate has no `[lints]` table and no `build.rs`, and the one
  `RUSTFLAGS` cargokit passes an Android build is a library search path;
  nothing pins that). The check that no source gets past
  is on the artifact: **owed by M3g**, the `nm -D` step is to hold the
  library's exported `Java_*` symbols to exactly the nine of the fixture.
  The seven
  calls that take no array are run against the engine on the host
  (`the_calls_a_jni_export_forwards_reach_their_entries_each_argument_in_its_place`).
  `receive`, `poll` and every export still need a JVM.
- **`unsafe`.** With `jni` 0.21's wrappers no export needs an `unsafe`
  block; the one thing the `unsafe_code` lint fires on is `#[no_mangle]`.
  `lib.rs` gains `#![deny(unsafe_code)]`, with `#[allow(unsafe_code)]` on
  `mod frb_generated` and `mod mesh_jni` and nowhere else. `api.rs` and
  `test_keyring.rs` compile under the deny (M3b: the host's test and
  non-test builds). Guard `check_mesh_radio.sh` [G] — one script for every
  textual fact of the radio, its checks named where they apply: `unsafe`,
  `no_mangle` and `extern "` appear under `haven/rust_builder/src` in
  those two files only.
- **Panics.** Unwinding out of an `extern` function aborts the process,
  and the process is also the relay path's (F-14). `api` gains
  `fn radio_guarded<T>(none: T, call: impl FnOnce() -> T + UnwindSafe) -> T`
  (`catch_unwind`); every export is its argument conversion, then
  `radio_guarded(…)` around the one `radio_*` call, then the answer's
  conversion. A panic under the lock poisons it, and the next `mesh_home`
  drops that engine (`api:12882-12890`); the service then reads
  `leftMs() == 0` and stops, with the stopped notice. **As built (M3b):** a
  panic that held no lock leaves the engine, which was in no call. A caught
  panic is silent in every build: the guard logs nothing, because the
  mesh's part of the bridge writes no log line (a gate, and a claim of the
  privacy manifest), and Android discards what the panic hook prints. The
  entries and the guard are dead code in a build that has neither the shim
  nor the tests — every target but Android — and each carries
  `expect(dead_code)` under exactly that condition.
- **No callbacks, no stored `JavaVM`, no global reference, no thread
  attach**: every call is made by a Java thread and returns.
- **Thread.** One: the service's `HandlerThread` (§B.1). Never the main
  thread. The lock is a `std::sync::Mutex` held for one engine call; the
  bridge's entries hold it as briefly (`api:12900`, taken in no `async` fn).
- **Loading.** `MeshNative`'s initializer calls
  `System.loadLibrary("rust_lib_haven")`, as `Keyring` does; idempotent.
- **A JNI name mismatch is a run-time error**, not a compile error. Two
  things hold it: the same guard's parity check [G] — the
  `external fun`s of `MeshNative.kt` and the `Java_…MeshNative_*` exports
  agree in name, arity and types, and the status and kind constants agree —
  and, in `build-check.yml`, `nm -D` on the built library lists the nine
  symbols [C]. **As built (M3b):** the guard holds the exports to the fixture;
  its Kotlin half lands with `MeshNative.kt` (M3g), read against the same
  fixture, and the `nm -D` step with the first unit that builds the radio
  for Android. **As built (M3f):** the interface `MeshNative` is to
  implement, `MeshEngineApi`, is held to the fixture — the nine names, each
  with its JNI descriptor, and no other method — by the JVM test
  `theEngineInterfaceIsTheNineExportsOfTheFixture` [J]. `cross-check.yml`'s Android step is a plain `cargo check`: it
  denies no warning, so dead code that exists only in the Android
  configuration would pass it — owed to the same unit.
  **As built (M3g, unit 1; §N.7):** the exports are eleven, with the log
  lever's `leverInstall` and `leverHolds`; the two interfaces,
  `MeshEngineApi` and `LogLever`, are held to the fixture by
  `theTwoNativeInterfacesAreTheElevenExportsOfTheFixture`; the `nm -D`
  step is `scripts/ci/check_mesh_radio_symbols.sh` in `build-check.yml`,
  which also holds the keyring's one `Java_*` symbol (N-3) and the
  library's `liblog` imports; and the Android step of `cross-check.yml`
  is clippy with warnings denied. Neither step has run on a runner.
- **`jni` logs** (found in M3b): its wrappers write a `trace` line naming
  the JNI function they call — a fixed word, no value. The bridge's logger
  admits Haven's two targets alone and caps the level below `trace`, so none
  is emitted; a service that calls an export before `init_app` has run has
  no logger at all.
- **Type-checked here.** The module also compiles under `cfg(test)`, so the
  host test build checks every signature against `jni` [L]. Calling an
  export needs a JVM: [E] or [H] only.

### A.7 Dependencies

`haven/rust_builder/Cargo.toml` gains `jni = "0.21"` under
`[target.'cfg(target_os = "android")'.dependencies]` and under
`[dev-dependencies]` (for the host type-check). `Cargo.lock` of
`rust_builder` gains `"jni"` in `rust_lib_haven`'s dependency list and no
package. `haven-core/Cargo.lock` and `tooling/soak/Cargo.lock` do not
change: neither depends on `rust_builder`. `check_mdk_supply_chain.sh` and
`check_lockfile_universe.sh` read the MDK, OpenMLS, SQLCipher and nostr
crates and are untouched. `check_generated_bridge_pinned.sh` pins the
bridge against `api.rs`, so M3a re-pins it; **[U]** that the codegen skips
`pub(crate)` items — `scripts/regenerate_frb.sh` must leave
`frb_generated.rs` and the Dart bindings unchanged. dependency-auditor on
`jni` 0.21.1 before M3b lands.

**As built (M3b).** The lockfile gained the one edge and no package (525
before and after). The codegen lists `radio_guarded` in the not-`pub`
comment of `haven/lib/src/rust/api.dart` at the next regeneration and
changes nothing else. RustSec's advisory database (commit `fd6f398`,
2026-11-11) has no entry for `jni`, `jni-sys`, `cesu8`, `combine`, `walkdir`
or `same-file`; `cargo-audit` was not run where this was built.

### A.8 Tests

All [L], in `api`'s `mesh_ffi_tests`, on the existing `Phone` harness (a
second engine wired to the one in the slot, `api:24364`).

| Test | Proves | Mutation it kills |
|---|---|---|
| `the_radio_carries_a_packet_between_this_phone_and_another` | handshake, inventory and a packet cross through `radio_link_up` / `radio_receive` / `radio_poll` in both roles | `central` inverted; a poll that ignores `ready`; a wrong kind byte |
| `the_frame_length_of_a_link_is_one_formula` | 23 → none, 50 → none, 51 → 48, 185 → 182, 517 → 512, 65535 → 512 | `− 3` dropped; the 512 cap dropped |
| `a_frame_longer_than_the_radio_carries_closes_its_link` | 513 bytes reach no engine code and the link's close is polled | the bound removed |
| `with_no_engine_every_radio_entry_does_nothing` | `Off` and `Ended`: no input changes the home, poll is `None`, wake is `None`, left is 0 | an entry that installs an engine |
| `the_radio_starts_an_engine_with_no_session_and_carries_with_it` | `radio_resume` then a packet passes phone → this → phone | `mesh_take` refusing a radio |
| `a_session_that_opens_takes_over_the_engine_the_radio_started` | `mesh_resume` answers `AlreadyOn`, the store is kept, the deadline is the nearer of the two, the session's next send is emitted | adoption that replaces the engine |
| `whichever_of_a_session_and_the_radio_asks_first_there_is_one_engine_and_the_session_feeds_it` | both orders: radio then session, session then radio; the session is never answered `Off` beside a running engine, and a radio never replaces a session's hand-off (F-16) | `mesh_take` split back into two acquisitions (with the source gate); a radio taker that adopts |
| `a_session_whose_mesh_is_off_ends_the_engine_the_radio_started` | after that session's first entry `radio_left_ms() == 0` and no key was stored | `with_mesh` ignoring a zero `session_left_ms` |
| `the_radio_cannot_keep_an_engine_past_twelve_hours_nor_start_over_one_that_ended` | `left_ms = u64::MAX` gives `MESH_ON_MAX_MS`; after `Ended`, `radio_resume` is false until a session entry paid | the cap; the `Off`-only check |
| `a_radio_entry_after_the_deadline_drops_the_engine_and_the_next_session_entry_deletes_the_keys` | the split of §A.4 | a radio entry that leaves the engine; a session entry that skips `mesh_off` |
| `what_passed_through_with_no_session_is_read_by_the_first_drive` | a fellow member's packet carried session-less is taken in and counted once by `mesh_drive_driven` (T-BG-3 at the bridge) | the unread queue cleared at adoption |
| `a_location_left_by_the_session_goes_out_at_the_radios_next_poll` | the hand-off is applied by a radio entry | `apply` moved out of `with_mesh` |
| `the_radio_entries_take_no_session` (source gate) | no `radio_*` body names `CircleManagerFfi`, `session`, `.await`; `mesh_jni.rs` names of `api` only `radio_*` | a shim that calls `mesh_start` |
| `an_output_is_encoded_as_the_fixture_says` | the three encodings, byte for byte, against the shared fixture | a field order change on one side |
| `a_call_that_panics_under_the_guard_answers_its_no_engine_value_and_leaves_no_engine` | `radio_guarded` itself, on the host: no export can be called without a JVM | the `catch_unwind` removed |
| `every_export_is_one_guarded_call` (source gate) | each `Java_…` body in `mesh_jni.rs` holds one `radio_guarded(` and names no `radio_*` outside it | an export that calls the engine bare |
| `the_calls_a_jni_export_forwards_reach_their_entries_each_argument_in_its_place` (as built, after the review of M3b) | the seven calls that take no array, on Java's types, against the engine: `resume` true exactly when an engine runs; `leftMs`, and `wakeInMs` with its −1; a sighting of its peer at its strength; `linkUp` under its link's number, bound to its peer, in its role, over its MTU; `connectFailed` of its peer; `linkDown` of its link; a peer below zero makes no entry | a link's number taken from `peer`; `resume`'s answer inverted; a call that makes another call's entry |

`the_engine_lock_is_taken_only_where_nothing_can_be_awaited` (four
holders, `mesh_take` for `mesh_open`)
and `the_mesh_entries_log_nothing_and_format_nothing` (now also reading
`mesh_jni.rs`) are extended, not loosened.

**Not provable here:** that the exports link and are callable from Kotlin
([C], [E]); that `CLOCK_BOOTTIME` counts a sleeping phone's time ([H]).

---

## B. Android `MeshService` (M3f, M3g)

### B.1 Shape

Package `com.oblivioustech.haven.mesh`. The split is what makes Kotlin
testable without a device: **pure classes import nothing of `android.*`**
and take every platform effect through an interface; adapters are thin and
hold no decision. **As built (M3f):** the pure classes are a package of
their own, `com.oblivioustech.haven.mesh.core`, in
`kt/mesh/core/`, and the compiler holds the rule in place of a guard's
list: `haven/android/mesh-jvm` is a Gradle build whose one source
directory is that package and whose classpath has no Android SDK, so an
Android import there does not compile (run in the mutation pass: plan
§16). Its warnings are errors, the extended ones included. It is not part
of the app's build and changes nothing in it.

| Pure — [J] | Holds |
|---|---|
| `MeshEngineApi` | the nine calls of §A.6 as an interface; `MeshNative` is its one real implementation |
| `RadioOutput` | `decode(ByteArray)`: the encoding of §A.5 |
| `MeshRadioCore` | **the one operation queue**: links, pending connects, in-flight frames, the pump |
| `PeerTable` | Bluetooth address → `PeerRef`, 64 entries — the engine's own `max_peers` (`eng:264`) — least recently seen evicted. **As built (after the review of M3f):** not the least recently seen. A full table forgets one picked at random (`SecureRandom`; injected in tests) among the addresses neither being dialled nor of a link this phone dialled (the engine's rule; a link this phone took has no address in the table), and an address not yet known whose sighting is below the engine's `rssi_floor` (−85) gets no number and is not told to the engine; a known address's weak sighting is told. The engine forgets at random "so whoever advertises under many addresses keeps nobody out" (`eng` `make_room`) and ignores an unknown weak peer; a table that forgot its oldest undid both — one advertiser rotating 64 addresses, at any distance, pushed every honest address out between two of its sightings, the engine's connect met a forgotten number, failed and backed off, and outgoing links stopped |
| `DeadlinePolicy` | from time left: nothing / reminder / stop |
| `StartPolicy` | at a service start, from (Bluetooth permission held, engine's time left, stored copy): run, resume, or stop with which notice |
| `PermissionMatrix` | per API level: what to ask, whether it may search |
| `ScanPolicy` | restart before 30 min; no more than one start in 6 s |
| `MeshRadioConstants` | every mode, interval and cap of §G, one site |
| `RadioPort`, `MeshThread` (as built, M3f) | the interface of §B.2; the wrapper below, and the one stop of §B.5 |

| Adapter — [C], behaviour [E]/[H] | Wraps |
|---|---|
| `MeshService` | lifecycle, `startForeground`, the `HandlerThread`, receivers |
| `GattServerAdapter`, `GattClientAdapter` | `BluetoothGattServer`, `BluetoothGatt` |
| `AdvertiserAdapter`, `ScannerAdapter` | `BluetoothLeAdvertiser`, `BluetoothLeScanner` |
| `MeshNotices` | the channel and four notifications |
| `MeshPrefs` | the on flag, the deadline copy, the notice copy |
| `MeshReceiver` | boot, package replaced, the alarm, notification actions |
| `MeshChannel` | the method and event channels in `MainActivity` |

**One thread.** Every platform callback — GATT callbacks arrive on binder
threads — posts to the service's `HandlerThread`; `MeshRadioCore` and every
`MeshNative` call run there and nowhere else. No lock, no coroutine.

**Nothing thrown leaves that thread (F-14).** Android's Bluetooth calls
throw when the adapter changes under them — `SecurityException`,
`IllegalStateException`, `DeadObjectException`, a null advertiser with
Bluetooth off — and an uncaught exception here ends the process that also
publishes to relays. Every handler message and every platform callback
body runs inside one wrapper, `MeshThread.run { … }`: `try`, and on any
`Throwable` the radio is stopped as a stop the user did not make (§B.5) —
the stopped notice, the flag cleared — and nothing is rethrown or logged.
The service's own lifecycle methods use the same wrapper. A guard holds
that every `override fun on…` of an adapter and every post to the handler
goes through it.

**As built (M3f): `MeshThread` is pure, and it is also the stop.**
`MeshThread(running, steps, notice)`: `run { … }` drops the body once the
thread has stopped; else runs it, and stops — with the notice — when it
threw anything or when `running()` (the core's) is false after it.
`stop(notice)` runs each of `steps` (the radio down, the flag and the copy
cleared, the notification removed, the service ended), then `notice`
unless it is the user's stop, **each step in its own `try`**: what made
the stop — a dead adapter — throws again in the steps of it, and the flag
and the notice must not depend on that. A stop is final: one `MeshThread`
serves one start, and the service makes a new one for a start that comes
after. Nothing caught is kept or rendered. The `HandlerThread`, and the
guard that every callback is inside `run`, are M3g's.

### B.2 `MeshRadioCore`

```kotlin
interface RadioPort {                       // implemented by the adapters
    fun connect(peer: Long)                 // → onLinkUp(central) or onConnectFailed
    fun close(link: Long)
    fun send(link: Long, frame: ByteArray): Boolean   // false: not accepted
    fun holdAwake(ms: Long)                 // timed wake lock
    fun wakeAt(inMs: Long)                  // handler timer + the one alarm
}
class MeshRadioCore(engine: MeshEngineApi, port: RadioPort, clock: () -> Long) {
    fun onSighting(address: String, rssi: Int)
    fun onLinkUp(link: Long, central: Boolean, attMtu: Int, address: String?)
    fun onLinkDown(link: Long)
    fun onConnectFailed(address: String)
    fun onFrame(link: Long, frame: ByteArray)
    fun onSendDone(link: Long, ok: Boolean)
    fun onWake()
    fun stopRadio()                          // Bluetooth off, or the service ends
    val running: Boolean                     // false once the engine is gone
}
```

**As built (M3f), where the interface above could not be built as
written or says too little:**

- `RadioPort.connect(address: String)`, not `connect(peer: Long)`. The
  port has no way from a peer's number to a device: `PeerTable` is the
  core's. The core keeps the pending dial (address → the engine's number)
  until the port answers with that address, so a peer forgotten meanwhile
  is still bound to its link or reported failed.
- `RadioPort.scan()` and `RadioPort.remind()` are added, and the core
  holds `ScanPolicy` and `DeadlinePolicy`: the scan's restart and the
  reminder are terms of the one wake the core asks for (§B.3, §B.5), and
  a term somebody else must act on is a decision in an adapter. The
  adapters start the server and the advertiser themselves, and the scan
  only when told.
- `MeshRadioCore.startRadio()` is added (Bluetooth on, the adapters up),
  the counterpart of `stopRadio()`. A core is made with the radio down;
  with Bluetooth off the service calls `onWake()` once, which arms the
  deadline's wake.
- `MeshRadioCore.onConnected(link)` is added: a central connected to the
  server and is not a link yet. Without it §B.4's four unlinked
  connections have no input. It is for inbound connections only: an
  outgoing one has its own 25 s (§B.3). The adapter numbers links, inbound
  ones from this call on.
- `stopRadio()` asks nothing of the port but the deadline's wake: the
  engine is told every link down and every pending dial failed, and the
  adapters close their own objects wholesale (§B.6).
- While the radio is down, sightings, connections and link-ups that still
  arrive are dropped; the engine is not polled, and the wake asked for is
  the reminder's or the deadline's alone.
- `MeshRadioCore` takes a fourth argument, the picker `PeerTable` forgets
  by (§B.1), a `SecureRandom` unless a test hands one in.

**What the core asks of the adapters (for M3g).**

- One thread; every callback and handler message inside `MeshThread.run`;
  one `MeshThread` a start (a stopped one drops every body).
- **The stop's steps cancel the alarm after the radio-down step.**
  `stopRadio()` asks for the deadline's wake even when the service's own
  stop calls it, so an alarm cancelled first is armed again behind it.
- One counter of link numbers across both roles, never used twice. An
  inbound connection is numbered at `onConnected` and keeps its number.
- **Exactly one `onLinkUp` a connection.** A second for the same number
  replaces the link's state, and a late completion of the first could then
  free the second before its own frame completed.
- `onConnected` only for a central that connected to Haven's server: the
  core cancels after 10 s whatever it is told of.
- Every `connect(address)` answered once, by `onLinkUp(central = true, …,
  address)` or `onConnectFailed(address)`.
- `send` answers false only when no completion follows; true is followed
  by exactly one `onSendDone`.
- `close` of a number the port does not know does nothing: the core closes
  what it refused at its caps and what the engine closes.
- `scan()` ends the scan that runs and starts one; where
  `PermissionMatrix.canSearch` is false it does nothing.
- `wakeAt` replaces the wake before it; 0 is "post now".
- At a service start: `startRadio()` with Bluetooth on, else `onWake()`
  once; after a Keep on, `onWake()`.

The engine's schedule runs here and nowhere else: no entry that holds a
session runs an engine timer (§A.3), so a slot that fell due waits for
`onWake` or the next radio event.

Every input ends in `pump()`:

1. `engine.leftMs() == 0` → `running = false`; the service stops (§B.5).
2. Until `poll(ready)` answers `null`, at most 64 outputs a pump (then it
   re-posts itself): `Frame` → `port.send`; `Close` → `port.close`;
   `Connect` → `port.connect`, or `connectFailed` at once when the peer is
   no longer in `PeerTable`.
3. `port.wakeAt(engine.wakeInMs())`.

**As built (M3f).** Step 1 is the first thing an input does, before its
own engine call, not the first step of the pump after it (T-AUTO-4): with
no time left an input makes that one call and nothing else, and once
`running` is false an input makes none. `running` also goes false when
`wakeInMs()` answers −1 (an engine that went in the middle of the input:
a panic the shim caught) and when a poll answers bytes that are no output
— then the engine is told every link down first. The re-post of step 2 is
`wakeAt(0)`. The wake of step 3 is the earliest of the engine's, the next
re-offer or give-up of a frame, the next cancel of an unlinked
connection, the scan's restart and the reminder. What is done with a
`Close` for a link that has a frame in flight is: closed at once (the
engine queues a close behind its own `BYE`, and a `BYE` lost with the
connection changes nothing for the peer, which sees the disconnect).

- **`ready`** is the links that are up and have no frame in flight. One
  frame per link is in flight until its completion callback
  (`onCharacteristicWrite` for a central's write without response,
  `onNotificationSent` for a peripheral's notification — "an application
  must wait for this callback to be received before sending additional
  notifications" [A17]; that a no-response write is paced by
  `onCharacteristicWrite` the same way is **[U]**).
  bitchat serializes the same way (`bc:BluetoothPacketBroadcaster.kt:536-600`).
- **R-1.** A `send` the platform refuses is offered again, the same bytes,
  after 50 ms, three times; then the link is closed and `linkDown` told.
  Never a new poll for that link in between. A frame whose completion
  callback has not come in 10 s closes its link: a callback that never
  arrives would otherwise leave the link not ready for ever. **As built
  (M3f):** a completion that reports failure (`onSendDone(ok = false)`)
  closes the link the same way — the text above does not say; and wherever
  a link is dropped the engine is told before the port is asked to close,
  so that a `close` that throws leaves the engine no link the table has
  forgotten (found by `aRadioPortThatThrowsStopsTheRadioAndNothingEscapes`).
- **Addresses never cross.** `PeerTable` numbers an advertiser when it is
  first seen; an inbound link is told with no peer, because a central's
  address is not the address it advertises under.
- **Wake lock** only for `onFrame` and `onLinkUp`:
  `holdAwake(min(wakeInMs + 250, HOLD_CAP_MS))` (§G). Not for sightings.
  **As built (M3f):** `wakeInMs` there is the engine's own, not the
  earlier of the core's timers; and only for a frame of a link the table
  holds and a link it admitted. **After the review of M3f:** and not when
  the engine's close of that same link came out of the same pump — a link
  it does not admit, a frame it rejects — so that trying again buys no
  wakefulness (`aLinkTheEngineClosesAtOnceHoldsNoLock`). This narrows Q-13
  and does not settle it: a linked peer sending frames the engine takes
  still holds the phone awake.

### B.3 Radio

- **GATT table.** One service, one characteristic (write without response
  + notify), its client configuration descriptor. Nothing else is Haven's;
  a connected peer also sees the system's services, Device Name among
  them, and every other app's (F-6). The service
  and characteristic UUIDs are 128-bit values drawn once at implementation,
  kept as two `Long` constants each and built at run time — a canonical-form
  UUID in a tracked file fails `check_no_committed_secrets.sh` (plan §13),
  the standard descriptor's included.
- **Advertisement.** The service UUID, and the Flags field where the
  stack adds one. Below API 34 it does: 21 of 31 bytes. From API 34
  `setDiscoverable(false)` [A15] takes Flags away — the stack adds it
  only to an advertisement that is connectable and discoverable — and
  the 18-byte UUID field is the whole payload (§M.7 [V]; the draft had
  21 bytes on every level). No name,
  no TX power, no service data, no scan response. bitchat puts a peer id in
  service data (`bc:BluetoothGattServerManager.kt:404`); Haven does not.
  Legacy `startAdvertising`, `ADVERTISE_MODE_LOW_POWER`, connectable, no
  timeout, on every API level the radio runs on (Q-9; §M.3).
  `setDiscoverable(false)` is there so that a peer connecting in cannot
  read Device Name unencrypted (F-6) — the stack's rule from 14 QPR3,
  as read in a mirror, and not its rule on a controller with neither
  extended nor multi advertising, where the setting is ignored (§M.7).
  Whether an iPhone
  finds an advertisement without Flags is **[U]**, recorded for M4.
  Start failures
  (`bc:BluetoothGattServerManager.kt:418-429` lists them): too many
  advertisers and internal error are retried at the next Bluetooth-on or
  service start, never in a loop; unsupported means central-only.
- **Scan.** One `ScanFilter` on the service UUID, `SCAN_MODE_LOW_POWER`,
  all matches, no report delay. A filtered scan keeps running with the
  screen off; an unfiltered one does not (plan §2.3 [V]). A scan that has
  run 30 minutes is taken down a step — to `SCAN_MODE_FORCE_DOWNGRADED` on
  Android 15 (`le_scan/ScanManager.java:1408-1440`, the review's reading of
  a mirror, **[U]** here), to an opportunistic scan before — and a sixth
  start in 30 seconds is silently ignored [A8, secondary]. `ScanPolicy`
  restarts the scan at 25 minutes and never twice in 6 s. **The restart
  time is one of the alarm's terms (§B.5)**: a phone alone has no input
  and its engine wakes only for emission slots, so a restart checked only
  at a pump could never come. bitchat adds a watchdog because a scan can
  die with no callback (`bc:BluetoothGattClientManager.kt:312-346`); the
  25-minute restart covers that, late.
- **Outgoing link.** `connectGatt(context, false, callback, TRANSPORT_LE)`
  → `requestMtu(517)` → on `onMtuChanged`, `discoverServices` → enable
  notifications and write the descriptor → on `onDescriptorWrite`,
  `onLinkUp(central = true, mtu)` → `requestConnectionPriority(LOW_POWER)`.
  MTU before discovery, as bitchat (`bc:BluetoothGattClientManager.kt:475`,
  `:499-515`). Android 14+ asks for 517 whatever is passed [A4]. Each step
  waits for its callback; a step that fails, or the whole not done in 25 s,
  is `disconnect` + `close` + `connectFailed`.
- **Status 133** (and any failed `onConnectionStateChange` before the link
  is up): `close()`, one retry 300 ms later on the handler, then
  `connectFailed`. The engine's back-off, 60–90 s (`eng:262-263`), spaces
  later dials. **`close()` after every disconnect, always** — a leaked
  client interface is what exhausts Android's GATT clients
  (`bc:BluetoothGattClientManager.kt:493`).
- **Incoming link.** The server's `onConnectionStateChange` is not a link:
  it also fires for connections other apps and this app's own client
  make — on Android 16 the stack tells every registered application of
  every LE link of the phone and the server side passes it on unfiltered
  (§M.1 [V], one release read; observed on none). Such a connection is
  never a link, and what the platform logs of it is §M.1's. A link is up when a
  central enables notifications on Haven's characteristic and its MTU is at
  least 51: `onLinkUp(central = false, mtu, address = null)`. It is down at
  disconnect or when notifications are disabled.
- **Incoming write.** `preparedWrite`, a non-zero offset, a write that
  wants a response, a write from a device with no link: refused, and a
  linked device is closed. Else `onFrame`.
- **Close.** `cancelConnection` on the server, `disconnect` then `close` on
  a client. **[U]** whether `cancelConnection` ends a connection the server
  did not itself `connect` to; the lane answers.
- **No bonding (§M.4).** No attribute of Haven's carries an encrypted,
  authenticated or signed permission; nothing calls `createBond`, reads a
  characteristic or writes one with a response; the transport is
  `TRANSPORT_LE`. The one write that has a response is the descriptor's,
  and the platform answers a peer's refusal of it (ATT 0x05 or 0x0F) by
  asking again with authentication, before Haven's callback runs — a
  hostile peer can raise a pairing dialog that way, and any central can
  ask to pair. The lever: the running service registers for
  `ACTION_BOND_STATE_CHANGED`, and a device Haven is linked or linking
  with that enters `BOND_BONDING` is closed at once, as a failed step
  above. Whether that stops the pairing before keys are exchanged, and
  whether the dialog shows anyway, is unproved (§M.9).
- **Bluetooth off / no advertiser.** §B.6.

### B.4 Native limits

Beside the engine's (§H): at most 4 devices connected and not yet linked,
each cancelled 10 s after it connected; a fifth is cancelled at once. At
most `max_outgoing` + `max_incoming` links in `MeshRadioCore`'s table (8,
`eng:254-255`), since the engine closes what it does not admit. **As built
(M3f):** a link beyond the eight is closed and the engine is not told of
it (`aLinkBeyondTheEnginesEightIsClosed`); if it was one the engine had
asked for, the engine is told the connect failed.

### B.5 Lifecycle, deadline and notices

- **Start** (`onStartCommand`, any cause — the channel, a sticky restart,
  boot). `StartPolicy` first, on what the service reads itself: **the
  Bluetooth runtime permissions** (`checkSelfPermission`; from API 31) —
  `startForeground` cannot be trusted to refuse, because `connectedDevice`
  is also satisfied by a declared `CHANGE_NETWORK_STATE`,
  `CHANGE_WIFI_STATE` or `NFC` [A1], which a plugin's manifest may merge
  in. Then `startForeground`, type `connectedDevice`, in the wrapper: a
  refusal (`SecurityException`, `ForegroundServiceStartNotAllowedException`)
  is a stop. Then: `left = engine.leftMs()`; if 0, `left = min(stored
  deadline − wall clock, 12 h)` and `engine.resume(left)`; still no engine
  → stop. Else store `wall clock + engine.leftMs()` as the deadline copy,
  arm the alarm, start the radio if Bluetooth is on. `START_STICKY`.
  **[U]** whether a sticky restart may call `startForeground` on Android
  12+: reports disagree; the wrapper is the answer either way.
  **As built (M3f):** the order is one pure function,
  `StartPolicy.start(permission, engine, storedDeadline, wallClock,
  foreground)`: no permission → a stop, with `foreground` not called and
  the engine not touched; then `foreground()`; then the engine. It asks
  for no engine when the stored deadline is not ahead (the text above
  would call `resume` with nothing left and leave the refusal to Rust). It
  answers the deadline copy to store, or null — a stop the service makes,
  through `MeshThread.stop(notice = true)`. The session-less resume (Q-2)
  is one `if` of it. **As researched, 2026-11-12:** the rule of §M.3
  comes before the permission — the API level, then the lever of §M.2
  installed and checked — and before any Bluetooth object. `StartPolicy`
  gains that input, and its [J] test, with M3g.
- **The deadline is enforced by the engine**, read at every pump. The copy
  in `MeshPrefs` serves only a restart with no engine and the alarm. Like
  the session's own across a restart (`haven-core/SECURITY.md`,
  "Residuals"), it is the wall clock's word: a clock set back while Haven
  is not running lengthens it, never past twelve hours from the start.
- **One alarm**, `setAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP, …)`, to
  `MeshReceiver`, at the earliest of the engine's wake, the scan restart,
  the reminder and the deadline. Inexact, so no permission (exact alarms
  are denied by default from Android 14 [A4]); in Doze at most one per
  nine minutes per app [A7]. While the processor is awake the handler
  timer serves the engine on time.
- **Reminder** when 30 minutes or less are left: one notification with
  **Keep on** (Q-3). **At the deadline** the service stops and the stopped
  notice takes the reminder's id, so no Keep on outlives it. **As built
  (M3f):** `DeadlinePolicy` gives the reminder once, and again after a
  Keep on took the time left back over 30 minutes; a service that starts
  with less than that left gives it at its first input.
- **Taps.** Keep on and the tap that opens the statistics sheet are
  `PendingIntent.getActivity` on `MainActivity`, each with an extra — never
  a broadcast that then starts the activity: an app targeting Android 12+
  "can't start activities from services or broadcast receivers that are
  used as notification trampolines" [A19].
- **Stop.** By the user (the channel's `stop`): radio down, flag and copy
  cleared, notification removed, no notice. By anything else — deadline,
  engine gone, start refused, permission missing, a caught `Throwable`:
  the same, **and the stopped notice**. Mesh is never left on with no
  radio and no notice. **A stop the service made is final**: the flag is
  cleared, so nothing restarts the radio until the user turns mesh on
  (§C.4).
- **Boot and update.** `MeshReceiver` on `BOOT_COMPLETED` and
  `MY_PACKAGE_REPLACED`: flag set, deadline ahead, permission held →
  `startForegroundService`, in the wrapper. Both are exemptions from the
  background-start rule [A5], and `connectedDevice` is not among the types
  a boot receiver may not start [A3]. **After a reboot mesh resumes only
  once the phone has been unlocked**: `BOOT_COMPLETED` is sent after the
  first unlock and the preferences are in credential-encrypted storage.
  Plan §0.4 item 3 does not say so.
- **Permission revoked.** Android ends the process; at the restart
  `StartPolicy` finds it missing; stopped notice. The keys stay until the
  next open of Haven, where reconcile turns mesh off (§C.4).
- **Swiped away.** Nothing: the service has no `stopWithTask`.
- **Persistent notification (F2).** Own channel, low importance, title
  "Haven", fixed text, no count, no identifier. On Android 14+ the user can
  dismiss it except while the phone is locked or by "Clear all" [A4]; the
  service posts it again at every `ACTION_SCREEN_OFF` (the same id: an
  update when present, a new post when dismissed — **[U]**, M0 spike (c)
  was never run). **With notification permission denied (D-9)** the
  service still starts — "Apps don't need to request the
  `POST_NOTIFICATIONS` permission in order to launch a foreground service"
  [A6] — and its notice shows in the Task Manager only [A6]; no reminder
  and no stopped notice are seen.

### B.6 Bluetooth off

`ACTION_STATE_CHANGED`, registered by the running service. Turning off:
every link is told down, GATT objects are closed, the notification reads
"paused". On: server, advertiser and scan start again. The service stays
in the foreground throughout (F-4), holds no wake lock and arms only the
deadline alarm. The twelve hours keep running. **As built (M3f):** "the
deadline alarm" is the reminder's time while the reminder is still to
come, then the deadline's: a paused mesh is reminded too. The engine is
not polled meanwhile, so none of its timers wakes the phone.

### B.7 Notice copy

The channel's `start` and `sync` carry six strings, localized in Dart in
the language the user chose in Haven: channel name, on, paused, reminder
(with the turn-off time already formatted), Keep on, stopped. `MeshPrefs`
keeps them so that a notice posted with no Dart isolate has text. They are
fixed copy and a time; nothing identifying.

### B.8 Permissions and manifest

| API | Asked at run time | Notes |
|---|---|---|
| 31+ | `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` — one "Nearby devices" dialog [A2] | `BLUETOOTH_SCAN` declared `neverForLocation`: "some BLE beacons are filtered from the scan results" [A2]; **[U]** that a plain service-UUID advertisement is not one |
| 30 | nothing | `BLUETOOTH`, `BLUETOOTH_ADMIN` are install-time. Searching needs fine location granted, Location switched on, and, from a service, background location [A2] |
| 29 | — **the radio is not started (§M.3)** | as API 30. Kept as the record of what the level would have needed |
| 23–28 | — **the radio is not started (§M.3)** | as API 30 with coarse or fine location, and no background permission. Kept as the record |

**The radio starts on API 30 and later, and nowhere else (§M.3).** Below
it nothing lets a process keep the platform's Bluetooth lines out of its
own log (§M.2), so under the owner's condition (Q-10) the radio is not
started: `start` answers `unsupported`, before a foreground start and
before any Bluetooth object. Phones on Android 6 to 10 cannot use the
mesh; the rest of Haven runs there as before (`minSdk` 23). The draft
had the mesh on every level from 23; `PermissionMatrix` (M3f) still
answers for 23–29, which no start reaches.

Mesh never asks for location. On API 30 a phone without it advertises,
accepts links and cannot search: the status line says so.

**The mesh manifest is in no build that has the flag off (F-15).** Every
entry of the mesh — the three Android 12 permissions (`BLUETOOTH_SCAN` with
`usesPermissionFlags="neverForLocation"`), `BLUETOOTH` and
`BLUETOOTH_ADMIN` with `maxSdkVersion="30"`,
`FOREGROUND_SERVICE_CONNECTED_DEVICE`, `<uses-feature
android.hardware.bluetooth_le required="false">`, `<service
.mesh.MeshService foregroundServiceType="connectedDevice"
exported="false">`, `<receiver .mesh.MeshReceiver exported="false">` with
the two boot actions — is in `app/src/mesh/AndroidManifest.xml`, and the
main manifest gains nothing. `build.gradle.kts` merges that file into a
variant only when the build's defines carry `HAVEN_MESH=true`, read from
the `dart-defines` project property the Flutter tool hands Gradle
(base64, comma-separated — **[U]**, not read in the Flutter tool's source
today) and added through AGP's per-variant manifest sources (**[U]**, API
from memory; AGP is 8.11.1, `settings.gradle.kts`). One switch, so the
Dart flag and the manifest cannot disagree. The Kotlin of the package
still compiles into a flag-off build and is inert there: no component, no
permission, and no Dart code that calls the channel. `WAKE_LOCK`,
`RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS` and `FOREGROUND_SERVICE`
are declared already.

Held by `check_mesh_radio.sh` [G] — the main manifest names no Bluetooth
permission, no `connectedDevice` and no mesh component — and in
`build-check.yml` [C]: the merged manifest of the default build has none
of them, and the mesh lane's flag-on build has all. **As built (M3f):**
the guard reads every `AndroidManifest.xml` under `app/src` but
`src/mesh/`'s — main, debug and profile today — and fails the words
`bluetooth`, `connectedDevice` and `mesh` in any case, a comment
included. The mesh's own manifest, the Gradle switch and the [C] half are
M3g's.

Play requires each foreground-service type to be declared in the Console
with a description and a video [A13 — **[U]**, the page could not be
fetched]; whether phone-to-phone qualifies as `connectedDevice` is G-4,
console-side, open. With the gate, G-4 holds up the mesh's release and no
other (Q-12).

### B.9 Logs (Rule 15)

**Haven's mesh package logs nothing**: no `Log`, no `println`, in any
build. A caught `Throwable` is dropped, never rendered; a
`BluetoothDevice` is never interpolated. `check_native_log_allowlist.sh`
already fails any unlisted call; `check_mesh_radio.sh` adds that the
allowlist has no row under `mesh/`. **As built (M3f):** it also fails, in
any `.kt` under a `mesh/` directory of `app/src`, a `Log.`, `Timber.`,
`println(`, `print(`, `printStackTrace(`, `System.out`, `System.err`,
`Logger` or `logging`, in every build type, and a canonical UUID there or
in the JVM tests. `aRadioPortThatThrowsStopsTheRadioAndNothingEscapes`
plants an address in what is thrown and reads both standard streams empty.

**Android logs for it (F-13); from API 30 Haven's process need not
carry it (§M).** The framework's GATT classes run in Haven's process and
write to logcat, at debug level in every build and in both roles, the
address of whatever connected — in full on every release read up to
15 QPR2, its last two bytes from 16 (§M.1) — with the log's own
timestamp. A GATT server
is told of every LE connection of the phone, so the addresses are not
Haven's peers' alone. The draft said here that Haven cannot turn that
off. That holds for the calls — no other public API makes a link — and
for every level below API 30. From API 30 a process decides what its own
log calls write (§M.2): Haven installs a logger that writes nothing but
lines under its own tags, with the process's minimum priority raised
behind it, before any Bluetooth object exists, and starts no radio where
that is not in force (§M.3). The platform also prints whatever a callback
of Haven's throws, and an uncaught exception leaves the process for the
system's crash records whatever the lever does: §B.1's wrapper is what
keeps both empty.

What this costs Haven's own diagnostics, and what stays whatever Haven
does — the system's Bluetooth process logs the same links under its own
pid — is §M.8. Who can read a process's log: someone with the phone and
`adb` (USB debugging on and the computer authorized), a bug report the
user shares, and apps holding `READ_LOGS` — protection level
`signature|privileged|development` — which from Android 13 need a
consent at each use ([V], §M.1); an ordinary app is given only its own
uid's entries ([V] at
Android 6.0; "since Android 4.1" is from memory, **[U]**). Decided by
the owner, on conditions: Q-10.

### B.10 Tests

[J], in `haven/android/app/src/test/kotlin/…/mesh/`, JUnit 4 and
`kotlin-test` (test-only Gradle dependencies; no Robolectric), against a
fake `MeshEngineApi` and a recording `RadioPort`.

**As built (M3f).** The tests are in
`haven/android/mesh-jvm/src/test/kotlin/…/mesh/core/`, in the JVM build of
§B.1, not under `app/src/test`: the app's own unit-test source set stays
empty and the app gains no dependency. Run with
`bash scripts/ci/run_mesh_jvm_tests.sh` (a JDK and Gradle; no Android SDK),
which fails unless every test ran. The clock is injected; no test sleeps or
reads the time. Every test of the table exists under its name, and the
guard pins the names. Three rows are narrower than the table has them,
because the other half is an adapter's: the "stopped notice" and "the flag
is cleared" of `aRadioPortThatThrows…` and `aStartWithout…` are a
`MeshThread`'s steps and notice, recorded by the test — that the service
hands it the real ones is M3g's; `theAdvertisementIsTheServiceUuidAlone`
holds what has a switch (no name, no power level, not discoverable,
connectable, no timeout) — that no service data and no scan response are
set has no constant to hold it, and is the advertiser adapter's source;
`theRadioModesComeFromOneSite` pins the values, the one site is the
guard's. Added: `theEngineInterfaceIsTheNineExportsOfTheFixture` (§A.6),
`thePeerTableHoldsSixtyFourAndForgetsTheLeastRecentlySeen`,
`aLinkBeyondTheEnginesEightIsClosed` (§B.4),
`aLinkTheEngineClosesIsClosedAndALinkLostIsToldDown`,
`anEngineThatAnswersNoWakeIsGone`,
`aStopTheUserDidNotMakeIsAStopWithTheNoticeAndIsFinal` (§B.5) and
`anEngineWhoseTimeIsUpStopsTheServiceWithTheNotice` (T-AUTO-2). After the
review of M3f: `aFloodOfAddressesDoesNotPushOutAPeerUnlessItIsPicked`,
`anAddressBeingDialledOrLinkedIsNeverForgotten`,
`aWeakAddressNotYetKnownTakesNoPlaceAndIsNeverToldToTheEngine`,
`aWeakSightingOfAKnownAddressIsToldToTheEngine`,
`aCompletionWhileARefusedFrameWaitsClosesItsLink` and
`aLinkTheEngineClosesAtOnceHoldsNoLock`; the table's own test is now
`thePeerTableHoldsSixtyFourAndForgetsOnePickedAmongThoseNotHeld`.
The script fails unless the tests that ran are the tests the sources
declare, by name; it cannot tell a test whose body was emptied.

| Test | Proves | Mutation it kills |
|---|---|---|
| `aPolledFrameIsSentOrItsLinkIsClosed` | R-1 over refused sends | a re-poll after a refusal; a dropped frame |
| `aLinkWithAFrameInFlightIsNotReady` | `ready` excludes it until `onSendDone` | `ready` = all links |
| `everyInputChecksTheDeadlineBeforeAnythingElse` (T-AUTO-4) | with `leftMs() == 0` no `poll`, no `send`, `running` false | the check moved after the poll |
| `anAddressNeverReachesTheEngine` | every engine argument is a table number; an inbound link has no peer | passing `address.hashCode()` |
| `aConnectForAPeerNoLongerKnownFailsAtOnce` | no dial, `connectFailed` told | a dial of a stale device |
| `thePumpStopsAtItsBudgetAndComesBack` | 64 outputs, then a re-post | an unbounded loop on the mesh thread |
| `theWakeIsTheEnginesAndTheLockIsCapped` | `wakeAt(wakeInMs)`; `holdAwake ≤ HOLD_CAP_MS`; none for a sighting (T-PWR) | an untimed lock |
| `bluetoothOffTellsEveryLinkDownAndSendsNothing` | §B.6 | links left up in the engine |
| `unlinkedConnectionsAreCappedAndTimedOut` | §B.4: a fifth unlinked connection is cancelled at once, each of the four after 10 s on the injected clock | either cap removed |
| `aRadioPortThatThrowsStopsTheRadioAndNothingEscapes` | every `RadioPort` method and the engine throwing in turn: the wrapper stops the radio with the stopped notice, the flag is cleared, no exception leaves (F-14) | a callback run outside the wrapper |
| `aFrameWhoseCompletionNeverComesClosesItsLink` | 10 s on the injected clock, then `close` and `linkDown` | the timeout removed |
| `theScanRestartIsATermOfTheAlarm` | with no input at all the wake asked for is no later than the scan's 25 minutes | the restart left to a pump |
| `aStartWithoutTheBluetoothPermissionIsAStopWithTheNotice` | `StartPolicy`: permission missing, deadline passed, engine owed — each a stop; a stop the service made clears the flag | trusting `startForeground` to refuse |
| `outputsDecodeAsTheFixtureSays` | the shared fixture, and that a short or unknown output stops the radio | a field order change |
| `theScanIsRestartedBeforeThirtyMinutesAndNeverTwiceInSixSeconds` | `ScanPolicy` | either bound |
| `theReminderComesOnceAtThirtyMinutesAndTheStopAtZero` (T-AUTO-1, -2) | `DeadlinePolicy` | a second reminder; a stop that is not a notice |
| `whatIsAskedAndWhetherItCanSearchPerApiLevel` | `PermissionMatrix`, API 23, 28, 29, 30, 31, 35 | location asked for; `neverForLocation` levels crossed |
| `theAdvertisementIsTheServiceUuidAlone` (T-PRIV-5, plan half) | the advertise plan has no name, power or data field | `includeDeviceName` |
| `theRadioModesComeFromOneSite` (T-PWR-1) | the constants | — |

`check_mesh_radio.sh` [G], the Android checks: the mesh manifest declares
the service with no `android:process`, the type `connectedDevice`, the
receiver not exported, `neverForLocation`; the main manifest has none of
it (§B.8); the pure classes import no `android.`; `MeshRadioConstants` is
the one file naming a scan, advertise or priority constant; every adapter
callback and handler post goes through `MeshThread.run`; no canonical
UUID. **As built (M3f):** in the guard — no manifest of a flag-off build
names the mesh (§B.8), no log call and no UUID (§B.9), the one site of the
modes, no allowlist row, and the JVM tests by name with none ignored. Not
in it: that the pure classes import no `android.`, which the compiler
holds (§B.1); the mesh manifest's own shape and the `MeshThread.run`
check, which have nothing to read until M3g.

**Not proved by any of this:** every adapter. That `connectGatt`, the GATT
server, advertising and scanning behave as §B.3 says is [E] if the netsim
lane exists and [H] otherwise.

---

## C. The Dart seam to the radio (M3c)

### C.1 Interface

`haven/lib/src/services/mesh_radio.dart`:

```dart
enum MeshRadioPermission { granted, denied, deniedForGood }
enum MeshRadioStart { started, noPermission, unsupported, failed }
enum MeshRadioState { stopped, running, paused }   // paused: Bluetooth is off
enum MeshRadioAction { openStats, keepOn }

class MeshRadioStatus {                // no Bluetooth address, no count
  final MeshRadioState state;
  final bool wanted;                   // the service's own flag: it was
                                       // started and has not stopped itself
  final bool canSearch;                // false: findable only (§B.8)
}

abstract interface class MeshRadio {
  Future<MeshRadioPermission> permission();
  Future<MeshRadioPermission> requestPermission();   // the system dialog
  Future<bool> bluetoothOn();
  Future<String?> bluetoothName();                   // shown, never kept (§E.2)
  Future<void> openBluetoothSettings();
  Future<MeshRadioStart> start(MeshNoticeCopy copy); // Bluetooth off: starts paused
  Future<void> sync(MeshNoticeCopy copy);            // deadline or language changed
  Future<void> stop();                               // also clears the service's copy
  Future<MeshRadioStatus> status();                  // live
  Stream<MeshRadioStatus> get changes;               // pushed
  Stream<MeshRadioAction> get actions;               // a notice was tapped
}
```

`AndroidMeshRadio` implements it over `haven.app/mesh_radio` (methods) and
`haven.app/mesh_radio_state` (events); every platform failure becomes
`failed` or a `MeshRadioException` with fixed text, nothing logged.
`meshRadioProvider` is `null` unless `meshEnabledProvider` and the platform
is Android (M4 adds iOS): **the button exists only where it is non-null.**
`test/lints/mesh_entries_behind_flag_test.dart` gains the channel names:
named in `mesh_radio.dart` alone.

`bluetoothName()` is `BluetoothAdapter.getName()`: "the friendly Bluetooth
name of the local Bluetooth adapter. This name is visible to remote
Bluetooth devices"; it needs `BLUETOOTH_CONNECT` for an app targeting
Android 12+, the install-time `BLUETOOTH` below, and is `null` on error
[A18]. It crosses the channel to be shown and is held in no provider,
preference, log or Rust call.

**S1** of `aura` §7 is `status().state == running`, pushed on `changes`
and read live at resume. `MeshStatsFfi.on` is not S1.

### C.2 Turning on

`MeshNotifier.turnOn()`:

| Step | Failure | Unwind | Copy |
|---|---|---|---|
| 1. `radio.requestPermission()` | denied | none | `meshErrorNoPermission` (+ Open settings when `deniedForGood`) |
| 2. the first time: the name is shown (§E.2), now that it can be read | the user backs out | none | — |
| 3. `radio.bluetoothOn()` | off | none | `meshErrorBluetoothOff` |
| 4. `mesh.start()` — deadline, keys, engine | `MeshStartFfi.off` or a throw | none: Rust stored nothing (`api:13025-13028`) | `meshErrorStartFailed` |
| 5. `radio.start(copy)` | anything but `started` | **`mesh.stop()`** — engine, keys, deadline | by the variant |
| 6. state read; S1 arrives on `changes` | | | |

The brief for this design orders it "store deadline → engine → permissions
→ service start". This puts the stateless steps first: a refusal then has
nothing to unwind, and no key is at rest while a system dialog is on
screen, where a process death would leave keys with no radio until the
next start. Q-4. The notification permission is asked before step 1 and its
answer is ignored (D-9).

If the unwind in step 5 throws, the keys remain; reconcile (§C.4) turns
mesh off at the next resume, and the deadline bounds it.

### C.3 Turning off, keeping on

- **Off:** `radio.stop()`, then `mesh.stop()`, the second whatever the
  first did. Radio first, so the service's copy is gone before the engine
  is: a failure between the two leaves keys until reconcile, never a radio
  with the store saying off.
- **Keep on:** `mesh.keepOn()`, then `radio.sync(copy)`, which makes the
  service re-read `leftMs()`, re-store its copy and re-arm.
- **Logout:** `radio.stop()` before `wipe_all_mls_state`, which empties the
  engine (`api:1215-1217`), and again by the wipe's retry at the next
  launch, so the service's copy cannot outlive the identity; without
  either the service's next entry finds no engine and stops itself.

### C.4 One queue, and reconcile

**`turnOn`, `turnOff`, `keepOn` and reconcile run one at a time, in one
queue in `MeshNotifier`.** Without it a turn-off races itself: the service
reports `stopped` while `mesh.stop()` has not run, a reconcile on that
event reads "store on, radio stopped" and starts the radio again, the
service writes its deadline copy again and then stops with the notice of a
stop nobody asked for — and a process death in that window leaves a copy
that resumes a keyless relay at boot, after the user said off.

- A reconcile asked for while a user's transition is queued or running is
  dropped. Every transition ends with one reconcile of its own.
- Reconcile is a pure function of what it reads, run at the shell's
  start-up, at every resume and on every `changes` event:

| Store (`stats.on`) | Radio | Do |
|---|---|---|
| on | running or paused | nothing |
| on | stopped, `wanted`, permission held | `radio.start`; anything but `started` → `mesh.stop()` and `meshStoppedNotice`, once — never a second start |
| on | stopped, otherwise | `mesh.stop()`; `meshStoppedNotice` once |
| off | running or paused | `radio.stop()`, then `mesh.stop()` |
| off | stopped | nothing |
| not read | any | nothing |

`wanted` is what makes a stop the service made final: it cleared its flag,
so the second row does not apply and the notice it posted stays true. The
fourth row's `mesh.stop()` is for an engine that went while the store
still says on — after a panic `mesh_home` leaves `Off` and the keys
(`api:12882-12890`), and nothing else would delete them before the
deadline.

### C.5 Tests [D]

`test/providers/mesh_radio_flow_test.dart`, fake `MeshService` and fake
`MeshRadio`, each recording its calls and able to hold a call open while
the test feeds events:

- `a_refused_permission_stores_nothing` — steps 4 and 5 never called.
- `bluetooth_off_stores_nothing`.
- `a_radio_that_does_not_start_takes_the_keys_back` — `stop` called once
  after `start`; kills an unwind skipped for one variant.
- `mesh_is_on_only_when_both_started`.
- `turning_off_stops_the_radio_first_and_the_engine_regardless`.
- `a_stopped_event_in_the_middle_of_a_turn_off_starts_nothing` — the
  fake radio emits `stopped` while `mesh.stop()` is held open; `radio.start`
  is never called. Kills a reconcile outside the queue.
- `a_running_event_in_the_middle_of_a_turn_on_stops_nothing`.
- `a_radio_that_will_not_come_back_is_asked_once_and_mesh_goes_off` —
  row 2 with a failing start: one `start`, one `mesh.stop()`, one notice,
  whatever events follow. Kills the loop.
- `a_stop_the_service_made_is_not_undone` — store on, radio stopped,
  `wanted` false: `mesh.stop()`, no `start`.
- `an_engine_that_went_takes_its_keys_with_it` — row 4 calls `mesh.stop()`.
- `transitions_run_one_at_a_time_in_the_order_asked`.
- `keeping_on_tells_the_service_the_new_deadline`.
- `reconcile_is_this_table` — every row; kills each cell.
- `a_logout_and_its_retry_both_clear_the_services_copy`.
- `with_the_flag_off_or_on_another_platform_there_is_no_radio`.
- `every_failure_has_fixed_copy` — each `MeshRadioStart` maps to an ARB
  key; no exception text reaches a widget (Rule 8).
- `nothing_is_logged_by_a_start_a_stop_a_failure_or_the_name` — log
  capture, with a planted address in the fake's exception and a planted
  Bluetooth name (Rule 15).
- `android_mesh_radio_maps_each_channel_answer` — mock message handler; a
  `MissingPluginException` is `failed`.

---

## D. Strings (M3d)

Every key gets a `description`; brand and unit conventions as
`haven/lib/l10n/README.md`. `commonCancel`, `commonRetry` and
`commonOpenSettings` exist and are reused. English:

| Key | English |
|---|---|
| `meshName` | Bluetooth mesh |
| `meshButtonOff` / `meshButtonOn` / `meshButtonOnConnected` / `meshButtonPaused` | Bluetooth mesh, off / Bluetooth mesh, on / Bluetooth mesh, on, connected to a nearby phone / Bluetooth mesh, paused, Bluetooth is off |
| `meshButtonHintTurnOn` / `meshButtonHintTurnOff` | turn on / turn off |
| `meshIntroTitle` | Bluetooth mesh |
| `meshIntroWhat` | Even with no internet, mesh passes your circles' encrypted location updates from phone to phone over Bluetooth. Your phone also carries other people's encrypted packets, which it can't read. |
| `meshIntroNearby` | Anyone nearby can tell that this phone has Haven's mesh on, and can follow its radio signal. They can't read your location or see your circles. |
| `meshIntroConnected` | A phone that connects to yours can tell which encrypted packets your phone sent, about how old each is, and when your phone is asleep. It can't tell what they say or whose they are, unless it's in one of your circles. |
| `meshIntroName` | Phones that mesh connects with can read your phone's Bluetooth name and see which other Bluetooth services it offers. |
| `meshIntroNameIs` | Your phone's Bluetooth name is "{name}". |
| `meshBluetoothSettings` | Bluetooth settings |
| `meshIntroRemoved` | While you're offline, someone removed from a circle can still read your updates until your phone learns they were removed. |
| `meshIntroBridge` | When you're online, your phone passes a nearby circle member's update on to your circle's relays. A relay can then tell that a member of that circle is offline near you. |
| `meshIntroClosed` | Mesh keeps running when Haven is closed. With Haven closed and background sharing off, it carries other people's packets but doesn't send or read your circles' locations until you open Haven. |
| `meshIntroBattery` | Mesh uses more battery. |
| `meshIntroAutoOff` | Mesh turns itself off after 12 hours. If notifications are allowed, you get a reminder 30 minutes before. |
| `meshIntroStats` | Hold the mesh button to see what it has done. |
| `meshIntroTurnOn` | Turn on |
| `meshTurnedOn` / `meshUndo` | Bluetooth mesh is on / Undo |
| `meshErrorNoPermission` | Mesh needs the Nearby devices permission. |
| `meshErrorBluetoothOff` | Turn on Bluetooth to use mesh. |
| `meshErrorUnsupported` | This phone can't use Bluetooth mesh. |
| `meshErrorStartFailed` | Couldn't turn mesh on. Try again. |
| `meshErrorStopFailed` | Couldn't turn mesh off. Try again. |
| `meshStoppedNotice` | Bluetooth mesh turned off. |
| `meshStatsTitle` | Mesh activity |
| `meshStatsSinceOn` / `meshStatsAllTime` | Since turned on / All time |
| `meshStatsFromCircles` | Updates from your circles |
| `meshStatsPassedOn` | Encrypted packets passed on |
| `meshStatsCell` | {row}, {column}: {count} |
| `meshStatsFootnote` | Passed-on packets can't be read by this phone. They include other people's updates and cover traffic. |
| `meshStatusConnected` / `meshStatusSearching` / `meshStatusFindable` / `meshStatusPaused` / `meshStatusOff` | Mesh is on · connected / Mesh is on · searching / Mesh is on · can be found, can't search / Mesh is paused · Bluetooth is off / Mesh is off |
| `meshTurnsOffAt` | Turns off at {time} |
| `meshKeepOn` | Keep on for 12 hours |
| `meshStatsReset` / `meshStatsResetTitle` / `meshStatsResetBody` / `meshStatsResetConfirm` | Reset counts / Reset mesh counts? / All four counts go back to zero. / Reset |
| `settingsMeshTitle` / `settingsMeshOn` / `settingsMeshOff` | Bluetooth mesh / On / Off |
| `meshNoticeChannel` | Bluetooth mesh |
| `meshNoticeOn` / `meshNoticePaused` / `meshNoticeStopped` | Bluetooth mesh is on / Bluetooth mesh is paused — Bluetooth is off / Bluetooth mesh has turned off |
| `meshNoticeReminder` / `meshNoticeKeepOn` | Bluetooth mesh turns off at {time} / Keep on |

**The disclosure tells plan §0.4** — `meshIntroNearby` item 6,
`meshIntroConnected` items 7, 7a and 8, `meshIntroRemoved` 7b,
`meshIntroBridge` 11a (T-BRIDGE-12), `meshIntroClosed` 3, `meshIntroAutoOff`
9a, `meshIntroBattery` 5 (no figure: none is measured). It does not say
re-identification "from the set of packets it holds" in those words; "can
follow its radio signal" is the plain form, and the reviewer of the copy
must judge whether that tells it. `meshIntroName` tells F-6 in both
directions — "connects with", not "connects to yours" — and is written
now, so no translated copy waits on Q-6; where the name can be read,
`meshIntroNameIs` shows the name itself.

No plural form is used: counts stand in table cells, and the time left is a
clock time (Q-7).

**Process, per `CLAUDE.md`:** one translating agent per language for the 12;
a separate, independent reviewing agent per language (correctness,
readability, accessibility, natural register, RTL for ar/fa/ur); then
`scripts/ci/arb_parity_check.dart` and a warning-free `flutter gen-l10n`.
`meshNoticeOn`, `meshNoticePaused` and `meshNoticeStopped` are one-line
notification text and say so in their descriptions, as
`fgsNotificationPaused` does. `test/lints/fgs_notification_localized_test.dart`
is the model for a test that every string the channel carries comes from
`AppLocalizations`.

---

## E. UI (M3e)

### E.1 `MeshButton`

`haven/lib/src/widgets/map/mesh_button.dart`. `MapShell.buildLayers` gains
`Widget? meshButton`, placed after `map` and before the dim overlay, so the
expanded sheet covers it as it covers the map controls, and `Widget? aura`
after the sheet and before the banners (`aura` §3). Its rect is
`meshButtonRect(shellSize, viewPadding)` (`aura` §2): 48 × 48, `left = 16 +
viewPadding.left`, `bottom = collapsed sheet height + 16`, the same in
right-to-left. The collapsed fraction 0.12 moves to one public constant
that `map_page.dart`, the sheet and the geometry all read.

- **Tap:** off → turn on (the intro sheet first, the first time — a flag
  in `shared_preferences`, cleared at logout); on → off, at once, with no
  confirmation.
- **Long press:** haptic, statistics sheet. Also a `CustomSemanticsAction`
  labelled `meshStatsTitle`, the Settings row, and `MeshRadioAction.openStats`.
  No `Tooltip`.
- **State, never colour alone:** two icons (the off one struck through), a
  filled against an outlined surface, and a dot when `linked`. Semantics:
  `button`, `toggled`, the label of the state, `onTapHint`,
  `onLongPressHint`.
- **Large text:** the button has no text. **Reduced motion:** `aura` §5.
- A change the user did not make — the deadline, Bluetooth off, the
  reconcile's stop — is announced with `SemanticsService.sendAnnouncement`
  (`meshNoticeStopped`, `meshNoticePaused`); the user's own tap is not.

### E.2 Intro sheet

A modal bottom sheet, scrollable, each paragraph of §D its own `Text`
(so a screen reader steps through them), `meshIntroTurnOn` and
`commonCancel`. Shown once; the same text is reachable from the statistics
sheet afterwards.

**The name (F-6, Q-6).** Under `meshIntroName` the sheet shows
`meshIntroNameIs` with what `radio.bluetoothName()` answers, and a
`meshBluetoothSettings` button that opens the system's Bluetooth settings,
where the name is changed — so the user sees exactly what a nearby phone
will read before turning mesh on. On Android 12+ the name cannot be read
before the Nearby devices permission is granted, so the first time it is
shown as its own step after the grant and before anything is stored
(§C.2 step 2); from then on in the intro text and in the statistics
sheet. A `null` name shows the general sentence alone. Never logged,
never stored.

### E.3 Statistics sheet

`meshStatsTitle`; the two-by-two table, each cell one semantics node read
by `meshStatsCell`; the footnote; one status line from `stats` and the
radio's status; `meshTurnsOffAt` with the deadline formatted by the
locale's time format; `meshKeepOn`; `meshStatsReset` behind a confirm
dialog; the Bluetooth name line and its settings button (§E.2).

**It drives when opened**: `MeshNotifier.drive()` then `refresh()`. A device
with no circle due to publish drives the mesh at no tick (plan §16,
"Residuals of M2g-2a"), so without this "passed on" would lag by however
long the sheet stayed closed. While open it refreshes on every radio
`changes` event and once a minute.

### E.4 Settings row

In `settings_page.dart`, after Location, where a radio exists: title
`settingsMeshTitle`, subtitle on or off, opens the statistics sheet.

### E.5 Aura

Built as `aura` has it; M3e supplies its inputs and changes nothing of it.
The wave starts on the observed change of S1 to running (§C.1), never on
the tap. **S2**: a publish pass that returned, for at least one circle, an
answer past the send-time check — accepted, refused, unreachable, the
three clock answers, mesh-only — while S1 holds and `stats.linked`. `aura`
§7 words this "sent or sealed for the mesh"; taken as accepted alone it
would show no ripple with no internet, which is when the mesh carries. The
bridge has no "handed to the mesh" bit, so a ripple can show for a location
the hand-off dropped (the ring's lock was held, `haven-core/SECURITY.md`
"The one hand-off"). Stated, not fixed: an exact bit is a new field on a
fieldless FFI enum.

### E.6 Tests [D]

`test/widgets/map/mesh_button_test.dart`,
`test/widgets/mesh/mesh_stats_sheet_test.dart`,
`test/pages/map_shell_mesh_test.dart`, pumped through
`pumpLocalized`, plus `aura` §8's own list.

- T-STAT-3: long press, the semantics action, the Settings row and a
  `MeshRadioAction.openStats` each open the one sheet; the sheet reads in
  order through the semantics tree; the button and `MapControls` do not
  overlap in ar, at 200 % text, at 320 × 568, and in landscape with a left
  inset.
- `there_is_no_button_where_there_is_no_radio` — flag off; flag on, iOS.
- `the_button_is_under_the_expanded_sheet_and_above_the_map` — hit test.
- `the_state_is_told_without_colour` — icon and semantics differ per
  state under a greyscale filter of the theme.
- `the_first_tap_shows_every_disclosure_paragraph_and_nothing_starts_before_turn_on`
  — T-BRIDGE-12 is the assertion that `meshIntroBridge` is among them.
- `opening_the_sheet_drives_the_mesh_once`.
- `the_bluetooth_name_is_shown_before_anything_is_stored_and_kept_nowhere`
  — the name step precedes `mesh.start`; backing out stores nothing; a
  `null` name shows the general sentence; no provider holds the name
  after the sheet closes.
- `a_reset_asks_first_and_zeroes_all_four`.
- `keep_on_moves_the_time_shown`.
- `a_stop_the_user_did_not_make_is_announced_and_the_users_own_is_not`.
- T-STAT-2 at the widget: totals shown after an off and on are not below
  those before. The store's half exists [L]:
  `what_was_passed_on_is_added_to_the_totals_when_mesh_goes_off`
  (`api:25386`).
- T-NOTIF-3, Dart half: with the notification permission refused, turn-on
  completes and the button shows on.

ui-ux-reviewer before M3e lands (plan §10).

---

## F. CI (M3f, M3h)

### F.1 What exists and what M3 adds

| Lane | Proves | Status |
|---|---|---|
| `android-unit.yml` (new; stage 1 of `ci.yml`) — `./gradlew :app:testDebugUnitTest` | every [J] test; and that all Kotlin compiles | feasible **[U]**: cargokit hooks the Rust build to `merge…NativeLibs` only (`haven/rust_builder/cargokit/gradle/plugin.gradle:166-170`), which a unit-test task does not need — read, not run. **As built (M3f):** the lane does not build the app. It runs `scripts/ci/run_mesh_jvm_tests.sh` — `gradle test` in `haven/android/mesh-jvm` — on a JDK 21 with the Gradle distribution the app's wrapper pins, fetched and checked against the pinned SHA-256 (the tree has no `gradlew`). It proves every [J] test and that the pure package compiles with no Android; **not** that any other Kotlin compiles — that is `build-check.yml`'s, from M3g. The script was run where M3f was built; the workflow has never run. After the review of `de152a2`: the lane restores the shared Gradle cache read-only before the script, which `check_gradle_build_hardened.sh` now requires of it as of every Gradle build site, and the script fails unless the tests that ran are, by name, the tests the sources declare |
| `build-check.yml` (exists) + `nm` step | the nine JNI symbols are in the library [C] | feasible |
| `cross-check.yml` (exists) | `mesh_jni.rs` compiles for Android [C] | feasible |
| `repo-guards.yml` (exists) + one step | `check_mesh_radio.sh` | feasible; run here too |
| `e2e-mesh-android.yml` (new), **loopback** | §F.2 | feasible on the evidence of the existing lanes |
| `e2e-mesh-android.yml`, **netsim** | §F.3 | **unproven** |

### F.2 Loopback first

A `RadioPort` that is a socket, in `app/src/debug/` only — absent from a
release APK by source set, held by a guard — chosen by a debug-only launch
extra. The real `MeshService`, `MeshRadioCore`, `MeshNative`, the shim and
the engine run on the one emulator the existing lanes boot (API 34, x86_64,
`google_apis`, `-no-window`, `e2e-android.yml:313-322`); two host peers,
each a Rust binary running the real `MeshEngine` (`tooling/mesh-peer`, a
new tooling crate), reach it through `adb forward`. Plan §9.1 L5 already
plans this shape for iOS.

It proves, per push: **T-RELAY-E2E** (peer A → app → peer B, "passed on"
rises by one), **T-REL-1** (a peer drops mid-packet; the packet arrives
after it returns), **T-NOTIF-1** and **-2** (present when on, absent when
off, back after a cancel at the next screen-off — through `dumpsys
notification`), **T-NOTIF-3**, **T-AUTO** with the reminder and the stopped
notice (the deadline shortened by a debug-only extra, never a sleep),
**T-INDEP-4** (app swiped away with mesh on and sharing off; the catch-up
worker and a relaunch obtain the session), **T-LOG-1** for Haven's own
lines (logscan over the lane's sinks, with planted peer numbers) — **as
researched, 2026-11-12: not as written.** The real `MeshService` runs
here, so the lever of §M.2 is in force from the first turn-on and
Haven's process writes no line for a scanner to read; what the lane must
show instead is §M.8's requirement — and that
the flag-on build's merged manifest has every mesh entry (§B.8).

**Of the Kotlin, JNI and engine pipeline only**, and labelled so in the
lane: **T-PERF-3** (M packets inside a budget declared in
`e2e_lane_budget.manifest` — no radio's throughput is in it) and
**T-BG-1** (forced idle; process killed and the service back; reboot with
mesh on; reboot with the permission revoked and no crash — no Bluetooth
stack is asleep or restarted in it).

**The relay path with mesh on (plan §9.3, T-INDEP).** "The existing
core-flow, background-catch-up and foreground-service lanes run their
relay oracles once more with mesh on and a peer present": `e2e-android.yml`,
`e2e-background-catchup.yml` and `e2e-fgs-publish.yml` each gain a `mesh`
input that builds with the flag, turns mesh on and attaches one loopback
peer, and are called once more from `ci.yml` with it. Their oracles are
unchanged; a red there is the mesh moving the relay path. Three more
emulator jobs a push. Each of the three runs the log scanner over its
captures today (`HAVEN_LOGSCAN`), and the scanner's positive controls
are lines Haven's process writes; from the turn-on that process writes
none (§M.8). Every read of Haven's log in them — a control, or an oracle
that takes its signal from a line, which was not surveyed for this
revision — is found and given another signal before the lane counts.

**It proves nothing about Bluetooth**: no adapter of §B.1 runs, and so
nothing of F-13 either — the framework's own log lines appear only with a
real stack.

### F.3 Netsim: what is known

- The emulator's virtual controller is netsim; emulators of one host user
  share one medium, and Bumble joins it as `android-netsim` [A14 —
  **[U]**, the page could not be fetched; from a search summary].
- One report, emulator 37.1.11, API 35, arm64, on a Mac: an emulator
  advertised, ran a GATT server and was read by a second emulator and by a
  Bumble 0.0.236 peer; "Android's emulator needed no flags"; Linux, KVM and
  hosted runners "not measured"; MTU and more than two devices not
  measured; an advertiser is invisible to a second central while one is
  connected [A9].
- One report, emulator 36.4.9, API 34, two emulators in a KVM container:
  pairing passed 15 of 15; one boot took over 180 s; "37.2.13 crashes at
  start on some hosts" [A10]. Whether that runner was GitHub-hosted is not
  stated.
- **Not known from any source found:** a GitHub-hosted runner; `-no-window`
  with netsim; a negotiated MTU of 517; two inbound and two outbound links
  at once; snapshot boot; the peripheral role on the API 34 x86_64 image
  Haven's lanes use. This is G-1 and G-6, unanswered.

So the netsim half starts as a `workflow_dispatch` spike that answers
exactly the list of plan §10 M0 (a), and becomes a per-push lane only at 50
green runs. It adds Bumble — Python, from PyPI — to CI: pinned by hash, and
dependency-auditor's to review. What only it can prove: **T-PRIV-5 on the
air** — the advertisement's bytes, and, **in both directions (Haven dialled,
and Haven dialling)**, the whole attribute table a peer is shown and what
Device Name answers, with `setDiscoverable(false)` and without (F-6);
§B.3's link sequence against a real Bluetooth stack; the [U]s of §B.3;
the `neverForLocation` [U]; and what the framework logs (F-13): on API 30
and later, that none of it is under Haven's pid, with an address planted
(§M.9 item 1), and what the Bluetooth process writes under its own, for
the scanner rule Q-10 asks for.

**If it cannot be made reliable:** the adapters have no proof per push;
requirement N1 is unmet for them (plan G-1's own words); the loopback lane
stands; the adapters wait for the device matrix [H]. A self-hosted runner
with two phones is the owner's call.

### F.4 What no lane proves

A sleeping processor (emulators do not sleep, plan §9.2): the timed wake
lock on a vendor's build (F-5), the alarm's lateness. Radio range, throughput, another
vendor's Bluetooth stack. Battery. All [H], DEFERRED:
`docs/MESH_DEVICE_MATRIX.md` gets its Android half in M3i, marked so.

---

## G. Power (F3)

**Nothing here is measured.** The project has no device
(`docs/POWER_EFFICIENCY_PLAN.md` §2.5); every figure for this feature is
**ESTIMATED** or absent, and `docs/POWER_MEASUREMENT.md` gains nothing.

**As built (M3f).** `MeshRadioConstants` compiles without Android, so the
four platform modes are held as the integers of the Android constants,
each named in a comment beside it — `SCAN_MODE_LOW_POWER` 0,
`ADVERTISE_MODE_LOW_POWER` 0, `ADVERTISE_TX_POWER_MEDIUM` 2,
`CONNECTION_PRIORITY_LOW_POWER` 2, read off the platform's reference
pages on 2026-11-12 — and an adapter passes them on unmapped, naming no
platform constant itself (the guard). That the integers are the SDK's is
proved by no compiler until M3g builds against it.

| Choice (`MeshRadioConstants`) | Value | Basis |
|---|---|---|
| Scan | filtered, `SCAN_MODE_LOW_POWER` | the lowest duty the platform offers; 512 ms in 5.12 s, 10.24 s with the screen off (plan §2.3 [V]) |
| Advertise | `ADVERTISE_MODE_LOW_POWER` | the lowest rate; the advertising-set API documents about 1000 ms as its lowest-power interval (the review); the legacy mode's mapping to it is **[U]** |
| TX power | `ADVERTISE_TX_POWER_MEDIUM` | a judgement: lower costs range, which is function; unmeasured (Q-9) |
| Connection | `CONNECTION_PRIORITY_LOW_POWER` | plan §6.1 |
| Links | at most 4 + 4 | the engine's (`eng:254-255`) |
| Wake lock | timed, `min(next wake + 250 ms, HOLD_CAP_MS = 10 s)`, on an inbound frame or a link coming up; never held otherwise | plan §7.7 R2; the cap is a judgement |
| Alarm | one, inexact, allow-while-idle | §B.5 |
| Scan restart | a term of that alarm | no alarm added |

- **The wake lock is expected to hold in Doze (F-5)**, so R2 costs what D-8
  accepted: in a busy mesh a phone with sharing off is awake most of the
  time. The same lever is a stranger's (§H, Q-13).
- **The alarm serves emission slots** (plan §7.3): outside Doze, a phone
  with no peer and sharing off is woken every 60–120 s
  (`emit_period_ms` ± `emit_jitter_ms`, `eng:241-242`) to emit to nobody.
  Its cost is an input model E does not have yet; it is owed there with
  the mesh's other entries (M5, plan §10), each ESTIMATED.

What CI holds is mechanism, not milliamps: T-PWR-1 (the constants come
from one site [J], [G]), T-PWR-2 (the link cap, [L] in the engine), T-PWR-3
(with no peer no frame is sent and no lock is taken [J]).

---

## H. Security and privacy of the new surface

security-reviewer on M3a, M3b and §B.3–B.4 before they land (plan §8.3).

| Threat | Bound | Where | Test |
|---|---|---|---|
| Malformed, truncated or oversized frame | closes the link; nothing unbounded is allocated | engine (`eng:1078-1134`); `RADIO_MAX_FRAME` before the copy (§A.5) | T-SEC-3 [L, exists]; `a_frame_longer_than_the_radio_carries_closes_its_link` [L] |
| Frame flood on a link | credit per link; unsolicited packet closes it | engine (`eng:44-57`) | T-SEC-3, T-SEC-4 [L, exist] |
| Long write, offset write, write with response | refused; link closed | `GattServerAdapter` (§B.3) | [E] netsim only |
| Connection flood | 12 new inbound links a minute, burst 4 (`eng:252-253`); at most 4 unlinked connections, 10 s each (§B.4) | engine; `MeshRadioCore` | [L, exists]; `unlinkedConnectionsAreCappedAndTimedOut` [J] |
| One advertiser under many addresses, pushing the others out of the peer table (found by the review of M3f) | a full table forgets one picked at random among those neither linked nor being dialled, in the engine and in `PeerTable` alike (the table knows the address of a link this phone dialled; a link it took has none); an unknown address below the signal floor takes no place in either | engine (`make_room`, `rssi_floor`); `PeerTable` (§B.1) | [L, exists]; `aFloodOfAddressesDoesNotPushOutAPeerUnlessItIsPicked`, `anAddressBeingDialledOrLinkedIsNeverForgotten`, `aWeakAddressNotYetKnownTakesNoPlaceAndIsNeverToldToTheEngine` [J]; the floor's two copies pinned [G] |
| Slot exhaustion, eclipse | random and rotated slots; departed class | engine (`eng:38-42`) | T-SEC-4 [L, exists] |
| Controller connection slots held by a stranger who never subscribes | **none**: Android has no accept filter for a connectable advertisement | — | residual, stated |
| **A stranger keeps the phone awake** | **none that keeps R2**: each link coming up and each inbound frame holds the lock up to 10 s, and one valid frame every few seconds — far inside the credit of 120 a minute — is enough. Bounded only by the twelve hours. As built: a link or a frame the engine answers with that link's close in the same pump holds no lock (§B.2), so a link the engine refuses at once, or a frame it answers with a close, buys none | §G | residual; Q-13; cost [H]; `aLinkTheEngineClosesAtOnceHoldsNoLock` [J] for the narrowing |
| **A fault in the mesh ends the relay path's process** (F-14) | every callback inside `MeshThread.run`; every export inside `radio_guarded` | §B.1, §A.6 | `aRadioPortThatThrowsStopsTheRadioAndNothingEscapes` [J]; `every_export_is_one_guarded_call` [L]; guard [G] |
| Handshake cost | two scalar multiplications a connection, behind the inbound limit | engine | plan §6.7 |
| Tracking by advertisement | the service UUID alone; no name, data or power | `AdvertiserAdapter` | `theAdvertisementIsTheServiceUuidAlone` [J]; on air [E] netsim |
| Tracking by address | Haven sets none and cannot: the address, in both roles, is the build's (§M.5). AOSP's default is a resolvable private address, rotated every 15 minutes on Android 6–11 and at a random 7 to 15 on 12L and 13 ([V1]), and the same from 14 unless a vendor's property says otherwise ([V]). An AOSP fix (bug 246692649) for rotation stopping after a connection exists; which releases have it is **[U]** | platform | [H] |
| **The phone's own address fixed**, where a vendor ships LE privacy off or a public or static address policy | **none**: no public API chooses the address or tells which kind it is (§M.5) | platform | residual, stated; [H] |
| Re-identification across rotation by the packets held, or by a link kept open | **none**: plan §0.4 item 6, accepted | — | disclosed (§D) |
| **The phone's Bluetooth name, read by a peer that connects in** | API 34+: `setDiscoverable(false)` (F-6; the stack's rule [V] in a mirror from 14 QPR3, §M.7). **None** on API 30–33, and none on a controller with neither extended nor multi advertising, where the stack ignores the setting | `AdvertiserAdapter` | T-PRIV-5 [E] netsim, both directions; [H] |
| **The same name, read by a peer Haven dials** — anyone advertising Haven's public UUID | **none**, on every API level ([V], §M.7). From Android 16 the peer's stack reads it on every link, no app asking | — | disclosed, and the name shown (§D, §E.2); Q-6, Q-11 |
| **Other apps' Bluetooth services, seen by any connected peer** (one attribute table a device, [U]) | **none** | platform | T-PRIV-5 records the table; disclosed in `meshIntroName` |
| What Haven's characteristic reveals | nothing readable: write and notify only, every byte after the handshake sealed (plan §6.7) | engine | T-PRIV-8 [L, exists] |
| A Bluetooth address in a log, a notice or across the bridge **by Haven's code** | the package logs nothing; `PeerTable` keeps addresses in Kotlin memory only; the channel carries a state and two bools | §B.9, §C.1 | `anAddressNeverReachesTheEngine` [J]; `nothing_is_logged_…` [D]; T-LOG-1 [E] |
| **An address in logcat by Android's code, under Haven's pid** (F-13) — a peer's, and that of any other device that connects to the phone (§M.1) | the process's own logger, and the floor behind it, in force before any Bluetooth object exists, or no radio; below API 30, no radio (§M.2, §M.3). Not built | §M | Q-10; [E]/[H], §M.9 items 1–3 and 7 — nothing run |
| **The same links in the system's own records, outside Haven's process**: the Bluetooth process's log, and from Android 16 the names it reads of peers (§M.7) | **none** | platform | residual, stated (§M.8) |
| **A crash or a `Log.wtf` in Haven's process, recorded by the system** with the exception's message (`am_crash`, `am_wtf`, DropBox) | nothing thrown leaves the mesh thread (§B.1), and the package builds no message from an address (§B.9). What a platform exception's message carries is unread | §B.1, §M.8 | `aRadioPortThatThrowsStopsTheRadioAndNothingEscapes` [J] for the wrapper; the system's record [E] |
| **A peer makes the phone ask to pair** — by refusing the descriptor write, or as a central asking outright | nothing of Haven's asks for security; a device that enters `BOND_BONDING` while linked or linking is closed (§B.3). The system's consent dialog may show all the same; an accepted pairing would hand the stranger the phone's identity address (**[U]**, the specification from memory) | `MeshService`, the adapters; §M.4 | [E]/[H], §M.9 item 4 |
| The radio reaching a key or a session | no radio entry takes one; the engine is keyless | §A.4 | `the_radio_entries_take_no_session` [L] |
| A radio with the store saying off | bounded to one process start until the first session entry; turn-off stops the radio first; no reconcile runs inside a transition | §A.4, §C.3, §C.4 | `a_session_whose_mesh_is_off_ends_…` [L]; `a_stopped_event_in_the_middle_of_a_turn_off_starts_nothing` [D] |
| The deadline copy at rest | an app-private preference: that mesh was on, and until when. The counters went to the encrypted store for less (D-4) | `MeshPrefs` | Q-2 |
| A debug loopback radio in a release | not in the release source set | §F.2 | guard [G] |
| Mesh permissions and components in a build with the flag off | not in its manifest | §B.8 | guard [G]; merged manifest [C] |

**What stays exposed whatever M3 does**, beyond plan §0.4: the phone's
Bluetooth name to any peer Haven dials, and to any peer at all below API
34 or on a controller that ignores the setting; the list of other apps'
Bluetooth services; the phone's own address where its vendor does not
randomize it; and the system's records of the links, outside Haven's
process. The whole list is §M.8. The draft ended this paragraph with the
addresses Haven linked with, under its own pid in the device's log: on
the levels the radio runs on they are not written there (§M.2, §M.3) —
as read in source, and unproved on a device.

---

## I. Documents made stale, and written with the code

- `haven-core/SECURITY.md` "Bluetooth mesh": "The radio is not [built]"
  and "An entry that holds no session — none exists in this build"
  (`:3293`, `:3419`) — with M3a; a new part for the radio's privacy cost
  (plan §0.4, §8.1, and F-6, F-13 here), owed there since M2g-1, with M3g.
- `docs/privacy/privacy_invariants.json`: invariants for the advertisement,
  the GATT table, the notices, the deadline copy, the session-less engine;
  accepted deviations for the Bluetooth name and, if Q-10 is answered that
  way, for the framework's log lines. **As decided and researched,
  2026-11-12:** Q-10 is answered that way. The deviation is what §M.8
  lists and no more, written when M3g builds the lever and not before:
  both documents describe what is built.
- `plan` §0.4 item 6 (identity; and "after its Bluetooth address
  rotates", which is the build's to do and not every build's, §M.5) and
  item 3 (after a reboot, after the first unlock); a new item there, that
  phones on Android 6 to 10 cannot use the mesh (§M.3); §7.1, which has
  the radio on every level from 23; §16: M3's status, each "not as the
  plan has it" of §0.
- `haven/lib/src/providers/mesh_provider.dart`'s "No radio is built yet"
  and `api:12745-12746`'s "The radio is not built yet".
- `docs/MESH_DEVICE_MATRIX.md`: new, Android half, DEFERRED.
- `CLAUDE.md` is the owner's. Proposed for it: in Architecture, the
  radio's JNI surface as the one hand-written `extern` in `rust_builder`;
  in the proposed Rule 17, "the radio's entries take no session and open
  none; a radio entry may start a keyless engine under a deadline no later
  than twelve hours and the first session entry overrules it"; in Rule 15,
  whatever Q-10 decides — the owner approves the wording (Q-10, item 4),
  from §M.8; the mesh lanes in the CI section.

---

## J. Open questions for the owner

### Decided by the owner, 2026-11-12

The six questions put to the owner after M3f, and what was answered. Each
binds M3g and later units; the question's own text below is kept as the
record of what was weighed.

- **Q-10 — Android's own log lines: accepted, as (a), on conditions.** The
  owner's words: Haven must do "everything to reduce this amount of
  exposure as much as possible", for example "randomization of ALL
  identifiers such that the debug logs do not mean anything to anyone who
  has access to them"; "we cannot have **some** parts of the logs
  anonymized if other parts cannot and therefore we need an all-or-nothing
  approach"; "if the amount of information which the Bluetooth logs reveal
  can be reduced, we should do that as much as possible as well"; and,
  "since this is a system-level reality, we have to accept what we have
  to". What that requires of M3g, before any adapter is written:
  1. an inventory, per API level, of every line the platform's Bluetooth
     classes write from Haven's process for the calls Haven makes, and of
     every identifier in them (addresses in both roles, names, interface
     and connection numbers, UUIDs);
  2. for every identifier Haven's choices decide, the choice that leaves
     nothing but a random, rotating value — this phone's address as an
     advertiser and as the one that dials, no bonding or pairing (which
     would exchange an identity address), no name, no data in the
     advertisement — taken for all of them or the radio is not started:
     never one identifier randomized beside another that is fixed;
  3. no call that logs more than the link needs, where another call makes
     the same link;
  4. what is left, stated exactly — in `haven-core/SECURITY.md`, as a
     declared deviation in the privacy manifest, in Rule 15's text (owner
     to approve the wording, plan §16), and as one logscan rule scoped to
     the platform's tags and message shapes and to nothing of Haven's.
  The inventory and the levers are **not established yet**: they are
  M3g's first step, researched against the platform's source and
  documentation and confirmed independently before code.

  **As researched, 2026-11-12 (§M).** Established on paper — a research
  pass, then an independent confirmation that fetched every cited file
  again — and proved on no emulator or device (§M.9). By item:
  1. The inventory is §M.1, by release band and not by API level: the
     lines changed within API 35 and again within API 36. No line names this
     phone's own address or name. One finding widens the question: a
     GATT server is told of every LE connection of the phone, so the
     addresses would be those of the user's own devices too.
  2. The choices are §M.4 to §M.7, and one identifier is not among
     them: this phone's address is private and rotating by AOSP's
     default, a vendor's to change, and an app can neither choose it nor
     see which it has (§M.5). The condition reaches what "Haven's
     choices decide"; nothing here says every identifier is random.
  3. No other call makes the link (§L). But from API 30 a process
     decides what its own log calls write, and with the lever of §M.2
     in force none of the platform's Bluetooth lines is written from
     Haven's process at all. "All of them or the radio is not started"
     becomes the rule of §M.3: API 30 or later, the lever in force and
     checked, never bonded — or no radio. Its price: phones on Android 6
     to 10 cannot use the mesh.
  4. What is left is §M.8, stated there and in none of the three
     documents yet: they describe what is built. Under Haven's pid
     nothing of the platform's is left to scope a scanner rule to; the
     rule is for the Bluetooth process's own lines.
- **Q-11 (and Q-6) — the Bluetooth name: accept and disclose**; and, in the
  owner's words, "if there is a way to remove/obfuscate this information,
  do it". Disclosure is built (the intro sheet's name step, M3d/M3e).
  Whether a way exists that is Haven's to take is M3g's to establish:
  `setDiscoverable(false)` from API 34 is designed and unverified (§B.3);
  renaming the phone's Bluetooth name (Q-6 (c)) changes a system setting
  the user's other devices see, and is not taken without the owner's word.

  **As researched, 2026-11-12 (§M.7).** No way that is Haven's to take
  withholds the name from a peer this phone dials, on any release.
  `setDiscoverable(false)` withholds it from a peer that connects in,
  from API 34, except on a controller with neither extended nor multi
  advertising; it also takes the Flags field out of the advertisement,
  and whether an iPhone still finds that is unproved (M4). From Android
  16 a peer's stack reads the name on every link without any app asking.
  Renaming stays untaken: an app may do it, for every Bluetooth use of
  the phone. So the name is accepted and disclosed, with
  `setDiscoverable(false)` where it exists.
- **Q-13 — a linked stranger can keep the phone awake: accept and record.**
  Recorded in §H; narrowed, not bounded, by M3f's review (a link or frame
  the engine closes at once holds no lock).
- **Q-2 — a keyless engine started by the service with no session: yes.**
  As built in M3a (`radio_resume`) and M3f (`StartPolicy`).
- **Q-1 — a draft pull request: yes, now**; "both the old and the new CI
  steps" must be working.
- **Emission times and relay times (plan §7.3, R1/R2): the conditional
  guarantee is enough.** Session code runs no mesh timer (R1, built); the
  unconditional form, in which only the radio's alarm ever serves a late
  slot (R2), is not built and not owed.

Still on the design's recommended default, the owner not having been
asked again: Q-3, Q-4, Q-5, Q-7, Q-8, Q-9, Q-12.

**Q-1. Open a draft pull request, and when?** Today no Kotlin can be
compiled and no [J], [C] or [E] claim can be tested: CI runs only for pull
requests to `main`. (Since M3f the pure Kotlin compiles and [J] runs
without CI; the rest stands, and M3g is the first unit written blind.)
- *Now, with M3b:* `deny(unsafe_code)` over the whole crate and the
  Android-only shim get `cross-check.yml` — every platform's `cfg` code —
  before anything is built on them; later units get a compiler as they
  come. Every existing lane also runs on each push, and the branch becomes
  visible.
- *At M3f:* fewer runs; M3b's platform-gated code is first compiled weeks
  after it was written.
- *Not at all:* M3f–M3h are written blind.
- **Recommended: a draft when M3b is pushed.** M3a needs nothing from CI;
  M3b is the first unit this machine cannot fully check.

**Q-2. A keyless engine started by the service with no session (F-1, F-2)?**
- *Yes (designed):* the phone relays and emits cover after a reboot or a
  restart, as plan §0.4 item 3 and R4 promise. Cost: a second, weaker copy
  of the deadline in a plain preference; a window, from process start to
  the first session entry, in which the service's word alone keeps a radio
  on.
- *No:* after a restart the radio stays silent until a session opens. No
  copy beyond an on flag. Plan §0.4 item 3 then reads "relays only while
  the process that turned mesh on lives".
- **Recommended: yes**, with `mesh_take` (§A.3) and the queue (§C.4), which
  close the two ways the copy could outlive a turn-off.

**Q-3. Keep on from the notification (F-3).**
- *(a) It always opens Haven*, which keeps on as it starts — a direct
  `getActivity` intent (§B.5). One path. On a locked phone it asks for the
  unlock. Plan §7.6's "without opening Haven" is given up.
- *(b) Through the channel when Haven's Dart isolate is alive, else opens
  Haven.* Works from the lock screen in the common case; two paths, the
  second reachable only on a lane.
- **Recommended: (a).** The store write is made by the one session owner,
  in the one way that is tested locally.

**Q-4. The order of turning on (§C.2).** Permission, name and Bluetooth
before the store (designed), or the store first as this design's brief had
it. **Recommended: as designed** — a refusal has nothing to unwind.

**Q-5. The L4 lane.** Loopback first and netsim as a spike (designed);
netsim only, as plan §9.1 L4 has it; or loopback only. Against loopback:
a new tooling crate and a debug-only socket radio, and three more emulator
jobs a push, for proof that covers no Bluetooth. For it: it is the only
per-push proof known to be feasible, and the plan's own T-INDEP relay
oracles need a peer of some kind. **Recommended: as designed.**

**Q-6. The Bluetooth name (F-6): how it is told.**
- *(a) Show it:* the intro sheet says nearby phones can read the name,
  shows the name itself and offers the system's Bluetooth settings to
  change it (§E.2), with `setDiscoverable(false)` on API 34+ (§B.3). The
  user decides knowing exactly what is exposed. Cost: one more step the
  first time; a user who renames the phone renames it for every Bluetooth
  use.
- *(b) The general sentence only.* Simpler; the user must guess what
  their phone is called.
- *(c) Rename the phone for the user* while mesh is on. Not designed:
  Haven would change a system setting other devices rely on.
- **Recommended: (a).** Whatever is chosen, a peer Haven dials reads the
  name (Q-11), and below API 34 so does any peer.

**Q-7. "Turns off at 03:15" in place of a time left (§E.3).** One string,
no plural forms in 13 languages, nothing to tick. Plan §7.6 says "the time
left". **Recommended: the clock time.**

**Q-8. Bluetooth switched off while mesh is on (F-4).** Paused, the service
kept, resuming by itself (designed, and plan §7.1's boot wording); or mesh
turned off, which matches iOS (plan §0.4 item 4), is simpler and leaves no
"paused" notification for up to twelve hours, but ends mesh at every
airplane-mode toggle. **Recommended: paused.**

**Q-9. Advertising.** The one legacy path at about 1 s and medium power
(designed), or plan §7.1's 1022.5 ms through the advertising-set API on
API 26+, a second path whose only stated reason is iOS background discovery
[U]. **Recommended: legacy now; decide the interval in M4 with evidence.**

**Q-10. Android's own log lines under Rule 15 (F-13).** Rule 15 says no
address reaches any log in any build; Android writes each linked peer's
address to logcat from Haven's process, and Haven cannot stop it.
- *(a) Record it as the platform's, outside Rule 15:* a sentence in Rule
  15 and `SECURITY.md`, an accepted deviation in the privacy manifest, and
  one logscan rule scoped to the framework's tags and message shapes and
  to nothing of Haven's. For: the address is the one the peer showed
  everyone in radio range, random and rotating on a phone; reading the log
  takes the unlocked phone with debugging authorized, or a bug report the
  user hands over; Android's Bluetooth process logs the same lines under
  its own pid already. Against: it is the first identifier the scanner is
  told to let through; a device that does not randomize is logged under
  its real address; a shared bug report shows which addresses the phone
  linked with and when.
- *(b) Hold the rule as written:* then Android can have no radio — both
  roles log, and there is no other API. The mesh ships on iOS only, or
  not at all.
- **Recommended: (a)** — but it is a pillar giving, so it is the owner's
  word, before M3g, not a lane's finding.
- *As researched, 2026-11-12:* the question was weighed on "Haven cannot
  stop it", which is false from API 30 (§M.2), and on "the address is the
  one the peer showed everyone", which leaves out the user's other
  devices (§M.1). The decision above stands; §M.3 is what it now asks.

**Q-11. A phone Haven dials reads this phone's Bluetooth name (F-6).** No
setting prevents it; anyone can be dialled by advertising Haven's UUID.
- *Accept and disclose* (designed, with Q-6): plan §0.4 item 6 is
  corrected to say that a name is exposed.
- *Do not ship the Android radio* until the platform offers a way.
- **Recommended: accept and disclose.** The dual role is what makes a mesh;
  a phone that never dials cannot link to another Android phone that
  hides its name the same way.
- *As researched, 2026-11-12:* "no setting prevents it" is confirmed in
  source for every release read (§M.7).

**Q-12. Keep the mesh out of the manifest while the flag is off (F-15)?**
- *Gate it (designed, §B.8):* ordinary releases declare nothing new and do
  not wait on G-4. Cost: a Gradle branch on a property the Flutter tool
  owns ([U] until compiled), two native build shapes to keep green, and
  the permissions first appear to users when the flag flips in M5.
- *Declare it always:* one build shape; every release from M3g carries
  three Bluetooth permissions and a foreground-service type Play may ask
  about, for a feature that is off.
- **Recommended: gate it.**

**Q-13. A stranger can keep the phone awake (§H).** R2 holds a wake lock
on every inbound frame; a hostile linked peer needs one cheap frame every
few seconds.
- *Accept and record:* it is the cost D-8 accepted for a busy honest mesh,
  it ends with the twelve hours, and no bound exists that an honest busy
  mesh would not also hit.
- *Cap the lock* — say 20 s in any minute while asleep: bounds the drain,
  and a sleeping phone in a busy mesh then forwards a third of the time.
- *Hold the lock for the pump only:* least power; announce ticks stop
  while asleep, which is what R2 was chosen to prevent.
- **Recommended: accept and record**, and revisit with the first device:
  nothing about its size can be learned without one.

**Carried, not M3's:** the two open decisions of plan §16 (the engine clock
through `rustix` or `libc`; whether a burst awaits its mesh drive); that
Android passes nothing on to a relay (it publishes before it fetches); G-4
(Play's declaration), which only the Console answers.

---

## K. Not verified

**Settled since the draft**, with where: the 512-byte attribute limit (the
review: Core spec Vol 3 Part F §3.2.9, AOSP `f25b742c`); the
`onNotificationSent` wait rule [A17]; `setDiscoverable` from API 34 on both
builders [A15, A16]; `getName` and its permission [A18]; the notification
trampoline rule [A19]; the framework's log lines [A20]; MTU 517 and
notification dismissal on Android 14 [A4]; `connectedDevice`'s
prerequisites [A1]; the boot and package-replaced exemptions [A5]; the
wake lock in Doze (the review, on a mirror — [U] here, [H] for vendors).

**Settled by the research of 2026-11-12, in source and on no device**
(§M; from API 33 in a LineageOS mirror, the AOSP host unreachable):
what the framework's GATT classes log, per release (§M.1); that a
process can keep those lines out of its own log from API 30, by two
mechanisms, and what undoes each (§M.2); who may read logcat (§M.1);
the retry that lets a peer raise a pairing dialog, and that no public
call stops a pairing but dropping the link (§M.4); this phone's address
type and rotation by release, and that an app cannot choose it (§M.5);
`getAddressType()` and where it means anything (§M.6); the Device Name
permission from 14 QPR3, that a dialled peer always reads the name, what
`setDiscoverable(false)` changes and where it is ignored, and the name
read a 16 stack makes on every link (§M.7); that the server's connection
callback fires for every LE connection of the phone (read on 16 only).

**Still open:**

- F-12, and netsim on a hosted runner at all (§F.3).
- Whether `cancelConnection` ends an inbound connection; `startForeground`
  in a sticky restart on Android 12+; whether the server's connection
  callback fires for other apps' connections on a release other than 16,
  and on any device; whether a no-response
  write is paced by its callback; re-posting a dismissed foreground
  notification; that a Bluetooth state change reaches no manifest
  receiver.
- Whether `neverForLocation` filters a plain service-UUID advertisement;
  whether an iPhone finds a non-discoverable advertisement; iOS's typical
  MTU; the legacy advertise mode's interval.
- The text of AOSP `5fc5174`, and whether Android 14.0.0 itself carries
  it (read at 14 QPR3); the shared attribute table (memory); the scan
  downgrade on Android 15 (the review's reading); the AOSP fix for
  address rotation stopping after a connection.
- **New with §M.** Everything of §M.9: that the lever leaves Haven's
  pid empty on a real phone, a vendor's included; that nothing in the
  process moves the floor; that the check sees a property; that dropping
  the link stops a pairing; that `setDiscoverable(false)` stops a
  peer-initiated bond; that a 16 stack's name read is stored and logged
  on a user build; whether an app may clear its own log entries. And
  beside it: every [V] of §M on the AOSP host itself; every vendor's
  Bluetooth stack and `liblog`; the Bluetooth Core Specification, not
  fetched — so that an address cannot be resolved without a bond, and
  what a pairing exchanges, are from memory; an iPhone's own Device
  Name; whether the logger sees the binary event-log writes; how the
  logger's being in force is read back (§M.2); the defaults of the
  platform flags §M names.
- Play's declaration: `support.google.com` [A13] and Bumble's pages
  `google.github.io` [A14] are outside this session's network.
- That the Flutter tool hands Gradle the defines as designed, and AGP's
  per-variant manifest API; that a Gradle unit-test task builds no Rust
  (no longer asked: the lane of M3f builds no part of the app);
  grouping with the plugin's notification. (Settled by M3a and M3b: the
  codegen ignores a function that is not `pub` but lists it in a comment;
  `api.rs` compiles under `deny(unsafe_code)`.)
- That the shim compiles for Android, links under its nine names and is
  callable: no Android target where M3b was built ([C], [E]).
- [A9] and [A10] were read through a summarizing fetch, not in full.
- Nothing was built or run for this design or its revisions, §M's
  included.

---

## 12. Sources

Fetched 2026-11-11 unless marked.

- [A1] https://developer.android.com/develop/background-work/services/fgs/service-types
- [A2] https://developer.android.com/develop/connectivity/bluetooth/bt-permissions
- [A3] https://developer.android.com/about/versions/15/behavior-changes-15
- [A4] https://developer.android.com/about/versions/14/behavior-changes-all
- [A5] https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- [A6] https://developer.android.com/develop/ui/views/notifications/notification-permission
- [A7] https://developer.android.com/training/monitoring-device-state/doze-standby
- [A8] https://punchthrough.com/android-ble-scan-errors/ — search summary only
- [A9] https://github.com/kaeawc/auto-mobile/issues/14265
- [A10] https://github.com/VRuzhentsov/fini/pull/200
- [A11] https://docs.rs/crate/jni/latest/source/docs/0.22-MIGRATION.md — search summary only
- [A13] https://support.google.com/googleplay/android-developer/answer/13392821 — **not reachable**
- [A14] https://google.github.io/bumble/platforms/android.html — **not reachable**
- [A15] https://developer.android.com/reference/android/bluetooth/le/AdvertiseSettings.Builder
- [A16] https://developer.android.com/reference/android/bluetooth/le/AdvertisingSetParameters.Builder
- [A17] https://developer.android.com/reference/android/bluetooth/BluetoothGattServerCallback
- [A18] https://developer.android.com/reference/android/bluetooth/BluetoothAdapter
- [A19] https://developer.android.com/about/versions/12/behavior-changes-12
- [A20] `LineageOS/android_packages_modules_Bluetooth`, branch `lineage-22.1`,
  `framework/java/android/bluetooth/BluetoothGatt.java`,
  `BluetoothGattServer.java`, `BluetoothDevice.java` — a mirror of AOSP,
  fetched raw from GitHub; the AOSP host itself was not read.
- Read by the confirming review only, on the same mirror or through search
  summaries, and not fetched here: `PowerManagerService`
  (`setWakeLockDisabledStateLocked`), `le_scan/ScanManager.java`, AOSP
  changes `5fc5174` and `f25b742c`.
- bitchat-android at `14ab73c4`: `BluetoothGattClientManager.kt`,
  `BluetoothGattServerManager.kt`, `BluetoothPacketBroadcaster.kt`,
  `app/src/main/AndroidManifest.xml`.

**For §M, fetched 2026-11-12**, by the research pass and again by its
confirmation; neither pass's report is in the tree. `AM/<repo>@<tag>` is
`raw.githubusercontent.com/aosp-mirror/<repo>/<tag>/…`, Google's GitHub
mirror at an AOSP release tag; `LO/<repo>@<branch>` is
`raw.githubusercontent.com/LineageOS/<repo>/<branch>/…`.
`android.googlesource.com`, `cs.android.com`, `source.android.com` and
`www.bluetooth.com` were **not reachable** in either pass.

- [A21] `AM/platform_frameworks_base`, tags `android-6.0.0_r1` to
  `android-14.0.0_r1`: `core/java/android/bluetooth/` (the Bluetooth
  classes, to Android 12L only), `core/java/android/util/Log.java`,
  `core/jni/android_util_Log.cpp`, `RuntimeInit.java`,
  `ActivityManagerService.java`, `LogcatManagerService.java`,
  `core/res/AndroidManifest.xml`.
- [A22] `AM/platform_system_core`: `liblog/` and `base/logging.cpp` at
  `android-10.0.0_r1` and `android-11.0.0_r1`; `logd/` at
  `android-6.0.0_r1`.
- [A23] `LO/android_packages_modules_Bluetooth` (the framework classes
  and the stack from API 33), `LO/android_system_logging` (`liblog/`),
  `LO/android_frameworks_base`, and — the research pass only —
  `LO/android_system_bt` (the stack to 12L, `cm-13.0` to
  `lineage-19.1`). Branch to release, by each branch's
  `LO/android_build` `core/build_id.mk`: `lineage-20.0`
  TQ3A.230901.001, 13 QPR3, API 33 · `lineage-21.0` AP2A.240905.003,
  14 QPR3, API 34 — not Android 14.0.0 · `lineage-22.0`
  AP3A.241105.008, 15 · `lineage-22.1` AP4A.250205.002, 15 QPR1 ·
  `lineage-22.2` BP1A.250505.005, 15 QPR2, all API 35 · `lineage-23.0`
  BP2A.250805.005, 16 · `lineage-23.1` BP3A.250905.014, 16 QPR1 ·
  `lineage-23.2` BP4A.251205.006, 16 QPR2, all API 36 · `lineage-24.0`
  CP2A.260605.016, the release after 16, its number an inference.
- [A24] https://developer.android.com/ndk/reference/group/logging and
  https://developer.android.com/ndk/guides/using-newer-apis
- [A25] developer.android.com reference pages: `BluetoothDevice`
  (`toString`, `getAddressType`, `setPairingConfirmation`,
  `cancelBondProcess`, `ACTION_BOND_STATE_CHANGED`),
  `BluetoothAdapter#setName`, `Manifest.permission#READ_LOGS`; and
  [A15], [A16] again.
- [A26] `flutter/flutter`, branch `master` (no pinned revision):
  `fml/logging.cc`, `shell/platform/android/flutter_main.cc`.
- [A27] `android_logger 0.15.1`, `src/lib.rs`, as resolved in
  `haven/rust_builder/Cargo.lock`.

---

## L. What the confirmation changed

Each finding was checked against the code or its source before it was
applied.

**Changed**

- A fault in the mesh can no longer end the shared process: one wrapper
  round every callback, a [J] test, a guard (F-14, §B.1).
- Android's own address logging is named, with who can read it, as an
  owner question (F-13, §B.9, Q-10).
- The Bluetooth name: `setDiscoverable(false)` from API 34; T-PRIV-5 in
  both directions and over the whole table; the sentence written now; the
  name itself shown with a way to change it (F-6, §B.3, §D, §E.2, Q-6,
  Q-11).
- One queue for turn-on, turn-off, keep-on and reconcile; a failed restart
  unwinds once; a stop the service made is final (`wanted`) (§C.4).
- The mesh manifest is merged only into a build with the flag (F-15,
  §B.8, Q-12).
- The relay oracles of three existing lanes run once more with mesh on
  and a peer (§F.2).
- Adopt-or-install under one lock acquisition, `mesh_take`; the holder set
  stays four (F-16, §A.3).
- Notification taps are direct activity intents (§B.5).
- The service checks the Bluetooth permission itself (§B.5).
- The scan restart is a term of the alarm; the Android 15 downgrade (§B.3).
- Copy: "unless it's in one of your circles"; "Even with no internet" (§D).
- Two residuals named: a stranger keeping the phone awake (Q-13); mesh
  resuming after a reboot only after the first unlock (§B.5, §H).
- The panic test is of a shared guard function, with a source gate over
  the exports (§A.6, §A.8).
- F-4's reasoning corrected; F-5 reversed: the wake lock holds in Doze,
  and its cost is real (§0, §G).
- Advisories taken: `PeerTable` is 64; one guard script; a timeout on a
  frame in flight; reconcile deletes the keys of an engine that went; the
  logout retry clears the service's copy; T-PERF-3 and T-BG-1 labelled
  pipeline-only; the deadline copy's wall-clock exposure stated; the
  emission-slot alarm owed to model E.

**Not taken**

- Re-posting the notification from its delete intent: posting again the
  moment the user dismisses it undoes the dismissal Android 14 gives them,
  and plan §7.1 says the next screen-off; re-posting there needs no state.

**Checked and not as the review had it**

- "Read how `build.gradle*` already decodes dart-defines": it decodes
  none (`haven/android/app/build.gradle.kts` reads `key.properties` and
  `HAVEN_RELEASE_WRAPPER`, `:126`; no file under `haven/android` names
  `dart-defines`). §B.8 is designed from nothing existing, and tagged [U].
- "Avoid the logging calls where an alternative exists": none exists. The
  server class logs too (`onMtuChanged() - device=` + address,
  `BluetoothGattServer.java:360` on the mirror), so both roles write an
  address; Q-10's second option is therefore "no Android radio".
  **As researched, 2026-11-12:** there is still no other call; but from
  API 30 the process can keep the lines themselves out of its log
  (§M.2), so the second option was narrower than it read here.
- `max_peers` is at `eng:264`, not `:263`.

---

## M. Android's own logs, the device name, and what Haven does about them

The owner's decisions on Q-10 and Q-11 (§J) asked for facts before any
adapter. They are here: what the platform does, what Haven does about
it, what is left. It is M3g's brief for everything that is not an
adapter.

### M.0 How this was established, and how far

Two read-only passes on 2026-11-12: a research pass, then an independent
confirmation that fetched each cited file again, corrected the first and
added to it. Where they differ the confirmation is followed (§M.10).
Neither built or ran anything: no emulator, no device.

**The AOSP hosts were not reachable in either pass.** Read instead
(§12, [A21]–[A27]): `developer.android.com`; Google's GitHub mirror of
AOSP at release tags (`AM/…`), which carries the Bluetooth classes only
to Android 12L; and, for everything from API 33, LineageOS branches
(`LO/…`), each tied to a release by its build ID. A LineageOS branch is
a fork: it can differ from the AOSP tag by its own patches and by
monthly backports, and `lineage-21.0` is 14 QPR3, not Android 14.0.0. So
**every statement here about API 33 and later is "read in a mirror, to
be confirmed on the AOSP host"**, and none is about a vendor's build: no
vendor's Bluetooth stack, framework or `liblog` was read. The Bluetooth
classes also ship as a module, updatable from Android 16 (**[U]**, a
search summary), so a phone's can be newer than its API level:
`SDK_INT` does not say which column of §M.1 a phone is in.

Tags, in this section: **[V]** fetched and read by the confirming pass —
what the research cited, read again, or what the confirmation added;
**[V1]** read by the research pass alone; **[U]** unverified, saying
why; **[E]**, **[H]** needs an emulator or a device (§M.9). A [V] is a
reading of source, never an observation.

Short forms: `fw/` is `framework/java/android/bluetooth/` and `sys/` is
`system/`, both in `LO/android_packages_modules_Bluetooth`; up to 12L
`fw/` is `core/java/android/bluetooth/` in `AM/platform_frameworks_base`.
`liblog/` is in `LO/android_system_logging`, and in
`AM/platform_system_core` at Android 10 and 11. `@6.0`, `@11`, `@12.1`
are the AOSP tags `android-6.0.0_r1` and so on; `-22.2` is the branch
`lineage-22.2`. The confirmation found the research's line numbers two
to four off in places; a number here is the confirmation's where it
gave one.

### M.1 What the platform writes from Haven's process

`BluetoothGatt` and `BluetoothGattServer` run in the app's process and
log with `Log.d` under their own names. Through Android 16 QPR0 the gate
is `DBG = true`, a constant compiled into the platform: the same on a
user build, and nothing in Haven's build type changes it. From 16 QPR1
there is no gate ([V]: `fw/BluetoothGatt.java:41-42` @6.0, `:49-50`
@12.1, `-20.0:59-60`, `-23.0:64-65`; `-23.1:67`, `-24.0:71`;
`fw/BluetoothGattServer.java:44-45` @6.0, `-22.2:51-52`, `-23.1:56`).

**The address of whatever connected**, for the calls of §B.3. "Full" is
`AA:BB:CC:DD:EE:FF`; "tail" is `XX:XX:XX:XX:EE:FF`.

| Lines | API 23–33 | 34 – 35 QPR1 | 35 QPR2 | 36 (16 QPR0) | 16 QPR1 and later |
|---|---|---|---|---|---|
| **Call sites**, written as Haven calls — client `connect()`, `configureMTU()`, `discoverServices()`, `cancelOpen()`; server `cancelConnection()` | full | tail¹ | tail¹ | tail¹ | tail¹ |
| **Callbacks, first group** — client `onClientConnectionState` (at connect and at disconnect), `onConfigureMTU`, `onConnectionUpdated`, `onServiceChanged`; server `onServerConnectionState`, `onConnectionUpdated`, `onPhyUpdate`, `onExecuteWrite` | full | full | full | tail | tail¹ |
| **Callbacks, second group** — client `onSearchComplete`, `onPhyUpdate`; server `onMtuChanged` | full | full | tail | tail | tail¹ |

¹ The line prints the `BluetoothDevice`. Its `toString()` is the tail,
on API 34 and later, only for an app that targets 34 or later, and the
full address otherwise; Haven targets 35
(`haven/android/app/build.gradle.kts:48`).

- [V]: `connect()` (`fw/BluetoothGatt.java:723` @6.0, `:932` @12.1,
  `-20.0:977`; `-21.0:1200`, `-22.2:1195`, `-23.2:1104`; gone in
  `-24.0`); `onClientConnectionState` (`-21.0:375-378`, `-22.2:367-371`,
  `-23.0:380-385`, `-23.2:404-407`); `onConfigureMTU` (`-21.0:849-850`,
  `-22.2:849-850`, `-23.0:877-878`, `-23.2:834`); `onSearchComplete`
  (`-21.0:424`, `-22.2:419-420`, `-23.2:450`); the client's
  `onPhyUpdate`, `onConnectionUpdated`, `onServiceChanged`
  (`-22.2:298-301`, `:881-882`, `:917`; `-23.0:909-910`, `:947-948`);
  `onServerConnectionState` (`fw/BluetoothGattServer.java:97-98` @6.0,
  `-21.0:112-119`, `-22.2:107-109`, `-23.1:105-113`); `onMtuChanged`
  (`-21.0:361`, `-22.2:363-364`, `-23.2:359`); the tail
  (`fw/BluetoothUtils.java -21.0:201-206`, `-24.0:208-213`; on 13 it
  kept three bytes, `-20.0:184-189`); `toString()`
  (`fw/BluetoothDevice.java -20.0:1413-1415`, `-22.2:1065-1066`,
  `:1635-1640`, and its reference page).
- [V1]: the other four call-site lines, and the server's
  `onConnectionUpdated`, `onPhyUpdate` and `onExecuteWrite` — a peer
  triggers the last by sending Execute Write. The confirmation saw the
  server's whole family print the tail at `-23.0` (`:308-450`) and did
  not read each release.
- The branches for 15 and 15 QPR1 were not read for this table; 14 QPR3
  and 15 QPR2 on either side of them were, and F-13's own reading of
  15 QPR1 [A20] agrees for the second group. The client's callbacks in
  the last column were read at 16 QPR2, the server's at 16 QPR1.

What else is written:

- **Haven's UUIDs, on every release**: the characteristic's, in
  `setCharacteristicNotification() - uuid:`; the service's, in
  `addService() - service:` and `onServiceAdded() … uuid=` ([V]:
  `fw/BluetoothGatt.java:1159` @6.0, `-24.0:1776-1781`;
  `fw/BluetoothGattServer.java -21.0:1001`, `:143-146`, `-23.2:954`,
  `:134-137`). `registerApp() - UUID=` is a random value a registration
  ([V1]). They name no user: they say this phone ran Haven's mesh, in
  which role, and when.
- **A line a frame**, with the peer's address (`onNotify`,
  `onCharacteristicWrite`, `onDescriptorWrite`, `onNotificationSent`,
  the write requests): behind `VDBG`, a constant `false` through 16
  QPR0. From 16 QPR1 `VDBG` is `Log.isLoggable("bluetooth",
  Log.VERBOSE)`, so `setprop log.tag.bluetooth VERBOSE` from a shell
  turns them on ([V]: `fw/BluetoothGatt.java -23.1:647-648`,
  `-23.2:563-567`; `fw/BluetoothGattServer.java:275` @6.0,
  `-24.0:294-295`).
- **Whatever a callback of Haven's throws**: `Log.w(TAG, "Unhandled
  exception in callback", ex)`, message and stack ([V]:
  `fw/BluetoothGatt.java -23.2:276`; in the server's callbacks too from
  `-24.0`, `fw/BluetoothGattServer.java:118` and after).
- **Scanner, advertiser, adapter, the value classes**: registration
  numbers and fixed text, no identifier at the default level. One error
  line, `ScanRecord`'s `unable to parse scan record:`, would print a
  peer's raw advertising bytes; behind a service-UUID filter it is
  expected unreachable — an inference, untested ([V1], all of it).
- **This phone**: no line in the app's process prints its own address or
  its name ([V1]: the research's reading of the classes above; the
  confirmation did not look again).

**A GATT server is told of every LE connection of the phone.** On
Android 16 the stack calls every registered application's connection
callback for every link, and the server side passes it on unfiltered to
the `onServerConnectionState` line above ([V], the confirmation's
finding: `sys/stack/gatt/gatt_main.cc -23.0:927-949`;
`sys/bta/gatt/bta_gatts_act.cc -23.0:561-591`) — the user's watch,
earbuds, car, another app's link. For a bonded device the stack has put
the identity address in place of the one on the air (`gatt_consolidate`,
`-23.0:968-975`). Read on 16 only; observed nowhere; the client side not
traced (§M.9 item 7). If it holds where that line prints the address in
full — through 15 QPR2 — Haven's process would log, with no lever, the
fixed addresses of the user's own devices. So what Q-10 weighed as "the
address a peer showed everyone in range" is more than that, and nothing
Haven decides about its peers reaches it.

**Who can read a process's log.** `adb logcat`, with USB debugging on
and the computer authorized; a bug report, which needs Developer
options; an app holding `READ_LOGS` (`signature|privileged|development`),
asked at each use from Android 13; an ordinary app is given its own
uid's entries only ([V]: `core/res/AndroidManifest.xml:4521-4522`
@14.0.0_r1; `LogcatManagerService.java:73`, `:409`, `:413-417`
@13.0.0_r1; `logd/LogBuffer.cpp:638` @6.0. [V1]: the developer pages for
logcat and bug reports).

### M.2 The lever: from API 30 a process decides what its log calls write

Every line of §M.1 goes `android.util.Log` → `println_native` →
`__android_log_buf_write`, in the process's own `liblog` ([V]:
`Log.java:158`, `android_util_Log.cpp:94` @11; the second file is
byte-identical at Android 11, 13, 14 and
`LO/android_frameworks_base@lineage-23.2`). So does everything else the
process logs ([V]): `System.out` and `System.err`
(`RuntimeInit.java:430`, `:432` @11), the Flutter engine and Dart's
`print` (`fml/logging.cc:139`,
`shell/platform/android/flutter_main.cc:184` [A26]), and Haven's Rust
lines (`android_logger 0.15.1`, `src/lib.rs:100`, `:109`). Two public
NDK functions, each "available since API level 30" [A24], act on that
path.

**The floor — `__android_log_set_minimum_priority`**, "the minimum
priority that will be logged for this process".

- *Where it is checked.* `__android_log_buf_write` asks
  `__android_log_is_loggable` and returns before anything is written
  ([V]: `liblog/logger_write.cpp` ~318 @11; `-20.0:322`, `-21.0:381`,
  `-22.2:381`, `-23.2:388`, `-24.0:383`).
  `__android_log_write_log_message` does not check, so a caller that
  goes straight to it passes the floor; none is among the writers in
  Haven's process named above ([V]).
- *A property can only lower it, tag by tag, and is read live.* A line
  is written when its priority is at least the lower of the floor and
  the tag's property level ([V]: `liblog/properties.cpp` ~276-289 @11,
  `-20.0:245-255`, `-24.0:248-258`), the property being
  `log.tag.<tag>`, `persist.log.tag.<tag>`, `log.tag` or
  `persist.log.tag` (~112-119 @11). The lookup is cached against the
  property area's serial (~65, ~151-152 @11): a `setprop` made after
  the radio started counts at the next log call. A shell can set one
  and a vendor's image can ship one; that an app cannot is from memory
  (**[U]**).
- *Code in the process can move it.* libbase's `SetMinimumLogSeverity`
  writes the same value, `ScopedLogSeverity` puts an old one back when
  its scope ends, and `InitLogging` sets it from `ANDROID_LOG_TAGS`
  ([V]: `base/logging.cpp:564-568` @11). `android_logger` does not call
  it. Whether ART, the Flutter engine or a plugin does, in Haven's
  process, is **[U]**: the confirmation's search found nothing and was
  inconclusive.
- The value is atomic ([V]: `liblog/logger_write.cpp:148-151` @11).

**The logger — `__android_log_set_logger`**: `__android_log_buf_write`
→ `__android_log_write_log_message` → the function installed, in place
of the write to `logd` ([V]: `liblog/logger_write.cpp -24.0:358-377`,
`:383`).

- It sits after the loggability check. It is handed every line the
  check let through, and what it drops no property brings back, for any
  tag, set before or after.
- It is handed the crash buffer's lines too ([V]).
- The pointer is a plain static, not atomic ([V]: `-24.0:168`,
  `:173-174`): it has to be set before other threads log.
- The binary event-log, security and statistics writes skip the
  loggability check ([V]: the same file); whether they reach the logger
  neither pass says (**[U]**).

Below API 30 neither exists: Android 10's `__android_log_buf_write` has
no check, and there is no setter ([V]: `liblog/logger_write.cpp`
@10.0.0_r1); `DBG` is a constant and the write is unconditional. With
`minSdk` 23 (`haven/android/app/build.gradle.kts:43`) the two symbols
are looked up at run time — weak references under `__builtin_available`,
or `dlopen` and `dlsym`; `liblog` is on every release ([V]: [A24]).

**Decided here.**

1. **The logger is the lever.** It writes a line only when the line's
   tag is one of Haven's own, and drops every other line of the process,
   at every priority. The floor alone does not meet "all of them": a
   property set while the mesh runs lowers it for a tag, which a check
   made at the radio's start never sees, and code in the process can
   move it. Neither undoes a logger.
2. **The floor is the second line**, raised to `ANDROID_LOG_FATAL` with
   it (`SILENT` is documented as internal, [V1]), for the case that the
   logger is not what is in force.
3. **Before any Bluetooth object exists**, on every path that can start
   the radio: the channel's `start`, and the service's own start after
   a boot or a sticky restart, where no Dart isolate runs.
4. **For the life of the process once the mesh has been on in it.** GATT
   callbacks — a disconnect, a close, an MTU or connection update —
   arrive after mesh is turned off; taking the lever away then would let
   them through, and buy diagnostics only.
5. **Checked at ERROR, not DEBUG**: `Log.isLoggable(tag, Log.ERROR)` is
   false for each tag the platform's Bluetooth classes write under — the
   research lists them; M3g pins the list against the classes it calls.
   `Log.isLoggable` evaluates the function the write does ([V]:
   `android_util_Log.cpp:45-47`). The research proposed DEBUG. With the
   floor at FATAL and `log.tag.BluetoothGatt` set to E the threshold is
   E: DEBUG reads false while every warning and error of the tag is
   written, the "Unhandled exception" line among them. ERROR false is
   D, I, W and E all dropped.
6. **Checked again while the radio runs**, not only at its start: the
   property is live, and the check answers for the tags asked at the
   instant asked. How often is M3g's — a term of the one wake (§B.5),
   not a new alarm. A check that fails stops the radio (§M.3).

**What the floor costs — stated by neither pass.** The floor is one
value for the process, not one for each tag. While it stands at FATAL, Haven's
own lines below FATAL are dropped before the logger sees them, and the
logger's list decides only what is written where a property has lowered
the threshold. "Haven's own lines are still written" and "the floor
stands above ERROR" cannot both hold. Designed with the floor raised,
because the check of item 5 is the floor's and means nothing without it:
once the mesh has been on, Haven's process writes nothing below FATAL.
If M3g finds Haven's own lines must be kept (§M.8), the floor's level is
the owner's to decide; it is not lowered on the way.

**Haven's own tags, as defined today** — nowhere as a list of Android
tags for this purpose. What there is:

- Rust: the targets `haven_core` and `rust_lib_haven`, the allow-list of
  `HavenTargetFilter` (`api:168-193`). `android_logger` tags a record
  with its module path (`src/lib.rs:178-189` [A27]), so the Android tag
  is one of the two, or begins with one and `::`.
- Kotlin: `HavenApplication`, the one tag that has a log call — two
  rows, both of that file, in `scripts/ci/native_log_allowlist.txt`,
  held both ways by `check_native_log_allowlist.sh`.
- Dart: none of its own. `debugPrint` is `print`, which the engine
  writes under the engine's tag — `flutter`, in the scanner's policy —
  as it writes every Dart package's. In a release build it is a no-op in
  every entry point (`check_release_log_silencer.sh`).
- The runtime scanner's `owned_tags` (`tooling/logscan/policy.toml:135`):
  the lines the scanner answers for — `flutter`, the two Rust targets,
  `RustStdoutStderr`, `frb_user`, `HavenApplication`, `MainActivity`,
  `PublishWakeLock`. More than Haven's code calls a log under, and the
  shared `flutter` is among them.

**To be established by M3g, not guessed here:** the logger's own list —
which of these it holds, by what match (the scanner's is: equal, or the
entry followed by `::`), and what keeps one definition from drifting
from the others. A tag is free text any code in the process can write
under. `flutter` in the list passes every Dart package's `print`;
`flutter` out of it drops Haven's own Dart lines in a debug build.

**Where it lives is M3g's to settle.** The constraints:

- Both functions are NDK symbols; Kotlin cannot call them. It is native
  code: the Rust library — already loaded in `HavenApplication.onCreate`,
  which runs before any Activity, Service or worker
  (`kt/HavenApplication.kt`) — or a native source of a kind the app's
  build does not have today.
- In Rust it needs `unsafe`, for the symbol lookup and the C callback,
  in a crate that denies `unsafe_code` outside two pinned modules
  (§A.6, F-8): a third site is a change to that guard, and
  security-reviewer's. `libc` is not a direct dependency of
  `rust_builder` today; adding one is dependency-auditor's.
- The function runs inside `liblog`, on whichever thread logs: it must
  not log, block, allocate without bound or unwind into C.
- "Before other threads log" and "when mesh is first turned on" are
  different moments: by a turn-on the engine, the Rust runtime and the
  UI have been logging for the life of the process. Either the lever
  goes in at process start, in a build that has the mesh — and then
  §M.8's cost is every such process's, mesh on or off — or M3g shows
  that the late write of that pointer is safe. Not settled here.
- The floor can be read back (`__android_log_get_minimum_priority`,
  [V1]); neither pass names a read-back for the logger. "Installed and
  checked" (§M.3) needs a check that fails when the logger in force is
  not Haven's. What that check is, is M3g's.
- One process holds the UI, the location service and the mesh (F-14):
  the lever, and its cost, are all three's.
- What can be held where: the list's predicate, [L] or [J]; that the
  platform's lines are absent, only where `liblog` is — [E], §M.9
  item 1, which is also the planted-identifier proof Rule 15 asks of
  any change to what is logged.

### M.3 The rule

The owner's "all of them or the radio is not started" (Q-10), as it now
reads. The radio is started only where every one of these holds:

1. **API 30 or later.** Below it no lever exists.
2. **The lever of §M.2 — logger and floor — installed and checked**
   before any Bluetooth object exists; and a check that fails later
   stops the radio.
3. **Nothing that could bond** (§M.4).
4. The advertisement of §B.3: the service UUID, no name, no data, and
   not discoverable from API 34.

**What it costs: phones on Android 6 to 10 (API 23–29) cannot use the
mesh.** Haven's `minSdk` stays 23 and the rest of Haven runs there. The
research weighed one other route, for API 29 alone — L2CAP channels,
whose classes print no full address at the default level ([V1];
spot-checked by the confirmation at 15 QPR2) — and it is not taken: a
second transport, the same name exposure, for one release.

**How the native side says so.** The Dart side has the state:
`MeshRadioStart.unsupported` (`haven/lib/src/services/mesh_radio.dart:32-33`)
becomes `MeshTurnOn.unsupported` and sets `meshUnsupportedProvider`, and
`meshAvailableProvider` then takes the button, its sheets, the Settings
row and the aura away for the life of the process
(`haven/lib/src/providers/mesh_provider.dart:324-328`, `:486-495`); the
copy is `meshErrorUnsupported`. Plan §16 keeps `unsupported` for
"hardware that can never run the mesh", anything passing being `failed`,
because of what Dart does with it. An Android release is not hardware,
and is as fixed for a process: the plan's sentence is widened to say so
(plan §16), and the code's two comments that say "hardware" are M3g's to
reword. So:

- API below 30, or either symbol not found: the channel's `start`
  answers `unsupported` — before `startForeground`, before any Bluetooth
  object, with nothing stored by the service.
- The lever in, and a check failing: `failed` at a start; for a running
  radio, a stop the user did not make, with the stopped notice (§B.5).
- The service's own starts — boot, a sticky restart — make the same
  checks first. Below API 30 they have nothing to resume: no start ever
  set the flag.

**Not as the Dart side is built.** `unsupported` is learned at step 5 of
turning on (§C.2): after the intro sheet and the name step, and after
`mesh.start()` stored the deadline and the keys, which the unwind then
deletes. On an Android 6–10 phone with the flag on, the button is there
until its first tap in each process. Answering before the button is
drawn is a change to the seam of §C.1 — M3g's, with its [D] test.

### M.4 Never bond

A bond would hand a stranger this phone's identity address and the key
that resolves every address it rotates to (**[U]**: the specification,
from memory; not fetched). Haven needs none: every byte after the
handshake is sealed by Haven (plan §6.7).

- **Haven asks for no security.** The stack answers "insufficient
  authentication" or "insufficient encryption" for an attribute only
  under a permission bit that asks for it ([V1]:
  `sys/stack/gatt/gatt_db.cc -22.2:74-122`, `:604-664`). Haven's
  characteristic and descriptor carry none, nothing calls `createBond`,
  and the transport is `TRANSPORT_LE`.
- **A peer can make the phone ask.** When an operation is refused with
  ATT 0x05 or 0x0F the framework sends it again asking for
  authentication — `AUTHENTICATION_NO_MITM`, then `AUTHENTICATION_MITM` —
  before the app's callback runs: in `onCharacteristicRead`,
  `onCharacteristicWrite`, `onDescriptorRead` and `onDescriptorWrite`,
  on every release read ([V]: `fw/BluetoothGatt.java:329`, `:389`,
  `:477`, `:530` @6.0; `-22.2:493`, `:564`, `:679`, `:741`; `-24.0:483`,
  `:546`, `:640`, `:692`). Haven reads nothing, and its frames are
  writes without response, which have no answer to refuse. The
  descriptor write of §B.3 has one: a hostile peer that refuses it
  starts a pairing from this phone. And as a peripheral, any central
  may ask to pair (**[U]**, memory).
- **The user is asked first**, on a phone with a screen, on the Just
  Works path ([V]: `sys/stack/smp/smp_act.cc -22.2:1431-1438`). So the
  harm is a system dialog a stranger can raise, and a bond if the user
  accepts it, which no public call removes.
- **The one public lever** is `ACTION_BOND_STATE_CHANGED`, which needs
  `BLUETOOTH_CONNECT` and no more ([V], [A25]): a device Haven is linked
  or linking with that enters `BOND_BONDING` has its link dropped at
  once (§B.3). Nothing better is public ([V], [A25]):
  `setPairingConfirmation` is privileged; `cancelBondProcess` is public
  only from API 37, and privileged for a bond the app did not start;
  `removeBond` is not public.
- **Unproved**: that dropping the link ends the pairing before keys are
  exchanged, and whether the dialog shows for a moment all the same
  (§M.9 item 4). The reference says of `setDiscoverable(false)` that
  "devices connecting to non-discoverable advertisements cannot
  initiate bonding" [A16]; neither pass found code that enforces it —
  the flag is stored and no pairing code read uses it ([V]:
  `sys/stack/btm/btm_ble_sec.cc -22.2:1541`) — so nothing rests on it
  (§M.9 item 5).

### M.5 This phone's address: the identifier Haven does not decide

- **An app cannot choose it.** `setOwnAddressType`, on both advertising
  builders, is a system API that needs `BLUETOOTH_PRIVILEGED` ([V]:
  `fw/le/AdvertisingSetParameters.java -22.2:549-556`; absent from the
  public reference [A16]). Nor read it: `BluetoothAdapter.getAddress()`
  answers a constant since Android 6.0 ([V1]).
- **AOSP's default is private and rotating, in both roles — and it is a
  build's setting.** LE privacy is on by default: a compile-time value
  a vendor's header overrides on Android 6 to 12L, a system property
  from 13 — from 14 `bluetooth.core.gap.le.privacy.enabled`, default
  true ([V] from 14: `sys/btif/src/btif_dm.cc -21.0:2256-2260`,
  `-24.0:2397-2400`; [V1] before). With it on, an advertisement goes out
  under a resolvable private address and a dial under the host's current
  one ([V1]). With it off the stack's own comment is "always use public
  address" ([V1]: `sys/stack/btm/btm_ble_gap.cc -22.2:755-757`).
- **Rotation.** Every 15 minutes on Android 6 to 11; at a random 7 to
  15 minutes on 12L and 13 ([V1]); the same from 14, where two system
  properties let a device move both ends ([V]:
  `sys/main/shim/acl_api.cc -21.0:84-88`). From 15 QPR2, behind a flag
  whose default was not read: at the first moment the phone is awake
  after about 7 to 9 minutes, and by 13 to 15 at the latest ([V]:
  `sys/gd/hci/le_address_manager.cc -22.2:571-600`).
- **Stopping and starting the advertisement gives a new advertising
  address** where the controller has extended advertising or Android's
  multi-advertising command, and not where it has neither. There, from
  12L, the advertisement goes out under the address the phone dials with: a
  peer that is dialled and also sees the advertisement can tie the two
  roles until the next rotation ([V1]:
  `sys/gd/hci/le_advertising_manager.cc -22.2:455-471`; the confirmation
  did not look again).
- That such an address cannot be traced to the phone without a bond is
  the specification's, from memory (**[U]**).

**What Haven can and cannot say.** It can say that it never bonds, dials
over LE only, and puts nothing in the advertisement but the service
UUID. It cannot say that this phone's address is private, or that it
rotates: that is the build's, an app can neither set it nor find out,
and no vendor's stack was read. On a phone whose vendor turned LE
privacy off, a fixed address is on the air in both roles, and in every
peer's records, and Haven does not know. Of the identifiers Q-10 lists
this is the one Haven's choices do not decide, and **nothing in this
design may say that all identifiers are random.** Restarting the
advertisement on a schedule, to retire an address sooner than the
platform does, was weighed by the research and is not designed: the
rule does not need it, and it does nothing on the controllers above.

### M.6 A peer's address type: not designed in

`BluetoothDevice.getAddressType()` is public from API 35 and answers
public, random, anonymous or unknown, "random" being resolvable,
non-resolvable and static alike ([V], [A25]). It means something for a
scan result, which the Bluetooth process builds with the real type
([V]: `le_scan/TransitionalScanHelper.java -22.2:385`). The device a
GATT server is handed is built from the address alone and always says
public, through 16 QPR0 ([V]: `fw/BluetoothGattServer.java
-22.2:121-122`, `fw/BluetoothDevice.java -22.2:1571-1573`); from 16
QPR1 it is not known (**[U]**). So "refuse a peer whose address is not
private" can be decided only for a link this phone dials, on API 35 and
later — and telling a static address from a private one there rests on
the address's top bits, from memory of the specification (**[U]**).

The research proposed it, to keep fixed addresses out of logs. It is
not designed in:

- With the lever, no address is written from Haven's process, private or
  fixed. The condition it served is met without it.
- What is left is the Bluetooth process's own record (§M.8). To keep a
  fixed address out of that, the refusal would have to hold in both
  directions, and it cannot: two Haven phones link both ways (plan
  §6.1), and the incoming half cannot be judged on any release read.
  The other devices of §M.1 it does not touch at all.
- It costs links: a phone whose vendor does not randomize could no
  longer be dialled by a newer phone.

A rule that holds for one direction on two API levels is the "some
parts" Q-10 rules out. Should the owner want the partial form, it is one
check before `connectGatt`.

### M.7 The device name

- **The characteristic.** Android's own Generic Access service is on
  every LE link, in either role, and carries Device Name. Through
  Android 13 any connected peer may read it ([V]:
  `sys/stack/gap/gap_ble.cc -20.0:438`; Android 6 and 7 [V1]). From
  14 QPR3 its permission is "encrypted, or discoverable" ([V]:
  `-21.0:425`, `-22.2:460`, `-24.0:468`); whether Android 14.0.0 itself
  has it is **[U]**.
- **A peer this phone dials can always read it.** That permission passes
  without encryption when the link "can read discoverable
  characteristics", and for a link this phone made as the central the
  stack answers true — its comment: "if we are the central, the peer can
  always see discoverable characteristics" ([V]:
  `sys/stack/gatt/gatt_db.cc -22.2:111-122`; `sys/main/shim/acl.cc
  -21.0:1673-1684`, `-22.2:1606-1617`, `-24.0:1408-1419`). There is no
  setting, on any release.
- **`setDiscoverable(false)`**, from API 34 [A15, A16], does two things.
  A peer that connected in is refused the name unless the link is
  encrypted: incoming links only. And the stack no longer adds the Flags
  field, which it adds only to an advertisement that is connectable and
  discoverable ([V]: `sys/gd/hci/le_advertising_manager.cc
  -22.2:1056-1070`; `fw/le/BluetoothLeAdvertiser.java -22.2:151`,
  `:165`): §B.3's 21 bytes are 18 from API 34. On a controller with
  neither extended nor multi advertising the stack ignores the setting
  for the name — such a link always counts as discoverable, under a
  TODO ([V]: `sys/gd/hci/acl_manager/le_impl.h -21.0:510-522`,
  `-22.2:543`, `-24.0:621`).
- **From Android 16 the stack reads a peer's name itself**, on every LE
  connection, in either role, with no app asking; at 15 QPR2 the same
  code is behind a flag; at 14 QPR3 it is absent ([V]:
  `sys/stack/btm/btm_ble_sec.cc -22.2:1575-1579`, `-23.0:1614-1617`,
  `-24.0:1310-1313`; `sys/stack/acl/btm_acl.cc -23.0:967-983`). So every
  Android 16 phone a Haven phone dials fetches this phone's name, and a
  Haven phone on 16 fetches its peers' — into the Bluetooth process,
  not Haven's. That the name is then stored, and logged in clear: the
  code is there (`sys/btif/src/btif_dm.cc -23.0:1912`, `:1917-1918`),
  the path from the read to it was not traced, and what a user build
  keeps of that log level is not known (**[U]**; §M.9 item 6). The same
  stack may read Appearance too, behind a flag — a device category, not
  an identifier ([V] for the code: `btm_ble_sec.cc -23.0:1619-1634`;
  the flag's default **[U]**).
- **Renaming the phone.** `BluetoothAdapter.setName` needs
  `BLUETOOTH_CONNECT` (`BLUETOOTH_ADMIN` on API 30) and is open to an
  ordinary app ([V]: [A25];
  `AdapterService.java -22.2:2439-2450`). It renames the phone for every
  Bluetooth use — the car, the headphones, every pairing list — and the
  Bluetooth process logs the new name. It is a way, and not Haven's to
  take without the owner's word (Q-11). Neither pass found another.

**Conclusion (Q-11): accepted and disclosed, with
`setDiscoverable(false)` where it exists.** That withholds the name from
peers that connect in, on API 34 and later, on controllers that honour
it. Nothing withholds it from a peer this phone dials. The disclosure is
built (§D, §E.2). Unproved, and bearing on M4: whether an iPhone finds
an advertisement with no Flags field — the research's memory is that
CoreBluetooth does not need one — and what an iPhone answers for its
own name.

### M.8 What is left, and what the lever costs

**Left, with all of the above in force, on a phone the radio runs on:**

1. **The system's Bluetooth process**, under its own pid, and `dumpsys
   bluetooth_manager` in a bug report: that Haven's uid registered a
   client and a server; each link's time; each peer's address — in full
   in some lines of 13 and 14, its tail from 15 QPR2 in the lines read;
   and from 16 the names it read of peers ([V1], a brief reading, not
   an inventory; the names **[U]** as in §M.7). Outside Haven: nothing
   Haven does changes it.
2. **The system's crash records.** A `Log.wtf` and an uncaught exception
   have their lines dropped in the process and then go to
   system_server, which writes `am_wtf` or `am_crash` — the exception's
   class and message — and a DropBox entry ([V]: `Log.java:311-319`,
   `RuntimeInit.java:73-74`, `ActivityManagerService.java:9850-9854`,
   `:10059`, `:10065`, all @11). "Nothing thrown leaves the mesh thread"
   (§B.1) bounds it for the mesh; the record is of the whole process.
3. **Lines written before the lever was in**: in the log's buffer until
   it turns over, and in any capture already taken. No Bluetooth object
   existed then, so they hold nothing of the mesh. Whether an app may
   clear its own entries is **[U]** (§M.9 item 8).
4. **The name**: to every peer this phone dials, on every release; to
   every peer on API 30 to 33; and to every peer on 34 and later where
   the controller ignores the setting.
5. **Appearance**, to an Android 16 peer.
6. **This phone's address, fixed**, on a build that does not randomize
   it (§M.5).
7. **On every peer's phone**: this phone's address of the moment and,
   where it could be read, its name.
8. A packet capture the user switched on in Developer options holds
   everything on the air (**[U]**, memory).
9. **Android 6 to 10: no mesh.**

Not on this list, and not ruled out: lines in the event and statistics
buffers, which never pass through the logger and which the lever
therefore cannot reach (§N: N-1, N.1.6, N.6).

**What the lever takes from Haven itself**, for the whole process and
for as long as it lives:

- Every line the logger does not list: the Flutter engine's, Dart's
  `print` and `debugPrint`, `System.out` and `System.err`, a Java
  crash's stack, every plugin's and every dependency's ([V], §M.2). And
  while the floor stands, Haven's own listed lines below FATAL with
  them.
- **Debug builds.** Once the mesh has been on in a process, logcat shows
  nothing of what Haven does afterwards — the relay path, the location
  service and the UI included. A release build loses its Rust warnings
  and errors (`api:158-164`); its Dart side is silent already.
- **CI lanes that read logcat.** The runtime scanner asks every `logcat`
  capture for positive controls — a Rust and a Kotlin token written at
  launch, and the harness's Dart token (`tooling/logscan/policy.toml:135`;
  `tooling/logscan/README.md`, "Positive controls") — and each proves
  only that the process reached the sink when it was written. After the
  lever is in, a scan that finds no identifier under Haven's pid has
  read no line of Haven's: it says nothing of Haven's own lines, and
  nothing of the platform's unless something shows the capture was
  live. **Required of M3h, and not designed here:** a lane with the mesh
  on does not count such a scan as a pass. It shows, with an address
  planted through a real link in each role, that no line of the
  platform's is under Haven's pid at any priority; it shows, by a
  control that is not one of the dropped lines, that the capture was
  live and was that process's; and what it still claims of Haven's own
  lines (T-LOG-1) it proves by something that is written. The three
  relay lanes that gain a `mesh` input (§F.2) come under the same
  requirement.

### M.9 To be proved on a device or an emulator before the flag flips

None of it is proved. Each is [E] where an emulator's Bluetooth stack
can show it — itself unproven (§F.3) — and [H] otherwise; a vendor's
build is always [H].

1. **The lever leaves Haven's pid empty.** Proved by: a full link in
   both roles with an address planted, then the log filtered to Haven's
   pid holding no line of the platform's — on API 30, 33, 34, 35, 36 and
   on vendors' builds, whose `liblog` and Bluetooth classes are unread.
2. **Nothing in the process moves the floor.** Proved by: the minimum
   read back unchanged across a session with the engine, every plugin
   and the location service running.
3. **The check sees a property.** Proved by: `log.tag.<tag>` set to E
   over `adb`, and `Log.isLoggable(tag, Log.ERROR)` turning true and the
   radio stopping.
4. **Dropping the link ends a pairing.** Proved by: a peer that refuses
   the descriptor write, and a central that asks to pair; no bond is
   stored afterwards; and whether the system's dialog showed.
5. **`setDiscoverable(false)` and bonding; iPhones and Flags.** Proved
   by: a peer connected to the non-discoverable advertisement failing
   to start a bond; and an iPhone's scan reporting an advertisement
   that has no Flags field (M4).
6. **The Android 16 name read, on a user build.** Proved by: a name
   planted on a peer, a link, and the Bluetooth process's log and its
   store searched for it.
7. **The server's callback for the phone's other connections.** Proved
   by: a second device connecting to the phone and not to Haven, and
   whether the server's callback fires in Haven's process, on each
   release.
8. **Whether an app may clear its own log entries.** `logd` lets a
   client without privilege clear its own uid's ([V]:
   `CommandListener.cpp -22.2:87-96`); whether SELinux lets an app send
   the command is unread. Proved by: trying it.
9. **What the source read could not settle**: the address type a
   16 QPR1 server-side device carries; Android 14.0.0 against 14 QPR3
   for the name's permission; the defaults of the flags
   `name_discovery_for_le_pairing`, `non_wake_alarm_for_rpa_rotation`
   and `read_le_appearance`. Proved by: the AOSP host, once it can be
   read, for the first two; a phone of each release for the flags.

### M.10 Where the confirmation and the research differ

The confirmation is followed in each.

- **The check.** The research: `isLoggable(tag, DEBUG)` false proves the
  floor. Contradicted: it must be ERROR (§M.2 item 5).
- **The lever.** The research: the floor, with the logger "the finer
  alternative". The confirmation: the logger, or both — a property is
  read live, and libbase's setters move the floor (§M.2). It also added
  that `__android_log_write_log_message` skips the floor, that the
  logger's pointer is not atomic, and that the lever stays for the life
  of the process.
- **"Silences the process."** Not as a whole: `Log.wtf` and a crash
  leave for system_server (§M.8 item 2).
- **Added by the confirmation**: the server's callback for every LE
  connection of the phone (§M.1); `cancelBondProcess` from API 37, no
  lever (§M.4); Appearance (§M.7).
- **Narrowed**: the research states that a 16 stack logs and stores the
  name it read; the confirmation found the code and not the path to it,
  nor what a user build keeps (§M.7).
- **Line numbers**: the confirmation's.

Not from either pass, and this design's own: that the floor costs
Haven's own lines (§M.2); that a peer's address type is left out (§M.6),
which the research proposed and the confirmation called decidable; the
mapping to `unsupported` and `failed` (§M.3).

---

## N. M3g as it will be built

> **Drafted by one agent and confirmed with changes by an independent
> review, both 2026-11-12.** Paper only when written; unit 1 has been
> built since (N.7), and nothing of this section has run on Android.
> It settles what §M.2 left to M3g, orders the unit into six that CI can
> compile one at a time, and lists what the code will rest on unproved.
> Where it departs from §B, §C or §M it says so.

### N.0 What was read, and what it changes

Tags as §1. **[V1]** here is a source fetched and read for this draft
alone, on 2026-11-12, in §M.0's mirrors and short forms; `base/` is
libbase (`AM/platform_system_core` at Android 11). Also read: the
Flutter SDK this machine has, 3.44.8, the version the coverage pin
names (`scripts/ci/coverage_toolchain.env:46`; the build lanes float on
`channel: stable`, `build-check.yml:111`); the crates as
`haven/rust_builder/Cargo.lock` resolves them; the plugins in the pub
cache; `developer.android.com/reference/tools/gradle-api/8.11/`.
`dl.google.com` and `android.googlesource.com` were not reachable.

**What the confirmation changed.** It read the cited code again — one
cite was false, N.2.8's "hardware" — and more of the Bluetooth stack
than the draft had, and found two things unsound and four missing. Each
is folded in where it belongs:

- **U-1**, the server's MTU rule and the dial's order: N-6 is withdrawn,
  the MTU is kept with its connection (N.2.3), §B.3's order stands
  (N.2.4).
- **U-2**, a pairing asked before the subscription: stated in N.2.5 and
  put to the owner (Q-15).
- **M-3**: the lane reads the buffers the lever cannot reach (N.1.6),
  and the owner is told (N.6; §M.8).
- **M-4**: the library's `__android_log_*` imports are held to a list,
  not to five names (N.4).
- **M-5**: taps are held until an engine's first `takeAction` (N.2.8).
- **M-6**: the service calls `startForeground` before it may refuse
  (N.1.5).

**Confirmed in source, where the draft had [U]**: one `liblog` a
process — the linker answers a library already loaded in a linked
namespace with that one (bionic's `linker.cpp` at Android 11 only,
`find_library_in_linked_namespace`); `addStaticManifestFile`, from AGP
8.3.1 and still in the 9.0 reference; `buildConfig = true`, set;
`-Pdart-defines`, as read in Flutter 3.44.8 and not read for 3.50.
**Read after the confirmation, by the revision alone**, and so [V1]:
N-7, and the source of N-5.

| # | Finding | Consequence |
|---|---|---|
| N-1 | **The event, statistics and security buffers never reach the logger.** Each ends in `write_to_log` ([V1]: `liblog/logger_write.cpp:416-518` @11, `-22.2:487-579`); the logger is called from `__android_log_write_log_message` alone, and only for the main, system, radio and crash buffers (`:295-315` @11, `-23.2:363-383`). | Settles §M.2's **[U]**. The lever does not cover those buffers. Whether Android's Bluetooth classes write to them from an app's process is unread (N.5). |
| N-2 | **Calling an API-30 symbol through an `extern` declaration would stop the library loading on Android 6 to 10** — an import the linker cannot bind there (**[U]** for the exact failure, memory). `android_log-sys 0.3.2`, in the lockfile (`Cargo.lock:89-93`), declares one ready to call (`src/lib.rs:99`). | Every one of the lever's symbols is found with `dlsym`, and the built library's `__android_log_*` imports are held to a list of old ones (N.4). All of Haven on those phones depends on it, not the mesh alone. |
| N-3 | **The library already exports a `Java_*` symbol that is not the radio's**: `Java_io_crates_keyring_Keyring_00024Companion_initializeNdkContext` (`android-native-keyring-store 0.5.0`, `src/lib.rs:36`; called at `kt/HavenApplication.kt:57`). | The `nm -D` step §A.6 owes cannot hold the library to "exactly the fixture": it holds it to the fixture and that one name. |
| N-4 | **A tap on a notice that starts the app is lost.** The Dart side sets the state channel's handler when either stream is first listened to (`mesh_radio.dart:208-214`); the mesh's providers listen to `changes` (`mesh_provider.dart:164-167`), the button to `actions` only when it is built (`mesh_button.dart:73`), and a message with no listener of its kind is dropped (the contract test "with nobody listening…", `test/services/mesh_radio_test.dart:267`). The channel has no listen call the native end could wait for (`mesh_radio.dart:197-201`). | A pull, `takeAction` (N.2.8). |
| N-5 | **A service started with `startForegroundService` that ends without `startForeground` takes its process down**: bringing it down while the foreground start is still owed posts a crash of the app ([V1]: the confirmation's copy of `ActiveServices.java`, a release before 14, `:4193-4212`, `:5279-5287`; later releases unread). The process is the relay path's (F-14). `StartPolicy.start` refuses before `foreground()` (`kt/mesh/core/StartPolicy.kt:22-23`). | Whoever would start the service asks first, and the service calls `startForeground` before it may refuse (N.1.5). |
| N-6 | **Withdrawn by the confirmation.** The draft had the dial subscribe first and the server wait for `onMtuChanged`, so as to keep nothing of a device before its subscription. From Android 14 a request for an MTU on a link that already has one is answered locally and nothing goes over the air ([V]: `sys/bta/gatt/bta_gattc_act.cc -22.2:817-838`; `sys/stack/gatt/gatt_api.cc -22.2:894-927`, `-21.0:880-917`). A server is told of an MTU only when the peer's request comes in (`sys/stack/gatt/gatt_sr.cc -22.2:857-917`), never when this phone's own client made the exchange (`sys/stack/gatt/gatt_cl.cc -22.2:1127-1165`). On a link whose MTU was agreed before the subscription the event the draft waited for never comes: two Android 14 phones that dial each other over one connection (§M.5), and any peer that agrees the MTU as it connects. | The MTU is the connection's, kept in memory while the connection lives (N.2.3). §B.3's order stands (N.2.4). |
| N-7 | **On the one release read, a GATT server cannot end a connection it did not make.** `cancelConnection` reaches `GATT_Disconnect`, which takes the calling app off the link's holders and does nothing more when it was not one ([V1]: `sys/btif/src/btif_gatt_server.cc -22.2:383-393`; `sys/bta/gatt/bta_gatts_act.cc -22.2:485-516`; `sys/stack/gatt/gatt_api.cc -22.2:1733-1749`; `sys/stack/gatt/gatt_main.cc -22.2:329-362`, `:376-390`). An app is a holder by its own connect (`gatt_main.cc -22.2:993-1012`). And a link on which this phone was only ever a server is never timed out (`sys/stack/l2cap/l2c_utils.cc -22.2:2792-2798`). Not traced: the framework's Java between the call and `btif`; any other release. | Settles §K's **[U]** for 15 QPR2, as read. There, §B.4's cancel, a refused write's close and the engine's close of a link this phone took are Haven forgetting the device: the peer stays connected until it leaves (N.2.3, N.5). |

### N.1 The lever

**N.1.1 Where: a third pinned module, `haven/rust_builder/src/log_lever.rs`.**
`mesh_jni.rs` is held to `use`s and exports (guard check 3,
`check_mesh_radio.sh:71-83`); a callback and a lookup there would end
the one shape that check reads. `lib.rs` gains `#[allow(unsafe_code)]
mod log_lever;` under the `cfg` line of the other two (`lib.rs:17-21`).

- **What is `unsafe` there**, and nothing else: `dlopen`, `dlsym`, the
  cast of what `dlsym` answers to a function pointer, the calls through
  those pointers, and — in a debug build's arm only — reading two
  fields of the message handed in. The callback is `extern "C"`, a
  keyword check 1 bans outside the allowed files.
- **How the symbols are found.** `libc::dlopen("liblog.so", RTLD_NOW)`,
  then `dlsym` on that handle, once; the handle is never closed. Not
  `RTLD_DEFAULT`: its value and `RTLD_NOW`'s differ between Android's
  32- and 64-bit ABIs (`libc 0.2.180`,
  `src/unix/linux_like/android/b32/mod.rs:196-197`, `b64/mod.rs:153-154`)
  — the reason the constants come from `libc` and are not written out —
  and what it searches from an app's library is bionic's rule, unread.
  Not an `extern` block (N-2). Stable Rust has no weak linkage (**[U]**,
  memory).
- **Dependency.** `libc = "0.2"`, for Android and as a dev-dependency
  for the host's type-check and tests, as `jni` is
  (`haven/rust_builder/Cargo.toml:56`, `:105`). The lockfile holds
  `libc 0.2.180` (`Cargo.lock:2171-2172`): `rust_lib_haven`'s list
  (`:3557-3580`) gains `"libc"` and no package. The other two lockfiles
  do not change. `check_lockfile_universe.sh` and
  `check_mdk_supply_chain.sh` read the MLS, MDK, SQLCipher and nostr
  crates and need nothing. dependency-auditor on the direct use;
  security-reviewer on the module and the third allowance.
- **The five symbols**, each "available since API level 30" ([V1]:
  `liblog/include/android/log.h -22.2:207-228`, `:233`, `:253`, `:265`,
  `:275`, `:369`, `:378`):

  ```c
  struct __android_log_message {
    size_t struct_size; int32_t buffer_id; int32_t priority;
    const char* tag; const char* file; uint32_t line; const char* message; };
  void    __android_log_set_logger(void (*)(const struct __android_log_message*));
  void    __android_log_logd_logger(const struct __android_log_message*);
  void    __android_log_write_log_message(struct __android_log_message*);
  int32_t __android_log_set_minimum_priority(int32_t);   /* answers the one before */
  int32_t __android_log_get_minimum_priority(void);
  ```

  The struct is declared in the module, `#[repr(C)]`, its size and
  offsets asserted at compile time for both pointer widths ([L] for the
  host's, [C] on the arm leg of `build-check.yml`).
- **The callback** adds one to a static atomic counter. In a release
  build that is all of it: it reads nothing of the message. In a debug
  build it then reads `struct_size` and `tag` — a message shorter than
  the struct, or with no tag, is dropped — and hands the message, as it
  came, to `__android_log_logd_logger` when the tag passes N.1.2; that
  function writes straight to `logd` and cannot come back through the
  logger ([V1]: `liblog/logger_write.cpp:276-289` @11). It takes that
  function from a static `install` fills before it sets the logger; a
  thread that sees the logger first finds none there and drops the
  line. It never reads `message`. It calls nothing of the `log` crate,
  formats nothing, allocates nothing, takes no lock, indexes nothing
  and does no arithmetic but the wrapping add: nothing in it can panic,
  which matters because an unwind out of it aborts the process.
- **What the guard gains** (N.2, unit 1): the file among check 1's
  exemptions and `lib.rs`'s pinned declarations (checks 2 and 6, a
  third allowance and a fourth `unsafe_code`); and a check 13 of the
  file itself — of `libc` it names `dlopen`, `dlsym`, `RTLD_NOW` and the
  C types; its only string literals are the library's name and the five
  symbols; one `extern "C" fn` outside its tests; a pinned count of
  `unsafe` blocks and no `unsafe fn` or `unsafe impl`; no `no_mangle`,
  `export_name`, `link_section`, `static mut`, `JNIEnv`, `radio_`,
  `log::`, macro that formats, `unwrap`, `expect(`, `Box`, `Vec`,
  `String`, `Mutex` or `RwLock`; and no file of the crate names
  `android_log_sys` or, outside this one, any of the five. It is a
  reader of text, as §A.6 says of the rest.

**N.1.2 What is written: nothing in a release build; in a debug build,
Haven's own lines (recommended; Q-14).** The three forms, weighed:

| | (i) nothing, every build | (ii) Haven's tags, every build | (iii) release as (i), debug as (ii) |
|---|---|---|---|
| Privacy, shipped | nothing of the process is written | Rust warnings and errors, and whatever the engine itself writes under `flutter`; no floor behind it | as (i) |
| List to keep | none | one, shipped | one, in debug builds only |
| The floor (§M.2) | FATAL, as §M.2 decided | cannot be raised | FATAL in release; left alone in debug |
| Debugging | blind once mesh has been on | as today for Haven's lines | as today for Haven's lines |
| Lanes | every oracle read from Haven's log goes blind | few | few |

- **What goes blind under (i)**, in the lanes §F.2 gives a `mesh` input
  (found by reading the runners' marker tables, not every line):
  `e2e-background-catchup.yml` takes its verdict from Dart lines in
  logcat — `[CatchupWorker] bootstrap ok`, `sweep complete:` and the
  counters parsed from it, the two no-op lines, the loopback opt-in
  (`tooling/e2e/ci/run-m7-background-catchup.sh:217-220`, `:233-234`,
  `:1132-1146`); `e2e-fgs-publish.yml` from some twenty
  `[BackgroundTask]` and `[b1]` lines
  (`tooling/e2e/ci/run-b1-fgs-publish.sh:333-458`); and in every lane the
  scanner's Dart plant of the closing phase
  (`tooling/logscan/README.md`, "Positive controls"). `e2e-android.yml`
  was not read for this. Nothing replaces them today: each would need a
  second way out of the process, written for the test alone.
- **What goes blind under (iii)**: lines under tags that are not
  Haven's — in those runners, WorkManager's (`:227`, `:779`, `:890`,
  `:1226` of the catch-up runner), for which it already reads `dumpsys
  jobscheduler` beside the log (`:745`, `:1111-1119`). M3h moves those
  three reads to it.
- **Why (iii) proves what ships.** Both arms are one installed
  function and one check; they differ in one predicate, and the
  release arm writes a subset of what the debug arm writes. A lane that
  shows no platform line under Haven's pid with the debug arm shows it
  for the release arm. What only a release build has — the floor and
  its read-back — gets its own leg (N.1.6).
- **The list is the scanner's**: `owned_tags` of
  `tooling/logscan/policy.toml:135`, by the scanner's match (equal, or
  the entry and then `::`). A debug build then writes exactly the lines
  the runtime scanner answers for. Held by an [L] test that reads that
  line of the policy; no second list exists to drift. `flutter` is in
  it, so a debug build passes every Dart package's `print`: a debug
  build, on a developer's phone or a runner.
- **One function of the build's kind**, as `max_log_level` is
  (`api:97`, `:158-164`), so that both arms are tested in the one build
  `rust-check.yml` runs. The kind is the Rust library's: cargokit builds
  it in release for every Flutter mode but debug
  (`haven/rust_builder/cargokit/build_tool/lib/src/builder.dart:154`).

**N.1.3 The check: a sentinel the logger must take, and the floor read
back.** It replaces §M.2's item 5 and settles the "how often" of item 6.

- `holds()`: read the counter; hand `__android_log_write_log_message` a
  message for the main buffer with an empty tag and an empty text at
  ERROR — a message for any buffer but the default, main, system, radio
  or crash one returns before the logger
  (`liblog/logger_write.cpp -22.2:359-363`); true when the
  counter moved and, in a release build, the minimum priority read
  back is FATAL or above. That call goes to the logger in force
  without passing the floor (§M.2), and only Haven's callback moves the
  counter, so a counter that moved is a line that reached Haven's
  logger; a concurrent line can make it move too, and proves the same.
  ERROR, not FATAL: a FATAL message is first stored as the process's
  abort message ([V1]: `liblog/logger_write.cpp:308-312` @11). Where the
  logger in force is not Haven's, the sentinel is written: one empty
  line, and the radio is not started.
- **Why not `Log.isLoggable(tag, ERROR)`.** It reads the floor and one
  tag's property, and says nothing of the logger — the open point of
  §M.2. It needs a list of the platform's tags, which a module update
  can change under the app (§M.0). And with a logger that drops the
  line whatever its tag, a property changes nothing that is written:
  the check would stop the radio, or keep it from ever starting on a
  vendor's image that ships such a property, for no line saved. Both
  designs find a logger that was replaced only at the next check, so
  nothing is given up between checks.
- **What can undo the logger**: any native code in the process that
  calls libbase's `SetLogger` or `InitLogging`, which install their own
  ([V1]: `base/logging.cpp:400-405` @11). That is what the check is for.
- **When.** At every start (N.1.5), and as the first thing every input
  of `MeshRadioCore` does, before the time left (`MeshRadioCore.kt:137`):
  one JNI call, no timer. A check that fails puts the lever back —
  callbacks still arrive after a stop (§M.2 item 4) — and stops the
  radio as a stop the user did not make.
- §M.9 item 3 becomes: with `log.tag.BluetoothGatt` set to VERBOSE over
  `adb` during a link, nothing of the platform's appears under Haven's
  pid.

**N.1.4 When it goes in: at the first thing that touches Bluetooth, not
at process start.** The channel's `bluetoothOn`, `bluetoothName` and
`start`, and the service's own start, each begin with it. §M.2 item 3
names the last two; the first two make a `BluetoothAdapter` before any
start (§C.2, steps 2 and 3). Where the lever is refused they fail, which
the turn-on reads as "couldn't turn on" (`mesh_provider.dart:359-362`).
So a phone on API 30 or later whose `liblog` lacked a symbol — which
the NDK's contract excludes — would keep a button that fails, and never
reach the `start` that answers `unsupported`.

- **The late write is as safe as an early one.** The setter is a plain
  store of one pointer and the writer a plain load of it ([V1]:
  `liblog/logger_write.cpp:158-165`, `:314` @11; `-23.2:170-177`, `:382`;
  no lock on either release). On Android's four ABIs an aligned pointer
  is stored whole (**[U]**: the compiled `liblog` of no build was
  read); a thread that loaded the old pointer writes that one line. No
  Bluetooth object exists yet, so the line holds nothing of the mesh
  (§M.8 item 3). The race is the platform's own at any moment an app can
  call the setter: by `Application.onCreate` the runtime's own threads
  are running (**[U]**, memory), and `HavenApplication` has itself
  logged (`kt/HavenApplication.kt:44-46`). Process start buys nothing.
- **A process that never turns mesh on pays nothing**: no symbol is
  looked up and nothing of §M.8 applies to it. A user who opens the
  turn-on and backs out at the name step (§C.2) has the lever for the
  rest of that process.
- **Native code does not learn the flag for this.** The lever's only
  callers are the channel, which only flagged Dart calls
  (`mesh_provider.dart:34`, `:70-76`), and components that are in no
  flag-off manifest. The channel itself is registered only under
  `BuildConfig.HAVEN_MESH`, written by the Gradle switch that merges
  the manifest (N.3): a flag-off build has no native entry to the mesh,
  rather than one nobody calls.

**N.1.5 How Kotlin reaches it.**

- Two native methods on `MeshNative`, eleven in the fixture
  (`haven/rust_builder/fixtures/mesh_radio_exports.txt:28-36`):

  ```
  leverInstall ()Z - jboolean      // false: a symbol is missing
  leverHolds ()Z - jboolean
  ```

  `mesh_jni.rs` gains two exports of the one shape, `mesh_radio.rs` two
  functions, and `api.rs` the entries `radio_lever_install` and
  `radio_lever_holds`, so the guard's checks 3 to 5 read eleven of what
  they read nine of. Each runs under `radio_guarded(false, …)`: a panic
  is a lever that is not there. They take no engine lock and may be
  called from the main thread; every other export stays on the mesh
  thread (§B.1).
- A second pure interface, `LogLever`, beside `MeshEngineApi`:
  `MeshNative` implements both, and
  `theEngineInterfaceIsTheNineExportsOfTheFixture`
  (`haven/android/mesh-jvm/…/FixtureTest.kt:69`) becomes the two
  interfaces against the eleven lines, no method twice and no other.
- **`StartPolicy`** answers the channel's four words in place of a
  deadline or null:

  ```kotlin
  fun supported(api: Int, bluetoothLe: Boolean): Boolean    // api >= 30
  fun refusal(api, bluetoothLe, lever, permission): MeshStart?  // null: go on
  fun start(api, bluetoothLe, lever, wipePending, permission, engine,
            storedDeadlineMs, wallClockMs, foreground): Start   // Refused(word) | Run(deadline)
  ```

  `refusal`, in §M.3's order: below API 30 or no Bluetooth LE →
  `unsupported`, with the lever not called; `leverInstall()` false →
  `unsupported`; `leverHolds()` false → `failed`; no permission →
  `noPermission`. `start`, the service's: `foreground()`; then
  `refusal` again; then a logout's marker (N.2.7); then the engine, as
  today (`kt/mesh/core/StartPolicy.kt:24-32`).
- **Whoever would start the service asks `refusal` first** (N-5): the
  channel's `start` and the receiver. So `unsupported` and
  `noPermission` are answered with no service started and nothing
  stored.
- **The service calls `startForeground` before it may refuse.** Between
  the caller's `refusal` and `onStartCommand` the lever can stop
  holding, or a permission go; a refusal made then before
  `startForeground` is N-5's crash. So the service is in the foreground
  first — the notice needs no Bluetooth object and no lever — and a
  refusal after it is a stop from the foreground, with the stopped
  notice (none behind a logout's marker, N.2.7). Chosen over recording
  the crash as accepted: the process is
  the relay path's. It reverses M3f's order, permission before
  `foreground()` (`StartPolicy.kt:22-23`), and the clause of
  `aStartWithoutTheBluetoothPermissionIsAStopWithTheNotice` that
  `foreground` is not called: the two cannot both hold. The policy
  still reads the permission itself and still stops without it, which
  is what that test's mutation kills. Left: `startForeground` itself
  refusing on such a start (N.5).

**N.1.6 What is proved where.**

| Claim | Where |
|---|---|
| The predicate, for both kinds of build; the list is the scanner's | [L] |
| The callback counts every line and forwards only what passes — against a recording function in place of the platform's writer | [L] |
| `install` then `holds` against four stand-ins for `liblog`: true; false once another logger is installed; false in a release build once the floor is moved | [L] |
| A library without the symbols is no lever (looked up under a name that does not exist); the two calls a JNI export forwards answer false off Android, where no lookup is made; a panic answers false | [L] |
| `below API 30 → unsupported, lever untouched`; `no lever → unsupported`; `lever not holding → failed, before the permission`; in the service the foreground comes first and each refusal after it is a stop; a lever that stops holding stops the radio at the next input and is put back | [J] |
| The module's shape; eleven exports both ways | [G] |
| The lookup compiles for Android; the library exports the eleven and the keyring's one, and imports no `__android_log_*` symbol outside the list of N.4 | [C] |
| The symbols resolve; `leverHolds` is true; no platform line under Haven's pid; a property does not bring one back | [E], API 30, 33, 34, 35, 36 |
| The same on a vendor's `liblog` | [H] |

**Required of M3h**, so that the lane cannot pass on a capture nothing
was written to (§M.8). In a debug build, from the turn-on's own Dart
line onward: every line under Haven's pid carries an owned tag; at
least one such line is there; before the turn-on the same pid has at
least one line under a tag that is not owned — the capture shows such
lines while the lever is out; and, on a real Bluetooth stack, the
address planted through a link in each role is found under the
Bluetooth process's pid and under none of Haven's lines — searched for
in every buffer the capture can read (`logcat -b all`: the event and
statistics buffers too), since those are the ones the lever cannot
reach (N-1); a hit there under Haven's pid is the outcome N.6 names.
One leg with a release build: the radio is still running at the end of
the session
(`dumpsys activity services`, the notification) — so the floor's
read-back held — and Haven's pid has no line after the turn-on, with
the system's own lines about that pid as the proof the capture was
live.

### N.2 The build order

Six units. Each is pushed alone, compiles in CI with the flag off, and
adds nothing a default build can reach: until unit 6 no Dart call has
a native end, and from unit 3 a flag-on build is compiled by its own
job (N.3). Each records itself in plan §16 and here as "As built".
security-reviewer on units 1, 2 and 4 (§H) before each lands.

| Unit | Files (`kt/mesh/` unless a path is given) | Tests it adds | [C] only | Guard gains | Unproved until [E] / [H] |
|---|---|---|---|---|---|
| **1. The lever** | in `haven/rust_builder`: `src/log_lever.rs`, `lib.rs`, `api.rs`, `mesh_radio.rs`, `mesh_jni.rs`, the fixture, `Cargo.toml`, `Cargo.lock`; what `scripts/regenerate_frb.sh` rewrites for a changed `api.rs` — `frb_generated.rs`, `haven/lib/src/rust/`, `scripts/ci/generated_bridge.sha256`; `core/LogLever.kt` | [L] of N.1.6; the fixture test [J] | Android compile; the `nm` step | checks 1, 2, 4, 6 widened; check 13 | everything [E] of N.1.6 |
| **2. Pure additions** | `core/`: `StartPolicy`, `MeshRadioCore` (the lever), `GattClientSteps`, `ServerLinks`, `ChannelWords`, `MeshRadioConstants` (UUIDs, GATT integers) | [J] below | — | test names; the constants' one site | — |
| **3. `MeshNative`, the gate** | `MeshNative.kt`; `app/build.gradle.kts`; `app/src/mesh/AndroidManifest.xml` (permissions and the feature); `scripts/ci/check_mesh_manifest.sh` | the script's self-test [G] | the class compiles; both merged manifests | Kotlin half of check 4; the Gradle switch named once | that Kotlin finds the eleven symbols |
| **4. Radio adapters** | `MeshLoop`, `GattServerAdapter`, `GattClientAdapter`, `AdvertiserAdapter`, `ScannerAdapter` | — | all of it; the SDK's integers | callbacks inside `MeshThread.run`; the never-bond and advertisement bans | all behaviour (§B.3) |
| **5. The service** | `MeshService`, `MeshNotices`, `MeshPrefs`, `MeshReceiver`; the manifest's two components | — | all of it | the mesh manifest's shape; `startForegroundService` at two sites | lifecycle, notices, boot |
| **6. The channel** | `MeshChannel`, `kt/MainActivity.kt`; `mesh_radio.dart`, `mesh_provider.dart` | [D] below | the channel | words agree, Dart and Kotlin; registration under the flag | the whole, on a phone |

Rule for every adapter (§B.1): it reads the platform and calls it; what
to do is a pure function's answer. Where this section finds a decision
in an adapter it moves it: units 4 and 5 add no test because unit 2 has
taken what was testable.

**N.2.1 `MeshNative` and the library.** `object MeshNative :
MeshEngineApi, LogLever`, eleven `external` methods, and
`System.loadLibrary("rust_lib_haven")` in its initializer. Needed: the
bridge opens the library from Dart
(`haven/lib/src/rust/frb_generated.dart:73`), which registers nothing
with the class loader that JNI resolves a native method through
(**[U]**, memory). Safe twice: `Keyring` already loads it
(`haven/android/app/src/main/kotlin/io/crates/keyring/Keyring.kt:7-9`,
first used at `kt/HavenApplication.kt:57`). That a release build's
shrinker keeps the class and its native methods by name, as it does
`Keyring`'s, is **[U]** until a release build runs.

**N.2.2 One thread.** `MeshLoop` owns the `HandlerThread` and the one
function adapters are given: post this body, inside this start's
`MeshThread.run`. An adapter holds no `Handler`. Each start makes a
loop, a `MeshThread`, a core and adapters; a callback of an earlier
start posts to a thread that has stopped and is dropped
(`kt/mesh/core/MeshThread.kt:26-27`). One thing is read on the
platform's own thread before the post: below API 33 a notification's
value, which lives in the characteristic and is overwritten by the
next. From API 33 the platform has a second form of that callback and
of the write and notify calls that carries the value; each is
implemented once, and the older form does nothing where the newer is
called (**[U]**, memory of the reference; [C], [E]).

**N.2.3 The server: a device is Haven's from its subscription; a
connection's MTU is kept while the connection lives.**

- **Known.** A device is known from the moment it enables notifications
  on Haven's characteristic, and not before.
  `onConnectionStateChange(connected)` is not numbered, counted or told
  to the core, and a write from a device not known is dropped. Nothing
  Haven does reaches a connection that is the user's watch or another
  app's (§M.1).
- **The MTU is the connection's, not the subscription's** (N-6).
  `ServerLinks` keeps, in memory, the last MTU this process was told
  for each connected device: by the server's `onMtuChanged`, whatever
  the device, and by Haven's own dial's `onMtuChanged` for the address
  it dialled — the case in which a server is told nothing. It is the
  one thing kept of a device that is not Haven's. It is not a record
  in §M.1's sense, which is of what reaches a log: an address and an
  integer the platform handed this process and itself holds for as
  long as that connection lives, kept here no longer, as `PeerTable`
  keeps advertisers' addresses (§B.2). It is never logged, stored,
  numbered, counted or acted on, and one thing reads it: a
  subscriber's link.
- **Its bound.** An entry goes when either callback tells of that
  device's disconnect, and all go when the radio stops (§B.6; the
  service's end), so a disconnect that is never delivered leaks
  nothing past that. Live entries are as many as the controller
  connects at once; the map has a cap in `MeshRadioConstants` above
  that, eldest out first (**[U]**: no controller's limit was read. An
  entry pushed out while its connection lives costs that device one
  link that does not come up).
- **`onLinkUp(central = false)`**: at the subscription, where that
  connection's MTU is known and 51 or more; else at its next
  `onMtuChanged` of 51 or more. Once (§B.2).
- **`onConnected(link)`**: a subscriber whose MTU is not yet 51. It is
  numbered there and is one of the four not yet linked
  (`MeshRadioCore.kt:80-84`), ended by the core's ten seconds. Haven's
  own dial never is one (N.2.4); a peer that subscribes first is.
- **Down, and forgotten**: disconnect, notifications disabled, the
  core's `close`, or — as Q-15 is answered — the device starting to
  bond (N.2.5).
- **A write**: prepared, at an offset, or wanting a response — refused,
  and a linked device closed; from a device with no link — dropped;
  else `onFrame`. The descriptor write is answered success or a plain
  failure, never "insufficient authentication" or "insufficient
  encryption", which would start the peer's pairing (§M.4).
- **What `close` can do** (N-7). The device is forgotten, the engine
  told, and `cancelConnection` called — which on the one release read
  ends nothing: the peer stays connected until it leaves. The one
  sequence read that would end such a connection is Haven's client
  attaching to the connected device and detaching, which puts the link
  under the stack's idle timeout
  (`sys/stack/gatt/gatt_main.cc -22.2:1047-1057`,
  `sys/stack/l2cap/l2c_utils.cc -22.2:2796-2805`). It is not designed
  in: unproven, and over a connection both phones dialled on it would
  end both directions.
- All of it is `ServerLinks`, pure: addresses in, one of *connected,
  link up, link down, frame, cancel, answer, nothing* out. The adapter
  maps callbacks to its inputs and outputs to platform calls.
- **What this gives up, against §B**: §B.4's cap no longer counts a
  stranger who connects and never subscribes — nothing could act on
  one without acting on everyone's connections, and §H already lists
  it with no bound; and §B.3's bond watch no longer covers one
  (N.2.5).
- **For M4**: an iPhone that agrees its MTU as it connects (**[U]**)
  links at its subscription, by the note.

**N.2.4 The client: `GattClientSteps`.** §B.3's order, which the draft
had changed (N-6): connect (`TRANSPORT_LE`, no auto-connect) →
`requestMtu(517)` → at `onMtuChanged`, discover → enable notifications
and write the descriptor → at `onDescriptorWrite`, `onLinkUp(central =
true)` with that MTU → connection priority. The MTU the dial is told is
told to `ServerLinks` too (N.2.3). Pure, on an injected clock: each step
waits for its callback; a step that fails, an MTU below 51, 25 s without
a link, or a bond starting is disconnect, close and one
`onConnectFailed`; a connection that fails before its link is closed
and tried once more after 300 ms (§B.3); every `connect` is answered
exactly once.

**N.2.5 Never bond, and what the subscription rule costs it.** No
attribute of Haven's has a permission bit beyond read and write; no
call that reads a characteristic, writes one with a response, creates
a bond or answers a pairing (the guard bans the names). The service
registers for `ACTION_BOND_STATE_CHANGED` while it runs, and the two
pure classes decide.

- **As drafted — option (a) of Q-15.** A device they hold — one being
  dialled or linked, or one that has subscribed — that leaves
  `BOND_NONE` is ended at once; a device they do not hold — the user
  pairing headphones — is left alone.
- **This is less than §B.3 has.** §B.3 closes a device "Haven is linked
  or linking with", and tracked an incoming connection from its
  connection. Here a central is held only from its subscription, so
  one that connects to Haven's advertisement and asks to pair without
  subscribing (§M.4) is not held: the system's dialog shows, a bond
  follows if the user accepts it, and Haven closes nothing. Haven
  cannot tell that connection from the user's own (§M.1).
- **Option (b), designed so that it can be built in (a)'s place.**
  `ServerLinks` also keeps every device the server is told is
  connected — the MTU map, with an entry before any MTU is told, under
  the same bound and clearing — and a connected device that was not
  bonded (`EXTRA_PREVIOUS_BOND_STATE`) and starts to bond is ended,
  whoever's it is. The two options differ in one predicate of the pure
  class and one branch of the adapter.
- **"Ended"**: for a device Haven dialled, the client's disconnect and
  close. For any other, `cancelConnection` — nothing, as N-7 reads it —
  and under (b) then the attach and detach of N.2.3, unproven; whether
  either ends a pairing under way is §M.9 item 4.
- **Nothing narrower was found sound**: the server is told of a
  connection with no role and no word of which advertisement it
  answered (§M.1), and who began a pairing is not in the public
  broadcast (**[U]**, memory of the reference).

**N.2.6 Advertisement, scan, UUIDs.** The advertisement is
`addServiceUuid` and nothing else, no scan response, the settings of
`MeshRadioConstants`, and `setDiscoverable(false)` where the level is
34 or more (§B.3: 18 bytes there, 21 below). The scan is §B.3's; it
does nothing where `PermissionMatrix.canSearch` is false. The service
and characteristic UUIDs are two random 128-bit values drawn once,
when unit 2 is written, from the system's generator, and kept as two
`Long`s each beside the standard descriptor's; a [J] test holds the
six numbers. They are fixed for good from the first release that has
the flag on, and M4 takes the same numbers; until then a change costs
nothing.

**N.2.7 Service, notices, prefs, receiver.**

- `MeshService` is §B.5 and §B.6 over the classes above. Its stop's
  steps, in order: the adapters closed and `stopRadio()`; the alarm
  cancelled (after, §B.2); flag and copy cleared; the notification
  removed; the service and its thread ended. `holdAwake` is a timed
  lock that does not count, as `PublishWakeLock`'s
  (`kt/PublishWakeLock.kt:95-103`).
- `MeshNotices` follows the location notice: its own channel under a
  versioned id, low importance, hidden on the lock screen, title
  "Haven", the app's icon, fixed ids
  (`background_location_manager.dart:121`, `:129`, `:327-329`). Taps are
  activity intents with an extra (§B.5).
- `MeshPrefs`: one app-private file — the flag, the deadline copy, six
  strings.
- **Plan §16 (c): yes, the service reads the logout's marker.** A
  logout sets it and then stops the radio
  (`haven/lib/src/providers/identity_provider.dart:240`, `:253`); a
  process that dies between the two leaves the flag set, and
  a restart would resume a keyless engine for up to twelve hours after
  the user logged out. `StartPolicy` takes the marker as an input: set,
  the start is a stop with the flag cleared and no notice. It is read
  from the plugin's own file — `FlutterSharedPreferences`
  (`shared_preferences_android 2.4.23`,
  `LegacySharedPreferencesPlugin.java:34`), key `flutter.` and
  `kPendingMlsWipeKey` (`pending_mls_wipe_service.dart:67`); the guard
  holds the key to the Dart constant. Stopping the radio before the
  marker is written was weighed: the marker is first on purpose
  (`identity_provider.dart:221-230`).
- `MeshReceiver`, boot and package replaced: flag, deadline ahead,
  `refusal` — then `startForegroundService`, in the wrapper.

**N.2.8 The channel, as the Dart side has it** (`mesh_radio.dart:193`,
`:203-206`, `:228-235`, `:265-302`), registered in
`MainActivity.configureFlutterEngine` under the flag:

| Method | Argument | Answer |
|---|---|---|
| `permission`, `requestPermission` | — | `granted` / `denied` / `deniedForGood` |
| `bluetoothOn` | — | Boolean |
| `bluetoothName` | — | String or null |
| `openBluetoothSettings`, `sync`, `stop` | `sync`: the six strings | null |
| `start` | the six strings: `channel`, `on`, `paused`, `reminder`, `keepOn`, `stopped` | `started` / `noPermission` / `unsupported` / `failed` |
| `status` | — | `{state: stopped / running / paused, wanted, canSearch}` |
| **`supported`** (new) | — | Boolean: `StartPolicy.supported` — the level and the Bluetooth LE feature, no Bluetooth object, no lever |
| **`takeAction`** (new) | — | the tap held for this engine, once; else null |

On `haven.app/mesh_radio_state`: a status at every change; and
`openStats` or `keepOn` for a tap — but only once this engine has asked
`takeAction`. Until then every tap is held, whether it started the
activity or reached one whose Dart side is not listening yet;
`takeAction` answers what is held, once: `keepOn` if any held tap was
one, else `openStats` (Keep on opens the sheet too,
`mesh_button.dart:84-88`). A pure function.

- **Only `bluetoothOn`, `bluetoothName` and `start` touch Bluetooth**,
  and each behind the lever (N.1.4). The channel's construction and
  every other method make no Bluetooth object: `permission` and
  `requestPermission` read and ask permissions, `status` answers what
  the service published, `sync` and `stop` speak to the service and the
  preferences, `openBluetoothSettings` sends an intent, `supported`
  reads the level and a package feature, `takeAction` a held word.
  Held two ways: which methods are gated is a set in `ChannelWords`,
  with its [J] test, that the handler asks at one site; and
  `MeshChannel.kt` imports nothing of `android.bluetooth` — the two
  reads are an adapter of their own, reached only behind the gate [G].
- `requestPermission` is the activity's own request and its result
  (F-11); which of the three words it answers is one pure function.
  `sync` stores the strings; a running service then reads the engine's
  time left again, re-stores its copy, re-arms and re-words its notice
  (§C.3).
- Every method answers on every path: one `try` round the handler, a
  failure answered with a fixed code and no text of the exception
  (plan §16 (b); Rules 8, 15). `start` answers when the service has
  started or refused; the Dart bound and the unwind behind it
  (`mesh_radio.dart:124`, `mesh_provider.dart:330-332`) are what bound
  it, and no native timer is added.
- Plan §16 (a): the service writes the flag and publishes its state
  before `start`'s reply is posted. `stop` clears flag and copy whether
  or not a service runs: the launch's retry calls it before any service
  could (`haven/lib/main.dart:166-168`).
- **The seam's two changes**, each with its [D] test. A new entry,
  `supported()`: `meshAvailableProvider` (`mesh_provider.dart:491-495`)
  is false until it has answered true, so no button is drawn and then
  taken away (§M.3); an answer that fails is "no". `actions` asks
  `takeAction` when it is first listened to (N-4). Two comments are
  reworded for an Android release that cannot run the mesh: the one
  that says "hardware" (`mesh_provider.dart:483-485`), and "This phone
  has no radio the mesh can use" (`mesh_radio.dart:32-33`). §M.3 counts
  two that say "hardware"; one does.

**Tests, unit 2 [J]** (names provisional; the guard pins the final
ones): `belowApiThirtyAStartIsUnsupportedAndTouchesNothing`,
`aLeverThatIsMissingIsUnsupportedAndOneThatDoesNotHoldIsFailed`,
`aStartBehindALogoutIsAStopWithNoNotice`,
`aLeverThatStopsHoldingIsPutBackAndStopsTheRadio`,
`anOutgoingLinkIsMtuThenDiscoveryThenSubscription`,
`aStepThatFailsOrTwentyFiveSecondsIsOneFailedConnect`,
`aConnectionThatFailsBeforeItsLinkIsTriedOnceMore`,
`aConnectionThatNeverWritesHavensDescriptorIsNeverKnown`,
`aSubscriberLinksAtOnceWhereItsConnectionsMtuIsKnownAndAtItsNextMtuWhereNot`,
`theMtuThisPhonesOwnDialWasToldServesThatDevicesSubscription`,
`anMtuNoteGoesAtDisconnectAtTheCapAndWithTheRadio`,
`aLongAnOffsetOrAnAnsweredWriteIsRefusedAndItsLinkClosed`,
`aDeviceThatStartsToBondIsDroppedOnlyIfItIsHavens`,
`theStopCancelsTheAlarmAfterTheRadioIsDown`,
`theChannelsWordsAreTheseAndTheStatusIsOneFunction`,
`onlyThreeChannelMethodsAreBehindTheLever`,
`theTapHeldForAnEngineIsKeepOnIfAnyWas`,
`inTheServiceTheForegroundComesBeforeAnyRefusal`,
`theUuidsAreTheOnesDrawn`; and `StartPolicy`'s existing test, on the
new answer and the new order (N.1.5). **Unit 6 [D]**: `supported` and
`takeAction` in `mesh_radio_test.dart`'s contract groups; "nothing of
the mesh is on screen until the radio says this phone can run it"; "a
tap that opened the app reaches the first listener, once".

### N.3 The manifest gate

**How the flag reaches Gradle — read, no longer [U]** (Flutter 3.44.8;
not read for the 3.50 the confirmation names):
the tool passes `-Pdart-defines=`, each define encoded as base64 of its
UTF-8 `KEY=value` and joined by commas
(`packages/flutter_tools/lib/src/build_info.dart:412`, `:1162`,
`:1176-1178`); a define from `--dart-define-from-file` is in the same
list, ahead of those of the command line
(`…/runner/flutter_command.dart:1669-1684`); the Flutter plugin reads
the property the same way
(`packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt:645`).
**How a manifest is added to a variant** ([V], the reference for AGP
8.11, which `haven/android/settings.gradle.kts:22` pinned at `597b4d6`,
and for 9.0):
`variant.sources.manifests.addStaticManifestFile(path)`, since 8.3.1 —
the path relative to the project, the file merged with the highest
priority.

```kotlin
// One switch for the Dart flag and its native half.
val meshOn = (findProperty("dart-defines") as String?).orEmpty()
    .split(',').filter { it.isNotEmpty() }
    .map { String(java.util.Base64.getDecoder().decode(it)) }
    .lastOrNull { it.startsWith("HAVEN_MESH=") } == "HAVEN_MESH=true"

android { defaultConfig { buildConfigField("boolean", "HAVEN_MESH", "$meshOn") } }

androidComponents {
    onVariants { variant ->
        if (meshOn) variant.sources.manifests.addStaticManifestFile("src/mesh/AndroidManifest.xml")
    }
}
```

`buildConfig` is already on (`app/build.gradle.kts`, `buildFeatures`;
confirmed). The last
define of the name decides, as the command line's does over a file's
(**[U]** that Dart reads a repeated define the same way).

**What proves each half**, both in `build-check.yml`, by
`scripts/ci/check_mesh_manifest.sh <apk> on|off`, which reads `aapt2
dump xmltree` of the built APK and has a self-test:

- *off* — the three existing legs, on the APK they already build
  (`build-check.yml:157-158`): no Bluetooth permission, no
  `bluetooth_le` feature, no component of the mesh package.
- *on* — a new job, `android-mesh`: `build_apk_with_retry.sh
  android-x64 --dart-define=HAVEN_MESH=true`, then every entry of §B.8
  with its attributes. One more runner for a build of the kind whose
  measured worst is 17.9 minutes (`build-check.yml:48`); it restores
  the Gradle cache and does not write it, and declares its receive
  path as the file's other jobs do (`build-check.yml:28-32`). It is
  also the only compile of the flag-on shape until M3h's lane.

### N.4 CI

| Workflow | Change | Unit |
|---|---|---|
| `cross-check.yml` | the Android step (`:107-109`) becomes `cargo clippy --target aarch64-linux-android -- -D warnings`, the host's own rule (`rust-check.yml:267`) on the configuration that has the shim and the lookup; `clippy` among its components. Owed since M3b (plan §16). What it finds in Android-only code already there is **[U]** | 1 |
| `build-check.yml`, the three legs | after the SQLCipher probe, on the library that step unpacks (`:162-165`): its defined `Java_*` symbols are the fixture's eleven and N-3's one; its undefined `__android_log_*` symbols are all in a list of symbols older than API 23 — as read, `__android_log_write` and `__android_log_buf_write`, the two `android_logger 0.15.1` calls (`src/lib.rs:100`, `:109`) without its feature `android-api-30` (`src/config.rs:34-69`, `Cargo.toml:51`; off by default, and named neither by `haven/rust_builder/Cargo.toml:101` nor by `flutter_rust_bridge 2.11.1`, `Cargo.toml:199-201`). A list and not the lever's five names: that feature, switched on by a dependency added later, imports `__android_log_is_loggable_len`, which stops the library loading on Android 6 to 10 (N-2) and names none of the five. What the built library imports today is the step's first run to say. Then the *off* manifest check | 1; 3 |
| `build-check.yml`, `android-mesh` | N.3; and `javap -constants` on the SDK's `android.jar` against the four integers of `MeshRadioConstants` (§G: "proved by no compiler") | 3; 4 |
| `android-unit.yml` | none: the script runs what the sources declare | — |
| `repo-guards.yml` | none in shape for `check_mesh_radio.sh` (more checks, more fixtures); one step, the manifest script's self-test | 1–6; 3 |

**Deferred to M3h**: every emulator lane; the loopback radio and
`tooling/mesh-peer` (§F.2); the `mesh` input of three lanes, with the
three WorkManager reads moved (N.1.2); the release-build leg and the
assertions of N.1.6; the netsim spike (§F.3). **To M3i**: the privacy
manifest, `SECURITY.md` and Rule 15's wording (§I), written when the
radio can run.

### N.5 What M3g rests on and cannot prove

| Claim | Source | Unit that rests on it | If it is false |
|---|---|---|---|
| The lever leaves Haven's pid empty of the platform's lines, on every level from 30 and on vendors' builds | §M.9 item 1 | 1, 5, 6 | the rule of §M.3 does not do what it says: the flag does not flip |
| The framework's `Log` and Haven's library write through one `liblog`, and `dlopen("liblog.so")` answers that one | §M.2's premise; N.1.1 | 1 | the same |
| A pointer store is whole on every build's compiled `liblog` | N.1.4 | 1 | a line torn at install — once a process |
| Nothing in the process moves the floor or replaces the logger | §M.9 item 2 | 1, 2 | the radio stops itself, with its notice: function lost, nothing written |
| The platform's Bluetooth classes write no identifier to the event or statistics buffers from an app's process (the confirmation, from memory: statistics have gone to `statsd`'s own socket since Android 11 — **[U]**) | N-1; unread; the lane reads those buffers (N.1.6) | 1 | lines the lever cannot reach: N.6 |
| No plugin in the process makes a Bluetooth object before the lever | unread | 1 | platform lines before the lever |
| Dropping the link ends a pairing before keys are exchanged | §M.9 item 4 | 2, 4, 5 | a bond a user accepted stays (§M.4) |
| The server's callback fires for the phone's other connections | §M.9 item 7 | 2 (`ServerLinks`) | nothing: the rule holds either way |
| `cancelConnection` ends a connection the server did not make | §K; N-7: on 15 QPR2, as read, it does not | 4 | as on that release: a device Haven refused, or a link the engine closed, stays connected, unknown to Haven |
| Two Android phones that dial each other over one connection link in both directions | N-6; N.2.3; [E] or [H], on a controller that shares the connection (§M.5) | 2, 4 | one direction only on such phones |
| Over such a connection, a close of one direction leaves the other | [E] or [H]. Read on one release: the server's `cancelConnection` ends nothing (N-7); the client's disconnect drops the whole link once no local client holds it (`sys/stack/gatt/gatt_main.cc -22.2:409-423`, `sys/stack/l2cap/l2c_utils.cc -22.2:2796-2805`) | 4 | as read for the client: closing the direction this phone dialled ends both, and the engine dials again |
| A central that connects to Haven's advertisement and asks to pair without subscribing: whether the dialog shows, and whether anything Haven can call ends it | N.2.5; Q-15 | 2, 4, 5 | under (a) nothing is lost that was held; under (b) the cost with no effect |
| A write without response is paced by its callback | §K, §B.2 | 4 | frames lost in the stack; the links' timeouts (R-1) |
| `neverForLocation` does not filter a plain service-UUID advertisement | §K | 3, 4 | phones on API 31 and later do not find each other |
| `setDiscoverable(false)` is the stack's rule on 14.0.0 itself, and an iPhone finds an advertisement without Flags | §M.9 items 5, 9 | 4 | the name to inbound peers on that release; M4 |
| `startForeground` in a sticky restart on Android 12 and later; a dismissed notice posted again at screen-off; a Bluetooth state change reaching only a registered receiver | §K | 5 | the wrapper stops the service with its notice; a missing notice until the next screen-off |
| A service ended before `startForeground` ends the process, on the releases the radio runs on | N-5, read before 14 | 5, 6 | nothing: the order is harmless |
| `startForeground` does not itself refuse on a start that came through `startForegroundService` — a permission revoked between the caller's check and the service | N.1.5 | 5 | N-5's crash, in that window |
| A flag-off release build with the new Kotlin shrinks and passes release lint | no job builds one before a tag: `release-build.yml` is the first | 3–6 | the tag's build fails, not a pull request's |
| The plugin's preferences file and key prefix | N.2.7, read at 2.4.23 | 2, 5 | the marker reads unset: the window of plan §16 (c) is open again |
| The Flutter tool's `dart-defines`, on the `stable` CI floats on (read in 3.44.8, not in 3.50); AGP's `addStaticManifestFile`, in the version the build then pins | N.3, read | 3 | the build fails, or the *on* check does |
| The library imports no `__android_log_*` symbol newer than API 23 | N-2; N.4 | 1 | the step fails; were it not there, Haven would not start on Android 6 to 10 |
| JNI resolves the eleven by name; a release build keeps `MeshNative` | §K; N.2.1 | 3 | the first call throws; `MeshThread` stops the radio |
| The four integers are the SDK's | §G | 4 | the `javap` step fails |
| An iPhone agrees its MTU as it connects, and the server is told of it | N.2.3 | — | M4 |

§M.9 items 3, 6 and 8 carry nothing of M3g: 3 is replaced (N.1.3), the
name read is the platform's, and no entry is cleared.

### N.6 For the owner

**Q-14. Debug builds keep Haven's own log lines once mesh has been on
(N.1.2).** §M.2 left the floor's level to the owner if Haven's lines
were to be kept.

- *(iii), recommended.* A release build writes nothing from the
  process, at any priority, with the floor at FATAL behind the logger.
  A debug build — a developer's, or a CI lane's — writes the lines the
  runtime scanner answers for and no other, and leaves the floor where
  it is: it has the logger and no second line. No user's phone is
  affected. The lanes keep their oracles, and the scanner keeps reading
  Haven's own lines with mesh on.
- *(i).* Nothing in any build. One rule, no list. A debug build is
  blind from the first turn-on, and of the three lanes that prove the
  relay path is unmoved by the mesh (§F.2) the two read for this lose
  every oracle they take from the log; each would need a second way
  out of the process before M3h can count them.

**Q-15. A stranger who connects and asks to pair before subscribing
(N.2.5).** With the mesh on the phone answers any central that connects
to its advertisement. Haven knows a device as its own only from its
subscription (N.2.3), so the bond watch of §M.4 does not cover a
central that asks to pair first: anyone in range can raise the
system's pairing dialog, and a bond — the phone's identity address and
the key to its rotating addresses, in a stranger's hands (§M.4) —
follows if the user accepts it. §B.3 covered this on paper by tracking
every incoming connection, which §M.1 shows would be treating every LE
connection of the phone as Haven's.

- *(a) Accept and record.* Haven ends what it knows is its own and
  nothing else. What is left is a system dialog naming a device the
  user did not choose, which the user must accept for any harm:
  recorded in §H, `SECURITY.md` and the privacy manifest. It may be
  narrower than that from API 34, where the reference says a peer on a
  non-discoverable advertisement cannot start a bond — unproved (§M.4,
  §M.9 item 5).
- *(b) End any connected device that starts to bond while the radio
  runs, unless it was bonded before.* Keeps §B.3's intent. What the
  user would see: with mesh on, pairing a new Bluetooth LE device of
  their own — earbuds, a watch, a tracker — from the system's settings
  is cut off as it starts, with the system's own failure message and
  nothing from Haven; they turn mesh off to pair. Devices already
  paired are untouched. Its effect is unproved in both directions: on
  the one release read Haven's server cannot end a connection it did
  not make (N-7), and the only other sequence read was not followed
  into a pairing. It could cost the user's pairing and stop no
  stranger's.
- *(c) Only connections that came in through Haven's advertisement.*
  Not available: the platform does not say which those are (N.2.5).
- **Recommended: (a) for now, and measured before the flag flips.**
  §M.9 item 4 gains the case — a central that connects, does not
  subscribe and asks to pair: whether the dialog shows on each level,
  with `setDiscoverable(false)` and without, and which of (b)'s calls,
  if any, ends it. If a device shows that (b) works, it comes back to
  the owner with what it breaks. Both are designed (N.2.5); the choice
  is the owner's.

**For the owner to know: two kinds of log the lever cannot reach**
(N-1). Lines in the event and statistics buffers never pass through
the logger. None of the platform's Bluetooth classes is known to write
an identifier there from an app's process, and none was looked for;
the lane reads those buffers in the planted-address proof (N.1.6). If
one is found, "all of them" (Q-10) cannot be met on that release by
anything Haven can do, and whether the radio runs there is the
owner's.

Not the owner's. Confirmed by the review: the check of N.1.3 in place
of §M.2's; reading the logout's marker (N.2.7); the two changes to the
Dart seam (N.2.8). Changed by it: the dial's order and the server's MTU
(N-6).

### N.7 As built

**Unit 1, the lever (2026-11-12).** Built as N.1 and N.4 say, with form
(iii) of Q-14 — the other form is one line, `lever_writes_own` answering
`false`. **Nothing calls it and nothing of it has run on Android**; plan
§16 has what is proved and how. Where the code differs from this
section:

- **Where the decisions are (N.1.1, N.1.2).** `log_lever.rs` holds the
  lookup, the logger and the calls through `liblog`'s functions. Which
  tags are Haven's, what a build writes and what a check comes to are
  four functions of `api.rs`, under the crate's deny (`lever_owns`,
  `lever_line`, `lever_held`, `lever_writes_own`), with the list
  (`LEVER_OWNED_TAGS`) beside them: so a second list does exist, in Rust,
  held to the policy's line by `the_levers_tags_are_the_scanners`.
- **What a debug build reads (N.1.1).** Three reads, not two fields: the
  message's size, its tag pointer, and the tag's bytes — at most the
  eighteen that decide (the longest entry and `::`), one at a time and
  never past the NUL, so no `strlen` over a string of the platform's.
  The message's text is never read.
- **The platform's writer (N.1.1)** is not a static of its own: the
  logger takes it from the one table the lookup filled, a `OnceLock`
  that is set before the logger is handed over and read without a lock.
- **Check 13 (N.1.1).** Of `libc` the file names `dlopen`, `dlsym` and
  `RTLD_NOW` only: the C types are `std::ffi`'s. Its strings are the
  library, the five functions, the `"C"` of a pointer type and the
  `"android"` of its one `cfg!`. The `unsafe` count (eleven) and the one
  `extern "C" fn` are the whole file's, tests included. Added to the
  list: no `impl`, `mod`, `macro_rules` or `thread_local`; no macro but
  `cfg!` and the layout's one compile-time assertion; nothing of the
  bridge but `lever_*` and `LEVER_*`.
- **The entries (N.1.5)** are compiled for Android and for tests only
  (`#[cfg]`), where the other nine are compiled everywhere and expected
  dead: the module they call exists nowhere else.
- **[L] of N.1.6, rows 2 to 4.** No stand-in for `liblog` was written,
  and no recording writer. What runs on the host: the four decisions,
  for both kinds of build; the logger itself, handed messages the tests
  build, with no platform writer to hand them on to; the tag's read; a
  lookup in a library that is absent and in one without the functions;
  and the two calls answering `false`. **Not run anywhere:** `install`
  and `holds` past their first line — the order of the calls, the
  sentinel, the floor raised and read back — and the forward to the
  platform's writer. That a host makes no lookup is read, not tested: a
  host has no `liblog.so` to tell the two apart.
- **The JVM test (N.1.5)** is
  `theTwoNativeInterfacesAreTheElevenExportsOfTheFixture`.
- **The import list (N.4)** is six functions, not two: those
  `android/log.h` declares with no `__INTRODUCED_IN`, read at
  `android-11.0.0_r1` — `__android_log_write`, `_print`, `_vprint`,
  `_assert`, `_buf_write`, `_buf_print`. The Flutter engine's own
  library imports three of them. The check is
  `scripts/ci/check_mesh_radio_symbols.sh`; a weak reference fails it
  too.
- **A host that is not Unix** cannot build the crate's tests: `libc` has
  no `dlopen` there. CI's host is Linux.

