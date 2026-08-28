/// Unit tests for [contactNicknameProvider].
///
/// Verifies:
/// - Returns the petname the user saved for that pubkey.
/// - Returns null when no petname is saved.
/// - Returns null (swallows, never throws) when the storage read fails.
/// - Two different pubkeys use independent provider instances.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/contact_nickname_provider.dart';
import 'package:haven/src/providers/service_providers.dart';

import '../mocks/mock_circle_service.dart';

void main() {
  const pubkeyA =
      'aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234aaaa1234';
  const pubkeyB =
      'bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234bbbb1234';

  ProviderContainer makeContainer(MockCircleService svc) {
    return ProviderContainer(
      overrides: [circleServiceProvider.overrideWithValue(svc)],
    );
  }

  test('returns the petname the user saved for the pubkey', () async {
    final svc = MockCircleService()..nicknames[pubkeyA] = 'Mum';
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final result = await container.read(
      contactNicknameProvider(pubkeyA).future,
    );

    expect(result, 'Mum');
  });

  test('returns null when no petname is saved', () async {
    final svc = MockCircleService();
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final result = await container.read(
      contactNicknameProvider(pubkeyA).future,
    );

    expect(result, isNull);
    expect(svc.methodCalls, contains('getContactDisplayName'));
  });

  test('returns null (does not throw) when the read fails', () async {
    // Every surface that shows a name treats it as a convenience, so a
    // failed contact-table read must degrade to "no nickname" rather than
    // put an error state in front of the user.
    final svc = MockCircleService()..shouldThrowOnGetContactDisplayName = true;
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    final result = await container.read(
      contactNicknameProvider(pubkeyA).future,
    );

    expect(result, isNull);
  });

  test('two different pubkeys use independent provider instances', () async {
    final svc = MockCircleService()
      ..nicknames[pubkeyA] = 'Mum'
      ..nicknames[pubkeyB] = 'Dad';
    final container = makeContainer(svc);
    addTearDown(container.dispose);

    expect(
      await container.read(contactNicknameProvider(pubkeyA).future),
      'Mum',
    );
    expect(
      await container.read(contactNicknameProvider(pubkeyB).future),
      'Dad',
    );
    expect(
      svc.methodCalls.where((call) => call == 'getContactDisplayName'),
      hasLength(2),
    );
  });
}
