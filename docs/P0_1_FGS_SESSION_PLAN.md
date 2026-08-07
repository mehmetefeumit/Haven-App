# P0-1 — Android background publishing is dead: fix plan

**Status:** FIXED 2026-08-03 — see §2b. The architecture is (b″) plus one piece
neither branch had named: the release on the way down has to be DURABLE, not
instantaneous. §3 still lands independently. §4-§7 are the routing design, which
P0-1 no longer needs.

**Earlier status (kept for the record):** the gating question is ANSWERED (§2,
2026-08-03) — the Rule-14 guard SURVIVES the main isolate's death, so the
routing design's cold-start fallback cannot be relied on. The architecture is
(b″): release on the way down *and* reclaim from the other side.

**Defect:** `docs/CI_HARDENING_BACKLOG.md` P0-1. Reproduced at runtime 2026-08-02
(CI run 30753193231) by the `e2e-fgs-publish` lane, now its regression test and
red until this lands.

```
15:14:35.583 [b1] checkpoint A2: foreground CircleManagerFfi open (Rule-14 guard held).
15:14:37.300 [BackgroundTask] onStart (starter=TaskStarter.developer)
15:14:37.738 [BackgroundTask] onStart FAILED: String
```

---

## 0. Two things bigger than the defect as filed

**0.1 — The receive path is dead too.** The killer gate is `_circleManager == null`
(`background_location_task.dart:360`), *before* the `_circleService` gate at
`:405`. So publish, `fetchMemberLocations` (`:514-533`) and both prunes
(`:544-561`) are all dead. `fetchMemberLocations` is **MLS-mutating** — its doc
at `:500-509` says it publishes and finalises an evolution event when MDK
auto-commits a peer's `SelfRemove`. A fix restoring only publishing leaves a
silently dead receive path.

**0.2 — Fixing P0-1 activates a privacy gap unless the gate comes with it.**
`kLocationDisclosureAcceptedKey` is checked before every foreground publish
(`location_publish_scheduler_provider.dart:214`) and appears **zero times** in
`background_location_task.dart`. The FGS publish path has no disclosure-consent
gate. It is masked today only because the FGS cannot publish at all. **The
consent gate is part of this fix, not a follow-up** — and routing through the
scheduler closes it by construction, which makes "collapse the two publish
paths" a requirement with a test rather than a tidiness item.

---

## 1. Why the dispose/reopen handshake (a) is rejected

Verified, and the reasons compound:

**`dispose()` does not release the guard.** It drops when the last
`Arc<CoreCircleManager>` does. Other holders: `LiveSyncFfi` (`api.rs:8964-8968`),
the process-global `static SESSION` (`api.rs:8801`) via `LiveSyncCore::new_local`
(`:9008-9011`), detached tokio workers holding `Arc<EngineProcessor>`
(`live_sync/session.rs:421`, signalled but never joined by `stop_inner`
`:629-674`), and every in-flight `run_blocking` closure. `MapShell._onPaused()`'s
Android branch (`map_shell.dart:713-739`) never stops live-sync. The repo already
says this: `nostr_circle_service.dart:1595-1597`.

**It manufactures Rule-13 violations on a schedule.** The `PendingStateRef` that
`confirm_published`/`publish_failed` require is in-memory only and dies with the
session. A pause-time dispose/reopen either rolls back a staged commit (emitting
`PendingCommitRecovered`, a mandatory-resync signal) or — for removal-bearing
commits, which upstream deliberately does not roll back — strands it with no
token, wedging every future commit in that group. There is also a window where a
commit is published and acked but never confirmed: the epoch advances on the wire
and an invitee's Welcome is never published (`circle/manager.rs:976-982`).

**Not a reason:** "the CAS makes the handshake redundant." That was in the first
draft and is a strawman — (a)'s value was never added exclusion, it was release
*ordering*. The two reasons above are the real ones.

### What Rule 14 is protecting (verified down to the ciphersuite)

Not the kind-445 outer nonce — CSPRNG per wrap
(`transport-nostr-peeler/src/peeler.rs:120-121`). OpenMLS `create_message` always
emits a `PrivateMessage` (`openmls-0.8.1/src/group/mls_group/application.rs:16-50`)
under `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (`cgka-engine/src/engine.rs:48-49`),
keyed from the sender ratchet at `(epoch, leaf, generation)`, read-modify-written
last-writer-wins (`mod.rs:611-632`), and `send.rs:748` reloads the group from
storage per send. Two hydrated sessions therefore reach the same generation:
same key, same nonce, two plaintexts — a two-time pad over location payloads plus
GHASH forgery. This is a steady-state collision between two independently
jittered tickers, not a narrow race.

---

## 2. ANSWERED (2026-08-03): the guard SURVIVES the main isolate's death

**Both confirmation reviews were right.** With live-sync running — the
production default — the Rule-14 guard is still held after the main
`FlutterEngine` is destroyed, so the routing design's cold-start fallback
cannot succeed. Derived from source, with the probe's contribution noted below.

The chain, every link verified:

1. `static SESSION: RwLock<Option<Arc<LiveSyncCore>>>` (`api.rs:8801`) is a
   **Rust process global**. Rust statics live in the loaded `.so`, not in any
   Dart isolate.
2. `LiveSyncCore { circle: Arc<CircleManager>, … }`
   (`live_sync/session.rs:127-129`, installed by `new_local` at `:243`) → that
   `Arc` reaches `SessionManager` → `LiveSessionGuard`.
3. `SESSION` is cleared in exactly three places, all in `api.rs`:
   `stop_session` (`:9081-9090`), and `start_session`'s stale-slot replace
   (`:9034-9042`) and start-failure path (`:9066`). Nothing else.
4. On the Dart side the only calls to `_liveSync?.stop()` are
   `map_shell.dart:433` (a start-race path) and `:1107`, inside
   `State.dispose()`.
5. `State.dispose()` does **not** run when the engine is destroyed — there is no
   orderly widget-tree teardown on isolate shutdown — and
   `didChangeAppLifecycleState` ignores `detached` (`map_shell.dart:670-682`).
6. `liveSyncEnabled` defaults to **true** (`live_sync_provider.dart:29-32`) and
   `_startLiveSync()` runs on every launch, so `SESSION` is populated in the
   normal case.

The repo already states the premise outright at `api.rs:9022`: *"the app process
outlives the Dart `ProviderScope`, so the static `SESSION` survives."*

### What the probe added, and why its first answer was wrong

Runs 30770222629 / 30772868486 / 30774016395. The third returned **ACQUIRED**,
which is *not* the production answer — the target held the guard only through a
leaked **Dart** `CircleManagerFfi` handle and never started live-sync, so
`SESSION` was empty. Isolate shutdown ran that handle's `NativeFinalizer`,
dropped the `Arc`, and freed the guard.

That is still a useful result, and it sharpens the design space rather than
being noise: **the Dart-held `Arc` IS released on engine destruction.** So the
only production holder that survives is `static SESSION`. If live-sync released
its clone on the way down, the guard would come free.

The earlier two runs are recorded as method failures, not results: 30770222629
reported REFUSED while never destroying the Activity at all (no precondition
existed), and 30772868486 correctly failed INCONCLUSIVE once one did. Both are
worth remembering — the first produced the *predicted* answer, which is the
most seductive kind of false positive.

### Consequence for the design

The cold-start fallback in §4 cannot be relied on. But (b″) is cheaper than the
reviews assumed: the blocker is one `Arc` in one global, not an intractable
ownership problem. Two ingredients, and both are needed:

* **Release on the way down.** Handle `AppLifecycleState.detached` in
  `map_shell.dart` with a synchronous `stop_session()`. Necessary, not
  sufficient — Android does not reliably deliver `detached`, and an abrupt
  engine kill delivers nothing.
* **Reclaim from the other side.** Because the above cannot be guaranteed, the
  FGS still needs a way to take a slot whose owning isolate is provably gone —
  a Rust-side liveness epoch on `LiveSessionGuard`, refreshed by the owner, so a
  stale registration can be reclaimed under the same CAS that already arbitrates
  acquisition. This is the piece that makes the fallback real.

If that reclaim proves harder than it looks, (c) — FGS owns the session, main
isolate routes to it — remains the fallback architecture.

### Optional confirmation

Re-running the probe with live-sync started before the pop would confirm
`REFUSED` empirically. The source chain above is decisive for the design
decision, so this is confirmation rather than a gate.

### Method notes (the experiment that produced the answer above)

Both confirmations found the same hole in the routing design (b′): **the guard
survives main-isolate death.**

`MainActivity : FlutterActivity()` caches no engine
(`android/app/src/main/kotlin/.../MainActivity.kt:7`), so Activity destruction
tears down the main isolate. `didChangeAppLifecycleState` acts only on
`paused`/`resumed` and explicitly ignores `detached` (`map_shell.dart:669-681`);
the only `_liveSync?.stop()` is in `State.dispose()` (`:1107`), which does not run
on abrupt engine teardown. Haven's FGS has no `android:stopWithTask`
(`AndroidManifest.xml:72-75`) and the plugin removes the pref when unset
(`ForegroundTaskOptions.kt:81`), so **swipe-from-recents kills the engine and
keeps the service**. `liveSyncEnabled` defaults true
(`live_sync_provider.dart:29-32`) and `_startLiveSync()` runs every launch, so
`static SESSION` pins the guard for the rest of the process with no isolate alive
to release it.

In that state there is nobody to route to **and** the guard is held, so the
CAS-gated fallback fails closed too. (b′) as drafted reproduces P0-1
permanently, with 20s of added latency per tick.

**Run this before writing any transport. It is BUILT and runnable now:**

```
gh workflow run "P0-1 Session Probe (manual)"
```

`workflow_dispatch` only — `.github/workflows/p0-1-session-probe.yml`, driving
`tooling/e2e/ci/run-p0-1-session-probe.sh` +
`haven/integration_test/p0_1_session_probe_test.dart`, with the probe itself in
`background_location_task.dart` behind `--dart-define=HAVEN_P0_1_PROBE=true`
(compiled out otherwise, and `kDebugMode`-gated on top).

It arms a process where the MAIN isolate holds the guard and a foreground
service is running, then destroys the Activity deterministically via
`always_finish_activities` + HOME — the swipe-from-recents state, reachable from
adb — and reads the next FGS tick's verdict:

* `REFUSED rule14=true` — the guard survived the isolate. The cold-start
  fallback is dead on arrival; take (b″) or (c) below. **This is what both
  confirmation reviews predict.**
* `ACQUIRED` — the guard died with the isolate; the routing design is viable as
  specified. Re-check *why* the reviews were wrong before relying on it.

The probe acquires and immediately disposes, so it never leaves the process in a
state it did not find — holding the guard would both change what it measures and
lock the foreground out on the next launch.

Either verdict is a successful run; the lane fails only when it cannot obtain
one. Delete the probe, the target, the script and the workflow once the answer
is recorded here.

A second question is worth logging in the same run but does not gate anything:
is `lookupPortByName` non-null while no reply ever arrives? That would confirm
the drop is undetectable from the FGS side, which is what forces the two-phase
ack in §4. The 30-minute Doze soak proposed in
the first draft measures only the happy path (Activity stopped, engine alive) and
cannot reach this state; it is not the decisive test. Note also that "do Dart
timers keep running" is *not* load-bearing — routing needs event-loop delivery of
a port message, not timer scheduling.

**If question 1 fails as expected, (b′) is unbuildable as specified.** The
branches are:

* **(b″)** — keep routing, but add a real release path that does not need the
  dead isolate: handle `detached` with a synchronous `stop_session()` +
  `closeAndInvalidate()`, **plus** a Rust-side liveness epoch letting the FGS
  prove the owning isolate is dead and reclaim the slot (Android does not
  reliably deliver `detached`, so the lifecycle hook alone is insufficient).
* **(c)** — invert: the FGS owns the session always and the main isolate routes
  to it. Rule-14-safe by construction, better Android liveness, much larger
  refactor (every UI read becomes an async round-trip).

---

## 2b. FIXED (2026-08-03): the release had to be durable, not instantaneous

The reclaim (§2) landed and the pause-time release landed, and the lane went red
one stage LATER — silently, which is the more expensive failure. CI 30792258968:

```
[MapShell] handoff: released=true                                  ← release worked
[LiveSyncResubscriber] engine not running — full restart instead of delta
[BackgroundTask] reclaim: declined, main isolate alive             ← 72s later
```

**Root cause.** Releasing frees the guard for an instant; it does not keep it
free. Both (b″) ingredients were framed around a main isolate that is GONE, and
at pause it is not gone — it is paused, with work still resolving. Three
straggler paths, all of which call `NostrCircleService.getCircleManagerFfi()`
and all of which simply re-open on a free guard:

* a publish chain suspended mid-`await` at the moment of the pause;
* `LiveSyncResubscriber.onCirclesChanged` → `_fullRestart`, whose engine start
  opens the manager and pins it in the process-global `SESSION`;
* the KeyPackage / relay-list maintenance ticks, which are provider timers, not
  `MapShell` timers, and so keep running while paused.

The service then found the guard held by a provably-ALIVE owner. Its reclaim did
the right thing and declined — reclaiming from a live isolate destroys that
isolate's live receive for nothing — and `_publishCycle` returned silently every
72 s for the rest of the session. Note the shape: no error, no failed marker,
and the FGS's own `Initialized (… locationSharing=false)` line is CORRECT at
`onStart`. Only the absence of a later acquire distinguishes it.

**Fix.** `releaseForHandoff` now latches the service closed
(`nostr_circle_service.dart`): while the latch holds, every `initialize()` fails
closed, so the one chokepoint every UI-isolate consumer already funnels through
is what makes the handoff durable. Three properties keep it from becoming its
own outage:

1. The latch is paired with "and we are still backgrounded"
   (`appIsForegrounded()`), so a missed clear LAPSES rather than bricking the
   database for the life of the process.
2. `MapShell._onResumed` ends it explicitly, before the heal and before the
   resume debounce — everything downstream of that point needs the manager.
3. An `initialize()` suspended across the latch disposes its handle instead of
   adopting it, the same fail-closed adoption `_wiped` already used.

The re-subscriber is replayed on resume, because the circle-set change it could
not apply while the handoff held leaves its running-set signature un-advanced on
purpose.

**Consequence for §4-§7.** Routing is no longer required for P0-1. Its costs
(the `sendDataToTask` platform-channel leak, the per-tick budget, the
`_active` bypass, the iOS collateral) stand unchanged if it is ever revisited
for other reasons.

**Coverage.** `nostr_circle_service_test.dart` ("handoff durability") for the
gate and its lapse; `session_guard_contention_test.dart` for the real-FFI
property that a FREE guard is still refused; `map_shell_detached_release_test.
dart` for the resume ordering; `scripts/ci/check_mls_session_single_owner.sh` so
a fourth `CircleManagerFfi.newInstance` cannot bypass the chokepoint. The B1
oracle also gained a window CLOSE (`[b1] HOLD_COMPLETE`): resuming takes the
session back by stopping the service, so an EOF-bounded window read the
teardown's `onDestroy` as the service dying mid-proof.

---

## 3. Land now — independent of the branch

**3.1 — Consent gate on the background publish path (§0.2).** Highest priority;
it is a privacy requirement, not a refactor.

**3.2 — `canonical_session_key` must fail closed** (`storage.rs:56-72`). The doc
claims the raw-path fallback "can only ever be stricter"; true for the merge
direction only. On Android `/data/user/0/<pkg>` is a symlink to
`/data/data/<pkg>`, so canonical and raw spellings genuinely differ — one
transient `canonicalize` failure yields two registry keys for one file and two
live sessions, the confidentiality-losing direction. This is a fail-open on a
confidentiality control. Fix it, don't document it.

**3.3 — Fix the stale concurrency doc at `api.rs:3399-3407`.** It says
`create_message` races and callers must serialize, naming a provider that no
longer owns it. haven-core has serialized every engine write since Dark Matter
through `SessionManager { session: tokio::sync::Mutex<AccountDeviceSession> }`
(`mls/manager.rs:99-101`, `:494-501`). Left in place it will make whoever builds
the routing layer construct a distributed lock for a solved problem — while
missing the real hazard: a compound Rule-13 sequence (stage → publish →
`confirm_published`) spans three FFI calls with the lock dropped between them
(`manager.rs:651-658`, `:667-674`). The engine refuses a second send while
non-`Stable` (`send.rs:756-766`), so an unfenced sequence wedges a group rather
than forking — a liveness failure, but the Dart FIFO is still required.

**3.4 — Install the `kReleaseMode` `debugPrint` silencer in `backgroundCallback()`**
(`background_location_task.dart:49-52`). `main.dart:77-79` and
`background_catchup_worker.dart:363-364` both do; the FGS does not. Benign today
(counts and `runtimeType` only) but must precede any new DTO logging.

**3.5 — Correct the stale `WRITER_LOCK` rationale.** `background_catchup_worker.dart`
justifies its fail-open gates (`:277`, `:286`, `:295`) with a Rust `WRITER_LOCK`
that **does not exist** — superseded at Dark Matter. The live mechanism is
`LiveSessionGuard`, which fails *closed*, so "proceed conservatively, the
WRITER_LOCK will serialize it safely" is false. Fix the comments and
`haven-core/SECURITY.md:201`.

**3.6 — Write down that the `CircleManagerFfi` opaque handle must never cross
isolates.** At the Rust level the MOI pool is process-global and it would
"work"; `frbInternalSseDecode` is public Dart. At the Dart level the FGS is a
separate isolate group and the handle carries a `NativeFinalizer`. A
hand-maintained cross-isolate refcount where one side can die without unwinding
gives a permanent +1 (guard held to process death) on one mistake and a dangling
`Arc` on the mirror mistake. Rule it out in writing.

**Not landing as previously claimed:** per-tick retry does *not* "remove the
forever". `circleServiceProvider` is a plain `Provider` released only at logout,
so retry fails every tick. It makes *transient* collisions recoverable and every
failure observable — a smaller, real claim. And it must land **with** the oracle
revision (§5), because it immediately falsifies the `Initialized (…
locationSharing=true)` marker.

**Typed session errors** (`NostrError::SessionAlreadyOpen`, `KeyringUnavailable`)
are safe and are a Rule-8 improvement — both strings already cross the FFI
verbatim. But as scoped they are **inert**: the boundary stringifies and the FGS
logs only `${e.runtimeType}`. Pair them with a stable `HAVEN_E_SESSION_BUSY:`
prefix and a log line that prints it, or the diagnosability claim is false.

---

## 4. Transport, if a routing branch wins

**Do not use `sendDataToTask` for the reply.** `MethodCallHandlerImpl.kt:78` is
the only branch in its `when` that never calls `result.success`/`error`/
`notImplemented`, and the Dart side discards the Future
(`flutter_foreground_task_method_channel.dart:170`). Every routed reply leaks a
permanently-pending platform-channel entry plus its retained payload — inside the
one process the design needs to survive indefinitely.

**Use an FGS-owned `ReceivePort` with its `SendPort` carried in the request.**
`SendPort` is sendable. The main isolate replies directly on it. This is a single
`dart:isolate` hop: no Kotlin, no `StandardMethodCodec`, no JSON round-trip (which
otherwise stringifies map keys and destroys nested `Uint8List`), no capacity-1
channel buffer, no leak. It also enables a **two-phase ack** — an immediate
`{ack: requestId}` then the result — which is the only way to distinguish
"reachable but slow" (back off, do **not** fall back) from "gone" (fall back).
Without it, the drop count is ~17 across both directions and a timeout cannot
tell dead from busy.

**One request per tick carrying the whole cycle, with a total per-tick budget** —
not 3+N requests at 20s each, which with three circles exceeds the 72s tick,
silently skips ticks, and makes `BackgroundIdleWaiter`'s 5s budget
(`background_idle_waiter.dart:28-52`) a guaranteed timeout on every resume.
Timeout retires the correlation entry; a late reply for a retired id is dropped —
otherwise routed and fallback paths both run `fetchMemberLocations`, which is
MLS-mutating.

**Route by `nostr_group_id` hex only, never `mlsGroupId`** (Rule 4). The FGS's
current inline publish uses `circle.mlsGroupId` (`:454-455`); the convention to
follow is `_circleKey` (`location_publish_scheduler_provider.dart:98-102`).

**Never split ingest from confirm across the boundary.** `PendingCommitToken`
wraps a `BigInt` over an engine-local counter with no cross-process stability
(`cgka-traits/src/engine_state.rs:46-52`), so a token minted by one session and
confirmed against another can collide with a live ref and confirm a *different*
staged commit — applying a commit that was never published. The request is "run a
receive cycle for circle X", never "here are events, decrypt them".

**CI guard, correctly shaped:** the proposed `decryptLocation` grep is vacuous —
the FGS reaches it through `LocationSharingService`, never by name. Ban
`PendingCommitToken` / `confirmPendingCommit` / `failPendingCommit` /
`commitEventJson` from the FGS and DTO files, plus the single-site
`CircleManagerFfi.newInstance` check. As steps in `repo-guards.yml`.

---

## 5. Oracle revision — the lane must not become a liar

The B1 lane's `max_published_count` is a **MAX** over the window
(`run-b1-fgs-publish.sh:123-127`) and the hold is 200s against a 72s tick. So
routing's characteristic failure — tick 1 succeeds, the Activity is destroyed,
ticks 2..n silently time out — passes every current assertion. Assert instead:

1. **Distinct** `Published to N/M` lines with N≥1 in the window: require ≥2.
2. The **last** such line has N≥1 (proves no degradation).
3. A **main-isolate-side** marker (`[PublishBridge] served req=…`) — the FGS
   logging "routed via bridge" proves only that it got *a* reply, not that the
   work ran where the design says.
4. `routed via local fallback` absent.
5. **A forced-fallback negative control.** Once the FGS stops calling
   `newInstance` in steady state, nothing in CI exercises a Rule-14 acquire under
   contention and P0-1 can regress silently. A `HAVEN_FORCE_FGS_FALLBACK=true`
   build asserting the fallback still fails closed, or a separate lane.

---

## 6. Resolve in writing before building

* **GPS ownership.** §4.4 and §4.5 of the first draft contradicted: `_publishCircle`
  acquires its own fix (`location_publish_scheduler_provider.dart:217-219`) while
  the FGS was said to keep GPS. Decide: FGS sends lat/lon and the entry point
  takes an injected `Position` (preferred — the main isolate's geolocator stream
  is not guaranteed running while backgrounded on Android).
* **The routed entry point must bypass `_active`.** `stopScheduling()` sets it
  false at pause (`:247-250`) — checked at `:191`, `:205`, `:215`, `:220` — so a
  routed request would be silently dropped in exactly the state it exists for.
  It must still join `_publishChain`. And `_publishCircle` returns `void` and
  swallows everything (`:228-231`), so it needs a typed per-circle outcome or the
  reply is a lie by default.
* **Android relay shutdown at pause.** `_onPaused` calls `relay.shutdown()`
  (`map_shell.dart:805-812`) because "Android hands publishing off to the FGS
  isolate (which owns its own relay)" — the premise routing deletes. Either every
  routed publish races a cold reconnect (documented to drop the first publish), or
  the socket stays warm for the whole background session, reversing the
  metadata-minimisation posture. Pick one and say so.
* **Retiring `kForegroundActiveAtMsKey`.** It is also the single-writer handoff
  signal (`background_location_task.dart:385-396`, `:445`, `:517`, `:546`) and
  what makes `background_catchup_worker` gate 4 defer (`:297-301`). Retiring it as
  a routing input is fine; name who still writes it and which consumers depend on
  it. Note routed work serializes with the per-circle scheduler but **not** with
  `locationPublisherProvider`'s one-shot burst (`map_shell.dart:975-981`), so the
  same circle can be published twice within seconds by two independently jittered
  schedulers — the co-timing signal the decorrelation work exists to remove.
* **The FGS notification lies when the bridge is dead.** `_onPaused` sets "Haven
  is sending and receiving location information" (`:731-736`) and only `_onResumed`
  changes it. With a destroyed engine that persists while nothing is sent — a Play
  prominent-disclosure surface, not cosmetics. The FGS should update its own text
  after N consecutive failures.
* **iOS collateral.** `_publishCircle` **is** the live iOS background publisher
  (`shouldKeepPublishingWhilePaused` = `backgroundSharingEnabled && isIOS`). Any
  change to its `_active` handling, position injection, or error propagation lands
  on iOS. Either add an iOS lane or keep the routed entry point a sibling sharing
  only the leaf.

---

## 7. Recovery from a fallback-held guard (was "out of scope" — retracted)

The first draft called this pre-existing and recoverable. It is not recoverable.
`_ensureInitialized` does retry (`nostr_circle_service.dart:244-249`, completer
reset at `:235`, `:238`), but every retry hits the same held guard. The FGS
releases only in `onDestroy` (`background_location_task.dart:325-330`), and the
only stops are toggle-off, no-identity, and provider dispose
(`background_location_provider.dart:294-302`, `:278-280`) — `_onResumed`
deliberately does not stop it (`map_shell.dart:938-946`). So a cold FGS boot that
takes the guard leaves the user with no circles, no map data, no publish and no
receive until they toggle background sharing off or the process dies.

Routing makes this **more** likely, not less: today the FGS reaches `newInstance`
once at `onStart` and normally loses the race; a routing design gives it a
routine, scheduled, timeout-driven reason to take the guard and cache it.

**Required:** on a Rule-14-attributable init failure, stop the FGS, await
`onDestroy`'s dispose, retry once. This is what makes the typed error
load-bearing rather than decorative.
