/// Stand-ins for driving [BackgroundLocationTaskHandler]'s publish cycle on
/// the host.
///
/// The cycle's collaborators are FFI opaque handles (`CircleManagerFfi`,
/// `NostrIdentityManager`, `LocationEventService`) and concrete services whose
/// real constructors need the bridge. All of them are plain Dart interfaces,
/// so a fake can stand in; the fakes record what they were asked so a test
/// asserts on the calls the cycle made, and throw on anything they were not
/// written for so an unexpected dependency fails loudly instead of returning a
/// silent default the cycle's `catch` blocks would swallow.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/circle_service.dart'
    show Circle, DecryptedLocation;
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:haven/src/services/publish_wake_lock.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One `encryptLocation` call as the cycle made it.
class EncryptCall {
  const EncryptCall({
    required this.mlsGroupId,
    required this.senderPubkeyHex,
    required this.latitude,
    required this.longitude,
    required this.updateIntervalSecs,
  });

  final List<int> mlsGroupId;
  final String senderPubkeyHex;
  final double latitude;
  final double longitude;
  final BigInt updateIntervalSecs;
}

/// One `notePublishAcked` stamp as the cycle recorded it.
class AckStamp {
  const AckStamp({required this.nostrGroupId, required this.atMs});

  final List<int> nostrGroupId;
  final int atMs;
}

/// One publish call as the cycle made it.
class PublishedEvent {
  const PublishedEvent({required this.eventJson, required this.relays});

  final String eventJson;
  final List<String> relays;
}

/// A [CircleManagerFfi] that serves a fixed roster and scripts each encrypt.
class FakeCircleManager implements CircleManagerFfi {
  FakeCircleManager({List<CircleWithMembersFfi> circles = const []})
    : circles = List.of(circles);

  /// What `getVisibleCircles` returns.
  List<CircleWithMembersFfi> circles;

  /// Decides each encrypt's outcome, given the group it is for. The default
  /// is a plain `sent` outcome whose event JSON carries the circle's PUBLIC
  /// `#h` id, so a test can tie a published event back to the circle it came
  /// from.
  late EncryptLocationOutcomeFfi Function(List<int> mlsGroupId)
  encryptOutcome = sentOutcomeFor;

  /// How many times the roster was read.
  ///
  /// One read per cycle that gets past the gates, so this is the only way to
  /// tell "the cycle ran and found nothing to do" from "no cycle ran" — which
  /// is exactly the difference the historical-re-delivery dedupe makes.
  int rosterReads = 0;

  final List<EncryptCall> encryptCalls = [];
  final List<AckStamp> acks = [];
  final List<BigInt> confirmedTokens = [];
  final List<BigInt> rolledBackTokens = [];
  int pruneExpiredLastKnownCalls = 0;

  /// Rows the next prune reports having deleted — the number the FGS renders
  /// into its prune log line.
  int pruneExpiredLastKnownRows = 0;
  int pruneProcessedGiftWrapsCalls = 0;
  bool disposed = false;

  /// Runs inside [dispose] — the seam a teardown test uses to observe the
  /// isolate's state at the Rule-14 handback, which is the LAST thing
  /// `onDestroy` does and the one thing no later sample can see.
  void Function()? onDispose;

  /// A `sent` outcome addressed to [relays] for the roster circle whose MLS
  /// id is [mlsGroupId]. Like the real engine it exposes only the circle's
  /// public `nostrGroupId` (Rule 4) — in the payload's `#h` and in the
  /// outcome — never the MLS id it was asked with.
  EncryptLocationOutcomeFfi sentOutcomeFor(
    List<int> mlsGroupId, {
    List<String> relays = const ['wss://payload.relay.example'],
  }) {
    final nostrGroupId = circles
        .firstWhere(
          (c) => hexOf(c.circle.mlsGroupId) == hexOf(mlsGroupId),
          orElse: () => throw StateError('encrypt for a group not in roster'),
        )
        .circle
        .nostrGroupId;
    return EncryptLocationOutcomeFfi(
      sent: EncryptedLocationFfi(
        eventJson: '{"kind":445,"h":"${hexOf(nostrGroupId)}"}',
        nostrGroupId: nostrGroupId,
        relays: relays,
      ),
    );
  }

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async {
    rosterReads++;
    return List.of(circles);
  }

  /// The single-circle read `NostrCircleService.getCircle` delegates to — how
  /// the FGS resolves which circle a REPLAYED result belongs to.
  @override
  Future<CircleWithMembersFfi?> getCircle({
    required List<int> mlsGroupId,
  }) async => circles
      .where((c) => hexOf(c.circle.mlsGroupId) == hexOf(mlsGroupId))
      .firstOrNull;

  @override
  Future<EncryptLocationOutcomeFfi> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required BigInt updateIntervalSecs,
  }) async {
    encryptCalls.add(
      EncryptCall(
        mlsGroupId: mlsGroupId,
        senderPubkeyHex: senderPubkeyHex,
        latitude: latitude,
        longitude: longitude,
        updateIntervalSecs: updateIntervalSecs,
      ),
    );
    return encryptOutcome(mlsGroupId);
  }

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required int atMs,
  }) async => acks.add(AckStamp(nostrGroupId: nostrGroupId, atMs: atMs));

  /// What each resolution REPLAYS, keyed by the pending token being resolved:
  /// resolving a staged commit makes the engine replay everything it buffered
  /// while that commit was in flight. Unset tokens replay nothing.
  final Map<BigInt, DecryptLocationOutcomeFfi> replayOnResolve = {};

  @override
  Future<DecryptLocationOutcomeFfi> confirmPublished({
    required PendingStateRefFfi pending,
  }) async {
    confirmedTokens.add(pending.token);
    return _replayFor(pending.token);
  }

  @override
  Future<DecryptLocationOutcomeFfi> publishFailed({
    required PendingStateRefFfi pending,
  }) async {
    rolledBackTokens.add(pending.token);
    return _replayFor(pending.token);
  }

  /// One-shot: a token's replay is handed back by the FIRST resolution of it,
  /// exactly as the engine's buffer is drained once.
  DecryptLocationOutcomeFfi _replayFor(BigInt token) =>
      replayOnResolve.remove(token) ??
      const DecryptLocationOutcomeFfi(
        results: [],
        autoCommits: [],
        proposals: [],
      );

  @override
  Future<int> pruneExpiredLastKnown({required int nowUnixSecs}) async {
    pruneExpiredLastKnownCalls++;
    return pruneExpiredLastKnownRows;
  }

  @override
  Future<BigInt> pruneProcessedGiftWraps({required int nowUnixSecs}) async {
    pruneProcessedGiftWrapsCalls++;
    return BigInt.zero;
  }

  @override
  void dispose() {
    disposed = true;
    onDispose?.call();
  }

  @override
  bool get isDisposed => disposed;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A [NostrIdentityManager] that has (or has not) an identity and nothing
/// else — in particular no secret bytes, so a manager open that reaches for
/// them fails the way the background isolate's does without a keyring.
class FakeIdentityManager implements NostrIdentityManager {
  FakeIdentityManager({this.pubkey});

  /// `null` means no identity is loaded.
  final String? pubkey;

  @override
  bool hasIdentity() => pubkey != null;

  @override
  String pubkeyHex() => pubkey!;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A [NostrRelayService] that records publishes and answers with a scripted
/// acceptance.
class FakeNostrRelayService extends Fake implements NostrRelayService {
  /// Relays that "accept" every publish. Empty means nothing acked.
  List<String> acceptedBy = const ['wss://relay.example'];

  /// Thrown by every publish while set, whichever ladder it took.
  Exception? publishError;

  /// Thrown by the next `initialize` call, once.
  Exception? initializeErrorOnce;

  /// Runs inside each publish, before it returns — the seam through
  /// which a test changes the world mid-cycle (a foreground resume, a stop).
  FutureOr<void> Function(PublishedEvent event)? onPublish;

  /// Every publish the cycle made, in order, whichever ladder carried it.
  final List<PublishedEvent> published = [];

  /// The subset that took the one-shot location ladder, and the subset that
  /// took the 3-attempt retry ladder.
  ///
  /// Kept apart because nothing in the types does it: both take an event JSON
  /// and a relay list, so which ladder an event took is only observable in
  /// which method the cycle called. Routing a commit onto the one-shot path
  /// would leave it neither confirmed nor rolled back (Rule 13).
  final List<PublishedEvent> publishedLocations = [];
  final List<PublishedEvent> publishedOnLadder = [];

  int initializeCalls = 0;

  /// How many times the cycle closed the publish pool.
  ///
  /// A COUNT, not a flag: the pool is closed at the end of EVERY cycle (the
  /// socket is what the Android presence copy promises does not stay open), so
  /// "it was closed once, at teardown" and "it is closed per cycle" have to be
  /// distinguishable.
  int shutdownCalls = 0;

  bool get shutdownCalled => shutdownCalls > 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    final error = initializeErrorOnce;
    if (error != null) {
      initializeErrorOnce = null;
      throw error;
    }
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) => _record(eventJson, relays, publishedOnLadder);

  @override
  Future<PublishResult> publishLocationEvent({
    required String eventJson,
    required List<String> relays,
  }) => _record(eventJson, relays, publishedLocations);

  Future<PublishResult> _record(
    String eventJson,
    List<String> relays,
    List<PublishedEvent> ladder,
  ) async {
    final event = PublishedEvent(eventJson: eventJson, relays: relays);
    published.add(event);
    ladder.add(event);
    await onPublish?.call(event);
    final error = publishError;
    if (error != null) throw error;
    return PublishResult(
      eventId: 'event-${published.length}',
      acceptedBy: acceptedBy,
      rejectedBy: const [],
      failed: const [],
    );
  }

  /// Runs inside each shutdown, before it returns.
  ///
  /// The teardown's own pool close is the ONE await between the abandoned
  /// drain and the Rule-14 handback, so this is what lets a teardown test
  /// order a publish that outlived the drain budget against the tail that
  /// follows it, instead of racing the two.
  FutureOr<void> Function()? onShutdown;

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await onShutdown?.call();
  }
}

/// A [LocationSharingService] whose receive plane is a recorder.
class FakeLocationSharingService extends Fake
    implements LocationSharingService {
  /// Thrown for circles whose hex `nostrGroupId` is listed here.
  final Set<String> failFor = {};

  /// Runs inside each fetch, before it returns.
  FutureOr<void> Function(Circle circle)? onFetch;

  final List<Circle> fetched = [];

  /// Every location handed to [ingestStreamedLocation], with the circle it
  /// was routed under.
  ///
  /// The FGS isolate has no provider container, so this service IS the only
  /// place a received fix can land: a replay that never reaches it is a fix
  /// the engine already wrote `Processed` and nobody ever sees.
  final List<({Circle circle, DecryptedLocation decrypted})> ingested = [];

  @override
  Future<void> ingestStreamedLocation({
    required Circle circle,
    required DecryptedLocation decrypted,
  }) async => ingested.add((circle: circle, decrypted: decrypted));

  @override
  Future<LocationFetchResult> fetchMemberLocations({
    required Circle circle,
    DateTime? since,
  }) async {
    fetched.add(circle);
    await onFetch?.call(circle);
    if (failFor.contains(hexOf(circle.nostrGroupId))) {
      throw StateError('fetch failed for ${hexOf(circle.nostrGroupId)}');
    }
    return const LocationFetchResult(locations: []);
  }
}

/// A [GeolocatorLocationService] standing in for both halves of the platform
/// boundary the background cycle uses: the long-interval position STREAM it
/// registers, and the `getCurrentLocation()` read it publishes from.
///
/// The two are wired together the way the real service wires them: a delivered
/// fix is teed into the cache, and `getCurrentLocation()` serves that cache
/// while it is fresh instead of issuing a one-shot. That tee is what makes
/// [oneShotRequests] a real oracle — without it, a cycle that never registered
/// would look identical to one that published from a delivery.
class FakeLocationService extends Fake implements GeolocatorLocationService {
  FakeLocationService({Future<Position> Function()? fix})
    : _fix = fix ?? (() async => defaultFix);

  static final Position defaultFix = Position(
    latitude: 48.8566,
    longitude: 2.3522,
    timestamp: DateTime.utc(2026, 8, 29, 12),
  );

  final Future<Position> Function() _fix;

  /// Every `getCurrentLocation()` call, served from the cache or not.
  ///
  /// The cycle MUST keep calling it — it is the one gated coordinate producer
  /// (`INV-L-ACCESS-GATE-PRECEDES-FIX`), so an oracle asserting this stays
  /// zero would assert the cycle never collects. [oneShotRequests] is the
  /// battery oracle; this one is the "the read still happens" one.
  int fixRequests = 0;

  /// Calls that could NOT be served from a delivered fix, i.e. the ones that
  /// reach the platform's 30 s HIGH_ACCURACY one-shot in production.
  int oneShotRequests = 0;

  /// The profile each [getLocationStream] call asked for, in order.
  final List<AndroidStreamProfile> capturedProfiles = [];

  /// How many registrations currently have a listener.
  int streamListeners = 0;

  /// Seeds the Android S+ historical delivery: a request whose interval
  /// exceeds `MIN_REQUEST_DELAY_MS` is answered at once with the provider's
  /// cached last location, so every NEW registration is handed one fix a
  /// microtask after it is listened to. `null` is API ≤ 30 (or a cold
  /// provider), where the first fix costs a real acquisition.
  ///
  /// What gets replayed is the LAST DELIVERED fix once there is one — the
  /// provider caches what it last produced, so a re-registration replays the
  /// fix the cycle just consumed, which is precisely the replay the cycle's
  /// timestamp dedupe exists for. A fake that replayed a fixed older fix
  /// forever would manufacture a delivery the platform never makes.
  Position? historicalFix;

  /// Runs at the top of every [getCurrentLocation], before anything is served
  /// — the seam a test uses to order the fix against the registration.
  void Function()? onGetCurrentLocation;

  /// The clock freshness is measured against.
  ///
  /// Injectable because "the registration went silent for longer than
  /// [kStreamPositionMaxAge]" is a 168 s property, and a test that waited it
  /// out would be both slow and, at the boundary, a race.
  DateTime Function() clock = DateTime.now;

  StreamController<Position>? _controller;
  Position? _delivered;

  /// Reports [error] on the live registration, as the platform does for a
  /// provider switched off or a permission withdrawn mid-stream.
  void failStream(Object error) {
    final controller = _controller;
    if (controller == null || !controller.hasListener) {
      throw StateError('no live registration to fail');
    }
    controller.addError(error);
  }

  /// Feeds [fix] to the live registration, exactly as a platform delivery
  /// would: the subscriber runs SYNCHRONOUSLY (the real service's outer
  /// controller is `sync: true`), so a test never has to pump and hope.
  void deliverFix(Position fix) {
    final controller = _controller;
    if (controller == null || !controller.hasListener) {
      throw StateError(
        'no live registration to deliver a fix to — the cycle under test '
        'never registered, which is itself the finding',
      );
    }
    _delivered = fix;
    controller.add(fix);
  }

  @override
  bool hasFreshStreamFix({DateTime Function()? now}) {
    final fix = _delivered;
    return fix != null && _isFresh(fix, (now ?? clock)());
  }

  @override
  Stream<Position> getLocationStream({
    bool backgroundSharingEnabled = false,
    AndroidStreamProfile profile = const AndroidStreamProfile.foreground(),
  }) {
    capturedProfiles.add(profile);
    final controller = StreamController<Position>(sync: true);
    _controller = controller;
    controller
      ..onListen = () {
        streamListeners++;
        final historical = _delivered ?? historicalFix;
        if (historical == null) return;
        // A microtask, never synchronously: `add` inside `onListen` on a sync
        // controller is illegal, and the real delivery is a platform hop.
        scheduleMicrotask(() {
          if (controller.hasListener) deliverFix(historical);
        });
      }
      ..onCancel = () {
        streamListeners--;
        if (identical(_controller, controller)) _controller = null;
      };
    return controller.stream;
  }

  @override
  Future<Position> getCurrentLocation() {
    fixRequests++;
    onGetCurrentLocation?.call();
    final delivered = _delivered;
    if (delivered != null && _isFresh(delivered, clock())) {
      return Future<Position>.value(delivered);
    }
    oneShotRequests++;
    return _fix();
  }

  static bool _isFresh(Position fix, DateTime now) =>
      now.difference(fix.timestamp) <= kStreamPositionMaxAge;
}

/// A fix stamped [at] (default: now), i.e. one the cache will serve.
///
/// [FakeLocationService.defaultFix] is deliberately stamped in the past so the
/// one-shot fallback is what an un-delivered cycle takes; a test that means to
/// exercise a DELIVERY needs a fix that is actually fresh.
///
/// Two calls never share a timestamp. The cycle dedupes a re-delivered fix BY
/// its timestamp, so a fixture that let two distinct fixes collide would make
/// a genuine second delivery read as a historical replay — a test failing for
/// the resolution of the system clock rather than for the behaviour.
Position freshFix({
  DateTime? at,
  double latitude = 51.5074,
  double longitude = -0.1278,
}) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: at ?? DateTime.now().add(Duration(microseconds: _fixSeq++)),
);

int _fixSeq = 0;

/// Records what the background cycle asked the native `Haven:publish` lock
/// for, by standing in for the platform side of its method channel.
///
/// Drives the REAL [PublishWakeLock] client (there is no injection seam in the
/// handler): with no handler installed the channel throws
/// `MissingPluginException` and every call is a silent no-op, which is exactly
/// what an unrelated test wants and exactly what an ordering test must not
/// mistake for a lock.
class FakeWakeLockChannel {
  /// Installs the handler for the current test and removes it afterwards.
  FakeWakeLockChannel() {
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(PublishWakeLock.channel, (call) async {
          switch (call.method) {
            case 'acquire':
              acquireCalls.add(
                Duration(milliseconds: (call.arguments as num).toInt()),
              );
              _lastWasAcquire = true;
              onAcquire?.call();
            case 'release':
              releaseCalls++;
              _lastWasAcquire = false;
              onRelease?.call();
            default:
              throw UnimplementedError('unexpected method: ${call.method}');
          }
          return null;
        });
  }

  /// Every acquire, with the timeout it asked for.
  final List<Duration> acquireCalls = [];

  /// How many times the lock was released.
  int releaseCalls = 0;

  /// Runs inside each acquire / release — the seam a test uses to order the
  /// lock against the work it protects.
  void Function()? onAcquire;
  void Function()? onRelease;

  bool _lastWasAcquire = false;

  /// Whether the lock is held.
  ///
  /// The last call decides, never a balance of counts: the native lock is
  /// `setReferenceCounted(false)`, so ONE release drops a lock however many
  /// times it was acquired. A counting model would report a cycle's leaked
  /// lock as released and a correctly re-acquired one as held.
  bool get held => _lastWasAcquire;

  /// Detaches the handler. Call from `tearDown`; the binding keeps mock
  /// handlers across tests otherwise.
  void detach() {
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(PublishWakeLock.channel, null);
  }
}

/// A [LocationEventService] whose jitter sampler returns a fixed interval, or
/// throws when [jitteredSecs] is `null` — the fallback path.
class FakeLocationEventService implements LocationEventService {
  FakeLocationEventService({this.jitteredSecs = 0});

  int? jitteredSecs;
  final List<BigInt> sampledNominals = [];

  @override
  BigInt jitteredPublishIntervalSecs({required BigInt nominalSecs}) {
    sampledNominals.add(nominalSecs);
    final secs = jitteredSecs;
    if (secs == null) throw StateError('jitter sampler unavailable');
    return BigInt.from(secs);
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// Hex-encodes a group id the way the cycle keys its schedule (`_bgCircleKey`).
String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// An accepted, publish-eligible circle whose ids are derived from [seed]
/// (`mlsGroupId` bytes are `seed`, `nostrGroupId` bytes are `seed + 100`).
///
/// [members] defaults to one admin because an accepted circle with NO
/// members is a pre-cutover orphan that `filterPublishEligibleCircles` drops.
CircleWithMembersFfi circleFixture({
  required int seed,
  List<String> relays = const ['wss://circle.relay.example'],
  String membershipStatus = 'accepted',
  List<CircleMemberFfi>? members,
}) => CircleWithMembersFfi(
  circle: CircleFfi(
    mlsGroupId: Uint8List(32)..fillRange(0, 32, seed),
    nostrGroupId: Uint8List(32)..fillRange(0, 32, seed + 100),
    displayName: 'Circle $seed',
    circleType: 'location_sharing',
    relays: relays,
    createdAt: 1756468800,
    updatedAt: 1756468800,
  ),
  membershipStatus: membershipStatus,
  members:
      members ??
      const [
        CircleMemberFfi(
          pubkey:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
              'aaaaaaaaaaaaaaaaaaaaaaaa',
          npub: 'npub1fixture',
          isAdmin: true,
        ),
      ],
);

/// The schedule key the cycle uses for [fixture].
String scheduleKeyOf(CircleWithMembersFfi fixture) =>
    hexOf(fixture.circle.nostrGroupId);

/// The identity the harness publishes as.
const String kHarnessPubkeyHex =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// `SharedPreferences` state in which background sharing is switched on, the
/// background isolate owns publishing and both Play disclosures are accepted
/// — the steady state after a pause with sharing on. Individual tests override
/// keys to close each gate.
///
/// The sharing toggle is CURRENT consent and the disclosures are the record
/// that the dialogs were accepted; the two are seeded together here because
/// the steady state has both, and separately in the tests because only one of
/// them is ever withdrawn.
Map<String, Object> backgroundOwnsPublishingPrefs() => {
  kBackgroundSharingKey: true,
  kForegroundActiveAtMsKey: 0,
  kLocationDisclosureAcceptedKey: true,
  kLocationDisclosureBackgroundAcceptedKey: true,
};

/// A handler wired over the fakes above and brought up the way `onStart`
/// does past the bridge.
class BackgroundTaskHarness {
  BackgroundTaskHarness._({
    required this.handler,
    required this.manager,
    required this.relay,
    required this.sharing,
    required this.location,
    required this.events,
  });

  /// Builds and brings up a handler.
  ///
  /// [circles] is the roster the manager serves. With [identityPubkey] `null`
  /// no identity is loaded. [manager] defaults to a [FakeCircleManager] over
  /// [circles] and is injected via `overrideCircleManager` while
  /// [injectManager] is true; with it false the open is left to the
  /// identity's (absent) secret bytes and fails, and the manager is still
  /// returned so a test can inject it later.
  static Future<BackgroundTaskHarness> start({
    List<CircleWithMembersFfi> circles = const [],
    String? identityPubkey = kHarnessPubkeyHex,
    bool injectManager = true,
    FakeCircleManager? manager,
    FakeNostrRelayService? relay,
    FakeLocationSharingService? sharing,
    FakeLocationService? location,
    FakeLocationEventService? events,
    PublishStagger? stagger,
    String dataDir = 'test-data-dir',
  }) async {
    final theManager = manager ?? FakeCircleManager(circles: circles);
    final theRelay = relay ?? FakeNostrRelayService();
    final theSharing = sharing ?? FakeLocationSharingService();
    final theLocation = location ?? FakeLocationService();
    final theEvents = events ?? FakeLocationEventService();
    final handler = BackgroundLocationTaskHandler(
      stagger: stagger ?? PublishStagger.none(),
    )
      ..overrideRelayService = theRelay
      ..overrideLocationSharingService = theSharing
      ..overrideLocationService = theLocation
      ..overrideLocationEventService = theEvents
      // The guard is free: the post-handoff steady state.
      ..overrideIsSessionLive = (({required String dataDir}) async => false)
      // The LENGTH of the cold-cache wait is pinned in `location_test.dart`;
      // what these tests are about is what the cycle does when the delivery
      // arrives or does not. Zero keeps that honest either way — a microtask
      // (the historical delivery a fake registration schedules) still runs
      // before a zero-duration timer, so a delivered fix always wins the race
      // and an undelivered one costs the suite nothing.
      ..firstDeliveryWait = Duration.zero;
    if (injectManager) handler.overrideCircleManager = theManager;
    await handler.startWithoutBridgeForTest(
      identityManager: FakeIdentityManager(pubkey: identityPubkey),
      dataDir: dataDir,
    );
    return BackgroundTaskHarness._(
      handler: handler,
      manager: theManager,
      relay: theRelay,
      sharing: theSharing,
      location: theLocation,
      events: theEvents,
    );
  }

  final BackgroundLocationTaskHandler handler;
  final FakeCircleManager manager;
  final FakeNostrRelayService relay;
  final FakeLocationSharingService sharing;
  final FakeLocationService location;
  final FakeLocationEventService events;

  /// Fires the real repeat entry point and waits for the cycle it started.
  ///
  /// Refuses while a cycle is running: `onRepeatEvent` would return without
  /// starting one, and the caller would await the PREVIOUS cycle's future.
  Future<void> tick(DateTime at) {
    if (handler.inFlightPublishForTest != null) {
      throw StateError('a cycle is still in flight — await the previous tick');
    }
    handler.onRepeatEvent(at);
    return handler.inFlightPublishForTest ?? Future<void>.value();
  }

  /// Delivers [fix] on the live registration and waits for whatever the
  /// handler started because of it.
  ///
  /// A delivery is the ordinary entry point in the steady state — the watchdog
  /// only covers the states where none arrives — so this, not [tick], is what
  /// most cycle tests drive.
  Future<void> deliverFix(Position fix) {
    location.deliverFix(fix);
    return handler.inFlightPublishForTest ?? Future<void>.value();
  }

  /// Sends a foreground-handoff signal the way `MapShell` does, and waits for
  /// whatever the handler started because of it.
  Future<void> signal(String payload) {
    handler.onReceiveData(payload);
    return handler.inFlightPublishForTest ?? Future<void>.value();
  }

  /// Reads the cross-isolate idle flag as the foreground would.
  static Future<bool?> readIdleFlag() async =>
      (await SharedPreferences.getInstance()).getBool(kBackgroundIdleKey);
}
