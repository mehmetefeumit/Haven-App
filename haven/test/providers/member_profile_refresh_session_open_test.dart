/// A profile refresh that met a circle session it could not open runs again,
/// once, when the session opens.
///
/// On Android a resume ends the MLS handoff and refreshes at once, and the
/// open behind that refresh can still lose the Rule-14 guard to the
/// foreground service. The real [NostrCircleService], [NostrProfileService],
/// [circlesProvider] and [MemberProfileRefreshNotifier], over a scripted
/// bridge: only the Rust open (`CircleManagerFfi.newInstance`) and the manager
/// it hands back are fakes. A separate file because `RustLib.initMock`
/// replaces the bridge for the whole isolate.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';

import '../mocks/background_task_fakes.dart';

/// The bridge's open, scripted: refused while [guardHeld], or for the next
/// [refusals] opens, as the Rule-14 guard refuses a second session, and
/// otherwise handing back [manager].
class _ScriptedBridge implements RustLibApi {
  _ScriptedBridge(this.manager);

  final _ProfileManager manager;
  bool guardHeld = false;
  int refusals = 0;

  @override
  Future<CircleManagerFfi> crateApiCircleManagerFfiNew({
    required String dataDir,
    required List<int> identitySecretBytes,
  }) async {
    if (refusals > 0) {
      refusals--;
      throw StateError('an MLS session is already open');
    }
    if (guardHeld) throw StateError('an MLS session is already open');
    return manager;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// Records every kind-0 fetch the refresh reaches the core with.
class _ProfileManager extends FakeCircleManager {
  _ProfileManager({super.circles});

  final List<({List<String> pubkeys, int maxAgeSecs})> fetches = [];

  @override
  Future<List<ProfileMetadataFfi>> fetchMemberProfiles({
    required List<String> pubkeysHex,
    required int maxAgeSecs,
  }) async {
    fetches.add((pubkeys: List.of(pubkeysHex), maxAgeSecs: maxAgeSecs));
    return const [];
  }
}

class _FixedDataDirectory implements DataDirectoryProvider {
  @override
  Future<String> getDataDirectory() async => '/haven-test-data';
}

/// The kind-0 refresh never reads the identity service.
class _UnusedIdentityService extends Fake implements IdentityService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedBridge bridge;
  final circle = circleFixture(seed: 1);
  final memberPubkey = circle.members.single.pubkey;
  final ownIdentity = Identity(
    pubkeyHex: kHarnessPubkeyHex,
    npub: 'npub1harness',
    createdAt: DateTime(2024),
  );

  setUpAll(() {
    bridge = _ScriptedBridge(_ProfileManager(circles: [circle]));
    RustLib.initMock(api: bridge);
  });

  setUp(() {
    bridge
      ..guardHeld = false
      ..refusals = 0
      ..manager.circles = [circle]
      ..manager.fetches.clear();
    // Profile fetches are foreground-only; most cases run in front.
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  /// The circle service the app builds, foregrounded, with no handover: a
  /// refused open stays refused until the guard is free.
  NostrCircleService circleService() => NostrCircleService(
    relayService: FakeNostrRelayService(),
    dataDirectoryProvider: _FixedDataDirectory(),
    keyringInitializer: () async {},
    // A fresh buffer per open: `withFreshSecret` scrubs what it is given.
    identitySecretBytesProvider: () async => List<int>.filled(32, 7),
    isForegrounded: () => true,
  );

  ProviderContainer containerOver(NostrCircleService service) {
    final container = ProviderContainer(
      overrides: [
        circleServiceProvider.overrideWithValue(service),
        profileServiceProvider.overrideWithValue(
          NostrProfileService(
            identityService: _UnusedIdentityService(),
            circleManagerFactory: service.getCircleManagerFfi,
          ),
        ),
        identityProvider.overrideWith((ref) async => ownIdentity),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> refresh(ProviderContainer container, Duration maxAge) async {
    await container
        .read(memberProfileRefreshProvider.notifier)
        .refreshAll(maxAge: maxAge);
    await pumpEventQueue();
  }

  test('a refresh refused at the open runs once the session opens, over '
      'every member', () async {
    bridge.guardHeld = true;
    final service = circleService();
    final container = containerOver(service);

    await refresh(container, profileForegroundMaxAge);
    expect(bridge.manager.fetches, isEmpty, reason: 'anti-vacuity');

    // Any later opener — the heal backstop, a publish tick — gets the
    // session once the foreground service lets go.
    bridge.guardHeld = false;
    await service.initialize();
    await pumpEventQueue();

    expect(
      bridge.manager.fetches,
      hasLength(1),
      reason:
          'the resume refresh the refused open swallowed must still '
          'happen, and only once',
    );
    final fetch = bridge.manager.fetches.single;
    expect(
      fetch.pubkeys,
      containsAll(<String>[memberPubkey, kHarnessPubkeyHex]),
      reason:
          'the re-run reads the circles the open made readable, so no '
          'member is left out of the union',
    );
    expect(fetch.maxAgeSecs, profileForegroundMaxAge.inSeconds);
  });

  test('a fetch refused over circles already read runs once the session '
      'opens', () async {
    // The Android resume with the circle list still cached: only the fetch
    // needs the session, and the foreground service still holds it.
    final service = circleService();
    final container = containerOver(service);
    expect(await container.read(circlesProvider.future), hasLength(1));
    service.releaseForHandoff();
    bridge.guardHeld = true;

    await refresh(container, profileForegroundMaxAge);
    expect(bridge.manager.fetches, isEmpty, reason: 'anti-vacuity');

    bridge.guardHeld = false;
    await service.initialize();
    await pumpEventQueue();

    expect(bridge.manager.fetches, hasLength(1));
    expect(
      bridge.manager.fetches.single.pubkeys,
      containsAll(<String>[memberPubkey, kHarnessPubkeyHex]),
    );
  });

  test('a union narrowed by a refused circle read is asked again once the '
      "refresh's own open succeeds", () async {
    // The circle read loses the guard; the fetch behind it, a moment later,
    // wins it. The fetch succeeds, but over the own pubkey alone.
    bridge.refusals = 1;
    final service = circleService();
    final container = containerOver(service);

    await refresh(container, profileForegroundMaxAge);
    await pumpEventQueue();

    expect(
      bridge.manager.fetches.first.pubkeys,
      [kHarnessPubkeyHex],
      reason: 'anti-vacuity: the first fetch saw no circle',
    );
    expect(
      bridge.manager.fetches.last.pubkeys,
      containsAll(<String>[memberPubkey, kHarnessPubkeyHex]),
      reason:
          'the members the refused read left out must still be asked '
          'for, without waiting for the next trigger',
    );
    expect(bridge.manager.fetches, hasLength(2));
  });

  test('refreshes refused while the session is closed collapse into one, '
      'at the strictest tier', () async {
    bridge.guardHeld = true;
    final service = circleService();
    final container = containerOver(service);

    await refresh(container, profileInteractiveMaxAge);
    await refresh(container, profileForegroundMaxAge);

    bridge.guardHeld = false;
    await service.initialize();
    await pumpEventQueue();

    expect(bridge.manager.fetches, hasLength(1));
    expect(
      bridge.manager.fetches.single.maxAgeSecs,
      profileForegroundMaxAge.inSeconds,
    );
  });

  test('a refresh that reached the relays is not run again at the next '
      'open', () async {
    final service = circleService();
    final container = containerOver(service);

    await refresh(container, profileForegroundMaxAge);
    expect(bridge.manager.fetches, hasLength(1));

    // A pause hands the session over and the resume takes it back: a fresh
    // open, which owes nothing to the refresh that succeeded.
    service.releaseForHandoff();
    await service.initialize();
    await pumpEventQueue();

    expect(bridge.manager.fetches, hasLength(1));
  });

  test('a user with no circles is owed at most one run, never forced, '
      'however many times the session reopens', () async {
    bridge.manager.circles = [];
    final service = circleService();
    final container = containerOver(service);

    // The explicit pull-to-refresh: forced, over the own pubkey alone.
    await refresh(container, profileForceMaxAge);
    expect(
      bridge.manager.fetches.first.maxAgeSecs,
      0,
      reason: 'anti-vacuity: the explicit refresh itself is forced',
    );

    // Every Android resume hands the session over and opens it again.
    for (var resume = 0; resume < 4; resume++) {
      service.releaseForHandoff();
      await service.initialize();
      await pumpEventQueue();
    }

    final owed = bridge.manager.fetches.skip(1).toList();
    expect(
      owed,
      hasLength(lessThanOrEqualTo(1)),
      reason: 'an empty circle list at every open must not re-arm forever',
    );
    expect(
      owed.map((f) => f.maxAgeSecs),
      everyElement(profileForegroundMaxAge.inSeconds),
      reason: 'an automatic run never skips the miss backoff',
    );
  });

  test('an open that lands while the app is not in front owes the run to '
      'the resume, and fetches nothing', () async {
    bridge.guardHeld = true;
    final service = circleService();
    final container = containerOver(service);

    await refresh(container, profileForegroundMaxAge);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );

    bridge.guardHeld = false;
    await service.initialize();
    await pumpEventQueue();

    expect(
      bridge.manager.fetches,
      isEmpty,
      reason: 'a kind-0 fetch from the background',
    );
  });

  test('a logout before the open leaves nothing owed', () async {
    bridge.guardHeld = true;
    final service = circleService();
    final container = containerOver(service);

    await refresh(container, profileForegroundMaxAge);
    // What `deleteIdentity` does before the MLS wipe.
    container.invalidate(memberProfileRefreshProvider);

    bridge.guardHeld = false;
    await service.initialize();
    await pumpEventQueue();

    expect(
      bridge.manager.fetches,
      isEmpty,
      reason: "no kind-0 REQ for the erased identity's social graph",
    );
  });
}
