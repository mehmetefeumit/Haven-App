/// Pins the production wiring of `profileServiceProvider`: a photo save made
/// while the MLS session is handed to the Android foreground service waits
/// for the handoff to end, then opens, instead of failing at once.
///
/// The real `NostrCircleService` is used, so the order is the real one; the
/// open itself cannot succeed without the Rust bridge, which is where this
/// stops. The save completing end to end on that path is proved on device by
/// the e2e photo leg.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_relay_service.dart';

class _UnusedIdentityService implements IdentityService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected: ${invocation.memberName}');
}

class _ThrowingDataDirectory implements DataDirectoryProvider {
  @override
  Future<String> getDataDirectory() async =>
      throw Exception('stop before the bridge');
}

void main() {
  final bytes = Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  ({ProviderContainer container, NostrCircleService circle, List<int> opens})
  build() {
    final opens = <int>[];
    final circle = NostrCircleService(
      relayService: MockRelayService(),
      dataDirectoryProvider: _ThrowingDataDirectory(),
      // The open's first step: counting it counts the opens attempted.
      keyringInitializer: () async => opens.add(opens.length),
      isForegrounded: () => false,
    );
    final container = ProviderContainer(
      overrides: [
        circleServiceProvider.overrideWithValue(circle),
        identityServiceProvider.overrideWithValue(_UnusedIdentityService()),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, circle: circle, opens: opens);
  }

  test('a photo save made while handed off waits for the handoff to end '
      'instead of failing', () async {
    final h = build();
    h.circle.releaseForHandoff();

    Object? outcome;
    unawaited(
      h.container
          .read(profileServiceProvider)
          .setOwnAvatar(bytes)
          .then<Object?>((p) => p, onError: (Object e) => e)
          .then((o) => outcome = o),
    );
    await pumpEventQueue();
    expect(
      outcome,
      isNull,
      reason:
          'failing now is "Could not update your photo" for a photo the '
          'user just chose',
    );
    expect(h.opens, isEmpty, reason: 'no open while the handoff holds');

    h.circle.endSessionHandoff();
    await pumpEventQueue();
    expect(h.opens, hasLength(1), reason: 'the open runs once it ended');
    expect(outcome, isA<ProfileServiceException>());
  });

  test('past kHandoffEndWait the save is tried anyway, and fails closed while '
      'the app is not in front', () {
    fakeAsync((async) {
      final h = build();
      h.circle.releaseForHandoff();
      Object? outcome;
      unawaited(
        h.container
            .read(profileServiceProvider)
            .setOwnAvatar(bytes)
            .then<Object?>((p) => p, onError: (Object e) => e)
            .then((o) => outcome = o),
      );
      async.elapse(kHandoffEndWait - const Duration(microseconds: 1));
      expect(outcome, isNull);
      async
        ..elapse(const Duration(microseconds: 1))
        ..flushMicrotasks();
      expect(outcome, isA<ProfileServiceException>());
      expect(h.opens, isEmpty, reason: 'the handoff refusal precedes the open');
    });
  });
}
