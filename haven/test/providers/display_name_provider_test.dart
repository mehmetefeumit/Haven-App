/// [displayNameProvider]: the one name every surface shows the user as.
///
/// The own profile row is that name — what a save writes, the sync publishes
/// and a newer kind-0 from another device replaces. The device-local name is
/// shown only while the row holds none, and is dropped once it does, so a
/// row cleared later never falls back to it.
library;

import 'dart:async';
import 'dart:typed_data';

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
    container.read(memberProfileRefreshProvider.notifier).refreshRoster([
      _identity.pubkeyHex,
    ]);
    await _settle();

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

  group('a row that cannot be read is not a row with no name', () {
    test(
      'the name already shown stays, and the failure names no one',
      () async {
        final logs = LogCapture.install();
        build(row: _row(displayName: 'Bobby New'));
        expect(await shown(), 'Bobby New');

        // The store will not open (the session is handed to the foreground
        // service) when the profile refresh asks again.
        profiles.shouldThrowOnGetOwnProfileText = true;
        container.read(memberProfileRefreshProvider.notifier).refreshRoster([
          _identity.pubkeyHex,
        ]);
        await _settle();

        expect(await shown(), 'Bobby New');
        expect(container.read(displayNameProvider).hasError, isFalse);
        logs
          ..assertContains('[Identity] own profile row not read')
          ..assertNoNeedles(['Bobby New', _identity.pubkeyHex]);
      },
    );

    test('the local name is shown and kept, never dropped', () async {
      build(
        localName: 'Alice',
        row: _row(displayName: 'Bob'),
      );
      profiles.shouldThrowOnGetOwnProfileText = true;

      expect(await shown(), 'Alice');
      expect(identity.localName, 'Alice');
      expect(identity.setDisplayNameCalls, isEmpty);
    });

    test('with no name to keep, the read fails rather than claiming none, '
        'and the next read that works shows the name', () async {
      build(row: _row(displayName: 'Bob'));
      profiles.shouldThrowOnGetOwnProfileText = true;

      await expectLater(shown(), throwsA(isA<ProfileServiceException>()));

      profiles.shouldThrowOnGetOwnProfileText = false;
      container.read(memberProfileRefreshProvider.notifier).refreshRoster([
        _identity.pubkeyHex,
      ]);
      await _settle();
      expect(await shown(), 'Bob');
    });

    test("another identity's failed read never shows the previous one's "
        'name', () async {
      var current = _identity;
      final other = Identity(
        pubkeyHex: 'dd' * 32,
        npub: 'npub1other',
        createdAt: DateTime(2025),
      );
      profiles = MockProfileService(ownProfile: _row(displayName: 'Bob'));
      container = ProviderContainer(
        overrides: [
          identityServiceProvider.overrideWithValue(
            LocalNameIdentityService(identity: _identity),
          ),
          identityProvider.overrideWith((_) async => current),
          profileServiceProvider.overrideWithValue(profiles),
        ],
      );
      addTearDown(container.dispose);
      final held = container.listen(displayNameProvider, (_, _) {});
      addTearDown(held.close);
      expect(await shown(), 'Bob');

      current = other;
      profiles.shouldThrowOnGetOwnProfileText = true;
      container.invalidate(identityProvider);

      expect(await shown(), isNull);
      expect(container.read(displayNameProvider).valueOrNull, isNull);
    });
  });

  test('the name is read without the photo, so holding it does not hold the '
      'photo', () async {
    build(
      row: Profile(
        pubkeyHex: _identity.pubkeyHex,
        displayName: 'Bob',
        pictureBytes: Uint8List.fromList(const [0xFF, 0xD8, 0xFF]),
      ),
    );
    // A surface shows the photo, then goes.
    final photo = container.listen(ownProfileProvider, (_, _) {});
    expect(
      (await container.read(ownProfileProvider.future))?.pictureBytes,
      isNotNull,
    );
    photo.close();
    await _settle();

    expect(await shown(), 'Bob');
    expect(
      container.exists(ownProfileProvider),
      isFalse,
      reason: 'the photo bytes are released while the name is still held',
    );
    expect(
      profiles.methodCalls.where((c) => c.method == 'getOwnProfile').length,
      1,
      reason: 'only the photo surface read the profile with its picture',
    );
  });
}

/// Drains the event queue so the refresh's fire-and-forget work settles —
/// no wall-clock wait.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
