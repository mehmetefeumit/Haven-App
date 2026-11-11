# M3 design — the Android radio, its Rust interface, and everything on screen

> Status: **DESIGN for milestone M3 of `docs/BLUETOOTH_MESH_PLAN.md` — drafted
> 2026-11-11 by one agent; not yet independently reviewed; nothing here is
> built.** Under the project's rule a second, independent set of expert agents
> confirms it before it is presented as a plan.

Repo at `132f5ca`, with another agent's uncommitted work in `haven-core/`,
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
| **[J]** | a JVM unit test of Kotlin | **no** — no Android SDK here; CI only |
| **[C]** | compiling for Android (`build-check.yml`, `cross-check.yml`) | **no** — CI only |
| **[E]** | an emulator lane | **no** — CI only, **and its feasibility is unproven** (G-1, G-6) |
| **[H]** | a real device | **no** — DEFERRED; the project has none |
| **[U]** | nothing: unverified | — |

CI (`ci.yml`) runs on pushes to `main` and pull requests to `main`
(`.github/workflows/ci.yml:22-26`); this branch has no pull request. So
**today [J], [C] and [E] are proved by nothing**, and no line of Kotlin can
be compiled before a pull request exists (Q-1). The M0 spikes of plan §10
were never run: G-1, G-6 and G-10 are unanswered.

---

## 0. Findings that change the plan's text (decide before coding)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F-1 | **No engine can exist in a process that has opened no session.** The engine is created only by `mesh_open(session, …)` (`api:12957-12982`); the radio's entry, `with_mesh(None, …)`, answers `None` when the home is `Off` (`api:12905-12907`). Plan §0.4 item 3, §7.7 R4 and T-BG-1 ("process killed, the service returns; reboot with mesh on, mesh resumes") need an engine in exactly that process. | — | M3a adds a session-less start, `radio_resume(left_ms)`. It needs the deadline from somewhere that is not the session's store. Q-2. |
| F-2 | **The deadline lives behind the session.** `user_settings.mesh_on_until` is in `circles-v2.db`, read through `SessionManager` (`haven-core/src/nostr/mls/manager/mesh.rs:1109`). Plan §7.1 says the boot receiver "checks the persisted flag" and §7.6 arms an alarm in `MeshService`; neither can read that store without opening the session (Rule 14). | — | The service keeps its own copy of the deadline, derived from the engine, in app-private preferences. The session's store stays the authority: the first session entry overrules the copy (§A.4). |
| F-3 | **"Keep on … without opening Haven" (plan §7.6) is impossible when no session-owning isolate is alive**: restarting the twelve hours is a write to the session's store (`mesh_keep_on` → `mesh_on_until`, `api:13044-13050`). | — | Q-3: the notification's Keep on opens Haven, or does so only when no Dart isolate is alive. |
| F-4 | **A stopped service cannot be restarted when Bluetooth comes back.** Android 12+ refuses a foreground-service start from the background outside a fixed list of exemptions; a Bluetooth adapter state change is not on it [A5]. Plan §7.1 has the service "wait for Bluetooth to come on". | [A5] | The service stays in the foreground, radio idle, while Bluetooth is off: a state "paused" that the plan does not name (§B.6, Q-8). |
| F-5 | **Doze "ignores wake locks"** [A7], and plan §7.7 R2 rests on a timed wake lock. Whether an app with a foreground service is exempt is not on that page. From AOSP's `PowerManagerService` as remembered it is exempt at foreground-service process state — **[U], not fetched**. | [A7] | G-10 widens: the timed lock may do nothing on a dozing phone. Nothing in M3 can show which. |
| F-6 | **"No characteristic exposes a name" (plan §6.1) holds for Haven's own service only.** Every GATT server carries the Generic Access service (0x1800) with Device Name (0x2A00); on Android that table belongs to the system and an app cannot remove it. Whether Android answers a stranger's read with the phone's Bluetooth name — often the owner's — is **[U]**: two searches confirmed neither way. | — | T-PRIV-5 reads 0x2A00 on the lane and records it. If it is the user's name, plan §0.4 item 6 ("identity stay[s] hidden") is false for such phones. Q-6. |
| F-7 | **The plan's button placement cites code that is elsewhere.** `MapControls` is positioned in `map_page.dart:659-667`, inside the `map` layer, not in `MapShell.buildLayers` (`map_shell.dart:1013-1073`); the collapsed height is a private constant there (`map_page.dart:181`, `:645`) with a twin in the sheet (`circles_bottom_sheet.dart:43`). | — | The button takes its rect from `aura` §2's `meshButtonRect`; the 0.12 becomes one shared constant (§E.1). |
| F-8 | **`rust_builder` has no `unsafe_code` lint**, and `frb_generated.rs` holds 223 `unsafe`s (`haven/rust_builder/src/lib.rs:1-19`, `Cargo.toml` has no `[lints]`). "`unsafe` confined to the shim" (plan §3) is not checkable today. | — | M3b denies `unsafe_code` crate-wide and allows it on two modules (§A.6). |
| F-9 | **`jni` is already resolved**: `jni 0.21.1`, through `android-native-keyring-store` (`haven/rust_builder/Cargo.lock:76-82`, `:2085`), and that crate already exports a JNI function from this library (`kt/HavenApplication.kt:57`;
`haven/android/app/src/main/kotlin/io/crates/keyring/Keyring.kt`). It is in neither other lockfile, and need not be. `jni 0.22.4` is current and changes the API [A11]. | — | Direct dependency on the 0.21 line: one line in one lockfile, no new package (§A.7). |
| F-10 | **Notification text has no native l10n pipeline.** The location notification's text is localized in Dart and handed over (`background_location_manager.dart:295-301`). | — | Mesh notices do the same; a notice posted after a reboot uses the copy of the last start (§B.7). |
| F-11 | **`permission_handler` is deliberately not a dependency** (`haven/pubspec.yaml:72-74`), and `MainActivity` is one line. | — | The Bluetooth prompt is asked by Haven's own channel in `MainActivity` (§C). |
| F-12 | **The emulator's peripheral role may hold one inbound link at a time.** A third party found on emulator 37.1.11 / API 35 that an advertising emulator "stops advertising, so a second central cannot see it until the first disconnects" [A9]. G-6 asks for 2+2 links. | [A9], one report | The netsim lane may be unable to show two inbound links whatever Haven does (§F). |

Smaller disagreements, each designed as stated: plan §3 pins "Kotlin, Swift
and Rust declarations" — M3 builds the JNI surface only, and the C surface
for Swift is M4's (an unused export is code nobody tests). Plan §7.1's
1022.5 ms advertising interval needs the advertising-set API, a second code
path; M3 uses the one legacy path (§B.3, Q-9). Plan §7.1's "grouped with the
location notification" needs a group key on a notification the plugin owns
— **[U]** whether `flutter_foreground_task` takes one; not built unless it
does. T-STAT-3's iOS clause is M4's. Plan §7.6's "time left" is shown as a
clock time (§E.3, Q-7).

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
| **M3f** | Kotlin: pure radio logic, JVM tests, the `android-unit` lane | [J] |
| **M3g** | Kotlin: `MeshService`, GATT adapters, notices, manifest, channel | [C]; behaviour [E]/[H] |
| **M3h** | The L4 lane: loopback radio first, then netsim | [E] |
| **M3i** | Documents, privacy manifest, device matrix | [G] |

Between M3e and M3g a flag-on Android build shows a button whose start
answers "Couldn't turn mesh on": the channel has no native end yet. No
script or workflow passes the flag.

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
carries `MTU − 3` bytes, and an attribute value is at most 512 [U — Core
spec figure, not re-fetched; Android's own note uses 517 − 5 = 512, A4]. The
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
- **No clock crosses**: `mesh_clock_ms` is read inside.
- A link with `att_mtu` that gives no frame is answered `Output::Close` by
  the engine (`eng:546-548`, `:568-570`): `radio_link_up` passes 0.

`radio_resume` is the one new holder of the lock. `mesh_open`'s tail
(`api:12970-12981`) becomes `fn mesh_install(handoff: Arc<Handoff>, left_ms:
u64) -> bool`, called by `mesh_open` with the session's hand-off and by
`radio_resume` with `Arc::new(Handoff::default())`
(`haven-core/src/mesh/handoff.rs:38-41`), which nobody fills. **The pinned
count of lock holders goes from 4 to 5** (`with_mesh`, `mesh_owed`,
`mesh_empty`, `mesh_open`, `mesh_install`); the gate at `api:25523-25564`
is updated with it and gains: `mesh_jni.rs` names none of `MESH`,
`mesh_home`, `with_mesh`.

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

**Rule 14.** No radio entry takes or reaches a session; `mesh_jni.rs`
names nothing of `api` but `radio_*`. Held by a source gate [L] and, for
T-INDEP-4, by the lane [E].

### A.5 Bytes across the boundary

- **In.** `receive(link, frame: ByteArray)`: the shim reads the array's
  length and returns if it exceeds `RADIO_MAX_FRAME`, *then* copies
  (`JNIEnv::convert_byte_array`, at most 512 bytes). `poll(ready:
  LongArray)`: length cut to `MAX_LINKS` = 32 (`store.rs:42`), then read into
  a stack array. Rust owns every copy; Java keeps its arrays.
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
  are clamped into their types.
- **`unsafe`.** With `jni` 0.21's wrappers no export needs an `unsafe`
  block; the one thing the `unsafe_code` lint fires on is `#[no_mangle]`.
  `lib.rs` gains `#![deny(unsafe_code)]`, with `#[allow(unsafe_code)]` on
  `mod frb_generated` and `mod mesh_jni` and nowhere else. **[U]** that
  `api.rs` and `test_keyring.rs` compile under the deny — the compiler
  answers in M3b. Guard `check_mesh_radio_shim.sh` [G]: `unsafe`,
  `no_mangle` and `extern "` appear under `haven/rust_builder/src` in those
  two files only.
- **Panics.** Unwinding out of an `extern` function aborts the process.
  Every export runs its `radio_*` call inside `std::panic::catch_unwind`,
  on plain data converted beforehand, and answers its "no engine" value. A
  panic under the lock poisons it, and the next `mesh_home` drops that
  engine (`api:12882-12890`). The service then reads `leftMs() == 0` and
  stops, with the stopped notice.
- **No callbacks, no stored `JavaVM`, no global reference, no thread
  attach**: every call is made by a Java thread and returns.
- **Thread.** One: the service's `HandlerThread` (§B.1). Never the main
  thread. The lock is a `std::sync::Mutex` held for one engine call; the
  bridge's entries hold it as briefly (`api:12900`, taken in no `async` fn).
- **Loading.** `MeshNative`'s initializer calls
  `System.loadLibrary("rust_lib_haven")`, as `Keyring` does; idempotent.
- **A JNI name mismatch is a run-time error**, not a compile error. Two
  things hold it: the parity guard `check_mesh_radio_parity.sh` [G] — the
  `external fun`s of `MeshNative.kt` and the `Java_…MeshNative_*` exports
  agree in name, arity and types, and the status and kind constants agree —
  and, in `build-check.yml`, `nm -D` on the built library lists the nine
  symbols [C].
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

### A.8 Tests

All [L], in `api`'s `mesh_ffi_tests`, on the existing `Phone` harness (a
second engine wired to the one in the slot, `api:24364`).

| Test | Proves | Mutation it kills |
|---|---|---|
| `the_radio_carries_a_packet_between_this_phone_and_another` | handshake, inventory and a packet cross through `radio_link_up` / `radio_receive` / `radio_poll` in both roles | `central` inverted; a poll that ignores `ready`; a wrong kind byte |
| `the_frame_length_of_a_link_is_one_formula` | 23 → none, 50 → none, 51 → 48, 185 → 182, 517 → 512, 65535 → 512 | `− 3` dropped; the 512 cap dropped |
| `a_frame_longer_than_the_radio_carries_closes_its_link` | 513 bytes reach no engine code and the link's close is polled | the bound removed |
| `with_no_engine_every_radio_entry_does_nothing` | `Off` and `Ended`: no input changes the home, poll is `None`, wake is `None`, left is 0 | an entry that installs an engine |
| `the_radio_starts_an_engine_with_no_session_and_carries_with_it` | `radio_resume` then a packet passes phone → this → phone | `mesh_install` refusing an empty hand-off |
| `a_session_that_opens_takes_over_the_engine_the_radio_started` | `mesh_resume` answers `AlreadyOn`, the store is kept, the deadline is the nearer of the two, the session's next send is emitted | adoption that replaces the engine |
| `a_session_whose_mesh_is_off_ends_the_engine_the_radio_started` | after that session's first entry `radio_left_ms() == 0` and no key was stored | `with_mesh` ignoring a zero `session_left_ms` |
| `the_radio_cannot_keep_an_engine_past_twelve_hours_nor_start_over_one_that_ended` | `left_ms = u64::MAX` gives `MESH_ON_MAX_MS`; after `Ended`, `radio_resume` is false until a session entry paid | the cap; the `Off`-only check |
| `a_radio_entry_after_the_deadline_drops_the_engine_and_the_next_session_entry_deletes_the_keys` | the split of §A.4 | a radio entry that leaves the engine; a session entry that skips `mesh_off` |
| `what_passed_through_with_no_session_is_read_by_the_first_drive` | a fellow member's packet carried session-less is taken in and counted once by `mesh_drive_driven` (T-BG-3 at the bridge) | the unread queue cleared at adoption |
| `a_location_left_by_the_session_goes_out_at_the_radios_next_poll` | the hand-off is applied by a radio entry | `apply` moved out of `with_mesh` |
| `the_radio_entries_take_no_session` (source gate) | no `radio_*` body names `CircleManagerFfi`, `session`, `.await`; `mesh_jni.rs` names of `api` only `radio_*` | a shim that calls `mesh_start` |
| `an_output_is_encoded_as_the_fixture_says` | the three encodings, byte for byte, against the shared fixture | a field order change on one side |
| `a_panic_in_a_radio_call_is_caught_and_leaves_no_engine` | the shim's guard answers the "no engine" value and the home is `Off` | the guard removed |

`the_engine_lock_is_taken_only_where_nothing_can_be_awaited` (5 holders)
and `the_mesh_entries_log_nothing_and_format_nothing` (now also reading
`mesh_jni.rs`) are extended, not loosened.

**Not provable here:** that the exports link and are callable from Kotlin
([C], [E]); that `CLOCK_BOOTTIME` counts a sleeping phone's time ([H]).

---

## B. Android `MeshService` (M3f, M3g)

### B.1 Shape

Package `com.oblivioustech.haven.mesh`. The split is what makes Kotlin
testable without a device: **pure classes import nothing of `android.*`**
(a guard holds the list) and take every platform effect through an
interface; adapters are thin and hold no decision.

| Pure — [J] | Holds |
|---|---|
| `MeshEngineApi` | the nine calls of §A.6 as an interface; `MeshNative` is its one real implementation |
| `RadioOutput` | `decode(ByteArray)`: the encoding of §A.5 |
| `MeshRadioCore` | **the one operation queue**: links, pending connects, in-flight frames, the pump |
| `PeerTable` | Bluetooth address → `PeerRef`, 256 entries, least recently seen evicted |
| `DeadlinePolicy` | from time left: nothing / reminder / stop |
| `PermissionMatrix` | per API level: what to ask, whether it may search |
| `ScanPolicy` | restart before 30 min; no more than one start in 6 s |
| `MeshRadioConstants` | every mode, interval and cap of §G, one site |

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

Every input ends in `pump()`:

1. `engine.leftMs() == 0` → `running = false`; the service stops (§B.5).
2. Until `poll(ready)` answers `null`, at most 64 outputs a pump (then it
   re-posts itself): `Frame` → `port.send`; `Close` → `port.close`;
   `Connect` → `port.connect`, or `connectFailed` at once when the peer is
   no longer in `PeerTable`.
3. `port.wakeAt(engine.wakeInMs())`.

- **`ready`** is the links that are up and have no frame in flight. One
  frame per link is in flight until its completion callback
  (`onCharacteristicWrite` for a central's write without response,
  `onNotificationSent` for a peripheral's notification — "an application
  must wait for this callback" **[U — reference page not re-fetched]**).
  bitchat serializes the same way (`bc:BluetoothPacketBroadcaster.kt:536-600`).
- **R-1.** A `send` the platform refuses is offered again, the same bytes,
  after 50 ms, three times; then the link is closed and `linkDown` told.
  Never a new poll for that link in between.
- **Addresses never cross.** `PeerTable` numbers an advertiser when it is
  first seen; an inbound link is told with no peer, because a central's
  address is not the address it advertises under.
- **Wake lock** only for `onFrame` and `onLinkUp`:
  `holdAwake(min(wakeInMs + 250, HOLD_CAP_MS))` (§G). Not for sightings.

### B.3 Radio

- **GATT table.** One service, one characteristic (write without response
  + notify), its client configuration descriptor. Nothing else. The service
  and characteristic UUIDs are 128-bit values drawn once at implementation,
  kept as two `Long` constants each and built at run time — a canonical-form
  UUID in a tracked file fails `check_no_committed_secrets.sh` (plan §13),
  the standard descriptor's included.
- **Advertisement.** Flags and the service UUID: 21 of 31 bytes. No name,
  no TX power, no service data, no scan response. bitchat puts a peer id in
  service data (`bc:BluetoothGattServerManager.kt:404`); Haven does not.
  Legacy `startAdvertising`, `ADVERTISE_MODE_LOW_POWER`, connectable, no
  timeout, on every API level (Q-9). Start failures
  (`bc:BluetoothGattServerManager.kt:418-429` lists them): too many
  advertisers and internal error are retried at the next Bluetooth-on or
  service start, never in a loop; unsupported means central-only.
- **Scan.** One `ScanFilter` on the service UUID, `SCAN_MODE_LOW_POWER`,
  all matches, no report delay. A filtered scan keeps running with the
  screen off; an unfiltered one does not (plan §2.3 [V]). Android turns a
  scan that has run 30 minutes into an opportunistic one, and silently
  ignores a sixth start in 30 seconds [A8, secondary]: `ScanPolicy` restarts
  the scan at 25 minutes, checked at a pump (no timer of its own), and
  never starts twice in 6 s. bitchat adds a watchdog because a scan can die
  with no callback (`bc:BluetoothGattClientManager.kt:312-346`); Haven's
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
`eng:254-255`), since the engine closes what it does not admit.

### B.5 Lifecycle, deadline and notices

- **Start** (`onStartCommand`, any cause — the channel, a sticky restart,
  boot): `startForeground` first, type `connectedDevice`, inside a
  `try`: a refusal (`SecurityException` when no Bluetooth permission is
  held on Android 14+ [A1]; `ForegroundServiceStartNotAllowedException`)
  clears the flag, posts the stopped notice and stops. Then, on the mesh
  thread: `left = engine.leftMs()`; if 0, `left = min(stored deadline −
  wall clock, 12 h)` and `engine.resume(left)`; still no engine → stop.
  Else store `wall clock + engine.leftMs()` as the deadline copy, arm the
  alarm, start the radio if Bluetooth is on. `START_STICKY`.
  **[U]** whether a sticky restart may call `startForeground` on Android
  12+: reports disagree; the `try` is the answer either way.
- **The deadline is enforced by the engine**, read at every pump. The copy
  in `MeshPrefs` serves only a restart with no engine and the alarm.
- **One alarm**, `setAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP, …)`, to
  `MeshReceiver`, at the earliest of the engine's wake, the reminder and
  the deadline. Inexact, so no permission (exact alarms are denied by
  default from Android 14 [A4]); in Doze at most one per nine minutes per
  app [A7]. While the processor is awake the handler timer serves the
  engine on time.
- **Reminder** when 30 minutes or less are left: one notification with
  **Keep on** (Q-3). **At the deadline** the service stops and the stopped
  notice takes the reminder's id, so no Keep on outlives it.
- **Stop.** By the user (the channel's `stop`): radio down, flag and copy
  cleared, notification removed, no notice. By anything else — deadline,
  engine gone, start refused: the same, **and the stopped notice**. Mesh is
  never left on with no radio and no notice.
- **Boot and update.** `MeshReceiver` on `BOOT_COMPLETED` and
  `MY_PACKAGE_REPLACED`: flag set, deadline ahead, Bluetooth permission
  held → `startForegroundService`, in a `try`. Both are exemptions from the
  background-start rule [A5], and `connectedDevice` is not among the types
  a boot receiver may not start [A3].
- **Permission revoked.** Android ends the process; the restart's
  `startForeground` is refused; stopped notice. The keys stay until the
  next open of Haven, where reconcile turns mesh off (§C.4).
- **Swiped away.** Nothing: the service has no `stopWithTask`.
- **Persistent notification (F2).** Own channel, low importance, title
  "Haven", fixed text, no count, no identifier; tapping opens the
  statistics sheet. On Android 14+ the user can swipe it away except on the
  lock screen [A4]; the service posts it again at every `ACTION_SCREEN_OFF`
  (the same id: an update when present, a new post when dismissed — **[U]**,
  M0 spike (c) was never run). **With notification permission denied
  (D-9)** the service still starts — "Apps don't need to request the
  `POST_NOTIFICATIONS` permission in order to launch a foreground service"
  [A6] — and its notice shows in the Task Manager only [A6]; no reminder
  and no stopped notice are seen.

### B.6 Bluetooth off

`ACTION_STATE_CHANGED`, registered by the running service. Turning off:
every link is told down, GATT objects are closed, the notification reads
"paused". On: server, advertiser and scan start again. The service stays
in the foreground throughout (F-4), holds no wake lock and arms only the
deadline alarm. The twelve hours keep running.

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

Manifest additions: the three Android 12 permissions (`BLUETOOTH_SCAN` with
`usesPermissionFlags="neverForLocation"`), `BLUETOOTH` and
`BLUETOOTH_ADMIN` with `maxSdkVersion="30"`,
`FOREGROUND_SERVICE_CONNECTED_DEVICE`, `<uses-feature
android.hardware.bluetooth_le required="false">`, `<service
.mesh.MeshService foregroundServiceType="connectedDevice"
exported="false">`, `<receiver .mesh.MeshReceiver exported="false">` with
the two boot actions. `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED`,
`POST_NOTIFICATIONS`, `FOREGROUND_SERVICE` are declared already.

Play requires each foreground-service type to be declared in the Console
with a description and a video [A13 — **[U]**, the page could not be
fetched]; whether phone-to-phone qualifies as `connectedDevice` is G-4,
console-side, open.

### B.9 Logs (Rule 15)

**The mesh package logs nothing**: no `Log`, no `println`, in any build. A
caught `Throwable` is dropped, never rendered; a `BluetoothDevice` is never
interpolated. `check_native_log_allowlist.sh` already fails any unlisted
call; M3g adds a check that the allowlist has no row under `mesh/`.

### B.10 Tests

[J], in `haven/android/app/src/test/kotlin/…/mesh/`, JUnit 4 and
`kotlin-test` (test-only Gradle dependencies; no Robolectric), against a
fake `MeshEngineApi` and a recording `RadioPort`.

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
| `outputsDecodeAsTheFixtureSays` | the shared fixture, and that a short or unknown output stops the radio | a field order change |
| `theScanIsRestartedBeforeThirtyMinutesAndNeverTwiceInSixSeconds` | `ScanPolicy` | either bound |
| `theReminderComesOnceAtThirtyMinutesAndTheStopAtZero` (T-AUTO-1, -2) | `DeadlinePolicy` | a second reminder; a stop that is not a notice |
| `whatIsAskedAndWhetherItCanSearchPerApiLevel` | `PermissionMatrix`, API 23, 28, 29, 30, 31, 35 | location asked for; `neverForLocation` levels crossed |
| `theAdvertisementIsTheServiceUuidAlone` (T-PRIV-5, plan half) | the advertise plan has no name, power or data field | `includeDeviceName` |
| `theRadioModesComeFromOneSite` (T-PWR-1) | the constants | — |

Guards [G], new: `check_mesh_android.sh` — the manifest declares the
service with no `android:process`, the type `connectedDevice`, the receiver
not exported, `neverForLocation`; the pure classes import no `android.`;
`MeshRadioConstants` is the one file naming a scan, advertise or priority
constant; no canonical UUID.

**Not proved by any of this:** every adapter. That `connectGatt`, the GATT
server, advertising and scanning behave as §B.3 says is [E] if the netsim
lane exists and [H] otherwise.

---

## C. The Dart seam to the radio (M3c)

### C.1 Interface

`haven/lib/src/services/mesh_radio.dart`:

```dart
enum MeshRadioPermission { granted, denied, deniedForGood }
enum MeshRadioStart { started, bluetoothOff, noPermission, unsupported, failed }
enum MeshRadioState { stopped, running, paused }   // paused: Bluetooth is off
enum MeshRadioAction { openStats, keepOn }

class MeshRadioStatus {                // no Bluetooth address, no count
  final MeshRadioState state;
  final bool canSearch;                // false: findable only (§B.8)
}

abstract interface class MeshRadio {
  Future<MeshRadioPermission> permission();
  Future<MeshRadioPermission> requestPermission();   // the system dialog
  Future<bool> bluetoothOn();
  Future<MeshRadioStart> start(MeshNoticeCopy copy);
  Future<void> sync(MeshNoticeCopy copy);            // deadline or language changed
  Future<void> stop();
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

**S1** of `aura` §7 is `status().state == running`, pushed on `changes`
and read live at resume. `MeshStatsFfi.on` is not S1.

### C.2 Turning on

`MeshNotifier.turnOn()`:

| Step | Failure | Unwind | Copy |
|---|---|---|---|
| 1. `radio.requestPermission()` | denied | none | `meshErrorNoPermission` (+ Open settings when `deniedForGood`) |
| 2. `radio.bluetoothOn()` | off | none | `meshErrorBluetoothOff` |
| 3. `mesh.start()` — deadline, keys, engine | `MeshStartFfi.off` or a throw | none: Rust stored nothing (`api:13025-13028`) | `meshErrorStartFailed` |
| 4. `radio.start(copy)` | anything but `started` | **`mesh.stop()`** — engine, keys, deadline | by the variant |
| 5. state read; S1 arrives on `changes` | | | |

The brief for this design orders it "store deadline → engine → permissions
→ service start". This puts the two stateless checks first: a refusal then
has nothing to unwind, and no key is at rest while a system dialog is on
screen, where a process death would leave keys with no radio until the
next start. Q-4. The notification permission is asked before step 1 and its
answer is ignored (D-9).

If the unwind in step 4 throws, the keys remain; reconcile (§C.4) turns
mesh off at the next resume, and the deadline bounds it.

### C.3 Turning off, keeping on

- **Off:** `radio.stop()`, then `mesh.stop()`, the second whatever the
  first did. Radio first, so the service's copy is gone before the engine
  is: a failure between the two leaves keys until reconcile, never a radio
  with the store saying off.
- **Keep on:** `mesh.keepOn()`, then `radio.sync(copy)`, which makes the
  service re-read `leftMs()`, re-store its copy and re-arm.
- **Logout:** `radio.stop()` before `wipe_all_mls_state`, which empties the
  engine (`api:1215-1217`); without it the service's next entry finds no
  engine and stops itself.

### C.4 Reconcile

A pure function, run at the shell's start-up, at every resume and on every
`changes` event:

| `stats.on` | radio | Do |
|---|---|---|
| on | running or paused | nothing |
| on | stopped, permission granted, Bluetooth on | `radio.start` |
| on | stopped, otherwise | `mesh.stop()`; show `meshStoppedNotice` once |
| off | running or paused | `radio.stop()` |
| off | stopped | nothing |

### C.5 Tests [D]

`test/providers/mesh_radio_flow_test.dart`, fake `MeshService` and fake
`MeshRadio`, each recording its calls:

- `a_refused_permission_stores_nothing` — steps 3 and 4 never called.
- `bluetooth_off_stores_nothing`.
- `a_radio_that_does_not_start_takes_the_keys_back` — `stop` called once
  after `start`; kills an unwind that is skipped for `bluetoothOff`.
- `mesh_is_on_only_when_both_started` — `turnOn` answers true in one row of
  the five.
- `turning_off_stops_the_radio_first_and_the_engine_regardless`.
- `keeping_on_tells_the_service_the_new_deadline`.
- `reconcile_is_this_table` — all rows; kills each cell.
- `with_the_flag_off_or_on_another_platform_there_is_no_radio`.
- `every_failure_has_fixed_copy` — each `MeshRadioStart` maps to an ARB
  key; no exception text reaches a widget (Rule 8).
- `nothing_is_logged_by_a_start_a_stop_or_a_failure` — log capture, with a
  planted address in the fake's exception (Rule 15).
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
| `meshIntroWhat` | With no internet, mesh passes your circles' encrypted location updates from phone to phone over Bluetooth. Your phone also carries other people's encrypted packets, which it can't read. |
| `meshIntroNearby` | Anyone nearby can tell that this phone has Haven's mesh on, and can follow its radio signal. They can't read your location or see your circles. |
| `meshIntroConnected` | A phone that connects to yours can tell which encrypted packets your phone sent, about how old each is, and when your phone is asleep. It can't tell what they say or whose they are. |
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
must judge whether that tells it. If F-6 is confirmed a sentence is owed:
"A phone that connects can read this phone's Bluetooth name." (Q-6).

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

### E.3 Statistics sheet

`meshStatsTitle`; the two-by-two table, each cell one semantics node read
by `meshStatsCell`; the footnote; one status line from `stats` and the
radio's status; `meshTurnsOffAt` with the deadline formatted by the
locale's time format; `meshKeepOn`; `meshStatsReset` behind a confirm
dialog.

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
| `android-unit.yml` (new; stage 1 of `ci.yml`) — `./gradlew :app:testDebugUnitTest` | every [J] test; and that all Kotlin compiles | feasible **[U]**: cargokit hooks the Rust build to `merge…NativeLibs` only (`haven/rust_builder/cargokit/gradle/plugin.gradle:166-170`), which a unit-test task does not need — read, not run |
| `build-check.yml` (exists) + `nm` step | the nine JNI symbols are in the library [C] | feasible |
| `cross-check.yml` (exists) | `mesh_jni.rs` compiles for Android [C] | feasible |
| `repo-guards.yml` (exists) + three steps | `check_mesh_radio_shim.sh`, `check_mesh_radio_parity.sh`, `check_mesh_android.sh` | feasible; run here too |
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
after it returns), **T-PERF-3** (M packets inside a budget declared in
`e2e_lane_budget.manifest`), **T-NOTIF-1** and **-2** (present when on,
absent when off, back after a cancel at the next screen-off — through
`dumpsys notification`), **T-NOTIF-3**, **T-AUTO** with the reminder and
the stopped notice (the deadline shortened by a debug-only extra, never a
sleep), **T-BG-1** (forced idle; process killed and the service back;
reboot with mesh on; reboot with the permission revoked and no crash),
**T-INDEP-4** (app swiped away with mesh on and sharing off; the catch-up
worker and a relaunch obtain the session), **T-LOG-1** (logscan over the
lane's sinks, with planted peer numbers). **It proves nothing about
Bluetooth**: no adapter of §B.1 runs.

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
air** (the advertisement's bytes; the GATT table; what 0x2A00 answers,
F-6), §B.3's link sequence against a real Bluetooth stack, the two [U]s of
§B.3, and the `neverForLocation` [U].

**If it cannot be made reliable:** the adapters have no proof per push;
requirement N1 is unmet for them (plan G-1's own words); the loopback lane
stands; the adapters wait for the device matrix [H]. A self-hosted runner
with two phones is the owner's call.

### F.4 What no lane proves

A sleeping processor (emulators do not sleep, plan §9.2): the timed wake
lock, Doze (F-5), the alarm's lateness. Radio range, throughput, another
vendor's Bluetooth stack. Battery. All [H], DEFERRED:
`docs/MESH_DEVICE_MATRIX.md` gets its Android half in M3i, marked so.

---

## G. Power (F3)

**Nothing here is measured.** The project has no device
(`docs/POWER_EFFICIENCY_PLAN.md` §2.5); every figure for this feature is
**ESTIMATED** or absent, and `docs/POWER_MEASUREMENT.md` gains nothing.

| Choice (`MeshRadioConstants`) | Value | Basis |
|---|---|---|
| Scan | filtered, `SCAN_MODE_LOW_POWER` | the lowest duty the platform offers; 512 ms in 5.12 s, 10.24 s with the screen off (plan §2.3 [V]) |
| Advertise | `ADVERTISE_MODE_LOW_POWER`, about 1 s [U — reference not re-fetched] | the lowest rate |
| TX power | `ADVERTISE_TX_POWER_MEDIUM` | a judgement: lower costs range, which is function; unmeasured (Q-9) |
| Connection | `CONNECTION_PRIORITY_LOW_POWER` | plan §6.1 |
| Links | at most 4 + 4 | the engine's (`eng:254-255`) |
| Wake lock | timed, `min(next wake + 250 ms, HOLD_CAP_MS = 10 s)`, on an inbound frame or a link coming up; never held otherwise | plan §7.7 R2; the cap is a judgement |
| Alarm | one, inexact, allow-while-idle | §B.5 |
| Scan restart | at a pump, never a timer of its own | no wake added |

What CI holds is mechanism, not milliamps: T-PWR-1 (the constants come
from one site [J], [G]), T-PWR-2 (the link cap, [L] in the engine), T-PWR-3
(with no peer no frame is sent and no lock is taken [J]). Cost accepted by
D-8 and unquantified: in a busy mesh a phone with sharing off is awake most
of the time (plan §7.7 R2) — **if** the lock holds in Doze at all (F-5).
Model E's entries are M5's (plan §10) and will all read ESTIMATED.

---

## H. Security and privacy of the new surface

security-reviewer on M3a, M3b and §B.3–B.4 before they land (plan §8.3).

| Threat | Bound | Where | Test |
|---|---|---|---|
| Malformed, truncated or oversized frame | closes the link; nothing unbounded is allocated | engine (`eng:1078-1134`); `RADIO_MAX_FRAME` before the copy (§A.5) | T-SEC-3 [L, exists]; `a_frame_longer_than_the_radio_carries_closes_its_link` [L] |
| Frame flood on a link | credit per link; unsolicited packet closes it | engine (`eng:44-57`) | T-SEC-3, T-SEC-4 [L, exist] |
| Long write, offset write, write with response | refused; link closed | `GattServerAdapter` (§B.3) | [E] netsim only |
| Connection flood | 12 new inbound links a minute, burst 4 (`eng:252-253`); at most 4 unlinked connections, 10 s each (§B.4) | engine; `MeshRadioCore` | [L, exists]; `unlinkedConnectionsAreCappedAndTimedOut` [J] |
| Slot exhaustion, eclipse | random and rotated slots; departed class | engine (`eng:38-42`) | T-SEC-4 [L, exists] |
| Controller connection slots held by a stranger who never subscribes | **none**: Android has no accept filter for a connectable advertisement | — | residual, stated |
| Handshake cost | two scalar multiplications a connection, behind the inbound limit | engine | plan §6.7 |
| Tracking by advertisement | the service UUID alone; no name, data or power | `AdvertiserAdapter` | `theAdvertisementIsTheServiceUuidAlone` [J]; on air [E] netsim |
| Tracking by address | Android advertises under a resolvable private address, rotated about every 15 minutes **[U — a 2026 paper's figure, from a search summary]**; Haven sets none. An AOSP fix (bug 246692649) for rotation stopping after a connection exists; which releases have it is **[U]** | platform | [H] |
| Re-identification across rotation by the packets held, or by a link kept open | **none**: plan §0.4 item 6, accepted | — | disclosed (§D) |
| The system's Device Name | **none in the app's reach** (F-6) | platform | [E] netsim records it; [H] |
| What Haven's characteristic reveals | nothing readable: write and notify only, every byte after the handshake sealed (plan §6.7) | engine | T-PRIV-8 [L, exists] |
| A Bluetooth address in a log, a notice or across the bridge | the package logs nothing; `PeerTable` keeps addresses in Kotlin memory only; the channel carries a state and a bool | §B.9, §C.1 | `anAddressNeverReachesTheEngine` [J]; `nothing_is_logged_…` [D]; T-LOG-1 [E] |
| The radio reaching a key or a session | no radio entry takes one; the engine is keyless | §A.4 | `the_radio_entries_take_no_session` [L] |
| A radio with the store saying off | bounded to one process start until the first session entry; turn-off stops the radio first | §A.4, §C.3 | `a_session_whose_mesh_is_off_ends_…` [L]; `turning_off_stops_the_radio_first…` [D] |
| The deadline copy at rest | an app-private preference: that mesh was on, and until when. The counters went to the encrypted store for less (D-4) | `MeshPrefs` | Q-2 |
| A debug loopback radio in a release | not in the release source set | §F.2 | guard [G] |

---

## I. Documents made stale, and written with the code

- `haven-core/SECURITY.md` "Bluetooth mesh": "The radio is not [built]"
  and "An entry that holds no session — none exists in this build"
  (`:3293`, `:3419`) — with M3a; a new part for the radio's privacy cost
  (plan §0.4, §8.1), owed there since M2g-1, with M3g.
- `docs/privacy/privacy_invariants.json`: invariants for the advertisement,
  the GATT table, the notices, the deadline copy, the session-less engine.
- `plan` §16: M3's status, each "not as the plan has it" of §0 here.
- `haven/lib/src/providers/mesh_provider.dart`'s "No radio is built yet"
  and `api:12745-12746`'s "The radio is not built yet".
- `docs/MESH_DEVICE_MATRIX.md`: new, Android half, DEFERRED.
- `CLAUDE.md` is the owner's. Proposed for it: in Architecture, the
  radio's JNI surface as the one hand-written `extern` in `rust_builder`;
  in the proposed Rule 17, "the radio's entries take no session and open
  none; a radio entry may start a keyless engine under a deadline no later
  than twelve hours and the first session entry overrules it"; the mesh
  lanes in the CI section.

---

## J. Open questions for the owner

**Q-1. Open a draft pull request now?** Today no Kotlin can be compiled and
no [J], [C] or [E] claim can be tested: CI runs only for pull requests to
`main`.
- *Yes, a draft:* M3f onward gets a compiler and the unit lane; the L4
  spike can run; every existing lane also runs on each push (minutes of
  macOS and Linux runners), and the branch becomes visible.
- *No:* M3a–M3e land with local proof; M3f–M3h are written blind and first
  compiled at whatever pull request comes later.
- **Recommended: yes, when M3f starts**, not before — M3a–M3e need nothing
  from CI. Writing a foreground service and two GATT adapters with no
  compiler is not work that can be called finished.

**Q-2. A keyless engine started by the service with no session (F-1, F-2)?**
- *Yes (designed):* the phone relays and emits cover after a reboot or a
  restart, as plan §0.4 item 3 and R4 promise. Cost: a second, weaker copy
  of the deadline in a plain preference; a window, from process start to
  the first session entry, in which the service's word alone keeps a radio
  on.
- *No:* after a restart the radio stays silent until a session opens. No
  second copy beyond an on flag. Plan §0.4 item 3 then reads "relays only
  while the process that turned mesh on lives".
- **Recommended: yes.** The engine was made keyless for this; the window
  is closed by ordering turn-off radio-first and by the session's overrule.

**Q-3. Keep on from the notification (F-3).**
- *(a) It always opens Haven*, which keeps on as it starts. One path.
  Plan §7.6's "without opening Haven" is given up.
- *(b) Through the channel when Haven's Dart isolate is alive, else opens
  Haven.* Keeps the plan's promise in the common case; two paths, the
  second reachable only on the lane.
- **Recommended: (a).** One tap either way; the store write is made by the
  one session owner in the one way that is tested locally.

**Q-4. The order of turning on (§C.2).** Permissions and Bluetooth before
the store (designed), or the store first as this design's brief had it.
**Recommended: as designed** — a refusal has nothing to unwind.

**Q-5. The L4 lane.** Loopback first and netsim as a spike (designed);
netsim only, as plan §9.1 L4 has it; or loopback only. **Recommended: as
designed.** The loopback lane is the only per-push proof that is known to
be feasible; netsim is the only proof of the adapters short of hardware.

**Q-6. If Android hands a stranger the phone's Bluetooth name (F-6).**
- *Disclose it* in the intro sheet and ship.
- *Gate Android's release* on a mitigation — none is known that does not
  rename the user's phone.
- *Find out first*: the netsim spike, or one real phone, answers it in
  minutes.
- **Recommended: find out before M3d's copy is translated**; if confirmed,
  disclose, and correct plan §0.4 item 6.

**Q-7. "Turns off at 03:15" in place of a time left (§E.3).** One string,
no plural forms in 13 languages, nothing to tick. Plan §7.6 says "the time
left". **Recommended: the clock time.**

**Q-8. Bluetooth switched off while mesh is on (F-4).** Paused, the service
kept, resuming by itself (designed, and plan §7.1's boot wording); or mesh
turned off, as on iOS (plan §0.4 item 4), which is simpler and loses mesh
at every airplane-mode toggle. **Recommended: paused.**

**Q-9. Advertising.** The one legacy path at about 1 s and medium power
(designed), or plan §7.1's 1022.5 ms through the advertising-set API on
API 26+, a second path whose only stated reason is iOS background discovery
[U]. **Recommended: legacy now; decide the interval in M4 with evidence.**

**Carried, not M3's:** the two open decisions of plan §16 (the engine clock
through `rustix` or `libc`; whether a burst awaits its mesh drive); that
Android passes nothing on to a relay (it publishes before it fetches); G-4
(Play's declaration), which only the Console answers.

---

## K. Not verified

- Every platform claim tagged [U] above; collected: the 512-byte attribute
  cap's source; iOS's typical MTU; the `onNotificationSent` wait rule and
  the no-response write's callback; that the server's connection callback
  fires for other connections; `cancelConnection` on an inbound link;
  `startForeground` in a sticky restart on Android 12+; re-posting a
  dismissed foreground notification; the advertise interval of
  `ADVERTISE_MODE_LOW_POWER`; `neverForLocation` and a service-UUID
  advertisement; the wake-lock exemption in Doze; address rotation and the
  AOSP fix; the system's Device Name; grouping with the plugin's
  notification.
- `support.google.com` (Play's foreground-service declaration, [A13]) and
  `google.github.io` (Bumble, [A14]) are outside this session's network.
- That the codegen ignores `pub(crate)` functions; that `api.rs` compiles
  under `deny(unsafe_code)`; that a Gradle unit-test task builds no Rust.
- [A9] and [A10] were read through a summarizing fetch, not in full.
- Nothing was built or run for this design.

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
- bitchat-android at `14ab73c4`: `BluetoothGattClientManager.kt`,
  `BluetoothGattServerManager.kt`, `BluetoothPacketBroadcaster.kt`,
  `app/src/main/AndroidManifest.xml`.
