/// A member profile read that failed because the circle session was closed is
/// read again once the session opens, and shows its last-known name and
/// picture until then.
///
/// The real [NostrCircleService], [NostrProfileService] and
/// [memberProfileProvider], over a scripted bridge: only the Rust open
/// (`CircleManagerFfi.newInstance`) and the manager it hands back are fakes.
/// A separate file because `RustLib.initMock` replaces the bridge for the
/// whole isolate, and the service tests elsewhere rely on an open that cannot
/// succeed.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_scope.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_profile_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/background_task_fakes.dart';

const _pubkey =
    'cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234cccc1234';

/// The bridge's open, handing back [manager].
class _ScriptedBridge implements RustLibApi {
  _ScriptedBridge(this.manager);

  final _ProfileManager manager;
  int opens = 0;

  @override
  Future<CircleManagerFfi> crateApiCircleManagerFfiNew({
    required String dataDir,
    required List<int> identitySecretBytes,
  }) async {
    opens++;
    return manager;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A manager whose profile store holds one member, named [displayName], with
/// a cached thumbnail.
class _ProfileManager extends FakeCircleManager {
  String displayName = 'Bo';
  int reads = 0;
  final Uint8List thumbnail = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 9]);

  @override
  Future<ProfileMetadataFfi?> getCachedProfile({
    required String pubkeyHex,
  }) async {
    reads++;
    return ProfileMetadataFfi(
      pubkeyHex: pubkeyHex,
      npub: 'npub1member',
      displayName: displayName,
      hasPicture: true,
      isKnown: true,
      fetchedAt: 1,
      relayAnswer: OwnProfileRelayAnswerFfi.unanswered,
      pictureSha256Hex: 'hash',
    );
  }

  @override
  Future<Uint8List?> getProfileThumbnail({required String pubkeyHex}) async =>
      thumbnail;

  // The service disposes the handle it gives away at a handoff.
  @override
  void dispose() {}
}

class _FixedDataDirectory implements DataDirectoryProvider {
  @override
  Future<String> getDataDirectory() async => '/haven-test-data';
}

class _NoIdentity extends Fake implements IdentityService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedBridge bridge;

  setUpAll(() {
    bridge = _ScriptedBridge(_ProfileManager());
    RustLib.initMock(api: bridge);
  });

  setUp(() {
    bridge
      ..opens = 0
      ..manager.reads = 0
      ..manager.displayName = 'Bo';
  });

  var foregrounded = true;

  NostrCircleService circleService() {
    foregrounded = true;
    return NostrCircleService(
      relayService: FakeNostrRelayService(),
      dataDirectoryProvider: _FixedDataDirectory(),
      keyringInitializer: () async {},
      identitySecretBytesProvider: () async => List<int>.filled(32, 7),
      isForegrounded: () => foregrounded,
    );
  }

  /// A container whose member is watched, as a member row watches it.
  ProviderContainer watching(NostrCircleService svc) {
    final container = ProviderContainer(
      overrides: [
        circleServiceProvider.overrideWithValue(svc),
        profileServiceProvider.overrideWithValue(
          NostrProfileService(
            identityService: _NoIdentity(),
            circleManagerFactory: svc.getCircleManagerFfi,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(memberProfileProvider(_pubkey), (_, _) {});
    return container;
  }

  /// Backgrounds the app on Android: the UI isolate hands the session to the
  /// foreground service, and every read it makes fails until it is back.
  void handOff(NostrCircleService svc) {
    foregrounded = false;
    svc.releaseForHandoff();
  }

  /// The resume: the handoff ends and the next opener takes the session.
  Future<void> resume(NostrCircleService svc) async {
    foregrounded = true;
    svc.endSessionHandoff();
    await svc.initialize();
    // The re-read is scheduled by the open, not awaited by its caller.
    await pumpEventQueue();
  }

  Future<void> settle(ProviderContainer container) async {
    await container.pump();
    await pumpEventQueue();
  }

  AsyncValue<Profile?> state(ProviderContainer container) =>
      container.read(memberProfileProvider(_pubkey));

  test('a read refused during a handoff keeps the name and photo, and is read '
      'again once the session opens', () async {
    final svc = circleService();
    final container = watching(svc);
    await container.read(memberProfileProvider(_pubkey).future);
    expect(state(container).valueOrNull?.displayName, 'Bo');

    handOff(svc);
    // What the batch refresh's `finally` does whatever the refresh's outcome.
    container.invalidate(memberProfileProvider);
    await settle(container);

    expect(state(container).error, isA<ProfileServiceException>());
    expect(state(container).valueOrNull?.displayName, 'Bo');
    expect(state(container).valueOrNull?.pictureBytes, isNotNull);
    expect(bridge.manager.reads, 1, reason: 'the refused read reached no row');

    bridge.manager.displayName = 'Bo Renamed';
    await resume(svc);
    await settle(container);

    expect(bridge.manager.reads, 2);
    expect(state(container).hasError, isFalse);
    expect(state(container).valueOrNull?.displayName, 'Bo Renamed');
  });

  test('a successful read is not read again at an open', () async {
    final svc = circleService();
    final container = watching(svc);
    await container.read(memberProfileProvider(_pubkey).future);

    handOff(svc);
    await resume(svc);
    await settle(container);

    expect(bridge.opens, 2, reason: 'premise: the session opened again');
    expect(bridge.manager.reads, 1);
  });

  test('a failed read superseded by a successful one does not read again at '
      'the open that read made', () async {
    final svc = circleService();
    handOff(svc);
    final container = watching(svc);
    await settle(container);
    expect(state(container).error, isA<ProfileServiceException>());

    // The resume lapses the handoff, and a refresh re-reads before any other
    // opener: that read makes the open the failed one was waiting for.
    foregrounded = true;
    svc.endSessionHandoff();
    container.invalidate(memberProfileProvider);
    await settle(container);
    await settle(container);

    expect(state(container).valueOrNull?.displayName, 'Bo');
    expect(
      bridge.manager.reads,
      1,
      reason: 'the superseded read must not re-read on its own',
    );
  });

  test('a member released at logout is not read again when the session '
      'opens', () async {
    final svc = circleService();
    handOff(svc);
    final container = ProviderContainer(
      overrides: [
        circleServiceProvider.overrideWithValue(svc),
        profileServiceProvider.overrideWithValue(
          NostrProfileService(
            identityService: _NoIdentity(),
            circleManagerFactory: svc.getCircleManagerFfi,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    // A row read it while the session was handed off, then left.
    container.listen(memberProfileProvider(_pubkey), (_, _) {}).close();
    await settle(container);

    identityScopedProviders.forEach(container.invalidate);
    await settle(container);
    await resume(svc);
    await settle(container);

    expect(bridge.opens, 1, reason: 'premise: the session opened');
    expect(container.exists(memberProfileProvider(_pubkey)), isFalse);
    expect(bridge.manager.reads, 0);
  });
}
