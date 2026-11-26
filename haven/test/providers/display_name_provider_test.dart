/// [displayNameProvider]: the one name every surface shows the user as.
///
/// The own profile row is that name — what a save writes, the sync publishes
/// and a newer kind-0 from another device replaces. The device-local name is
/// shown only while the row holds none, and is dropped once it does, so a
/// row cleared later never falls back to it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/local_name_identity_service.dart';
import '../mocks/mock_profile_service.dart';

final _identity = Identity(
  pubkeyHex: 'cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234',
  npub: 'npub1test',
  createdAt: DateTime(2025),
);

Profile _row({String? displayName, String? name}) => Profile(
  pubkeyHex: _identity.pubkeyHex,
  displayName: displayName,
  name: name,
);

void main() {
  late LocalNameIdentityService identity;
  late MockProfileService profiles;
  late ProviderContainer container;

  void build({String? localName, Profile? row}) {
    identity = LocalNameIdentityService(
      identity: _identity,
      localName: localName,
    );
    profiles = MockProfileService(ownProfile: row);
    container = ProviderContainer(
      overrides: [
        identityServiceProvider.overrideWithValue(identity),
        profileServiceProvider.overrideWithValue(profiles),
      ],
    );
    addTearDown(container.dispose);
    // A mounted self label holds the name, as the member list does.
    final held = container.listen(displayNameProvider, (_, _) {});
    addTearDown(held.close);
  }

  Future<String?> shown() => container.read(displayNameProvider.future);

  test(
    "the row's name wins over a stale local name, which is dropped",
    () async {
      build(
        localName: 'Alice',
        row: _row(displayName: 'Bob'),
      );

      expect(await shown(), 'Bob');
      expect(
        identity.localName,
        isNull,
        reason: 'left behind, a row cleared later would fall back to it',
      );
    },
  );

  test("the row's name field stands in for a blank display name", () async {
    build(
      localName: 'Alice',
      row: _row(displayName: ' ', name: 'Bob'),
    );

    expect(await shown(), 'Bob');
  });

  test(
    'while the row holds no name, the local name is shown and kept',
    () async {
      for (final row in [null, _row(), _row(displayName: '', name: '  ')]) {
        build(localName: 'Alice', row: row);

        expect(await shown(), 'Alice', reason: 'row: $row');
        expect(identity.setDisplayNameCalls, isEmpty, reason: 'row: $row');
      }
    },
  );

  test('a rename published on another device is the name once the profile '
      'refresh writes it to the row', () async {
    build(
      localName: 'Bob',
      row: _row(displayName: 'Bob'),
    );
    expect(await shown(), 'Bob');

    final gate = Completer<void>();
    profiles.refreshGate = gate;
    container.read(memberProfileRefreshProvider.notifier).refreshRoster([
      _identity.pubkeyHex,
    ]);
    await _settle();
    // Rust's `upsert_profile_if_newer` takes the newer kind-0 into the row.
    profiles.ownProfile = _row(displayName: 'Carol');
    gate.complete();
    await _settle();

    expect(await shown(), 'Carol');
  });

  test('a name cleared on another device is not replaced by an old local '
      'one', () async {
    build(
      localName: 'Bob',
      row: _row(displayName: 'Bob'),
    );
    expect(await shown(), 'Bob');

    profiles.ownProfile = _row(displayName: '');
    container.invalidate(ownProfileProvider);

    expect(await shown(), isNull);
  });

  test('a local name that cannot be dropped does not hide the row, and the '
      'failure names no one', () async {
    final logs = LogCapture.install();
    build(
      localName: 'Alice Old',
      row: _row(displayName: 'Bobby New'),
    );
    identity.throwOnSet = true;

    expect(await shown(), 'Bobby New');
    logs
      ..assertContains('[Identity] local display name not dropped')
      ..assertNoNeedles(['Alice Old', 'Bobby New', _identity.pubkeyHex]);
  });
}

/// Drains the event queue so the refresh's fire-and-forget work settles —
/// no wall-clock wait.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
