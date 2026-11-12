# M3 design — the Android radio, its Rust interface, and everything on screen

> Status: **DESIGN for milestone M3 of `docs/BLUETOOTH_MESH_PLAN.md` — drafted
> by one agent and confirmed with changes by an independent review, both
> 2026-11-11.** The review's changes are folded in and listed in §L, with
> the one premise of it that the code contradicts. Built so far, each with
> its departures from this text in plan §16: M3a; M3b; M3c; M3d in English
> only; M3e; M3f.
> The radio's pure Kotlin is built and tested on the JVM (M3f). No Android
> adapter is, and no `MeshNative`: the shim's exports (M3b) have no caller.

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
| F-6 | **A connected peer can read the phone's Bluetooth name, and sees more than Haven's service.** "No characteristic exposes a name" (plan §6.1) holds for Haven's service only. Android's Generic Access service carries Device Name. Per AOSP change `5fc5174` ("Selectively hide Device Name characteristic", bug 254314964) it is readable without encryption by a peer that connected through a *discoverable* advertisement, **or that this phone connected to**; earlier stacks let anyone read it (**[U]** as to the text: the review had it from search summaries). Advertisements are discoverable by default; `setDiscoverable(false)` exists from API 34 [A15, A16]. And Android keeps one attribute table a device, shared by every app (**[U]**, both passes' memory), so a peer also sees other apps' services. | [A15], [A16]; rest [U] | An attacker who advertises Haven's service UUID — public in the APK — is dialled by every Haven phone in range and reads each one's Bluetooth name, on every API level: a stable identifier across address rotation, often the owner's name. Plan §0.4 item 6 ("identity stay[s] hidden") is false. §B.3 hides the name from inbound peers on API 34+; nothing hides it from a peer Haven dials. §D discloses it; Q-6, Q-11. |
| F-7 | **The plan's button placement cites code that is elsewhere.** `MapControls` is positioned in `haven/lib/src/pages/map/map_page.dart:659-667`, inside the `map` layer, not in `MapShell.buildLayers` (`map_shell.dart:1013-1073`); the collapsed height is a private constant there (`map_page.dart:181`, `:645`) with a twin in the sheet (`circles_bottom_sheet.dart:43`). | — | The button takes its rect from `aura` §2's `meshButtonRect`; the 0.12 becomes one shared constant (§E.1). |
| F-8 | **`rust_builder` has no `unsafe_code` lint**, and `frb_generated.rs` holds 223 `unsafe`s (`haven/rust_builder/src/lib.rs:1-19`, `Cargo.toml` has no `[lints]`). "`unsafe` confined to the shim" (plan §3) is not checkable today. | — | M3b denies `unsafe_code` crate-wide and allows it on two modules (§A.6). |
| F-9 | **`jni` is already resolved**: `jni 0.21.1`, through `android-native-keyring-store` (`haven/rust_builder/Cargo.lock:76-82`, `:2085`), and that crate already exports a JNI function from this library (`kt/HavenApplication.kt:57`;
`haven/android/app/src/main/kotlin/io/crates/keyring/Keyring.kt`). It is in neither other lockfile, and need not be. `jni 0.22.4` is current and changes the API [A11]. | — | Direct dependency on the 0.21 line: one line in one lockfile, no new package (§A.7). |
| F-10 | **Notification text has no native l10n pipeline.** The location notification's text is localized in Dart and handed over (`background_location_manager.dart:295-301`). | — | Mesh notices do the same; a notice posted after a reboot uses the copy of the last start (§B.7). |
| F-11 | **`permission_handler` is deliberately not a dependency** (`haven/pubspec.yaml:72-74`), and `MainActivity` is one line. | — | The Bluetooth prompt is asked by Haven's own channel in `MainActivity` (§C). |
| F-12 | **The emulator's peripheral role may hold one inbound link at a time.** A third party found on emulator 37.1.11 / API 35 that an advertising emulator "stops advertising, so a second central cannot see it until the first disconnects" [A9]. G-6 asks for 2+2 links. | [A9], one report | The netsim lane may be unable to show two inbound links whatever Haven does (§F). |
| F-13 | **Android's own Bluetooth classes log peer addresses from inside Haven's process, in every build.** `android.bluetooth.BluetoothGatt` and `BluetoothGattServer` run in the app's process with `DBG = true` and call `Log.d` with the raw address: `onSearchComplete() = Device=` + address, `onDescriptorWrite() - Device=` + address (client, lines 419, 708), `onMtuChanged() - device=` + address (server, line 360) — LineageOS 22.1 mirror of `packages/modules/Bluetooth/framework/java/android/bluetooth/`, fetched 2026-11-11 [A20]; the review reports Android 11 the same. `BluetoothDevice.toString()` is redacted only for apps targeting 34+, and those three lines do not use it. | [A20] | Every link, in either role, writes a peer's address to logcat under Haven's pid. No public API avoids it. Rule 15 as written forbids it; the logscan of any radio lane would flag it. An owner decision before M3g, not a discovery on the lane: Q-10. |
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
| **M3g** | Kotlin: `MeshService`, GATT adapters, notices, manifest, channel | [C]; behaviour [E]/[H] |
| **M3h** | The L4 lane: loopback radio first, then netsim | [E] |
| **M3i** | Documents, privacy manifest, device matrix | [G] |

Between M3e and M3g a flag-on Android build shows a button whose start
answers "Couldn't turn mesh on": the channel has no native end yet. No
script or workflow passes the flag. M3d does not wait on Q-6: the sentence
about the Bluetooth name is written (§D) before any copy is translated.

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
- **Advertisement.** Flags and the service UUID: 21 of 31 bytes. No name,
  no TX power, no service data, no scan response. bitchat puts a peer id in
  service data (`bc:BluetoothGattServerManager.kt:404`); Haven does not.
  Legacy `startAdvertising`, `ADVERTISE_MODE_LOW_POWER`, connectable, no
  timeout, on every API level (Q-9). From API 34, `setDiscoverable(false)`
  [A15], so that a peer connecting in cannot read Device Name unencrypted
  (F-6, [U]); whether an iPhone finds a non-discoverable advertisement is
  **[U]**, recorded for M4. Start failures
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
  it also fires for connections other apps and this app's own client make
  **[U — widely reported, not confirmed today]**. A link is up when a
  central enables notifications on Haven's characteristic and its MTU is at
  least 51: `onLinkUp(central = false, mtu, address = null)`. It is down at
  disconnect or when notifications are disabled.
- **Incoming write.** `preparedWrite`, a non-zero offset, a write that
  wants a response, a write from a device with no link: refused, and a
  linked device is closed. Else `onFrame`.
- **Close.** `cancelConnection` on the server, `disconnect` then `close` on
  a client. **[U]** whether `cancelConnection` ends a connection the server
  did not itself `connect` to; the lane answers.
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
  is one `if` of it.
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
| 29–30 | nothing | `BLUETOOTH`, `BLUETOOTH_ADMIN` are install-time. Searching needs fine location granted, Location switched on, and, from a service, background location [A2] |
| 23–28 | nothing | as above with coarse or fine location, and no background permission |

Mesh never asks for location. Below API 31 a phone without it advertises,
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

**Android logs for it (F-13).** The framework's GATT classes, running in
Haven's process, write each peer's Bluetooth address to logcat at debug
level in every build, in both roles; Haven cannot turn that off and no
other public API makes a link. What the line holds: a peer's address as
it was on the air — random and rotating on a phone ([U], §H), fixed on a
device that does not randomize — with the log's own timestamp. Who can
read it: someone with the phone and `adb` (USB debugging on and the
computer authorized), a bug report the user shares, and system apps
holding `READ_LOGS`; an ordinary app has read only its own process's log
since Android 4.1 (**[U]**, from memory). The system's Bluetooth process
logs the same addresses under its own pid whatever Haven does. Whether
Rule 15 gives here is the owner's to say: Q-10.

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
lines (logscan over the lane's sinks, with planted peer numbers), and that
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
emulator jobs a push.

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
the `neverForLocation` [U]; and what the framework logs (F-13), under
whatever rule Q-10 gives the scanner.

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
| Tracking by address | Android advertises under a resolvable private address, rotated about every 15 minutes **[U — a 2026 paper's figure, from a search summary]**; Haven sets none. An AOSP fix (bug 246692649) for rotation stopping after a connection exists; which releases have it is **[U]** | platform | [H] |
| Re-identification across rotation by the packets held, or by a link kept open | **none**: plan §0.4 item 6, accepted | — | disclosed (§D) |
| **The phone's Bluetooth name, read by a peer that connects in** | API 34+: `setDiscoverable(false)` (F-6, [U] as to the stack's rule). Below 34, and on a stack older than the AOSP change: **none** | `AdvertiserAdapter` | T-PRIV-5 [E] netsim, both directions; [H] |
| **The same name, read by a peer Haven dials** — anyone advertising Haven's public UUID | **none**, on every API level | — | disclosed, and the name shown (§D, §E.2); Q-6, Q-11 |
| **Other apps' Bluetooth services, seen by any connected peer** (one attribute table a device, [U]) | **none** | platform | T-PRIV-5 records the table; disclosed in `meshIntroName` |
| What Haven's characteristic reveals | nothing readable: write and notify only, every byte after the handshake sealed (plan §6.7) | engine | T-PRIV-8 [L, exists] |
| A Bluetooth address in a log, a notice or across the bridge **by Haven's code** | the package logs nothing; `PeerTable` keeps addresses in Kotlin memory only; the channel carries a state and two bools | §B.9, §C.1 | `anAddressNeverReachesTheEngine` [J]; `nothing_is_logged_…` [D]; T-LOG-1 [E] |
| **A peer's address in logcat by Android's code, under Haven's pid** (F-13) | **none**: no public API links without it | platform | Q-10; netsim lane or [H] to see it |
| The radio reaching a key or a session | no radio entry takes one; the engine is keyless | §A.4 | `the_radio_entries_take_no_session` [L] |
| A radio with the store saying off | bounded to one process start until the first session entry; turn-off stops the radio first; no reconcile runs inside a transition | §A.4, §C.3, §C.4 | `a_session_whose_mesh_is_off_ends_…` [L]; `a_stopped_event_in_the_middle_of_a_turn_off_starts_nothing` [D] |
| The deadline copy at rest | an app-private preference: that mesh was on, and until when. The counters went to the encrypted store for less (D-4) | `MeshPrefs` | Q-2 |
| A debug loopback radio in a release | not in the release source set | §F.2 | guard [G] |
| Mesh permissions and components in a build with the flag off | not in its manifest | §B.8 | guard [G]; merged manifest [C] |

**What stays exposed whatever M3 does**, beyond plan §0.4: the phone's
Bluetooth name to any peer Haven dials, and to any peer at all below API
34; the list of other apps' Bluetooth services; and, under Haven's pid in
the device's own log, the addresses it linked with.

---

## I. Documents made stale, and written with the code

- `haven-core/SECURITY.md` "Bluetooth mesh": "The radio is not [built]"
  and "An entry that holds no session — none exists in this build"
  (`:3293`, `:3419`) — with M3a; a new part for the radio's privacy cost
  (plan §0.4, §8.1, and F-6, F-13 here), owed there since M2g-1, with M3g.
- `docs/privacy/privacy_invariants.json`: invariants for the advertisement,
  the GATT table, the notices, the deadline copy, the session-less engine;
  accepted deviations for the Bluetooth name and, if Q-10 is answered that
  way, for the framework's log lines.
- `plan` §0.4 item 6 (identity) and item 3 (after a reboot, after the
  first unlock); §16: M3's status, each "not as the plan has it" of §0.
- `haven/lib/src/providers/mesh_provider.dart`'s "No radio is built yet"
  and `api:12745-12746`'s "The radio is not built yet".
- `docs/MESH_DEVICE_MATRIX.md`: new, Android half, DEFERRED.
- `CLAUDE.md` is the owner's. Proposed for it: in Architecture, the
  radio's JNI surface as the one hand-written `extern` in `rust_builder`;
  in the proposed Rule 17, "the radio's entries take no session and open
  none; a radio entry may start a keyless engine under a deadline no later
  than twelve hours and the first session entry overrules it"; in Rule 15,
  whatever Q-10 decides; the mesh lanes in the CI section.

---

## J. Open questions for the owner

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

**Q-11. A phone Haven dials reads this phone's Bluetooth name (F-6).** No
setting prevents it; anyone can be dialled by advertising Haven's UUID.
- *Accept and disclose* (designed, with Q-6): plan §0.4 item 6 is
  corrected to say that a name is exposed.
- *Do not ship the Android radio* until the platform offers a way.
- **Recommended: accept and disclose.** The dual role is what makes a mesh;
  a phone that never dials cannot link to another Android phone that
  hides its name the same way.

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

**Still open:**

- F-12, and netsim on a hosted runner at all (§F.3).
- Whether `cancelConnection` ends an inbound connection; `startForeground`
  in a sticky restart on Android 12+; whether the server's connection
  callback fires for other apps' connections; whether a no-response
  write is paced by its callback; re-posting a dismissed foreground
  notification; that a Bluetooth state change reaches no manifest
  receiver.
- Whether `neverForLocation` filters a plain service-UUID advertisement;
  whether an iPhone finds a non-discoverable advertisement; iOS's typical
  MTU; the legacy advertise mode's interval.
- The text of AOSP `5fc5174` and which releases carry it; the shared
  attribute table (memory); the scan downgrade on Android 15 (the review's
  reading); address rotation and its AOSP fix; who may read logcat.
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
- Nothing was built or run for this design or its revision.

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
- `max_peers` is at `eng:264`, not `:263`.
