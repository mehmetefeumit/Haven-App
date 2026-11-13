/// The member the user confirmed is the member invited.
///
/// `KeyPackageData.pubkey` is the verified author Rust returned with the
/// KeyPackage (`MemberKeyPackageFfi.authorNpub`), and it is what the confirm
/// screen names. Handing it back with the package lets Rust refuse a package
/// that does not name it, because the Welcome goes to the package's signer.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../helpers/fake_change_driver.dart';
import '../mocks/mock_relay_service.dart';

const _authors = [
  'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg',
  'npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m',
];

List<KeyPackageData> _packages() => [
  for (final author in _authors)
    KeyPackageData(
      pubkey: author,
      eventJson: '{"kind":30443}',
      relays: const ['wss://relay.example.com'],
      nip65WriteRelays: const [],
    ),
];

class _CapturingManager implements CircleManagerFfi {
  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async => const [];

  @override
  Future<CircleWithMembersFfi?> getCircle({
    required List<int> mlsGroupId,
  }) async => CircleWithMembersFfi(
    circle: CircleFfi(
      mlsGroupId: Uint8List.fromList(mlsGroupId),
      nostrGroupId: Uint8List.fromList(List<int>.filled(32, 1)),
      displayName: 'Circle',
      circleType: 'location_sharing',
      relays: const ['wss://relay.example'],
      createdAt: 1700000000,
      updatedAt: 1700000000,
    ),
    membershipStatus: 'accepted',
    members: const [],
    engineState: CircleEngineStateFfi.live,
  );

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _VerifyingRelayManager implements RelayManagerFfi {
  _VerifyingRelayManager(this.verifiedAuthor);

  final String verifiedAuthor;

  /// The inviter's manager and the target circle the fetch was made for.
  CircleManagerFfi? askedBy;
  Uint8List? askedFor;

  @override
  Future<MemberLookupFfi> fetchMemberKeypackage({
    required String pubkey,
    required CircleManagerFfi circle,
    Uint8List? mlsGroupId,
  }) async {
    askedBy = circle;
    askedFor = mlsGroupId;
    return MemberLookupFfi(
      verdict: MemberLookupVerdictFfi.found,
      member: MemberKeyPackageFfi(
        keyPackageJson: '{"kind":30443}',
        inboxRelays: const ['wss://inbox.example.com'],
        nip65Relays: const ['wss://nip65.example.com'],
        nip65WriteRelays: const ['wss://nip65-write.example.com'],
        authorNpub: verifiedAuthor,
      ),
    );
  }

  /// What the last driven create was handed: its members and its word.
  ({List<MemberKeyPackageFfi> members, bool foreground})? created;

  @override
  Future<CircleCreationOutcomeFfi> createCircleDriven({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
    required List<MemberKeyPackageFfi> members,
    required String name,
    required String circleType,
    required List<String> relays,
    required bool foreground,
    String? description,
  }) async {
    created = (members: members, foreground: foreground);
    return const CircleCreationOutcomeFfi(
      welcomesSent: 0,
      welcomesTotal: 0,
      unsentRecipients: [],
    );
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

const _reason =
    'without the author Rust cannot refuse a package that names someone '
    'other than the member on the confirm screen';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creating a circle hands each key package back under its verified '
      'author', () async {
    final driver = FakeChangeDriver();

    await NostrCircleService.withInjectedManager(
      relayService: MockRelayService(),
      injectedManager: _CapturingManager(),
      changeDriver: driver,
    ).createCircle(
      identitySecretBytes: List<int>.filled(32, 7),
      memberKeyPackages: _packages(),
      name: 'New Circle',
      circleType: CircleType.locationSharing,
    );

    expect(
      driver.created?.members.map((m) => m.authorNpub),
      _authors,
      reason: _reason,
    );
  });

  test('adding members hands each key package back under its verified '
      'author', () async {
    final driver = FakeChangeDriver();

    await NostrCircleService.withInjectedManager(
      relayService: MockRelayService(),
      injectedManager: _CapturingManager(),
      changeDriver: driver,
    ).addMember(mlsGroupId: const [9, 9, 9], memberKeyPackages: _packages());

    expect(
      driver.members?.map((m) => m.authorNpub),
      _authors,
      reason: _reason,
    );
  });

  test("the relay service's create hands the driven create its members and "
      "the caller's foreground word, unchanged", () async {
    final manager = _VerifyingRelayManager(_authors.first);
    final relay = NostrRelayService.withInjectedManager(manager);
    final members = [
      for (final p in _packages())
        MemberKeyPackageFfi(
          keyPackageJson: p.eventJson,
          inboxRelays: p.relays,
          nip65Relays: p.nip65Relays,
          nip65WriteRelays: p.nip65WriteRelays,
          authorNpub: p.pubkey,
        ),
    ];

    for (final foreground in [false, true]) {
      await relay.createCircle(
        circle: _CapturingManager(),
        identitySecretBytes: List<int>.filled(32, 7),
        members: members,
        name: 'New Circle',
        circleType: 'location_sharing',
        relays: const ['wss://relay.example.com'],
        foreground: foreground,
      );
      expect(manager.created?.foreground, foreground);
      expect(manager.created?.members, same(members));
    }
  });

  test('a fetched key package is labelled with the author Rust verified, '
      'never the label it was asked for', () async {
    final relay = NostrRelayService.withInjectedManager(
      _VerifyingRelayManager(_authors.first),
      circleManagerFactory: () async => _CapturingManager(),
    );

    final fetched = await relay.fetchKeyPackage(_authors.last);

    expect(fetched?.pubkey, _authors.first);
  });

  test("a fetched key package carries the invitee's three relay lists, and "
      'each reaches the driver on a create and on an add', () async {
    final fetched = await NostrRelayService.withInjectedManager(
      _VerifyingRelayManager(_authors.first),
      circleManagerFactory: () async => _CapturingManager(),
    ).fetchKeyPackage(_authors.first);
    expect(fetched?.relays, ['wss://inbox.example.com']);
    expect(fetched?.nip65Relays, ['wss://nip65.example.com']);
    expect(
      fetched?.nip65WriteRelays,
      ['wss://nip65-write.example.com'],
      reason:
          'the write set is one of the lists a picked circle avoids; '
          'dropped here, nothing later can restore it',
    );

    final driver = FakeChangeDriver();
    final service = NostrCircleService.withInjectedManager(
      relayService: MockRelayService(),
      injectedManager: _CapturingManager(),
      changeDriver: driver,
    );
    await service.createCircle(
      identitySecretBytes: List<int>.filled(32, 7),
      memberKeyPackages: [fetched!],
      name: 'New Circle',
      circleType: CircleType.locationSharing,
    );
    await service.addMember(
      mlsGroupId: const [9, 9, 9],
      memberKeyPackages: [fetched],
    );

    for (final members in [driver.created!.members, driver.members!]) {
      expect(members.single.inboxRelays, ['wss://inbox.example.com']);
      expect(members.single.nip65Relays, ['wss://nip65.example.com']);
      expect(members.single.nip65WriteRelays, [
        'wss://nip65-write.example.com',
      ]);
    }
  });

  test("a key package is fetched for the inviter's own circle manager and "
      'the circle the person is being added to', () async {
    final inviter = _CapturingManager();
    final manager = _VerifyingRelayManager(_authors.first);
    final relay = NostrRelayService.withInjectedManager(
      manager,
      circleManagerFactory: () async => inviter,
    );

    await relay.fetchKeyPackage(_authors.first, mlsGroupId: const [7, 7, 7]);
    expect(manager.askedBy, same(inviter));
    expect(manager.askedFor, Uint8List.fromList(const [7, 7, 7]));

    await relay.fetchKeyPackage(_authors.first);
    expect(
      manager.askedFor,
      isNull,
      reason: 'no circle yet: the package is chosen for a new one',
    );
  });

  test('a relay service with no circle manager refuses to pick a key '
      'package, and says so as a relay failure', () async {
    final manager = _VerifyingRelayManager(_authors.first);
    final relay = NostrRelayService.withInjectedManager(manager);

    await expectLater(
      relay.fetchKeyPackage(_authors.first),
      throwsA(isA<RelayServiceException>()),
    );
    expect(
      manager.askedBy,
      isNull,
      reason: 'which package fits depends on the inviter, so none is fetched',
    );
  });
}
