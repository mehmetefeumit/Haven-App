/// B9 drive target — proves what Haven's LIVE RECEIVE path does when the
/// device loses the network mid-session and gets it back
/// (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B9:
/// "Network loss/reconnect | `adb emu network disable/enable`").
///
/// ## The item's stated MECHANISM does not exist — the lane uses another
///
/// There is no `network disable` / `network enable` in the Android emulator
/// console. The `network` command takes exactly four subcommands —
/// `status`, `speed`, `delay`, `capture` — verified by inspecting the
/// shipped `qemu-system-x86_64` binary's own help strings; the only
/// connectivity kill switch the console offers is `gsm data off`, which
/// reaches the CELLULAR path only, while an API-34 `google_apis` AVD routes
/// over its emulated Wi-Fi. The shell
/// (`tooling/e2e/ci/run-b9-network-reconnect.sh`) therefore drops the
/// network with `cmd connectivity airplane-mode enable` (verified through
/// `settings get global airplane_mode_on`) and additionally rejects the
/// relay port on the runner host, so the outage is immediate rather than
/// waiting out a 55 s WebSocket ping. THIS file never assumes either
/// worked: it proves the outage from inside the app process, and refuses to
/// score the recovery if it could not.
///
/// ## What recovery actually depends on (read from source before writing
/// this)
///
/// Three independent mechanisms can bring live receive back, at very
/// different speeds. The lane's budget is sized to the SLOWEST, because
/// which one fires is not under the test's control:
///
///  1. **The relay pool's own reconnect.** `build_engine_client`
///     (`haven-core/src/relay/live_sync/session.rs`) takes
///     `RelayOptions::default()`, i.e. `reconnect: true` with a 10 s
///     `DEFAULT_RETRY_INTERVAL` adapting up to a 60 s `MAX_RETRY_INTERVAL`
///     (`nostr-relay-pool-0.44`). On reconnect, `post_connection` calls
///     `resubscribe()`, which re-sends every stored filter VERBATIM — same
///     subscription id, same `since` — so the relay replays whatever landed
///     during the gap. `should_resubscribe` returns true after a drop
///     because `connected_at > subscribed_at` once the socket has come back.
///     This is the fast path: seconds to ~a minute.
///  2. **Haven's M8 subscription-health tick.** `maintainSubscriptionHealth`
///     re-anchors every subscription at its persisted cursor via
///     `resume_after_background` when any relay is `Disconnected`
///     (`haven-core/src/relay/live_sync/health.rs`). Scheduled by
///     `maintenanceSchedulerProvider` at +90 s and then every 15 minutes
///     (`subscriptionHealthInterval`).
///  3. **`MapShell`'s self-heal.** If the drop kills the engine outright,
///     `NostrSubscriptionService._onStreamClosed` tears the session down
///     (the handle would otherwise pin the Rule-14 guard), and NOTHING
///     restarts it except `_healLiveSyncIfStopped` →
///     `LiveSyncResubscriber.ensureRunning()`, on a jittered 90–150 s timer
///     that DOUBLES per consecutive failure up to ×8 (`map_shell.dart`).
///     A heal attempt made while the network is still down counts as a
///     failure, so one wasted tick pushes the next one out to 180–300 s.
///
/// [_recoveryBudget] is sized against (3), not against (1): 330 s covers a
/// heal tick that was burned during the outage plus its doubled successor.
/// A lane budgeted for the fast path would report a product defect every
/// time the slow path legitimately ran.
///
/// ## The assertion is a DECRYPTED PEER EVENT, not a reopened socket
///
/// A socket that comes back proves nothing a user cares about. This target
/// requires that a peer location published AFTER the outage reaches
/// `memberLocationsProvider` with the peer's NEW coordinates. The
/// coordinates are the anti-vacuity check and they are load-bearing:
/// `memberLocationsProvider` still holds the peer's PRE-outage entry, so
/// "an entry for Bob exists" is satisfied by the stale baseline and would
/// pass on an app whose receive path never came back at all. [_postLatitude]
/// / [_postLongitude] are therefore deliberately different from
/// [bobFakeLatitude] / [bobFakeLongitude], and the check is on the value.
///
/// ## The BACKLOG proof — an event that reached the relay while Alice was
/// genuinely partitioned
///
/// Bob encrypts a kind-445 at [_backlogLatitude] / [_backlogLongitude] WHILE
/// THE NETWORK IS STILL DOWN (encryption is local MLS work and needs no
/// relay) and writes it to a file instead of publishing it. The shell then
/// exports that file over adb — which rides the emulator's control channel,
/// not the guest IP stack, so airplane mode does not touch it — and imports
/// it into strfry with `strfry import` INSIDE the relay container, while the
/// guest is still in airplane mode. Nothing on the device publishes those
/// coordinates, ever; the only carrier is the imported event.
///
/// A host-side WebSocket publisher was rejected for two independent reasons.
/// The host cannot mint a genuine kind-445 — that needs the circle's MLS
/// exporter secret, which never leaves the device and must not (Security
/// Rules 6/7/10) — and an event not genuinely encrypted for the circle would
/// prove nothing about delivery-and-decrypt. And the shell's layer-L2
/// blackout is an `iptables -A OUTPUT ... --dport <strfry> -j REJECT` on the
/// RUNNER HOST, which applies to locally-generated packets: during the
/// blackout the host cannot reach the relay's published port either. Only a
/// writer inside the container survives it, and `strfry import` is that
/// writer.
///
/// ## Two senders, because `memberLocationsProvider` keeps one entry per
/// sender
///
/// The cache is latest-per-sender, strictly-newer-wins
/// (`location_sharing_service.dart`), so a post-restore event from BOB would
/// overwrite the older backlog entry the moment both land in the same replay
/// — and a 3-second sampler would see only the newer one, reporting a
/// delivered backlog as dropped. The backlog therefore comes from BOB and
/// the post-restore liveness events from CAROL, whose entries cannot mask
/// each other.
///
/// Carol's arrival is not decoration: it is the only signal that says WHEN
/// live receive came back, and without it a missing backlog event is
/// unattributable — "the app dropped it" and "the subscription had not
/// returned yet" look identical.
///
/// Because the whole verdict rests on her, CAROL IS IN THE BASELINE TOO. Her
/// receive path is proven before the network is touched, so a Carol-side
/// membership fault (a Welcome that never applied, a wrong epoch) fails as an
/// ordinary baseline failure instead of surfacing later as
/// [kReceiveDeadMarker] — which this lane reports as a receive-path defect,
/// in terms that steer the reader away from the harness.
///
/// ## What the backlog verdict is conditioned on, and why
///
/// The kind-445 wire TTL is a fixed `created_at + 228 s` NIP-40 `expiration`
/// (group component 0x8005, `LOCATION_MESSAGE_RETENTION_SECS`), strfry
/// deletes expired events on a 9-second cron, and Haven's own receiver-side
/// screen drops them anyway (`RECEIVER_EXPIRATION_GRACE_SECS`). Recovery
/// path (3) can legitimately take longer than that, in which case the relay
/// has GC'd the backlog event before there is any subscription to serve it
/// to. That is correct behaviour on both sides, so the lane must not score
/// it as a defect.
///
/// The discrimination is made by ASKING THE RELAY, never by arithmetic on
/// two clocks: while the backlog event is unseen, this target polls the
/// relay for it by id. Presence is monotone — strfry never re-adds a GC'd
/// event — so the last instant the relay was OBSERVED holding it is an
/// instant at which it demonstrably held it. If Carol's coordinates arrived
/// at or before that instant, the receive path was live while the event was
/// still on the relay and the app never surfaced it: a real defect
/// ([kBacklogMissedMarker] `reason=live`). If the relay had already dropped
/// it, the run reports `reason=expired` and the backlog proof simply did not
/// run — recorded loudly, never as a pass.
///
/// ## What one emulator still cannot prove
///
/// Bob's process is Alice's process. This proves that an event which reached
/// the relay while the receiver was partitioned is replayed and decrypted
/// after reconnect; it does NOT prove that a second physical device kept
/// publishing across the blackout, and it cannot, because the publisher and
/// the receiver share one network stack. Everything except the transport of
/// that one event is real: the event is genuine MLS ciphertext produced by
/// the production FFI, signed, and accepted by strfry's ordinary ingest
/// validation.
///
/// ## Why the body never throws mid-sequence
///
/// The shell drives the two network toggles from OUTSIDE the process and
/// waits on markers this file prints. A phase that threw would leave the
/// shell waiting for a marker that can never arrive, burning the lane's
/// deadline and reporting a timeout instead of the finding. Every phase
/// therefore RECORDS a verdict and continues; the collected verdicts are
/// asserted once, at the end, after connectivity has been restored and all
/// evidence is in logcat. The shell's oracle re-derives the same verdicts
/// from the markers independently, so a `flutter drive` that exits 0 on a
/// failed body (`drive-log-lib.sh`) cannot hide them.
///
/// ## Markers
///
/// Owned by THIS file. Change here AND in the shell together, or the lane
/// silently stops finding them.
library;

import 'dart:convert' show jsonDecode;
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart'
    show circlesProvider, selectedCircleIdProvider;
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/key_package_provider.dart'
    show keyPackagePublisherProvider;
import 'package:haven/src/providers/live_sync_provider.dart'
    show liveSyncEnabled;
import 'package:haven/src/providers/location_sharing_provider.dart'
    show memberLocationsProvider;
import 'package:haven/src/providers/onboarding_provider.dart'
    show
        OnboardingController,
        OnboardingFlags,
        kOnboardingCompletedKey,
        kOnboardingIntroSeenKey,
        onboardingControllerProvider;
import 'package:haven/src/providers/service_providers.dart'
    show
        circleServiceProvider,
        locationServiceProvider,
        subscriptionServiceProvider;
import 'package:haven/src/rust/api.dart'
    show CircleCreationResultFfi, MemberKeyPackageFfi, RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show
        FakeLocationService,
        aliceFakeLatitude,
        aliceFakeLongitude,
        bobFakeLatitude,
        bobFakeLongitude,
        carolFakeLatitude,
        carolFakeLongitude;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilFound;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show TestRelay, defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;
import 'e2e/_lib/throw_time_error_capture.dart';

/// Printed once identity, a two-member circle and a live engine all exist —
/// i.e. the session this lane is about to disconnect is genuinely live.
const String kArmedMarker = '[b9] ARMED';

/// Printed with `ms=<n>` once Alice has DECRYPTED a peer location over the
/// live engine BEFORE the outage. The shell parses it; without a baseline,
/// "the peer location did not arrive after the outage" is unattributable.
const String kBaselineReceivedMarker = '[b9] BASELINE_RECEIVED';

/// The negative twin of [kBaselineReceivedMarker].
const String kBaselineDeadMarker = '[b9] BASELINE_DEAD';

/// Printed with `running=<bool>`: the live-sync engine's own liveness before
/// the drop. `false` makes the whole lane vacuous — nothing was connected to
/// disconnect — so the shell fails on it.
const String kEngineBaselineMarker = '[b9] ENGINE_BASELINE';

/// The shell's cue to drop the network.
const String kAwaitingDownMarker = '[b9] AWAITING_NETWORK_DOWN';

/// Printed with `ms=<n>` once the APP PROCESS ITSELF could no longer open a
/// socket to the relay — proof the drop reached the process under test, not
/// merely that adb accepted a command.
const String kOutageObservedMarker = '[b9] OUTAGE_OBSERVED';

/// The negative twin: connectivity never went away, so nothing that follows
/// says anything about reconnect.
const String kOutageNotObservedMarker = '[b9] OUTAGE_NOT_OBSERVED';

/// Evidence (never asserted) with `running=<bool>`: whether the engine
/// survived the outage or was torn down by
/// `NostrSubscriptionService._onStreamClosed`. Decides which recovery
/// mechanism the run actually exercised.
const String kEngineDuringOutageMarker = '[b9] ENGINE_DURING_OUTAGE';

/// The shell's cue to restore the network.
const String kAwaitingUpMarker = '[b9] AWAITING_NETWORK_UP';

/// Printed with `ms=<n>` once the app process could reach the relay again.
const String kNetworkRestoredMarker = '[b9] NETWORK_RESTORED';

/// The negative twin of [kNetworkRestoredMarker] — a harness failure, since
/// the shell was asked to restore connectivity and it did not come back.
const String kNetworkNotRestoredMarker = '[b9] NETWORK_NOT_RESTORED';

/// Printed once the peer's post-outage kind-445 has been OK-acked by the
/// relay. Publishing is a precondition for receiving; without this line a
/// silent receive path and a silent send path are indistinguishable.
const String kPeerPublishedMarker = '[b9] PEER_PUBLISHED_POST_OUTAGE';

/// The negative twin of [kPeerPublishedMarker].
const String kPeerPublishFailedMarker = '[b9] PEER_PUBLISH_FAILED';

/// THE HEADLINE. Printed with `ms=<n> republishes=<n>` once
/// `memberLocationsProvider` surfaces the peer's POST-OUTAGE coordinates —
/// a peer event decrypted after the reconnect, not a socket that reopened.
const String kReceiveResumedMarker = '[b9] RECEIVE_RESUMED';

/// The negative twin, and the REAL FINDING case: connectivity came back, the
/// peer published, and live receive never recovered.
const String kReceiveDeadMarker = '[b9] RECEIVE_DEAD';

/// Evidence with `running=<bool>`: engine liveness after the recovery window.
const String kEngineRecoveredMarker = '[b9] ENGINE_AFTER_RECOVERY';

/// The shell's cue to export and import the backlog event, printed with
/// `offline=<bool> path=<abs>` once Bob's backlog kind-445 is on disk.
///
/// `offline` is re-probed immediately before the marker is printed: the shell
/// is about to import this event on the grounds that the device could not
/// have received it live, and that grounds is checked, not assumed.
const String kBacklogStagedMarker = '[b9] BACKLOG_STAGED';

/// The negative twin: the backlog event could not be produced at all, so the
/// shell has nothing to import and the backlog proof cannot run.
const String kBacklogStageFailedMarker = '[b9] BACKLOG_STAGE_FAILED';

/// Printed with `served=<bool>` right after connectivity returns: whether the
/// RUNNING relay answers a real `["REQ", …, {"ids":[…]}]` for the imported
/// event.
///
/// `strfry import` writes straight to LMDB, so a green import proves the
/// bytes are in the database and nothing more. This is the wire-level
/// precondition Alice's engine actually depends on, and a `false` here is a
/// harness finding — never scored against the app.
const String kBacklogOnRelayMarker = '[b9] BACKLOG_ON_RELAY';

/// THE BACKLOG HEADLINE, with `ms=<n>`: the event imported while the device
/// was in airplane mode reached `memberLocationsProvider`, decrypted, with
/// Bob's backlog coordinates.
const String kBacklogReplayedMarker = '[b9] BACKLOG_REPLAYED';

/// The negative twin, with `reason=<live|expired|none|unserved>` — see the
/// class doc: `live` is a real defect (the relay still held the event while
/// receive was demonstrably back); `expired`, `none` and `unserved` are not,
/// and each names a DIFFERENT reason the proof did not run, because a verdict
/// that lumps them together sends the reader to the wrong half. `unserved` in
/// particular is not `expired`: an event the relay never served was not
/// removed by the TTL, and its finding is [kBacklogOnRelayMarker]'s.
const String kBacklogMissedMarker = '[b9] BACKLOG_MISSED';

/// Closes the capture. Printed unconditionally, before the final assertion,
/// so the shell's oracle always reads a complete window.
const String kSequenceCompleteMarker = '[b9] SEQUENCE_COMPLETE';

/// CAROL's POST-RESTORE coordinates — the liveness signal that says when
/// live receive came back.
///
/// Deliberately distinct from [bobFakeLatitude] / [bobFakeLongitude]: the
/// pre-outage entry is still in `memberLocationsProvider`, so a presence
/// check would be satisfied by stale state on an app whose receive path
/// never came back. Same obviously-synthetic shape as the sentinels in
/// `fake_location_service.dart`.
const double _postLatitude = 15.678901;

/// Longitude twin of [_postLatitude].
const double _postLongitude = 93.210987;

/// BOB's BACKLOG coordinates — carried by exactly one event in the whole
/// run: the kind-445 encrypted during the blackout and imported into strfry
/// by the shell while the device was still in airplane mode.
///
/// Nothing on the device ever publishes these, so surfacing them can only
/// mean the imported event was delivered and decrypted. Distinct from BOTH
/// Bob's baseline and Carol's post-restore sentinels, since all three are
/// live in `memberLocationsProvider` at once.
const double _backlogLatitude = 27.135791;

/// Longitude twin of [_backlogLatitude].
const double _backlogLongitude = 61.472583;

/// Where the staged backlog event is written for the shell to `adb exec-out
/// run-as … cat`.
///
/// Under the app's private data dir rather than external storage: the lane's
/// APK is a debug build, so `run-as` reaches it with no permission and no
/// `adb root`, and nothing outside the app can read or tamper with it.
const String _backlogFileName = 'b9_backlog_event.json';

/// Coordinate comparison tolerance. The wire carries `f64` through MLS and
/// JSON, so an exact `==` would be brittle; 1e-6 is far tighter than the gap
/// between the baseline and post-outage sentinels.
const double _coordEpsilon = 1e-6;

/// How long the baseline peer location may take to arrive over the live
/// engine before the lane calls the session dead.
///
/// Generous relative to the sub-second delivery the M11 scenarios measure:
/// this runs on a cold, memory-constrained CI emulator, and a slow baseline
/// is still a usable baseline while a premature failure destroys the run.
const Duration _baselineReceiveTimeout = Duration(seconds: 75);

/// How long to wait for the shell's network drop to become observable from
/// inside the app process.
const Duration _outageObserveTimeout = Duration(seconds: 120);

/// How long to wait for the shell's restore to become observable.
const Duration _restoreObserveTimeout = Duration(seconds: 120);

/// How long the outage is held once observed.
///
/// Long enough that the relay pool has certainly failed at least one
/// reconnect attempt (`DEFAULT_RETRY_INTERVAL` 10 s) and that a `PING_INTERVAL`
/// (55 s) has elapsed, so the socket is declared dead by the pool's own
/// liveness path even in the case where the OS did not tear the socket down.
/// Kept short enough that at most ONE `MapShell` heal tick (90–150 s) can be
/// burned inside it, bounding the doubled-backoff worst case
/// [_recoveryBudget] has to cover.
const Duration _outageHold = Duration(seconds: 75);

/// How long live receive gets to come back after connectivity returns.
///
/// Sized to the SLOWEST recovery mechanism, not the fastest — see the class
/// doc. Worst case is a `MapShell` heal tick burned during the outage
/// (marking one consecutive failure) followed by its doubled successor at up
/// to 2 × 150 s = 300 s, plus the engine restart and a relay round trip.
const Duration _recoveryBudget = Duration(seconds: 330);

/// Spacing between Carol's post-restore re-publishes.
///
/// Comfortably inside the fixed 228 s kind-445 NIP-40 expiration, so there
/// is always an unexpired event on the relay for a late reconnect to find.
/// The BACKLOG event gets no such treatment on purpose — a re-publish would
/// be a fresh event created after the blackout, i.e. not backlog at all.
const Duration _republishSpacing = Duration(seconds: 45);

/// How often the relay is asked whether it still holds the backlog event.
///
/// Only runs while the answer is still `true`: strfry's expiration cron
/// deletes and never re-adds, so the first `false` is final and ends the
/// polling. The last `true` is the instant the backlog verdict is measured
/// against (class doc).
const Duration _backlogRelayProbeSpacing = Duration(seconds: 10);

/// Bound on one `{"ids":[…]}` query for the backlog event.
///
/// The relay is on the emulator's host loopback, so a hit answers in
/// milliseconds; this bound is only ever paid in full on the single query
/// that finds the event already GC'd.
const Duration _backlogQueryTimeout = Duration(seconds: 3);

/// How long a single relay reachability probe may take before it counts as
/// unreachable. Short: with no route the connect fails immediately, and this
/// bound only covers the pathological case where it neither connects nor
/// errors.
const Duration _probeTimeout = Duration(seconds: 6);

/// Opens and immediately closes a WebSocket to the hermetic relay from
/// INSIDE the app process, returning whether it succeeded.
///
/// This is the lane's outage oracle. It runs in the process under test and
/// over the exact transport the live-sync engine uses, so it cannot report
/// an outage the app is not experiencing, and it validates itself: the same
/// probe must succeed before the drop and after the restore, so a probe that
/// had rotted into always-failing could never satisfy the sequence.
Future<bool> _relayReachable() async {
  TestRelay? probe;
  try {
    probe = await TestRelay.connect().timeout(_probeTimeout);
    return true;
  } on Object catch (_) {
    return false;
  } finally {
    if (probe != null) {
      try {
        await probe.dispose();
      } on Object catch (_) {
        // Best-effort: the probe's only job was to answer reachable/not.
      }
    }
  }
}

/// Whether the RUNNING relay still serves [eventId] over a real
/// subscription.
///
/// A failed query answers `false`. That is the safe direction for the IN-LOOP
/// caller, where the value only ever widens the excuse for a missing backlog
/// event: a flaky query there ends the polling early, which can turn a
/// `reason=live` defect into an unproven `reason=expired`, never the reverse.
///
/// It is NOT the safe direction for the one-shot [kBacklogOnRelayMarker]
/// caller, where `false` is a recorded HARNESS failure and reddens the lane.
/// That call is made on a socket whose handshake has just completed, against a
/// hermetic strfry on the emulator's host loopback answering an `ids` lookup
/// out of LMDB, so [_backlogQueryTimeout] is orders of magnitude clear of it —
/// but if this lane ever reports `served=false` on a run whose host-side
/// import logged `postscan=1`, suspect this bound before suspecting the relay.
Future<bool> _relayHolds(TestRelay relay, String eventId) async {
  try {
    final events = await relay.collectN(
      count: 1,
      filter: <String, dynamic>{
        'ids': <String>[eventId],
      },
      timeout: _backlogQueryTimeout,
    );
    return events.isNotEmpty;
  } on Object catch (_) {
    return false;
  }
}

/// Pumps real frames while polling an asynchronous [condition], returning
/// `true` when it held and `false` on timeout.
///
/// Never throws: this target must reach its markers in every outcome (see
/// the class doc), so a timeout is a value, not an exception. Frames are
/// pumped rather than merely awaited because the state under observation
/// (`memberLocationsProvider`) is refreshed by provider invalidations the
/// live-sync router raises, and `MapShell` only rebuilds while a pump is in
/// flight under `LiveTestWidgetsFlutterBinding`.
Future<bool> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required Duration timeout,
  Duration probeSpacing = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    final until = DateTime.now().add(probeSpacing);
    while (DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }
  return condition();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B9: a network drop mid-session must not silently end live location '
    'receive — a peer event that reached the relay DURING the partition, and '
    'one published after it, are both decrypted',
    (tester) async {
      installThrowTimeErrorLogging();
      // The shell drops the network with Android shell commands
      // (`cmd connectivity airplane-mode`), and the recovery paths under
      // test are reached through the Android build. iOS connectivity has no
      // equivalent simctl lever and is out of scope for this item.
      if (!Platform.isAndroid) {
        markTestSkipped(
          'b9_network_reconnect_test drives the Android '
          '`cmd connectivity airplane-mode` toggle; skipped on non-Android '
          'runtimes.',
        );
        return;
      }

      // Verdicts collected across the sequence and asserted ONCE at the end,
      // so a failure never strands the shell mid-toggle (see class doc).
      final failures = <String>[];

      if (!liveSyncEnabled) {
        // Not a skip: the lane's workflow sets HAVEN_LIVE_SYNC=true, so an
        // APK built without it is a wiring defect that must be loud. The
        // 30 s poll path is a different receive mechanism with a different
        // recovery story, and scoring it here would report a result for a
        // subsystem this lane does not name.
        failures.add(
          'this APK was built with liveSyncEnabled=false, so the persistent '
          'relay-subscription engine whose reconnect this lane exists to '
          'prove was never started. Check HAVEN_LIVE_SYNC in '
          '.github/workflows/e2e-network-reconnect.yml',
        );
      }

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay.
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Alice under the PRODUCTION secure-storage key, onboarding skipped.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            onboardingControllerProvider.overrideWith(
              (ref) => OnboardingController(
                OnboardingFlags(introSeen: introSeen, completed: completed),
              ),
            ),
            // The RECEIVE path is this lane's subject, so Alice's own
            // position source is deliberately faked: a real GPS dependency
            // would add `adb emu geo fix` re-issue loops and a verified
            // permission gate to the shell for a signal this lane never
            // reads. B3 owns the real-GPS proof.
            locationServiceProvider.overrideWithValue(
              FakeLocationService(
                latitude: aliceFakeLatitude,
                longitude: aliceFakeLongitude,
              ),
            ),
          ],
          child: const HavenApp(),
        ),
      );
      // pumpUntilFound, never pumpAndSettle: MapShell's periodic timers (the
      // heal backstop among them) keep the frame queue non-empty forever.
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        description: 'MapShell after pumpWidget',
      );

      // The app's OWN container — never a drive-owned second one, or the
      // engine read here would not be the one the UI is running.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      await container.read(identityProvider.future);
      expect(
        container.read(identityProvider).valueOrNull,
        isNotNull,
        reason: 'identityProvider resolved to null after '
            'preSeedIdentityAndSkipOnboarding — MapShell gates its whole '
            'startup (including _startLiveSync) on it, so there would be no '
            'receive plane to disconnect.',
      );
      await container.read(keyPackagePublisherProvider.future);

      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b9] circleServiceProvider is not Nostr-backed in this run — the '
          'production receive path this target exercises was bypassed.',
        );
      }
      final manager = await circleService.getCircleManagerFfi();

      // TWO real second parties are REQUIRED here, unlike B6. The assertion
      // is a decrypted PEER location and Haven never surfaces its own
      // publishes through memberLocationsProvider — that is why Bob exists.
      // Carol exists because the cache holds ONE entry per sender: Bob's
      // backlog event and a post-restore event from Bob would overwrite each
      // other, and the newer one always wins (see the class doc).
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);
      final carol = await SyntheticUser.carol(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: carol.pubkeyHex);

      final relayManager = await RelayManagerFfi.newInstance();
      final CircleCreationResultFfi creation;
      try {
        final peerKps = <MemberKeyPackageFfi>[];
        for (final peer in <SyntheticUser>[bob, carol]) {
          final kp = await relayManager.fetchMemberKeypackage(
            pubkey: peer.pubkeyHex,
          );
          if (kp == null) {
            throw StateError(
              '[b9] fetchMemberKeypackage returned null for ${peer.label} — '
              'their KeyPackage was not found on the relay.',
            );
          }
          peerKps.add(kp);
        }
        creation = await withFreshSecret(
          () => container
              .read(identityNotifierProvider.notifier)
              .getSecretBytes(),
          // Publishes both gift-wrapped Welcomes and CONFIRMS the staged
          // create (Security Rule 13). Without the confirm the group stays
          // in MDK's PendingPublish, where every inbound kind-445 returns
          // `Buffered` — the baseline receive would time out and the lane
          // would report a reconnect defect that never happened.
          (aliceSecret) => createCircleConfirmed(
            manager: manager,
            relay: relay,
            identitySecretBytes: aliceSecret,
            members: peerKps,
            name: 'B9 Network Reconnect Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            // Synthetic peers advertise no inbox relays, so the admin's own
            // relay is the Welcome-delivery fallback (production admin flow).
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'b9',
          ),
        );
      } finally {
        await relayManager.shutdown();
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      final carolCircle = await carol.acceptInvitationViaRelay(relay: relay);

      // Mirror the UI's post-create provider mutation: refresh circlesProvider
      // (so LiveSyncResubscriber's listener re-anchors the engine onto the new
      // circle) and SELECT the circle, because memberLocationsProvider is
      // scoped to the selection and would otherwise never observe Bob at all.
      container.invalidate(circlesProvider);
      await container.read(circlesProvider.future);
      container.read(selectedCircleIdProvider.notifier).state =
          creation.circle.mlsGroupId.toList();

      // Give the debounced LiveSyncResubscriber time to re-anchor the engine
      // onto the new circle's `#h` before the baseline publish.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final engine = container.read(subscriptionServiceProvider);
      debugPrint(kArmedMarker);

      // ===================================================================
      // Phase 1 — baseline: live receive works before anything is broken.
      // ===================================================================
      // BOTH senders, and Carol is not along for the ride: the whole verdict
      // rests on her. She is the only signal that says WHEN live receive came
      // back, so a Carol-side fault (a Welcome that did not apply, a wrong
      // epoch) would surface as [kReceiveDeadMarker] — which this lane states
      // as a product defect in the strongest terms — with nothing in the
      // capture to contradict it. Proving her path here turns that
      // misattribution into an ordinary baseline failure.
      final baselineStart = DateTime.now();
      try {
        await bob.publishLocation(
          circle: bobCircle,
          latitude: bobFakeLatitude,
          longitude: bobFakeLongitude,
          relay: relay,
        );
      } on Object catch (e) {
        failures.add(
          "BOB's BASELINE location could not be published (${e.runtimeType}) "
          '— the lane never had a working session to disconnect',
        );
      }
      try {
        await carol.publishLocation(
          circle: carolCircle,
          latitude: carolFakeLatitude,
          longitude: carolFakeLongitude,
          relay: relay,
        );
      } on Object catch (e) {
        failures.add(
          "CAROL's BASELINE location could not be published "
          '(${e.runtimeType}) — she is the post-restore liveness signal the '
          'whole backlog verdict is measured against',
        );
      }

      var bobBaselineOk = false;
      var carolBaselineOk = false;
      await _pumpUntilAsync(
        tester,
        () async {
          bobBaselineOk = bobBaselineOk ||
              _hasCoords(
                container,
                senderPubkeyHex: bob.pubkeyHex,
                latitude: bobFakeLatitude,
                longitude: bobFakeLongitude,
              );
          carolBaselineOk = carolBaselineOk ||
              _hasCoords(
                container,
                senderPubkeyHex: carol.pubkeyHex,
                latitude: carolFakeLatitude,
                longitude: carolFakeLongitude,
              );
          return bobBaselineOk && carolBaselineOk;
        },
        timeout: _baselineReceiveTimeout,
      );
      if (bobBaselineOk && carolBaselineOk) {
        debugPrint(
          '$kBaselineReceivedMarker '
          'ms=${DateTime.now().difference(baselineStart).inMilliseconds}',
        );
      } else {
        debugPrint(kBaselineDeadMarker);
        // Named per sender: the two have different downstream consequences, so
        // "the baseline was dead" alone would not tell the next reader whether
        // the backlog carrier or the liveness signal was the broken one.
        final dead = <String>[
          if (!bobBaselineOk) "bob's (the backlog carrier)",
          if (!carolBaselineOk) "carol's (the post-restore liveness signal)",
        ].join(' and ');
        failures.add(
          '$dead BASELINE location never reached memberLocationsProvider '
          'within ${_baselineReceiveTimeout.inSeconds}s. Live receive was '
          'already broken BEFORE the network was touched, so nothing this '
          'lane observes afterwards can be attributed to the drop',
        );
      }

      final engineBaseline = engine.isRunning;
      debugPrint('$kEngineBaselineMarker running=$engineBaseline');
      if (!engineBaseline) {
        failures.add(
          'the live-sync engine was NOT running before the drop, so there '
          'was no standing subscription to disconnect and the reconnect '
          'verdict below is vacuous',
        );
      }

      // Release the harness's own relay socket BEFORE the outage. TestRelay
      // has a bounded 3-attempt reconnect budget and latches `_closed` when
      // it is exhausted, so carrying one through a 75 s blackout would leave
      // a permanently dead handle for the post-outage publish — a harness
      // failure that would present as "the peer could not publish".
      try {
        await relay.dispose();
      } on Object catch (_) {
        // Best-effort; a fresh handle is opened after the restore.
      }

      // ===================================================================
      // Phase 2 — the shell drops the network.
      // ===================================================================
      debugPrint(kAwaitingDownMarker);
      final downStart = DateTime.now();
      final outageObserved = await _pumpUntilAsync(
        tester,
        () async => !await _relayReachable(),
        timeout: _outageObserveTimeout,
        probeSpacing: const Duration(seconds: 3),
      );
      if (outageObserved) {
        debugPrint(
          '$kOutageObservedMarker '
          'ms=${DateTime.now().difference(downStart).inMilliseconds}',
        );
      } else {
        debugPrint(kOutageNotObservedMarker);
        failures.add(
          'the relay stayed reachable from inside the app process for '
          '${_outageObserveTimeout.inSeconds}s after the shell was cued to '
          'drop the network. This is a HARNESS failure, not a product '
          'finding — the app was never disconnected, so anything observed '
          'afterwards says nothing about reconnect',
        );
      }

      // Hold the blackout. Frames keep being pumped so the app's own timers,
      // the engine supervisor and the heal backstop all run inside it — the
      // point is to let the app react to a real, sustained outage.
      if (outageObserved) {
        final holdUntil = DateTime.now().add(_outageHold);
        while (DateTime.now().isBefore(holdUntil)) {
          await tester.pump(const Duration(milliseconds: 250));
        }
      }
      debugPrint('$kEngineDuringOutageMarker running=${engine.isRunning}');

      // Stage the BACKLOG event WHILE STILL OFFLINE. Encryption is purely
      // local MLS work, so it needs no relay; the event is written to disk
      // and never published from this process, because the shell is about to
      // put it on the relay from OUTSIDE the partition (class doc).
      //
      // Staged as late as possible inside the blackout: the wire TTL is a
      // fixed `created_at + 228 s`, and every second spent here is a second
      // the app's recovery does not get.
      String? backlogEventId;
      try {
        final encrypted = await bob.user.circleManager.encryptLocation(
          mlsGroupId: bobCircle.circle.mlsGroupId,
          senderPubkeyHex: bob.pubkeyHex,
          latitude: _backlogLatitude,
          longitude: _backlogLongitude,
          updateIntervalSecs: BigInt.from(198),
        );
        final decoded = jsonDecode(encrypted.eventJson);
        final id = decoded is Map<String, dynamic>
            ? decoded['id'] as String?
            : null;
        if (id == null) {
          throw StateError('the staged kind-445 carries no id');
        }
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$_backlogFileName');
        // flush: true — the shell reads this from another process seconds
        // later, and a buffered write would export a truncated event.
        await file.writeAsString(encrypted.eventJson, flush: true);
        backlogEventId = id;
        // Re-probe rather than reuse the earlier reading: the shell imports
        // this event on the grounds that the app could not have received it
        // live, and the grounds are re-established at the moment the claim
        // is made.
        final stillOffline = !await _relayReachable();
        debugPrint(
          '$kBacklogStagedMarker offline=$stillOffline path=${file.path}',
        );
        if (!stillOffline) {
          failures.add(
            'the relay became reachable again from inside the app process '
            'while the backlog event was being staged, so the event the '
            'shell is about to import was NOT out of reach of this device. '
            'HARNESS failure — the backlog proof has no partition behind it',
          );
        }
      } on Object catch (e) {
        // Security Rule 8: runtimeType only.
        debugPrint('$kBacklogStageFailedMarker reason=${e.runtimeType}');
        failures.add(
          'the backlog kind-445 could not be staged (${e.runtimeType}), so '
          'the shell had nothing to import and the backlog-replay proof '
          'could not run at all',
        );
      }

      // ===================================================================
      // Phase 3 — the shell restores the network.
      // ===================================================================
      debugPrint(kAwaitingUpMarker);
      final upStart = DateTime.now();
      final restored = await _pumpUntilAsync(
        tester,
        _relayReachable,
        timeout: _restoreObserveTimeout,
        probeSpacing: const Duration(seconds: 3),
      );
      if (restored) {
        debugPrint(
          '$kNetworkRestoredMarker '
          'ms=${DateTime.now().difference(upStart).inMilliseconds}',
        );
      } else {
        debugPrint(kNetworkNotRestoredMarker);
        failures.add(
          'the relay never became reachable again within '
          '${_restoreObserveTimeout.inSeconds}s of the shell being cued to '
          'restore the network. HARNESS failure — recovery could not be '
          'tested',
        );
      }

      if (restored) {
        final recoveryStart = DateTime.now();
        final backlogId = backlogEventId;
        TestRelay? postRelay;
        var republishes = 0;
        var published = false;

        // The relay's own view of the imported backlog event. `lastPresent`
        // is the latest instant the relay was OBSERVED holding it; presence
        // is monotone (strfry's expiration cron deletes and never re-adds),
        // so it is an instant at which the event demonstrably WAS there.
        var backlogOnRelay = false;
        DateTime? backlogLastPresent;

        try {
          final freshRelay = await TestRelay.connect();
          postRelay = freshRelay;

          // Wire-level precondition, checked BEFORE anything is asked of the
          // app: `strfry import` writes to LMDB, and the thing Alice's
          // engine depends on is the RUNNING relay answering a REQ.
          if (backlogId != null) {
            backlogOnRelay = await _relayHolds(freshRelay, backlogId);
            if (backlogOnRelay) backlogLastPresent = DateTime.now();
            debugPrint('$kBacklogOnRelayMarker served=$backlogOnRelay');
            if (!backlogOnRelay) {
              failures.add(
                'the relay did not serve the backlog event over a real '
                'subscription right after connectivity returned. HARNESS '
                'failure — either the host-side `strfry import` never '
                'reached the running relay, or the event was GC-ed before '
                'the restore. Nothing below is a statement about the app',
              );
            }
          }

          // Carol, not Bob: her entry cannot mask Bob's backlog entry.
          await carol.publishLocation(
            circle: carolCircle,
            latitude: _postLatitude,
            longitude: _postLongitude,
            relay: freshRelay,
          );
          published = true;
          debugPrint(kPeerPublishedMarker);
        } on Object catch (e) {
          debugPrint('$kPeerPublishFailedMarker reason=${e.runtimeType}');
          failures.add(
            'the peer could not publish a location after connectivity '
            'returned (${e.runtimeType}) — the receive verdict below cannot '
            'be read, because nothing was sent to receive',
          );
        }

        if (published && postRelay != null) {
          final liveRelay = postRelay;
          DateTime? recoveredAt;
          DateTime? backlogSeenAt;
          var backlogStillOnRelay = backlogOnRelay;
          var lastRelayProbe = DateTime.now();
          var lastRepublish = DateTime.now();

          await _pumpUntilAsync(
            tester,
            () async {
              if (backlogSeenAt == null &&
                  backlogId != null &&
                  _hasCoords(
                    container,
                    senderPubkeyHex: bob.pubkeyHex,
                    latitude: _backlogLatitude,
                    longitude: _backlogLongitude,
                  )) {
                backlogSeenAt = DateTime.now();
              }
              if (recoveredAt == null &&
                  _hasCoords(
                    container,
                    senderPubkeyHex: carol.pubkeyHex,
                    latitude: _postLatitude,
                    longitude: _postLongitude,
                  )) {
                recoveredAt = DateTime.now();
              }

              // Track how long the relay keeps the backlog event. Stops at
              // the first `false` — the answer cannot go back to `true`.
              if (backlogStillOnRelay &&
                  backlogId != null &&
                  DateTime.now().difference(lastRelayProbe) >=
                      _backlogRelayProbeSpacing) {
                lastRelayProbe = DateTime.now();
                if (await _relayHolds(liveRelay, backlogId)) {
                  backlogLastPresent = DateTime.now();
                } else {
                  backlogStillOnRelay = false;
                }
              }

              // Done once BOTH verdicts are decided: live receive is back,
              // and the backlog either arrived or can no longer arrive.
              if (recoveredAt != null &&
                  (backlogSeenAt != null || !backlogStillOnRelay)) {
                return true;
              }

              // Keep an unexpired CAROL event on the relay: the kind-445
              // NIP-40 expiration is a fixed created_at + 228 s and strfry
              // prunes on a cron, so a slow (but correct) heal-path recovery
              // would otherwise arrive to an empty relay and be scored as a
              // product defect.
              if (recoveredAt == null &&
                  DateTime.now().difference(lastRepublish) >=
                      _republishSpacing) {
                lastRepublish = DateTime.now();
                republishes++;
                try {
                  await carol.publishLocation(
                    circle: carolCircle,
                    latitude: _postLatitude,
                    longitude: _postLongitude,
                    relay: liveRelay,
                  );
                } on Object catch (e) {
                  debugPrint('[b9] re-publish failed: ${e.runtimeType}');
                }
              }
              return false;
            },
            timeout: _recoveryBudget,
            probeSpacing: const Duration(seconds: 3),
          );

          final recovered = recoveredAt;
          if (recovered != null) {
            debugPrint(
              '$kReceiveResumedMarker '
              'ms=${recovered.difference(recoveryStart).inMilliseconds} '
              'republishes=$republishes',
            );
          } else {
            debugPrint('$kReceiveDeadMarker republishes=$republishes');
            failures.add(
              'live location receive did NOT recover within '
              '${_recoveryBudget.inSeconds}s of connectivity returning. The '
              "peer's post-outage location was published and OK-acked by the "
              'relay, and Alice never decrypted it — a network drop '
              'permanently ended live receive for the session. The budget '
              'covers all three recovery paths: the relay pool reconnect '
              '(<=60s), the M8 subscription-health tick, and '
              "MapShell's 90-150s self-heal with one doubled retry",
            );
          }

          // THE BACKLOG VERDICT — skipped entirely when nothing was staged,
          // because BACKLOG_STAGE_FAILED already carries that finding and a
          // second one would blame the app for a harness fault. See the
          // class doc for why `expired` is not scored against the app and
          // why the discrimination is made by asking the relay rather than
          // by comparing two clocks.
          final seen = backlogSeenAt;
          final lastPresent = backlogLastPresent;
          if (backlogId == null) {
            debugPrint('[b9] backlog verdict skipped: nothing was staged');
          } else if (seen != null) {
            debugPrint(
              '$kBacklogReplayedMarker '
              'ms=${seen.difference(recoveryStart).inMilliseconds}',
            );
          } else if (recovered == null) {
            debugPrint('$kBacklogMissedMarker reason=none');
          } else if (lastPresent == null) {
            // The RUNNING relay never served the event even once, so the
            // 228 s TTL is not what took it away and `expired` would send the
            // next reader to the wrong half of the problem. The finding is
            // already recorded at the [kBacklogOnRelayMarker] check above;
            // this only stops the verdict borrowing an excuse that does not
            // apply to it.
            debugPrint('$kBacklogMissedMarker reason=unserved');
          } else if (!recovered.isAfter(lastPresent)) {
            debugPrint('$kBacklogMissedMarker reason=live');
            failures.add(
              'the backlog kind-445 — imported into the relay while this '
              'device was in airplane mode — was NEVER decrypted, even '
              "though the relay was still serving it when Carol's "
              'post-restore location arrived. Live receive was demonstrably '
              'back while the event was demonstrably there, so the '
              'reconnect replayed the gap and the app dropped what came '
              'back. This is the backlog-delivery defect the lane exists to '
              'find, NOT a timing artefact',
            );
          } else {
            debugPrint('$kBacklogMissedMarker reason=expired');
          }
        }

        debugPrint('$kEngineRecoveredMarker running=${engine.isRunning}');

        if (postRelay != null) {
          try {
            await postRelay.dispose();
          } on Object catch (_) {
            // Best-effort teardown.
          }
        }
      }

      for (final peer in <SyntheticUser>[bob, carol]) {
        try {
          await peer.dispose();
        } on Object catch (_) {
          // Best-effort teardown; does not affect the verdict.
        }
      }

      debugPrint(kSequenceCompleteMarker);

      // Single terminal assertion. Everything above is already in logcat, so
      // the shell's oracle has a complete window regardless of what happens
      // here.
      expect(
        failures,
        isEmpty,
        reason: 'B9 findings:\n - ${failures.join('\n - ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 16)),
  );
}

/// Whether `memberLocationsProvider` currently holds an entry for
/// [senderPubkeyHex] at [latitude] / [longitude] (within [_coordEpsilon]).
///
/// The COORDINATES are the check, never mere presence: the peer's pre-outage
/// entry survives the blackout, so a presence test would be satisfied by
/// stale state on an app whose receive path never came back.
bool _hasCoords(
  ProviderContainer container, {
  required String senderPubkeyHex,
  required double latitude,
  required double longitude,
}) {
  final locs = container.read(memberLocationsProvider).valueOrNull;
  if (locs == null) return false;
  final sender = senderPubkeyHex.toLowerCase();
  for (final l in locs) {
    if (l.pubkey.toLowerCase() != sender) continue;
    if ((l.latitude - latitude).abs() < _coordEpsilon &&
        (l.longitude - longitude).abs() < _coordEpsilon) {
      return true;
    }
  }
  return false;
}
