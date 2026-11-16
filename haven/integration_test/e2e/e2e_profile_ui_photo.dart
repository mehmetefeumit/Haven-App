/// The Identity-page photo trip on Android, through the REAL system Photo
/// Picker and uCrop, with background sharing ON — the configuration in which a
/// photo picked on Android once could not be saved (root cause A, 2026-11-16:
/// uCrop stops MainActivity, MapShell's Android pause branch hands the MLS
/// session to the foreground service, and the crop result arrives before the
/// app is resumed).
///
/// Driven by `tooling/e2e/ci/run-photo-ui-scenario.sh`, whose host sidecar
/// plays the user inside the picker and uCrop: this target prints a fixed
/// marker (`[pp] ARM round=<n> act=<pick:i|cancel>`) before each tap that
/// opens the picker, and the sidecar answers the marker, never the reverse.
/// Each side waits only on the other's EFFECT: the sidecar on the picker and
/// uCrop being resumed, this side on its own lifecycle. While the activity is
/// away this side never pumps (frames stop when it is paused); it waits on a
/// recorded lifecycle history, so a transition that lands before the wait
/// starts is not lost.
///
/// The lifecycle a round must show (AOSP MediaProvider android14-release):
/// the Photo Picker is TRANSLUCENT, so it only pauses Haven (`inactive`);
/// uCrop is opaque and stops it (`paused`). A pick is therefore `paused`
/// then a later `resumed`; a cancel at the picker is `inactive` then
/// `resumed` with no `paused`.
///
/// Steps (no explicit `syncOwnProfile`: the production triggers publish):
///   0  cancel at the picker: no change, no error
///   -  display name N1 through the Identity page's save button
///   1  pick: the photo shows within the product's worst case, never the
///      error; a kind-0 with N1 and the picture on every profile relay; Bob
///      downloads it through the Primal mimic's 302
///   -  display name N2: `name` follows it (owner decision 4: it equalled the
///      previous display name), the picture is kept
///   2  pick another photo: replaced on the relays; Bob sees the new one
///   -  remove through the dialog: a kind-0 without a picture
///   3  pick again after the removal
///   -  one distinct kind-0 per edit on each relay, none on the circle relay,
///      no upload refused
///
/// Before every pick round: background sharing on and the foreground service
/// running, so the pause the round causes takes MapShell's Android branch —
/// the sidecar checks the branch's marker in the logcat.
library;

import 'dart:async' show StreamController, StreamSubscription;
import 'dart:convert' show jsonDecode;
import 'dart:io' show HttpClient;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/main.dart';
import 'package:haven/src/constants/location.dart' show kBackgroundSharingKey;
import 'package:haven/src/pages/identity_page.dart' show IdentityPage;
import 'package:haven/src/pages/map_shell.dart' show MapShell;
import 'package:haven/src/providers/background_location_provider.dart'
    show backgroundSharingProvider;
import 'package:haven/src/providers/maintenance_scheduler_provider.dart'
    show MaintenanceSchedulerNotifier, maintenanceSchedulerProvider;
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart' show setDiscoveryRelaysForTest;
import 'package:haven/src/services/background_location_manager.dart'
    show BackgroundLocationManager;
import 'package:haven/src/services/mls_session_handover.dart'
    show handoverTimeout, kHandoffEndWait;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:haven/src/test_keys.dart' show WidgetKeys;
import 'package:haven/src/utils/log_alias.dart'
    show LogAliasClass, logAliasHandle, magnitudeBucket;
import 'package:haven/src/widgets/identity/display_name_card.dart'
    show DisplayNameCard;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/app_lifecycle.dart';
import '_lib/fake_location_service.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/synthetic_user.dart' show SyntheticUser;
import '_lib/test_relay.dart'
    show TestRelay, TestRelayEvent, connectProbeRelay, defaultStrfryUrl;
import '_lib/test_user.dart';
import '_lib/throw_time_error_capture.dart';

// =============================================================================
// The protocol with the host sidecar
// =============================================================================

/// The markers run-photo-ui-scenario.sh reads (its ARM_RE / END_RE; its
/// self-test pins these two constants).
const String _kArmMarker = '[pp] ARM round=';
const String _kEndMarker = '[pp] END rounds=';

// photo-picker-lib.sh's bounds, mirrored (run-photo-ui-scenario.sh's
// self-test pins each to the library's default).
const int _sidecarPickerSecs = 60;
const int _sidecarUcropSecs = 60;
const int _sidecarReturnSecs = 60;
const int _sidecarDumpSecs = 15;
const int _sidecarAdbSecs = 10;

/// The sidecar's whole trip at its bounds — five windows, each with the
/// reads that can start at its end, as the lane budget prices `pp_round` —
/// plus 30 s for its marker poll and this side's own reaction. Below it this
/// side could give up while the sidecar is still inside its own bounds.
const Duration _tripBound = Duration(
  seconds:
      2 * _sidecarPickerSecs +
      2 * _sidecarUcropSecs +
      _sidecarReturnSecs +
      3 * _sidecarDumpSecs +
      8 * _sidecarAdbSecs +
      30,
);

/// From the resume to the photo on screen: the product's worst case, not its
/// usual one. A crop that outlasts the excursion grace hands the session
/// over; the save then waits up to [kHandoffEndWait] for the resume to end the
/// hand-off and the open up to [handoverTimeout]. The no-stall promise inside
/// the grace is the Flutter fake_async tests' to keep.
final Duration _applyBound =
    kHandoffEndWait + handoverTimeout + const Duration(seconds: 10);

// =============================================================================
// Hermetic hosts
// =============================================================================

const String _profileRelaysRaw = String.fromEnvironment(
  'HAVEN_E2E_PROFILE_RELAYS',
  defaultValue: 'ws://localhost:7778,ws://localhost:7779,ws://localhost:7780',
);
const String _blossomUrlsRaw = String.fromEnvironment(
  'HAVEN_E2E_BLOSSOM_URLS',
  defaultValue: 'http://localhost:3000,http://localhost:3002',
);

/// Mirrors `haven_core::profile::PROFILE_POOL_MIN` (not exported over FFI).
const int _profilePoolMin = 3;

const String _nameOne = 'Alice Photo One';
const String _nameTwo = 'Alice Photo Two';

const Duration _kind0WaitDeadline = Duration(seconds: 90);
const Duration _httpTimeout = Duration(seconds: 15);
const Duration _teardownTimeout = Duration(seconds: 15);
const Duration _outerTestTimeout = Duration(minutes: 18);

List<String> _splitUrls(String raw) => raw
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList(growable: false);

/// The profile pool: at least [_profilePoolMin] distinct entries, none the
/// circle relay (the contamination ledger would subtract it). Loopback-only
/// is the harness's own check, made before anything is installed.
final List<String> _profileRelayUrls = () {
  final urls = _splitUrls(_profileRelaysRaw);
  final distinct = urls.map((u) => u.toLowerCase()).toSet();
  if (distinct.length < _profilePoolMin ||
      distinct.contains(defaultStrfryUrl.toLowerCase())) {
    throw StateError(
      '[e2e_photo_ui] HAVEN_E2E_PROFILE_RELAYS must name at least '
      '$_profilePoolMin distinct relays, none of them the circle relay; it '
      'names ${magnitudeBucket(distinct.length)}.',
    );
  }
  return urls;
}();

/// Primary (the Primal mimic, with its `/__haven-e2e/` control surface) and
/// fallback.
final List<String> _blossomUrls = () {
  final urls = _splitUrls(_blossomUrlsRaw);
  if (urls.length != 2) {
    throw StateError(
      '[e2e_photo_ui] HAVEN_E2E_BLOSSOM_URLS must name exactly two servers; '
      'it names ${magnitudeBucket(urls.length)}.',
    );
  }
  return urls;
}();

/// Inert stand-in for the maintenance scheduler: its ticks would be an
/// unscheduled publisher, and the one-kind-0-per-edit count would no longer
/// say anything about the edits.
class _InertMaintenanceScheduler extends MaintenanceSchedulerNotifier {
  @override
  void build() {}
}

Future<void> _boundedTeardown(String step, Future<void> Function() run) async {
  try {
    await run().timeout(_teardownTimeout);
  } on Object catch (e) {
    debugPrint(
      '[e2e_photo_ui:tearDownAll] $step did not complete within '
      '${_teardownTimeout.inSeconds}s (or threw): ${e.runtimeType}.',
    );
  }
}

// =============================================================================
// The lifecycle history
// =============================================================================

/// Every lifecycle transition the engine reports, in order. A waiter checks
/// the history first and then subscribes in the same synchronous turn, so no
/// transition can fall between the two.
class _Lifecycle with WidgetsBindingObserver {
  final List<AppLifecycleState> history = <AppLifecycleState>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    history.add(state);
    _changes.add(null);
  }

  Future<void> until(
    bool Function(List<AppLifecycleState> since) done, {
    required int from,
    required String what,
  }) async {
    bool check() => done(history.sublist(from));
    if (check()) return;
    try {
      await _changes.stream.firstWhere((_) => check()).timeout(_tripBound);
    } on Object catch (e) {
      throw StateError(
        '[e2e_photo_ui] $what: the lifecycle did not show it within '
        '${_tripBound.inSeconds}s (${e.runtimeType}); seen since the ARM: '
        '${_lifecycleWords(history.sublist(from))}. The sidecar '
        'log (/tmp/photo-sidecar.log) names the screen it was on.',
      );
    }
  }

  Future<void> close() => _changes.close();
}

/// A lifecycle history in fixed words, for a failure message.
String _lifecycleWords(List<AppLifecycleState> states) => states
    .map(
      (s) => switch (s) {
        AppLifecycleState.resumed => 'resumed',
        AppLifecycleState.inactive => 'inactive',
        AppLifecycleState.hidden => 'hidden',
        AppLifecycleState.paused => 'paused',
        AppLifecycleState.detached => 'detached',
      },
    )
    .join(',');

// =============================================================================
// Entry point
// =============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  resumeAppBeforeEachTest();

  late ScenarioContext ctx;
  late SyntheticUser bob;
  late String aliceHex;
  final profilePool = <TestRelay>[];
  var didInitCtx = false;
  var didInitPreSeed = false;
  var didInitBob = false;

  setUpAll(() async {
    // Real on-disk preferences, as the B1 lane keeps them: the foreground
    // service's isolate reads them too.
    ctx = await ScenarioHarness.bootstrap(
      profileRelays: _profileRelayUrls,
      blossomServers: _blossomUrls,
    );
    didInitCtx = true;
    setDiscoveryRelaysForTest(relays: <String>[defaultStrfryUrl]);
    for (final url in _profileRelayUrls) {
      profilePool.add(await connectProbeRelay(url));
    }
    await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
    didInitPreSeed = true;
    // Background sharing on before the app is pumped, so MapShell starts the
    // foreground service and its pause takes the Android hand-off branch.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBackgroundSharingKey, true);
    aliceHex = (await TestUser.derivePubkeyAndNpub(aliceSeed)).pubkeyHex;
    bob = await SyntheticUser.bob(ctx.relay);
    didInitBob = true;
    debugPrint(
      '[e2e_photo_ui:setUpAll] '
      'alice=${logAliasHandle(LogAliasClass.peer, aliceHex)} '
      'primary=${logAliasHandle(LogAliasClass.relay, _blossomUrls[0])} '
      'profilePool=${magnitudeBucket(_profileRelayUrls.length)} relays',
    );
  });

  tearDownAll(() async {
    if (didInitBob) await _boundedTeardown('bob.dispose', bob.dispose);
    if (didInitPreSeed) {
      await _boundedTeardown(
        'TestUser.clearPreSeededIdentity',
        TestUser.clearPreSeededIdentity,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBackgroundSharingKey);
    }
    for (var i = 0; i < profilePool.length; i++) {
      await _boundedTeardown(
        'profileRelay[$i].dispose',
        profilePool[i].dispose,
      );
    }
    if (didInitCtx) {
      await _boundedTeardown('ctx.relay.dispose', ctx.relay.dispose);
    }
  });

  testWidgets(
    'Identity photo trip through the real picker and uCrop, background '
    'sharing on: cancel, pick, rename, replace, remove, re-add',
    (tester) async {
      installThrowTimeErrorLogging();
      final semantics = tester.ensureSemantics();
      final life = _Lifecycle();
      WidgetsBinding.instance.addObserver(life);
      final l10n = lookupAppLocalizations(const Locale('en'));

      // Every kind-0 the circle relay sees (it must see none), and every
      // kind-0 of Alice's each profile relay sees, from before the pump.
      final kind0OnCircleRelay = <TestRelayEvent>[];
      final circleWatch = ctx.relay
          .events(<String, dynamic>{
            'kinds': const <int>[0],
          })
          .listen(kind0OnCircleRelay.add);
      final seen = <int, List<TestRelayEvent>>{
        for (var i = 0; i < profilePool.length; i++) i: <TestRelayEvent>[],
      };
      final poolWatches = <StreamSubscription<TestRelayEvent>>[
        for (var i = 0; i < profilePool.length; i++)
          profilePool[i]
              .events(<String, dynamic>{
                'kinds': const <int>[0],
                'authors': <String>[aliceHex],
              })
              .listen(seen[i]!.add),
      ];

      try {
        final prefs = await SharedPreferences.getInstance();
        expectAppResumed();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              maintenanceSchedulerProvider.overrideWith(
                _InertMaintenanceScheduler.new,
              ),
              onboardingControllerProvider.overrideWith(
                (ref) => OnboardingController(
                  OnboardingFlags(
                    introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
                    completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
                  ),
                ),
              ),
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
        await pumpUntilFound(
          tester,
          find.byType(MapShell),
          timeout: const Duration(seconds: 60),
          description: 'MapShell after pumpWidget',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(MapShell)),
          listen: false,
        );
        // The foreground session first, as B1 opens it, before the service
        // can be asked to start (Rule 14's single session).
        final circleService =
            container.read(circleServiceProvider) as NostrCircleService;
        await circleService.getCircleManagerFfi();
        await _expectBackgroundSharing(tester, container);

        // Settings > Identity, as a user gets there.
        await tester.tap(find.byTooltip(l10n.commonSettings));
        await pumpUntilFound(
          tester,
          find.text(l10n.settingsIdentityTitle),
          description: 'the Settings page',
        );
        await tester.tap(find.text(l10n.settingsIdentityTitle));
        await pumpUntilFound(
          tester,
          find.byType(IdentityPage),
          description: 'the Identity page',
        );
        await pumpUntilFound(
          tester,
          find.text(l10n.photoHeaderEditPhoto),
          description: 'the photo header',
        );
        final editPhoto = find.text(l10n.photoHeaderEditPhoto);
        var edits = 0;
        var round = 0;

        // ---- Round 0: cancel at the picker. -------------------------------
        await _cancelRound(tester, life, round++, editPhoto);
        await tester.pump();
        expect(
          find.bySemanticsLabel(l10n.photoHeaderAddPhotoSemantics),
          findsOneWidget,
          reason: 'a cancelled pick must leave the photo header as it was',
        );
        expect(find.text(l10n.avatarPickerUpdateError), findsNothing);
        debugPrint('[e2e_photo_ui] ROUND 0 — cancel was a silent no-op');

        // ---- Display name N1 through the save button. --------------------
        await _saveDisplayName(tester, l10n, _nameOne);
        edits++;
        await _kind0OnEveryRelay(profilePool, aliceHex, 'name one', (c) {
          return c['display_name'] == _nameOne && c['name'] == _nameOne;
        });

        // ---- Round 1: the first photo. ------------------------------------
        await _expectBackgroundSharing(tester, container);
        await _pickRound(tester, life, l10n, round++, editPhoto, cell: 0);
        edits++;
        final first = await _kind0OnEveryRelay(
          profilePool,
          aliceHex,
          'photo one',
          (c) =>
              c['display_name'] == _nameOne &&
              _pictureOn(c, _blossomUrls[0]) != null,
        );
        final pictureOne = first['picture'] as String;
        final statsBefore = await _stats(_blossomUrls[0]);
        final bobSeesOne = await _bobDownloads(bob, aliceHex);
        final statsAfter = await _stats(_blossomUrls[0]);
        expect(
          statsAfter['redirects'] as int,
          greaterThan(statsBefore['redirects'] as int),
          reason: "Bob's download must have met the Primal mimic's 302",
        );
        expect(
          statsAfter['cdn_gets'] as int,
          greaterThan(statsBefore['cdn_gets'] as int),
          reason: "Bob's download must have FOLLOWED the 302 to the media host",
        );
        debugPrint('[e2e_photo_ui] ROUND 1 — photo saved, published, fetched');

        // ---- Display name N2: `name` follows (owner decision 4). ----------
        await _saveDisplayName(tester, l10n, _nameTwo);
        edits++;
        await _kind0OnEveryRelay(profilePool, aliceHex, 'name two', (c) {
          return c['display_name'] == _nameTwo &&
              c['name'] == _nameTwo &&
              c['picture'] == pictureOne;
        });

        // ---- Round 2: replace the photo. ----------------------------------
        await _expectBackgroundSharing(tester, container);
        await _pickRound(tester, life, l10n, round++, editPhoto, cell: 1);
        edits++;
        await _kind0OnEveryRelay(
          profilePool,
          aliceHex,
          'photo two',
          (c) =>
              c['display_name'] == _nameTwo &&
              _pictureOn(c, _blossomUrls[0]) != null &&
              c['picture'] != pictureOne,
        );
        final bobSeesTwo = await _bobDownloads(bob, aliceHex);
        expect(
          bobSeesTwo,
          isNot(bobSeesOne),
          reason: 'Bob must see the replacement, not the first photo',
        );
        debugPrint('[e2e_photo_ui] ROUND 2 — photo replaced');

        // ---- Remove through the dialog. -----------------------------------
        await tester.tap(find.text(l10n.photoHeaderRemove));
        await pumpUntilFound(
          tester,
          find.byType(AlertDialog),
          description: 'the remove-photo dialog',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(l10n.photoHeaderRemove),
          ),
        );
        await pumpUntilFound(
          tester,
          find.bySemanticsLabel(l10n.photoHeaderAddPhotoSemantics),
          timeout: _applyBound,
          description: 'the photo header without a photo',
        );
        edits++;
        await _kind0OnEveryRelay(
          profilePool,
          aliceHex,
          'photo removed',
          (c) => c['display_name'] == _nameTwo && c['picture'] == null,
        );

        // ---- Round 3: a photo again after the removal. --------------------
        await _expectBackgroundSharing(tester, container);
        await _pickRound(tester, life, l10n, round++, editPhoto, cell: 0);
        edits++;
        await _kind0OnEveryRelay(
          profilePool,
          aliceHex,
          'photo re-added',
          (c) => _pictureOn(c, _blossomUrls[0]) != null,
        );
        debugPrint('$_kEndMarker$round');

        // ---- The accounting. ----------------------------------------------
        for (var i = 0; i < profilePool.length; i++) {
          expect(
            seen[i]!.map((e) => e.id).toSet(),
            hasLength(edits),
            reason:
                '${logAliasHandle(LogAliasClass.relay, profilePool[i].url)} '
                'must hold one distinct kind-0 per edit '
                '(${magnitudeBucket(edits)} edits): more means a pass signed '
                'again for an edit it had already published.',
          );
        }
        expect(
          kind0OnCircleRelay,
          isEmpty,
          reason: 'the circle relay must never see a kind-0',
        );
        final refused =
            (await _stats(_blossomUrls[0]))['refused'] as Map<String, dynamic>;
        for (final entry in refused.entries) {
          expect(
            entry.value,
            0,
            reason: 'the primary refused an upload for "${entry.key}"',
          );
        }
      } finally {
        await circleWatch.cancel();
        for (final w in poolWatches) {
          await w.cancel();
        }
        WidgetsBinding.instance.removeObserver(life);
        await life.close();
        semantics.dispose();
      }
    },
    timeout: const Timeout(_outerTestTimeout),
  );
}

// =============================================================================
// Rounds
// =============================================================================

/// Background sharing on and the foreground service running: the state in
/// which the pause a pick causes takes MapShell's Android hand-off branch.
Future<void> _expectBackgroundSharing(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await pumpUntilCondition(
    tester,
    () => container.read(backgroundSharingProvider),
    description: 'backgroundSharingProvider true',
  );
  await waitUntilAsync(
    () => BackgroundLocationManager.isRunning,
    description: 'the foreground service running before a pick round',
    timeout: const Duration(seconds: 45),
  );
}

/// A cancel at the picker: `inactive`, then `resumed`, and never `paused`.
Future<void> _cancelRound(
  WidgetTester tester,
  _Lifecycle life,
  int round,
  Finder tap,
) async {
  final from = life.history.length;
  debugPrint('$_kArmMarker$round act=cancel');
  await tester.tap(tap);
  await life.until(
    (since) {
      final away = since.indexOf(AppLifecycleState.inactive);
      return away >= 0 && since.lastIndexOf(AppLifecycleState.resumed) > away;
    },
    from: from,
    what: 'round $round (cancel): inactive, then resumed',
  );
  expect(
    life.history.sublist(from),
    isNot(contains(AppLifecycleState.paused)),
    reason:
        'the Photo Picker is translucent: opening and cancelling it '
        'pauses Haven at most, it never stops it',
  );
}

/// A pick: `paused` (uCrop) then a later `resumed`; then the photo shows
/// within [_applyBound], and the error SnackBar never, checked on every pump.
Future<void> _pickRound(
  WidgetTester tester,
  _Lifecycle life,
  AppLocalizations l10n,
  int round,
  Finder tap, {
  required int cell,
}) async {
  final from = life.history.length;
  debugPrint('$_kArmMarker$round act=pick:$cell');
  await tester.tap(tap);
  await life.until(
    (since) {
      final paused = since.indexOf(AppLifecycleState.paused);
      return paused >= 0 &&
          since.lastIndexOf(AppLifecycleState.resumed) > paused;
    },
    from: from,
    what: 'round $round (pick): paused by uCrop, then resumed',
  );
  await pumpUntilCondition(
    tester,
    () {
      if (find.text(l10n.avatarPickerUpdateError).evaluate().isNotEmpty) {
        throw TestFailure(
          '[e2e_photo_ui] round $round: the photo save was refused after the '
          'crop (avatarPickerUpdateError) — root cause A: the result arrived '
          'before the app was resumed while the MLS session was handed off.',
        );
      }
      return find
              .bySemanticsLabel(l10n.photoHeaderViewPhotoSemantics)
              .evaluate()
              .isNotEmpty &&
          find.text(l10n.photoHeaderRemove).evaluate().isNotEmpty;
    },
    timeout: _applyBound,
    description: 'round $round: the photo shown after the crop',
  );
}

/// Types [name] into the Identity page's field and saves it with the button.
Future<void> _saveDisplayName(
  WidgetTester tester,
  AppLocalizations l10n,
  String name,
) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(DisplayNameCard),
      matching: find.byType(TextField),
    ),
    name,
  );
  await tester.pump();
  await tester.tap(find.byKey(WidgetKeys.displayNameSaveButton));
  await pumpUntilFound(
    tester,
    find.byTooltip(l10n.displayNameCardSavedLabel),
    description: 'the display name saved',
  );
}

// =============================================================================
// Relays, Blossom, Bob
// =============================================================================

Map<String, dynamic> _content(TestRelayEvent event) {
  final content = event.raw['content'];
  if (content is! String || content.isEmpty) return const <String, dynamic>{};
  final decoded = jsonDecode(content);
  return decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
}

/// The picture URL when it is on [base]'s host and port, else null.
String? _pictureOn(Map<String, dynamic> content, String base) {
  final picture = content['picture'];
  if (picture is! String || picture.isEmpty) return null;
  return Uri.parse(picture).authority == Uri.parse(base).authority
      ? picture
      : null;
}

/// Waits for a kind-0 of Alice's matching [matcher] on EVERY profile relay
/// (each peer reads its own salted pick of them), and returns its content.
Future<Map<String, dynamic>> _kind0OnEveryRelay(
  List<TestRelay> pool,
  String authorHex,
  String step,
  bool Function(Map<String, dynamic> content) matcher,
) async {
  final events = await Future.wait(
    pool.map((relay) async {
      try {
        return await relay.firstWhere(
          filter: <String, dynamic>{
            'kinds': const <int>[0],
            'authors': <String>[authorHex],
          },
          matcher: (e) => matcher(_content(e)),
          timeout: _kind0WaitDeadline,
        );
      } on Object catch (e) {
        throw StateError(
          '[e2e_photo_ui] $step: profile relay '
          '${logAliasHandle(LogAliasClass.relay, relay.url)} never served a '
          'matching kind-0 within ${_kind0WaitDeadline.inSeconds}s '
          '(${e.runtimeType}): the production publish trigger did not reach '
          'it.',
        );
      }
    }),
  );
  expect(
    events.map((e) => e.id).toSet(),
    hasLength(1),
    reason: '$step: every relay must hold the same signed kind-0',
  );
  return _content(events.first);
}

/// Bob's forced refetch and download of Alice's photo; returns the decode key
/// his app would render it by.
Future<String> _bobDownloads(SyntheticUser bob, String aliceHex) async {
  await bob.user.circleManager.fetchMemberProfiles(
    pubkeysHex: <String>[aliceHex],
    maxAgeSecs: 0,
  );
  await bob.user.circleManager.downloadMemberPicture(pubkeyHex: aliceHex);
  final profiles = await bob.user.circleManager.fetchMemberProfiles(
    pubkeysHex: <String>[aliceHex],
    maxAgeSecs: 0,
  );
  final alice = profiles.firstWhere(
    (p) => p.pubkeyHex.toLowerCase() == aliceHex.toLowerCase(),
    orElse: () =>
        throw StateError('[e2e_photo_ui] Bob did not resolve Alice at all.'),
  );
  expect(alice.hasPicture, isTrue, reason: 'Bob must hold the photo bytes');
  final key = alice.pictureSha256Hex;
  expect(key, isNotNull, reason: 'a held photo carries its decode key');
  return key!;
}

/// The primary's counts-only stats.
Future<Map<String, dynamic>> _stats(String base) async {
  final client = HttpClient()..connectionTimeout = _httpTimeout;
  try {
    final request = await client
        .getUrl(Uri.parse('$base/__haven-e2e/stats'))
        .timeout(_httpTimeout);
    final response = await request.close().timeout(_httpTimeout);
    final body = await response
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk))
        .timeout(_httpTimeout);
    expect(
      response.statusCode,
      200,
      reason: 'the primary has no stats surface',
    );
    return jsonDecode(String.fromCharCodes(body)) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}
