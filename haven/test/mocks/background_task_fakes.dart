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
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
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

/// One `publishEvent` call as the cycle made it.
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

  final List<EncryptCall> encryptCalls = [];
  final List<AckStamp> acks = [];
  final List<BigInt> confirmedTokens = [];
  final List<BigInt> rolledBackTokens = [];
  int pruneExpiredLastKnownCalls = 0;
  int pruneProcessedGiftWrapsCalls = 0;
  bool disposed = false;

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
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async =>
      List.of(circles);

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

  @override
  Future<void> confirmPublished({required PendingStateRefFfi pending}) async =>
      confirmedTokens.add(pending.token);

  @override
  Future<void> publishFailed({required PendingStateRefFfi pending}) async =>
      rolledBackTokens.add(pending.token);

  @override
  Future<int> pruneExpiredLastKnown({required int nowUnixSecs}) async {
    pruneExpiredLastKnownCalls++;
    return 0;
  }

  @override
  Future<BigInt> pruneProcessedGiftWraps({required int nowUnixSecs}) async {
    pruneProcessedGiftWrapsCalls++;
    return BigInt.zero;
  }

  @override
  void dispose() => disposed = true;

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

  /// Thrown by every `publishEvent` while set.
  Exception? publishError;

  /// Thrown by the next `initialize` call, once.
  Exception? initializeErrorOnce;

  /// Runs inside each `publishEvent`, before it returns — the seam through
  /// which a test changes the world mid-cycle (a foreground resume, a stop).
  FutureOr<void> Function(PublishedEvent event)? onPublish;

  final List<PublishedEvent> published = [];
  int initializeCalls = 0;
  bool shutdownCalled = false;

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
  }) async {
    final event = PublishedEvent(eventJson: eventJson, relays: relays);
    published.add(event);
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

  @override
  Future<void> shutdown() async => shutdownCalled = true;
}

/// A [LocationSharingService] whose receive plane is a recorder.
class FakeLocationSharingService extends Fake
    implements LocationSharingService {
  /// Thrown for circles whose hex `nostrGroupId` is listed here.
  final Set<String> failFor = {};

  /// Runs inside each fetch, before it returns.
  FutureOr<void> Function(Circle circle)? onFetch;

  final List<Circle> fetched = [];

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

/// A [GeolocatorLocationService] that hands out one fix per call.
class FakeLocationService extends Fake implements GeolocatorLocationService {
  FakeLocationService({Future<Position> Function()? fix})
    : _fix = fix ?? (() async => defaultFix);

  static final Position defaultFix = Position(
    latitude: 48.8566,
    longitude: 2.3522,
    timestamp: DateTime.utc(2026, 8, 29, 12),
  );

  final Future<Position> Function() _fix;
  int fixRequests = 0;

  @override
  Future<Position> getCurrentLocation() {
    fixRequests++;
    return _fix();
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

/// `SharedPreferences` state in which the background isolate owns publishing
/// and both Play disclosures are accepted — the steady state after a pause
/// with sharing on. Individual tests override keys to close each gate.
Map<String, Object> backgroundOwnsPublishingPrefs() => {
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
      ..overrideIsSessionLive = (({required String dataDir}) async => false);
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

  /// Reads the cross-isolate idle flag as the foreground would.
  static Future<bool?> readIdleFlag() async =>
      (await SharedPreferences.getInstance()).getBool(kBackgroundIdleKey);
}
