/// Tests for who a staged or typed npub resolves to on the invite screens.
///
/// The promises: a co-member is answered from the local directory with no
/// network request; anyone else is looked up ONCE, however the directory or
/// the row rebuilds; a degraded or unfinished directory read asks nothing; a
/// resolved person's picture is downloaded once and never for someone who did
/// not resolve; and nothing identifying reaches a log on the way.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/member_directory_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/stranger_profile_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../helpers/log_capture.dart';
import '../mocks/mock_member_directory_service.dart';
import '../mocks/mock_profile_service.dart';

const _aliceHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';
const _strangerNpub =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5';
const _strangerHex =
    'de1e00000000000000000000000000000000000000000000000000000000fac3';

MemberDirectory _aliceDirectory() => buildDirectory(
  entries: const [
    DirectoryEntry(
      pubkeyHex: _aliceHex,
      npub: _aliceNpub,
      tier: DirectoryTier.current,
    ),
  ],
  profiles: const {
    _aliceHex: Profile(pubkeyHex: _aliceHex, displayName: 'Alice Aardvark'),
  },
  fold: (value) => value.toLowerCase(),
);

ProviderContainer _container({
  required MockMemberDirectoryService directory,
  required MockProfileService profiles,
}) {
  final container = ProviderContainer(
    overrides: [
      memberDirectoryServiceProvider.overrideWithValue(directory),
      profileServiceProvider.overrideWithValue(profiles),
      circlesProvider.overrideWith((ref) => Future.value(const <Circle>[])),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

int _calls(MockProfileService service, String method) =>
    service.methodCalls.where((c) => c.method == method).length;

/// Holds [npub]'s staged identity the way a host page does, and waits until
/// the directory (and any lookup it led to) has answered.
Future<ProviderSubscription<StagedMemberIdentity?>> _hold(
  ProviderContainer container,
  String npub,
) async {
  final subscription = container.listen(
    stagedMemberIdentityProvider(npub),
    (_, _) {},
  );
  await container.read(memberDirectoryProvider.future);
  await container.pump();
  return subscription;
}

void main() {
  group('stagedMemberIdentityProvider', () {
    test('a co-member is named from the directory with no lookup', () async {
      final profiles = MockProfileService();
      final container = _container(
        directory: MockMemberDirectoryService(directory: _aliceDirectory()),
        profiles: profiles,
      );

      final held = await _hold(container, _aliceNpub);

      expect(held.read(), (pubkeyHex: _aliceHex, name: 'Alice Aardvark'));
      expect(_calls(profiles, 'resolveTypedStrangerProfile'), 0);
      expect(_calls(profiles, 'downloadMemberPictures'), 0);
    });

    test('a stranger is looked up once, named, and their picture fetched '
        'once', () async {
      final profiles = MockProfileService()
        ..strangerProfiles[_strangerNpub] = const Profile(
          pubkeyHex: _strangerHex,
          name: 'cousin',
          displayName: 'Distant Cousin',
        );
      final container = _container(
        directory: MockMemberDirectoryService(directory: _aliceDirectory()),
        profiles: profiles,
      );

      final held = await _hold(container, _strangerNpub);
      await container.read(
        strangerProfileResolveProvider(_strangerNpub).future,
      );
      await container.pump();

      expect(held.read(), (pubkeyHex: _strangerHex, name: 'Distant Cousin'));
      expect(_calls(profiles, 'resolveTypedStrangerProfile'), 1);
      expect(
        profiles.methodCalls
            .where((c) => c.method == 'downloadMemberPictures')
            .single
            .args['pubkeyHexes'],
        [_strangerHex],
      );
    });

    test('a stranger whose picture is already cached downloads none', () async {
      final profiles = MockProfileService()
        ..strangerProfiles[_strangerNpub] = Profile(
          pubkeyHex: _strangerHex,
          displayName: 'Distant Cousin',
          pictureBytes: Uint8List.fromList([1, 2, 3]),
        );
      final container = _container(
        directory: MockMemberDirectoryService(directory: _aliceDirectory()),
        profiles: profiles,
      );

      await _hold(container, _strangerNpub);
      await container.read(
        strangerProfileResolveProvider(_strangerNpub).future,
      );
      await container.pump();

      expect(_calls(profiles, 'downloadMemberPictures'), 0);
    });

    test('a stranger with no published name keeps the key alone, and an '
        'unresolved one downloads nothing', () async {
      final profiles = MockProfileService()
        ..strangerProfiles[_strangerNpub] = const Profile(
          pubkeyHex: _strangerHex,
          displayName: '  ',
        );
      final container = _container(
        directory: MockMemberDirectoryService(),
        profiles: profiles,
      );

      final held = await _hold(container, _strangerNpub);
      await container.read(
        strangerProfileResolveProvider(_strangerNpub).future,
      );
      await container.pump();
      expect(held.read(), (pubkeyHex: _strangerHex, name: null));

      profiles.strangerProfiles.clear();
      final other = await _hold(container, _aliceNpub);
      await container.read(strangerProfileResolveProvider(_aliceNpub).future);
      await container.pump();
      expect(other.read(), isNull);
      expect(
        profiles.methodCalls
            .where((c) => c.method == 'downloadMemberPictures')
            .map((c) => c.args['pubkeyHexes']),
        [
          [_strangerHex],
        ],
        reason: 'the unresolved npub must not lead to a download',
      );
    });

    test('a degraded directory read asks nothing', () async {
      final profiles = MockProfileService();
      final container = _container(
        directory: MockMemberDirectoryService(
          directory: MemberDirectory.readFailed,
        ),
        profiles: profiles,
      );

      final held = await _hold(container, _strangerNpub);

      expect(held.read(), isNull);
      expect(_calls(profiles, 'resolveTypedStrangerProfile'), 0);
    });

    test('a failed directory read asks nothing', () async {
      final profiles = MockProfileService();
      final directory = MockMemberDirectoryService()
        ..shouldThrowOnLoadDirectory = true;
      final container = _container(directory: directory, profiles: profiles);

      final held = container.listen(
        stagedMemberIdentityProvider(_strangerNpub),
        (_, _) {},
      );
      await expectLater(
        container.read(memberDirectoryProvider.future),
        throwsStateError,
      );
      await container.pump();

      expect(held.read(), isNull);
      expect(_calls(profiles, 'resolveTypedStrangerProfile'), 0);
    });

    test('nothing is asked while the directory is still on its first load, '
        'so a co-member is never mistaken for a stranger', () async {
      final profiles = MockProfileService();
      final directory = MockMemberDirectoryService(directory: _aliceDirectory())
        ..loadGate = Completer<void>();
      final container = _container(directory: directory, profiles: profiles);

      final held = container.listen(
        stagedMemberIdentityProvider(_aliceNpub),
        (_, _) {},
      );
      await container.pump();
      expect(held.read(), isNull);
      expect(_calls(profiles, 'resolveTypedStrangerProfile'), 0);

      directory.loadGate!.complete();
      await container.read(memberDirectoryProvider.future);
      await container.pump();

      expect(held.read(), (pubkeyHex: _aliceHex, name: 'Alice Aardvark'));
      expect(_calls(profiles, 'resolveTypedStrangerProfile'), 0);
    });

    test(
      'a directory refresh while a stranger is held asks nothing again',
      () async {
        final profiles = MockProfileService()
          ..strangerProfiles[_strangerNpub] = const Profile(
            pubkeyHex: _strangerHex,
            displayName: 'Distant Cousin',
          );
        final directory = MockMemberDirectoryService(
          directory: _aliceDirectory(),
        );
        final container = _container(directory: directory, profiles: profiles);

        final held = await _hold(container, _strangerNpub);
        await container.read(
          strangerProfileResolveProvider(_strangerNpub).future,
        );
        await container.pump();

        directory.loadGate = Completer<void>();
        container.invalidate(memberDirectoryProvider);
        await container.pump();
        expect(held.read(), (
          pubkeyHex: _strangerHex,
          name: 'Distant Cousin',
        ), reason: 'a refresh keeps the previous answer on screen');
        directory.loadGate!.complete();
        await container.read(memberDirectoryProvider.future);
        await container.pump();

        expect(held.read(), (pubkeyHex: _strangerHex, name: 'Distant Cousin'));
        expect(_calls(profiles, 'resolveTypedStrangerProfile'), 1);
        expect(_calls(profiles, 'downloadMemberPictures'), 1);
      },
    );
  });

  group('strangerProfileResolveProvider', () {
    test(
      're-watching an npub while its lookup is in flight reuses it',
      () async {
        final gate = Completer<void>();
        final profiles = MockProfileService()
          ..resolveTypedStrangerProfileGate = gate;
        final container = _container(
          directory: MockMemberDirectoryService(),
          profiles: profiles,
        );

        final first = container.listen(
          strangerProfileResolveProvider(_strangerNpub),
          (_, _) {},
        );
        await container.pump();
        first.close();
        await container.pump();
        container.listen(
          strangerProfileResolveProvider(_strangerNpub),
          (_, _) {},
        );
        gate.complete();
        await container.read(
          strangerProfileResolveProvider(_strangerNpub).future,
        );

        expect(_calls(profiles, 'resolveTypedStrangerProfile'), 1);
      },
    );

    test('a failed lookup logs no identifier', () async {
      final capture = LogCapture.install();
      final profiles = MockProfileService()
        ..shouldThrowOnResolveTypedStrangerProfile = true;
      final container = _container(
        directory: MockMemberDirectoryService(),
        profiles: profiles,
      );

      final lookup = strangerProfileResolveProvider(_strangerNpub);
      container.listen(lookup, (_, _) {});
      final result = await container.read(lookup.future);

      expect(result, isNull);
      capture
        ..restore()
        ..assertContains('strangerProfileResolveProvider')
        ..assertNoNeedles([_strangerNpub, _strangerHex]);
    });
  });

  group('strangerPictureProvider', () {
    test('one download per pubkey, however often it is watched while in '
        'flight', () async {
      final gate = Completer<void>();
      final profiles = MockProfileService()..pictureGate = gate;
      final container = _container(
        directory: MockMemberDirectoryService(),
        profiles: profiles,
      );

      final first = container.listen(
        strangerPictureProvider(_strangerHex),
        (_, _) {},
      );
      await container.pump();
      first.close();
      await container.pump();
      container.listen(strangerPictureProvider(_strangerHex), (_, _) {});
      gate.complete();
      await container.read(strangerPictureProvider(_strangerHex).future);

      expect(_calls(profiles, 'downloadMemberPictures'), 1);
    });
  });
}
