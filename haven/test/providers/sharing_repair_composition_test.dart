/// The ORDER the sharing-health repair runs its legs in, and what survives a
/// leg that throws.
///
/// Order is not cosmetic here. The epoch leg is the only one that authors an
/// MLS commit, and it must run LAST: if a dropped relay subscription was the
/// whole fault, re-anchoring fixes it and no circle needs re-keying. Running it
/// first would spend a circle's once-a-day repair budget on a problem the next
/// leg was about to solve.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show SkipReasonFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

/// Records the order the repair chain reached each leg.
final _log = <String>[];

class _RecordingSubscriptionService implements SubscriptionService {
  _RecordingSubscriptionService({this.throwOnResume = false});

  final bool throwOnResume;

  @override
  Future<void> resumeAfterBackground() async {
    _log.add('resume');
    if (throwOnResume) throw StateError('relay plane is down');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _RecordingCircleService extends MockCircleService {
  @override
  Future<EpochRepairResult> repairCircleEpoch(
    Circle circle, {
    required String selfPubkeyHex,
  }) async {
    _log.add('epoch');
    return super.repairCircleEpoch(circle, selfPubkeyHex: selfPubkeyHex);
  }
}

class _RecordingHealth extends SharingHealthNotifier {
  _RecordingHealth({this.throwOnRefresh = false});

  final bool throwOnRefresh;

  @override
  SharingHealth build() =>
      SharingHealth.receiveSilent(DateTime.utc(2026, 8, 28, 12));

  @override
  Future<void> refresh() async {
    _log.add('refresh');
    if (throwOnRefresh) throw StateError('health storage is unreadable');
  }
}

Circle _circle() => Circle(
  mlsGroupId: const [1, 2, 3],
  nostrGroupId: const [4, 5, 6],
  displayName: 'c',
  circleType: CircleType.locationSharing,
  relays: const ['wss://relay.test'],
  membershipStatus: MembershipStatus.accepted,
  members: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

final _identity = Identity(
  pubkeyHex:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  npub: 'npub1test',
  createdAt: DateTime.utc(2026),
);

ProviderContainer _container({
  required CircleService service,
  bool throwOnResume = false,
  bool throwOnPublish = false,
  bool throwOnRefresh = false,
}) => ProviderContainer(
  overrides: [
    circleServiceProvider.overrideWithValue(service),
    selectedCircleProvider.overrideWithValue(_circle()),
    identityProvider.overrideWith((ref) async => _identity),
    subscriptionServiceProvider.overrideWithValue(
      _RecordingSubscriptionService(throwOnResume: throwOnResume),
    ),
    locationPublisherProvider.overrideWith((ref) async {
      _log.add('publish');
      if (throwOnPublish) throw StateError('no relay accepted the publish');
      return 1;
    }),
    sharingHealthProvider.overrideWith(
      () => _RecordingHealth(throwOnRefresh: throwOnRefresh),
    ),
  ],
);

void main() {
  setUp(_log.clear);

  test('the epoch leg runs LAST, after the cheap local remedies', () async {
    final service = _RecordingCircleService()
      ..repairCircleEpochResult = const EpochRepairApplied();
    final container = _container(service: service);
    addTearDown(container.dispose);
    await container.read(identityProvider.future);

    final result = await container.read(sharingRepairProvider)();

    expect(result, isA<EpochRepairApplied>());
    // Re-anchor and re-publish FIRST — a dropped REQ must never end up
    // authoring a commit — and re-derive the verdict only once everything has
    // had its turn.
    //
    // Asserted as ORDERING rather than an exact list: invalidating the
    // publisher makes Riverpod rebuild it eagerly, so `publish` legitimately
    // appears twice. The promise is about relative order, and stating it that
    // way keeps the test about the promise instead of about Riverpod's
    // scheduling.
    expect(_log.where((e) => e == 'epoch'), hasLength(1));
    expect(_log.indexOf('epoch'), greaterThan(_log.lastIndexOf('resume')));
    expect(_log.indexOf('epoch'), greaterThan(_log.lastIndexOf('publish')));
    expect(_log.last, 'refresh');
  });

  test('a throwing resume still reaches the epoch leg', () async {
    // Each leg is independent. A relay plane that cannot be re-anchored is
    // exactly the situation where the epoch repair might be the thing that
    // helps, so one failure must not cancel the rest of the chain.
    final service = _RecordingCircleService()
      ..repairCircleEpochResult =
          const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin);
    final container = _container(service: service, throwOnResume: true);
    addTearDown(container.dispose);
    await container.read(identityProvider.future);

    final result = await container.read(sharingRepairProvider)();

    expect(result, isA<EpochRepairSkipped>());
    expect(_log, contains('resume'));
    expect(_log.where((e) => e == 'epoch'), hasLength(1));
    expect(_log.indexOf('epoch'), greaterThan(_log.lastIndexOf('resume')));
    expect(_log.last, 'refresh');
  });

  test('a throwing publish still reaches the epoch leg', () async {
    // The mirror of the resume case, and the more likely one: a publish that
    // no relay accepts is a receive-side fault's most common companion, and
    // it is precisely when the epoch leg needs to run.
    final service = _RecordingCircleService()
      ..repairCircleEpochResult = const EpochRepairApplied();
    final container = _container(service: service, throwOnPublish: true);
    addTearDown(container.dispose);
    await container.read(identityProvider.future);

    final result = await container.read(sharingRepairProvider)();

    expect(result, isA<EpochRepairApplied>());
    expect(_log, contains('publish'));
    expect(_log.where((e) => e == 'epoch'), hasLength(1));
    expect(_log.indexOf('epoch'), greaterThan(_log.lastIndexOf('publish')));
    expect(_log.last, 'refresh');
  });

  test('a throwing refresh still returns the outcome', () async {
    // The chain is awaited inside `_repair`'s `try/finally` with no `catch`, so
    // an uncontained throw here would escape as an unhandled async error: the
    // user loses the outcome they are waiting for AND the raw error lands on
    // the zone handler, which is exactly what Rule 8 forbids.
    final service = _RecordingCircleService()
      ..repairCircleEpochResult =
          const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable);
    final container = _container(service: service, throwOnRefresh: true);
    addTearDown(container.dispose);
    await container.read(identityProvider.future);

    await expectLater(
      container.read(sharingRepairProvider)(),
      completion(isA<EpochRepairSkipped>()),
    );
    expect(_log.last, 'refresh');
  });

  test('the verdict is re-derived after the epoch leg, never before', () async {
    // `refresh()` reads the health storage the epoch leg can change. Running it
    // first would show the user a verdict computed before the repair.
    final service = _RecordingCircleService();
    final container = _container(service: service);
    addTearDown(container.dispose);
    await container.read(identityProvider.future);

    await container.read(sharingRepairProvider)();

    expect(_log.indexOf('epoch'), lessThan(_log.indexOf('refresh')));
  });
}
