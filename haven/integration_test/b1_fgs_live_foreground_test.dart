/// B1 drive target — arms the app, delivers a REAL pause, and HOLDS the
/// live foreground MLS session open long enough for the Android foreground
/// service (FGS) to publish — the runtime proof of P0-1
/// (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B1:
/// "FGS-with-live-foreground (catches P0-1)").
///
/// ## What P0-1 is
///
/// `MapShell._onPaused()` (`haven/lib/src/pages/map_shell.dart:699`) hands
/// location publishing off to the FGS when the app is backgrounded. The FGS
/// isolate's `onStart` method (line 140 of
/// `haven/lib/src/services/background_location_task.dart`) then calls
/// `CircleManagerFfi.newInstance` — but the
/// FOREGROUND `NostrCircleService` (`circleServiceProvider`, a plain,
/// never-torn-down `Provider`) still holds that database's Rule-14
/// `LiveSessionGuard`. Both isolates share ONE OS process (see
/// "Process-sharing", below), so there is exactly one Rust `LIVE_SESSIONS`
/// registry and the FGS's `acquire` fails closed. The error is swallowed at
/// `background_location_task.dart:245-247`
/// (`debugPrint('[BackgroundTask] onStart FAILED: ...')`), `_circleManager`
/// stays `null`, and every `_publishCycle` returns immediately at
/// `background_location_task.dart:360`. `onStart` runs once; there is no
/// retry.
///
/// ## The framework unmounts on success — why the WHOLE proof must run
/// inside this function (SEV-1 finding; read before touching this file)
///
/// An earlier version of this target left `MapShell` mounted when the
/// `testWidgets` body returned, and relied on the shell (`tooling/e2e/ci/
/// run-b1-fgs-publish.sh`) to keep the app alive (`--keep-app-running`) and
/// press a REAL `adb shell input keyevent HOME` afterward, so that a REAL
/// `AppLifecycleState.paused` would reach `MapShell`'s still-registered
/// `WidgetsBindingObserver` and run the genuine `_onPaused()`. That premise
/// is FALSE, and adversarial review caught it:
///
/// `flutter_test/lib/src/binding.dart`'s `TestWidgetsFlutterBinding.
/// _runTest` — shared by every binding, including
/// `LiveTestWidgetsFlutterBinding` (`binding.dart:2751`,
/// `runTest` → `_runTest`) and `IntegrationTestWidgetsFlutterBinding`
/// (`integration_test/lib/integration_test.dart:227`, `runTest` → `super.
/// runTest` with NO override of the cleanup) — runs, on every test that did
/// NOT throw:
///
/// ```dart
/// runApp(Container(key: UniqueKey(), child: _postTestMessage)); // Unmount
/// await pump();
/// ```
///
/// That happens the MOMENT this function returns successfully — seconds
/// after an "ARMED" line would have printed, long before any external
/// process could ever press HOME. `runApp` there replaces the ENTIRE tree,
/// which disposes the `ProviderScope` this drive pumped and, with it, the
/// `ProviderContainer` `circleServiceProvider` lives in. That fires
/// `backgroundServiceLifecycleProvider`'s `ref.onDispose(() {
/// unawaited(fns.stop()); })` (`background_location_provider.dart:278-280`)
/// — **stopping the FGS itself** — and `_MapShellState.dispose()` calls
/// `WidgetsBinding.instance.removeObserver(this)`
/// (`map_shell.dart:1108`), so a HOME press arriving afterward has no
/// observer left to deliver `paused` to: `_onPaused()` never runs. Worse,
/// once the UI is torn down the foreground heartbeat stops too, so
/// `kForegroundActiveAtMsKey` goes stale after `2 *
/// kBackgroundRepeatInterval` (144 s) and a cold `START_STICKY` FGS
/// restart can publish successfully from a FRESH process with NO
/// foreground guard held at all — the lane would go GREEN while P0-1 is
/// genuinely still present, because the Rule-14 contention was never
/// exercised.
///
/// **The fix**: do the entire proof — arm, pause, hold, and let the FGS
/// actually run its cycles — inside this ONE `testWidgets` body, before it
/// is ever allowed to return. `tester.binding.
/// handleAppLifecycleStateChanged(AppLifecycleState.paused)` is Flutter's
/// OWN public dispatch entry point (`flutter/lib/src/widgets/binding.dart:
/// 1100`, an `@override` of `SchedulerBinding`'s hook that iterates
/// `_observers` and calls `didChangeAppLifecycleState(state)` on each) — so
/// calling it runs `MapShell`'s genuine, UNMODIFIED `_onPaused()`, not a
/// hand-written stand-in. This function then HOLDS — polling, never a
/// blind sleep — for [_postPauseHoldDuration] so the FGS gets at least two
/// full `kBackgroundRepeatInterval` (72 s) ticks to publish WHILE the tree
/// is still mounted and `aliceManager` (the SAME `CircleManagerFfi`
/// `circleServiceProvider` opened) is still open — i.e. while the Rule-14
/// contention this whole lane exists to observe is genuinely, continuously
/// live. Only once that hold completes does this function return; whatever
/// the FGS did or didn't publish during it has already reached logcat by
/// then. The shell no longer needs to synthesize the foreground/background
/// transition itself — this drive already does, from the inside, where it
/// can be held open for exactly as long as the proof requires.
///
/// ## What "ARMED" means, and what still does NOT get proven from Dart
///
/// This drive still cannot observe the FGS's own log lines (no logcat
/// access from inside the app process) — the shell remains the assertion
/// authority for `[BackgroundTask] onStart` / `onStart FAILED` /
/// `Published to N/M`. What this drive DOES do, all inside one continuous,
/// uninterrupted run:
///
///   1. persists a REAL identity (Alice) under the production
///      secure-storage key, loads it, and confirms `identityProvider`
///      resolved non-null;
///   2. explicitly opens the FOREGROUND `CircleManagerFfi` via
///      `circleServiceProvider` and asserts it succeeded — BEFORE waiting
///      for the FGS at all (see "Forcing the DB-open race", below);
///   3. sets `kBackgroundSharingKey = true` in REAL SharedPreferences and
///      confirms `backgroundSharingProvider` observed it;
///   4. confirms Android reports the FGS SERVICE COMPONENT running (a
///      necessary, not sufficient, precondition — see the reworded
///      checkpoint-A4 description in the body);
///   5. creates a REAL 2-member circle (Alice + a synthetic Bob) that Bob
///      accepts, through the SAME manager from step 2, so
///      `filterPublishEligibleCircles` sees a genuinely `accepted`,
///      non-orphaned, non-blocked circle;
///   6. delivers a REAL `AppLifecycleState.paused` and CONFIRMS (via a
///      bounded poll of real SharedPreferences) that `_onPaused()` ran to
///      completion, not merely that the event was dispatched;
///   7. HOLDS the mounted tree + open manager for [_postPauseHoldDuration]
///      so the FGS's own publish cycles happen while the contention is
///      real, before returning and letting the framework's own
///      `runApp(Container(...))` unmount everything.
///
/// ## Process-sharing (verified, not assumed)
///
/// `haven/android/app/src/main/AndroidManifest.xml`'s
/// `<service android:name="com.pravera.flutter_foreground_task.service.
/// ForegroundService" .../>` declaration carries NO `android:process`
/// attribute, so the FGS isolate's background `FlutterEngine` runs in the
/// app's DEFAULT process — the SAME OS process as this drive. Every piece
/// of process-global Rust state this target relies on is therefore shared
/// with the FGS:
///
///   * `KEYRING_INIT: Mutex<Option<()>>` (`haven/rust_builder/src/api.rs:622`)
///     — the keyring backend, first-installed-wins;
///   * `LIVE_SESSIONS: OnceLock<Mutex<HashSet<PathBuf>>>`
///     (`haven-core/src/nostr/mls/storage.rs:50`) — the Rule-14 registry
///     that IS the mechanism under test;
///   * `ALLOW_WS_LOOPBACK_FOR_TEST: OnceLock<()>`
///     (`haven-core/src/relay/manager.rs:42`) and
///     `DEFAULT_RELAYS_OVERRIDE: OnceLock<Vec<String>>`
///     (`haven-core/src/circle/types.rs:44`) — the hermetic-relay overrides
///     this harness installs.
///
/// This is what makes SETUP here simpler than `m7_worker_setup_test.dart`'s:
/// that target's WorkManager worker is a genuinely SEPARATE OS process
/// (`am kill` + a cold JobScheduler wake), so it has to win the
/// `KEYRING_INIT` race with the REAL platform keyring BEFORE
/// `ScenarioHarness.bootstrap()`'s in-memory install. The FGS isolate here
/// never leaves the process, so the ordinary `useInMemoryKeyringForTest()`
/// install inside `ScenarioHarness.bootstrap()` is sufficient.
///
/// ## Why the production `circleServiceProvider` manager, never a
/// hand-rolled `CircleManagerFfi`
///
/// `LiveSessionGuard::acquire` keys on the CANONICAL `session.sqlite` PATH
/// (`haven-core/src/nostr/mls/storage.rs:65`, `canonical_session_key`). The
/// FGS isolate ALWAYS resolves that path via the PRODUCTION
/// `PathProviderDataDirectory().getDataDirectory()`
/// (`background_location_task.dart:159`). If this drive instead built its
/// own `CircleManagerFfi` — e.g. via a `TestUser`-style temp directory —
/// the two managers would open DIFFERENT canonical paths and NEVER
/// collide, and this whole lane would report a false PASS while the real
/// production collision went completely unexercised. The fix: mount
/// `HavenApp` for real, reach into its OWN `ProviderContainer`
/// (`ProviderScope.containerOf` — the same pattern `diagnostics.dart` and
/// `e2e_combined.dart` use), and drive circle creation through
/// `container.read(circleServiceProvider).getCircleManagerFfi()` — the
/// EXACT instance `MapShell`'s own providers already share.
///
/// Bob, by contrast, is a genuinely separate `TestUser` at his OWN temp
/// directory (via `SyntheticUser.bob`) — a DIFFERENT canonical path, so his
/// session never contends with Alice's.
///
/// ## Forcing the DB-open race (F8)
///
/// `MapShell.build()` does not itself watch `circlesProvider`; the
/// foreground's first `CircleManagerFfi` open otherwise happens lazily,
/// incidentally, behind whichever of `_runStartupTasks`'s several provider
/// reads gets there first. If the FGS ever won that open race instead, this
/// drive's LATER circle-creation call would throw "an MLS session is
/// already open on this database" — and report the confusing, inverted
/// failure "the app was never armed", rather than the true story (the FGS
/// opened first, so the very thing B1 exists to catch didn't get a chance
/// to happen). This target therefore opens `aliceManager` EXPLICITLY, as
/// checkpoint A2 — immediately after identity resolves and BEFORE this
/// drive does anything that could let `backgroundSharingProvider` observe
/// `true` (that observation only happens starting at checkpoint A3's
/// `pumpUntilCondition`, and starting the FGS requires
/// `backgroundServiceLifecycleProvider` to see that same `true` — which, in
/// turn, requires `MapShell.build()` to have re-run with it, which this
/// drive does not yet allow to happen at checkpoint A2). This does not
/// GUARANTEE the foreground wins by construction — Dart's cooperative
/// concurrency means the exact interleaving is never fully controllable
/// from outside the isolate — but it maximizes the foreground's head start
/// and, just as importantly, wraps the open in a `try`/`catch` that turns
/// any loss of that race into an immediately-surfaced, clearly-attributed
/// failure instead of a confusing one three steps later.
///
/// ## Real GPS, not `FakeLocationService`
///
/// The FGS isolate constructs its OWN `GeolocatorLocationService`
/// (`background_location_task.dart:209`) — any `locationServiceProvider`
/// override this drive's `ProviderScope` installs for the FOREGROUND widget
/// tree does NOT reach it. This target therefore does not override
/// `locationServiceProvider` at all: the foreground ALSO uses the real
/// `GeolocatorLocationService`, so there is only one location code path in
/// play, and the emulator GPS fix the shell seeds via `adb emu geo fix` is
/// what both isolates read.
///
/// ## Markers
///
/// Owned by `background_location_task.dart` (unmodified by this change;
/// this file emits none of them itself):
///
///   * `[BackgroundTask] onStart (starter=`  — PRESENT (the FGS isolate
///     actually booted).
///   * `[BackgroundTask] onStart FAILED`     — ABSENT (the Rule-14 acquire
///     succeeded).
///   * `[BackgroundTask] Published to `      — the `N` in `Published to
///     N/M due circle(s)` PARSED and required `>= 1`.
///
/// Owned by THIS file — change here AND in the shell together, or the lane
/// silently stops finding them:
///
///   * [kPauseDeliveredMarker] (`[b1] PAUSE_DELIVERED`, printed with a
///     trailing `pid=<pid>`) — the instant this drive dispatches the REAL
///     pause. Everything the shell attributes to "after the handoff"
///     should be scoped to start here, not to a HOME press this drive no
///     longer waits on.
///   * [kHandoffConfirmedMarker] (`[b1] HANDOFF_CONFIRMED`) — printed once
///     this drive has ITSELF confirmed, by re-reading real
///     SharedPreferences, that `_onPaused()` ran to completion (not merely
///     that the pause was dispatched). Strictly later and tighter than
///     [kPauseDeliveredMarker] if the shell wants the narrowest possible
///     window.
library;

import 'dart:io' show Platform, pid;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/constants/location.dart'
    show kBackgroundSharingKey, kForegroundActiveAtMsKey;
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/background_location_provider.dart'
    show backgroundSharingProvider;
import 'package:haven/src/providers/circles_provider.dart'
    show circlesProvider;
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/onboarding_provider.dart'
    show
        OnboardingController,
        OnboardingFlags,
        kOnboardingCompletedKey,
        kOnboardingIntroSeenKey,
        onboardingControllerProvider;
import 'package:haven/src/providers/service_providers.dart'
    show circleServiceProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/background_location_manager.dart'
    show BackgroundLocationManager;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/pump_helpers.dart'
    show pumpUntilCondition, pumpUntilFound, waitUntilAsync;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed, bytesToHex;

/// Verbatim marker printed the instant this drive dispatches a REAL
/// `AppLifecycleState.paused` to every `WidgetsBindingObserver` — i.e. the
/// instant `MapShell`'s own, unmodified `_onPaused()` starts running. See
/// this file's "Markers" doc for how the shell should use it.
const String kPauseDeliveredMarker = '[b1] PAUSE_DELIVERED';

/// Verbatim marker printed once this drive has CONFIRMED — via a bounded
/// poll of REAL on-disk `SharedPreferences` — that `_onPaused()` ran to
/// completion: `kForegroundActiveAtMsKey` reads back `0`, the exact value
/// `_publishCycle`'s gate 3 checks before it will publish.
const String kHandoffConfirmedMarker = '[b1] HANDOFF_CONFIRMED';

/// How long this drive keeps `MapShell` mounted (and `aliceManager` open)
/// AFTER the confirmed handoff, so the FGS gets at least two full
/// `kBackgroundRepeatInterval` (72 s) ticks — the FGS's master polling
/// cadence, `haven/lib/src/constants/location.dart:98` — to run a publish
/// cycle before this function is allowed to return (and the framework's
/// own post-test teardown unmounts everything — see the class doc's "The
/// framework unmounts on success" section). 200 s covers 2 ticks (144 s)
/// plus generous GPS-fix / relay-round-trip / loaded-CI-emulator slack.
const Duration _postPauseHoldDuration = Duration(seconds: 200);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B1: hold a live foreground MLS session across a REAL pause and prove '
    'the FGS publishes with it',
    (tester) async {
      // This lane proves the Android foreground-service publish path;
      // `backgroundServiceLifecycleProvider` is a deliberate no-op on every
      // other platform (platformIsAndroidProvider), so running this
      // elsewhere would only prove that a no-op did nothing.
      if (!Platform.isAndroid) {
        markTestSkipped(
          'b1_fgs_live_foreground_test proves the Android foreground-service '
          'publish path; skipped on non-Android runtimes.',
        );
        return;
      }

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay
      // override. See the "Process-sharing" doc above for why the
      // in-memory keyring (unlike m7_worker_setup_test.dart) is sufficient
      // for THIS lane.
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // --- Alice = the production identity, persisted under the
      // PRODUCTION secure-storage key so the (same-process) FGS isolate
      // reads it back exactly as MapShell's own identityProvider does.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      // REAL on-disk SharedPreferences, written BEFORE HavenApp is pumped
      // so BackgroundSharingNotifier's first `_load()` observes it as
      // `true` (see background_location_provider.dart).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundSharingKey, true);

      // --- Mount the REAL app. onboardingControllerProvider must be
      // overridden explicitly here: its default factory yields
      // OnboardingFlags.none — production only pre-loads it from
      // SharedPreferences in main.dart's own bootstrap, which pumping
      // HavenApp directly (as every E2E drive does) bypasses.
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
          ],
          child: const HavenApp(),
        ),
      );
      // pumpUntilFound, not pumpAndSettle — MapShell's own periodic timers
      // (the foreground heartbeat, and under liveSyncEnabled the live-sync
      // engine's internals) keep the frame queue non-empty; pumpAndSettle
      // would hang. See pump_helpers.dart's library doc.
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        description: 'MapShell after pumpWidget',
      );

      // Reach into the SAME ProviderContainer MapShell itself reads from —
      // never a second, drive-owned container — so every provider read
      // below observes and shares exactly the state the mounted app is
      // running on.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      // --- Checkpoint A1: identity resolved.
      await container.read(identityProvider.future);
      expect(
        container.read(identityProvider).valueOrNull,
        isNotNull,
        reason: 'identityProvider resolved to null after '
            'preSeedIdentityAndSkipOnboarding — the FGS isolate would find '
            'nothing in secure storage either.',
      );

      // --- Checkpoint A2 (F8): explicitly open the FOREGROUND
      // CircleManagerFfi, as early as this drive structurally can — BEFORE
      // this drive does anything that could let backgroundSharingProvider
      // observe `true` (checkpoint A3, below) and thus before the FGS could
      // possibly be asked to start. See "Forcing the DB-open race" doc
      // above for why this ordering matters and what it does/doesn't
      // guarantee.
      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b1] circleServiceProvider is not Nostr-backed in this run — '
          'the production path this target exists to exercise was '
          'bypassed.',
        );
      }
      final CircleManagerFfi aliceManager;
      try {
        aliceManager = await circleService.getCircleManagerFfi();
      } on Object catch (e) {
        throw StateError(
          '[b1] the FOREGROUND circleServiceProvider could not open its '
          'CircleManagerFfi (${e.runtimeType}) at checkpoint A2 — either a '
          'genuine storage failure, or this drive lost the Rule-14 open '
          'race to some other session before the foreground guard this '
          'whole lane depends on could be established. Either way this is '
          'a harness-ordering failure, not evidence about P0-1.',
        );
      }
      debugPrint(
        '[b1] checkpoint A2: foreground CircleManagerFfi open '
        '(Rule-14 guard held).',
      );

      // --- Checkpoint A3: backgroundSharingProvider observed true. This
      // MUST pump real frames (pumpUntilCondition does) rather than merely
      // wait on a Future: `backgroundServiceLifecycleProvider`'s side
      // effect (starting the FGS) is read from inside MapShell.build(), so
      // MapShell needs to actually RE-RUN build() with the new value —
      // which, under IntegrationTestWidgetsFlutterBinding,
      // `LiveTestWidgetsFlutterBinding.handleBeginFrame` only does while a
      // pump is in flight. See pump_helpers.dart's `waitUntilAsync` doc for
      // the full reasoning; this is exactly the case that doc warns
      // `waitUntilAsync` alone would not reliably cover.
      await pumpUntilCondition(
        tester,
        () => container.read(backgroundSharingProvider),
        description: 'backgroundSharingProvider resolved true from the '
            'persisted kBackgroundSharingKey',
      );

      // --- Checkpoint A4: the FGS SERVICE COMPONENT is running. By this
      // point checkpoint A3 has already pumped MapShell.build() through at
      // least one rebuild with backgroundSharingProvider == true, so
      // backgroundServiceLifecycleProvider's own `unawaited(fns.start(...))`
      // call has already been ISSUED — what remains here is purely the
      // Android platform-channel round-trip completing, which needs no
      // further widget rebuild. `BackgroundLocationManager.isRunning` is
      // `FlutterForegroundTask.isRunningService`: it proves ONLY that
      // `startForegroundService` succeeded and the native Service object
      // exists — it does NOT prove the FGS's Dart isolate has run
      // `onStart` yet. That is what the shell's `[BackgroundTask] onStart`
      // logcat marker proves, not this check.
      await waitUntilAsync(
        () => BackgroundLocationManager.isRunning,
        description: 'Android reports the foreground SERVICE COMPONENT '
            'alive (proves only that BackgroundLocationManager.startService '
            'succeeded at the platform level — not that the FGS Dart '
            'isolate has run onStart yet)',
        timeout: const Duration(seconds: 45),
      );
      debugPrint('[b1] checkpoint A4: FGS service component running.');

      // --- Bob: an in-process SyntheticUser at his OWN temp data
      // directory (see the class doc above — a DIFFERENT canonical
      // session path than Alice's production one, so his session never
      // contends with hers).
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

      // --- Create the circle through the SAME manager opened at
      // checkpoint A2 — the EXACT CircleManagerFfi instance MapShell's own
      // providers already share.
      final relayManager = await RelayManagerFfi.newInstance();
      final CircleCreationResultFfi creation;
      try {
        final bobKp = await relayManager.fetchMemberKeypackage(
          pubkey: bob.pubkeyHex,
        );
        if (bobKp == null) {
          throw StateError(
            '[b1] fetchMemberKeypackage returned null for Bob — his '
            'KeyPackage was not found on the relay.',
          );
        }

        // `withFreshSecret` rather than a hand-rolled fetch/zero pair
        // (Security Rule 9): it owns the fetch → validate-32-bytes →
        // scrub-in-`finally` contract, and it is one of the two forms the
        // repo's planned Rule-9 lint recognises, so this site stays
        // compliant by construction instead of by inspection.
        creation = await withFreshSecret(
          () => container
              .read(identityNotifierProvider.notifier)
              .getSecretBytes(),
          // Publishes Bob's gift-wrapped Welcome and CONFIRMS the staged
          // create (Security Rule 13) — an unconfirmed create pins the
          // group in MDK's PendingPublish, where every inbound kind-445
          // (including the FGS's own publish) buffers forever. See
          // createCircleConfirmed's doc.
          (aliceSecret) => createCircleConfirmed(
            manager: aliceManager,
            relay: relay,
            identitySecretBytes: aliceSecret,
            members: <MemberKeyPackageFfi>[bobKp],
            name: 'B1 FGS Publish Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            // Bob (a SyntheticUser) advertises no inbox relays, so the
            // Welcome-delivery cascade needs the admin's own relay as a
            // fallback (mirrors the production admin flow).
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'b1',
          ),
        );
      } finally {
        await relayManager.shutdown();
      }

      if (!creation.welcomeEvents.any(
        (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
      )) {
        throw StateError('[b1] createCircle produced no gift-wrap for Bob.');
      }

      // Bob accepts (Welcome → MDK state) — a genuine second member, so
      // filterPublishEligibleCircles sees a real, non-trivial circle.
      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);

      // The app's own reactive state never learned about this circle — we
      // drove CircleManagerFfi directly rather than through
      // NostrCircleService.createCircle()'s higher-level API. Invalidate so
      // circlesProvider (and the live-sync resubscriber that listens to it)
      // reflect the same on-disk state the FGS's own independent DB read
      // will see. Not required by the assertions below — production
      // fidelity only.
      container.invalidate(circlesProvider);

      // --- Checkpoint B: the armed multi-member circle.
      expect(
        bobCircle.members.length,
        greaterThanOrEqualTo(2),
        reason: 'Bob must have joined the circle at the shared epoch.',
      );
      final visible = await aliceManager.getVisibleCircles();
      expect(
        visible.any(
          (c) =>
              bytesToHex(c.circle.nostrGroupId) ==
              bytesToHex(creation.circle.nostrGroupId),
        ),
        isTrue,
        reason: 'the created circle is not visible via the PRODUCTION '
            'CircleManagerFfi — the FGS reads from the SAME manager/DB and '
            'would see nothing eligible to publish to.',
      );
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);

      debugPrint(
        '[b1] ARMED: identity loaded, foreground Rule-14 guard held, FGS '
        'service running, 2-member circle accepted.',
      );

      // Best-effort teardown of SETUP-only helpers, done BEFORE the pause
      // (not after): neither Bob nor this drive's own relay probe socket is
      // touched by `_onPaused()` or by the FGS, so releasing them now (a)
      // avoids leaving their sockets/temp dirs open through the ~200 s hold
      // for no reason, and (b) — more importantly — keeps this drive from
      // generating ANY of its own relay traffic during the exact window the
      // shell is about to scope its network-layer corroboration to. Any
      // activity from a lingering probe subscription in that window would
      // be indistinguishable from the FGS's own publish traffic.
      try {
        await bob.dispose();
        await relay.dispose();
      } on Object catch (_) {
        // Best-effort; does not affect the proof below either way.
      }

      // =======================================================================
      // THE PROOF — see the class doc's "The framework unmounts on success"
      // section for why this can no longer be delegated to the shell.
      // =======================================================================

      // --- Deliver a REAL pause from inside the drive. This is NOT a
      // hand-written stand-in for `_onPaused()` — `handleAppLifecycleState
      // Changed` is Flutter's own public dispatch entry point, so MapShell's
      // genuine, unmodified `didChangeAppLifecycleState(paused)` →
      // `_onPaused()` runs exactly as it would from a real
      // `Activity.onStop()`: cancels the foreground heartbeat, stops
      // `locationPublishSchedulerProvider`, and writes
      // `markForegroundActive(active: false)`. This drive never delivers
      // `resumed` afterward — doing so would re-arm the foreground and
      // defeat the hold below.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      debugPrint('$kPauseDeliveredMarker pid=$pid');

      // Confirm `_onPaused()` actually ran to completion — not just that it
      // was dispatched — by polling REAL on-disk SharedPreferences for the
      // exact flag `_publishCycle`'s gate 3 reads. Bounded: a stuck
      // `_onPaused()` (a hung platform-channel write, a disposed `ref`
      // throwing before the write lands) must fail this drive red with a
      // clear, attributable reason here, rather than silently falling
      // through to a 200 s hold that could never succeed.
      await waitUntilAsync(
        () async {
          await prefs.reload();
          return prefs.getInt(kForegroundActiveAtMsKey) == 0;
        },
        description: 'kForegroundActiveAtMsKey observed 0 in real '
            'SharedPreferences — proof that the production _onPaused() ran '
            'to completion, not merely that the pause was dispatched',
        pollInterval: const Duration(seconds: 1),
      );
      debugPrint(kHandoffConfirmedMarker);

      // --- Hold the body open. The tree stays mounted, the
      // ProviderContainer stays alive, and `aliceManager` stays open for
      // this entire window — the Rule-14 contention this lane exists to
      // observe is real and CONTINUOUS throughout, not merely at the
      // instant "ARMED" printed. Poll (never a single blind sleep) so a
      // genuinely wedged run still produces periodic evidence in the CI log
      // instead of silence; pump a frame on every iteration too —
      // belt-and-suspenders in case anything downstream of this point turns
      // out to depend on a widget rebuild (see pump_helpers.dart's
      // `waitUntilAsync` doc for why that is not guaranteed without one).
      final holdDeadline = DateTime.now().add(_postPauseHoldDuration);
      var elapsedHeartbeats = 0;
      while (DateTime.now().isBefore(holdDeadline)) {
        await tester.pump(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(seconds: 9));
        elapsedHeartbeats += 1;
        if (elapsedHeartbeats.isEven) {
          final lastPublish =
              await BackgroundLocationManager.readLastPublishTime();
          debugPrint(
            '[b1] holding (~${elapsedHeartbeats * 10}s of '
            '${_postPauseHoldDuration.inSeconds}s) — lastBackgroundPublish='
            '${lastPublish?.toIso8601String() ?? "none yet"}',
          );
        }
      }
      debugPrint(
        '[b1] hold complete — returning now hands control to '
        "flutter_test's own post-test teardown (see class doc). The "
        'shell should scope its logcat/network window to start at '
        '$kPauseDeliveredMarker, not to any later HOME press.',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
