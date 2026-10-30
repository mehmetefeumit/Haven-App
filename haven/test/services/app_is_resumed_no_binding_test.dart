/// The strict foreground read with NO binding at all.
///
/// Its own file, deliberately: a test binding cannot be un-initialised, so the
/// only way to exercise "there is no binding" is an isolate in which nothing
/// ever initialised one. Nothing here may call `testWidgets` or
/// `TestWidgetsFlutterBinding.ensureInitialized()`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

/// Records the foreground claim each call carried; everything else is never
/// reached here.
class _ClaimRecordingEngine implements LiveSyncFfi {
  final List<bool> claims = [];

  /// Never closed: a stream that ended would read as the engine dying, and
  /// the service would let go of it.
  final StreamController<FfiRelayEvent> _events =
      StreamController<FfiRelayEvent>();

  @override
  Future<void> startSession({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async {}

  @override
  Future<void> resumeAfterBackground({required bool foreground}) async {
    claims.add(foreground);
  }

  @override
  Future<void> claimForeground({required bool foreground}) async {
    claims.add(foreground);
  }

  @override
  Stream<FfiRelayEvent> liveEvents() => _events.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  test('with no binding nothing says the lifecycle is resumed', () {
    expect(
      () => WidgetsBinding.instance,
      throwsA(anything),
      reason: 'premise: this file runs with NO binding. With one, both reads '
          'below would answer the same for an unset lifecycle and the catch '
          'arm this test exists for would never be reached',
    );
    expect(
      appIsResumed(),
      isFalse,
      reason: 'a missing binding is not a foreground: this is the read that '
          'fails closed',
    );
    expect(
      appIsForegrounded(),
      isTrue,
      reason: 'control: the looser read answers yes here, which is why it '
          'must never be the claim',
    );
  });

  test('with no binding no call site claims the foreground', () async {
    final engine = _ClaimRecordingEngine();
    final service = NostrSubscriptionService(
      router: LiveEventRouter(
        circleService: MockCircleService.new,
        circlesSnapshot: () async => const [],
        secretBytes: () async => const [],
        parseLocation: (_, _) async => null,
        ingestLocation: (_, _) async {},
        reconcileRoster: (_) async {},
        onLocationsChanged: () {},
        onGroupUpdated: (_) {},
        onInvitationReceived: () {},
        onStatus: (_) {},
      ),
      engineFactory: () async => engine,
    );

    await service.start(groups: const [], inboxRelays: const []);
    await service.resumeAfterBackground();
    await service.claimForeground();

    expect(
      engine.claims,
      [false],
      reason: 'the re-anchor is refused its claim, and neither the start nor '
          'the heal asks the engine for one',
    );
  });
}
