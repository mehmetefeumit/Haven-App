// The Dart side of the Bluetooth mesh bridge, behind its build flag
// (`docs/BLUETOOTH_MESH_PLAN.md` §5, §7.5–§7.7, §16 "M2g-2a").
//
// Three promises:
//
//  * with `HAVEN_MESH` off — the default — NO Dart code calls a mesh entry,
//    whatever the app does: mesh cannot be turned on, no mesh key is stored,
//    nothing is passed on to a relay;
//  * with it on, the state is what the bridge reports and nothing else, and
//    a mesh an earlier process left on gets its engine back when the state
//    is first read;
//  * what a mesh drive read goes where a relay receive's results go, asks no
//    relay for anything, and never fails its caller.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/identity_scope.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/mesh_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_mesh.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

const _self =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peer =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Identity implements IdentityService {
  @override
  Future<Identity?> getIdentity() async =>
      Identity(pubkeyHex: _self, npub: 'npub1self', createdAt: DateTime(2025));

  @override
  Future<String> getPubkeyHex() async => _self;

  @override
  Future<String?> getDisplayName() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

/// A pool that records every driven entry made on it.
class _Pool implements RelayManagerFfi {
  final List<String> calls = [];

  @override
  Future<MeshDriveFfi> meshDriveDriven({
    required CircleManagerFfi circle,
  }) async {
    calls.add('meshDriveDriven');
    return const MeshDriveFfi(replayed: [], errored: false, more: false);
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('${invocation.memberName}');
    throw UnimplementedError('unexpected call: ${invocation.memberName}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A container over the REAL mesh service provider: a recording bridge
  /// and a recording pool stand where the Rust bridge would.
  ({ProviderContainer container, RecordingMeshBridge bridge, _Pool pool})
  bridged({required bool? flag}) {
    final bridge = RecordingMeshBridge();
    final pool = _Pool();
    final relay = NostrRelayService(openPool: () async => pool);
    final container = ProviderContainer(
      overrides: [
        if (flag != null) meshEnabledProvider.overrideWithValue(flag),
        meshBridgeProvider.overrideWithValue(bridge),
        identityServiceProvider.overrideWithValue(_Identity()),
        relayServiceProvider.overrideWithValue(relay),
        circleServiceProvider.overrideWithValue(
          NostrCircleService.withInjectedManager(
            relayService: relay,
            injectedManager: FakeMeshSession(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, bridge: bridge, pool: pool);
  }

  /// Everything the app can ask of the mesh, each once.
  Future<void> everyEntry(ProviderContainer container) async {
    await container.read(meshProvider.future);
    final mesh = container.read(meshProvider.notifier);
    await mesh.turnOn();
    await mesh.keepOn();
    await mesh.refresh();
    await mesh.isOn();
    await mesh.drive();
    await mesh.sharingStopped();
    await mesh.resetCounts();
    await mesh.turnOff();
  }

  group('the build flag', () {
    test('is off unless a build asks for the mesh', () {
      expect(meshEnabled, isFalse);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(meshEnabledProvider), isFalse);
    });

    test(
      'off: no mesh entry is called, whatever is asked of the mesh',
      () async {
        // Unset, as every shipped build has it, and explicitly off.
        for (final flag in [null, false]) {
          final t = bridged(flag: flag);

          await everyEntry(t.container);

          expect(t.bridge.calls, isEmpty, reason: 'flag: $flag');
          expect(t.pool.calls, isEmpty, reason: 'flag: $flag');
          expect(t.container.read(meshServiceProvider), isNull);
          expect(
            t.container.read(meshProvider),
            const AsyncData<MeshStatsFfi?>(null),
            reason: 'a build without the mesh has no mesh state',
          );
          final mesh = t.container.read(meshProvider.notifier);
          expect(await mesh.turnOn(), MeshTurnOn.failed);
          expect(await mesh.isOn(), isFalse);
        }
      },
    );

    test('on: the same asks reach the bridge — the proof above is not of a '
        'mesh nothing drives', () async {
      final t = bridged(flag: true);

      await everyEntry(t.container);

      expect(t.bridge.calls.toSet(), {
        'resume',
        'start',
        'keepOn',
        'stats',
        'sharingStopped',
        'resetCounts',
        'stop',
      });
      expect(t.pool.calls, ['meshDriveDriven']);
    });
  });

  group('a mesh an earlier process left on', () {
    test('gets its engine back when the state is first read, before any '
        'other entry, and once', () async {
      final t = bridged(flag: true)
        ..bridge.resumeAnswer = MeshStartFfi.started
        ..bridge.statsAnswer = meshState(on: true, onForMs: 60000);

      final state = await t.container.read(meshProvider.future);
      await t.container.read(meshProvider.notifier).refresh();

      expect(t.bridge.calls, ['resume', 'stats', 'stats']);
      expect(state!.on_, isTrue);
      expect(state.onForMs, BigInt.from(60000));
    });

    test(
      'is not asked for with no identity: no manager is opened for one',
      () async {
        final bridge = RecordingMeshBridge();
        final relay = NostrRelayService(openPool: () async => _Pool());
        final container = ProviderContainer(
          overrides: [
            meshEnabledProvider.overrideWithValue(true),
            meshBridgeProvider.overrideWithValue(bridge),
            relayServiceProvider.overrideWithValue(relay),
            identityProvider.overrideWith((ref) async => null),
            circleServiceProvider.overrideWithValue(
              NostrCircleService.withInjectedManager(
                relayService: relay,
                injectedManager: FakeMeshSession(),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(meshProvider.future),
          throwsA(isA<MeshServiceException>()),
        );
        expect(bridge.calls, isEmpty);
      },
    );
  });

  group('the state is what the bridge reports', () {
    ({ProviderContainer container, FakeMeshService mesh}) faked() {
      final mesh = FakeMeshService();
      final container = ProviderContainer(
        overrides: [meshServiceProvider.overrideWithValue(mesh)],
      );
      addTearDown(container.dispose);
      return (container: container, mesh: mesh);
    }

    test('whole: on, linked, the time left and the four counts', () async {
      final t = faked();
      final reported = MeshStatsFfi(
        on_: true,
        linked: true,
        onForMs: BigInt.from(123456),
        fromCirclesSinceOn: BigInt.from(3),
        passedOnSinceOn: BigInt.from(40),
        fromCirclesTotal: BigInt.from(7),
        passedOnTotal: BigInt.from(900),
      );
      t.mesh.statsAnswer = reported;

      expect(await t.container.read(meshProvider.future), same(reported));
    });

    test('turning mesh on: started and already-on are on, off is not — and '
        'the state is read again each time', () async {
      for (final (answer, on) in [
        (MeshStartFfi.started, true),
        (MeshStartFfi.alreadyOn, true),
        (MeshStartFfi.off, false),
      ]) {
        final t = faked()..mesh.startAnswer = answer;
        await t.container.read(meshProvider.future);

        final turnedOn = await t.container.read(meshProvider.notifier).turnOn();

        expect(
          turnedOn,
          on ? MeshTurnOn.on : MeshTurnOn.failed,
          reason: '$answer',
        );
        expect(t.mesh.calls, ['stats', 'start', 'stats'], reason: '$answer');
        expect(
          t.container.read(meshProvider).requireValue!.on_,
          on,
          reason: '$answer',
        );
      }
    });

    test(
      'keep on: after the deadline it answers off and turns nothing on',
      () async {
        for (final (answer, on) in [
          (MeshStartFfi.alreadyOn, true),
          (MeshStartFfi.started, true),
          (MeshStartFfi.off, false),
        ]) {
          final t = faked()..mesh.keepOnAnswer = answer;

          final kept = await t.container.read(meshProvider.notifier).keepOn();

          expect(kept, on, reason: '$answer');
          expect(t.mesh.calls, isNot(contains('start')), reason: '$answer');
        }
      },
    );

    test('turning mesh off and resetting the counts each read the state '
        'they left', () async {
      final t = faked();
      final mesh = t.container.read(meshProvider.notifier);
      await mesh.turnOn();
      expect(t.container.read(meshProvider).requireValue!.on_, isTrue);

      await mesh.turnOff();
      expect(t.container.read(meshProvider).requireValue!.on_, isFalse);
      await mesh.resetCounts();

      expect(t.mesh.calls.sublist(3), [
        'stop',
        'stats',
        'resetCounts',
        'stats',
      ]);
    });

    test('whether mesh is on is read afresh, never remembered', () async {
      final t = faked();
      final mesh = t.container.read(meshProvider.notifier);
      expect(await mesh.isOn(), isFalse);

      // The deadline passes, or mesh is turned on, with no word to Dart.
      t.mesh.statsAnswer = meshState(on: true);
      expect(await mesh.isOn(), isTrue);
      t.mesh.statsAnswer = meshState();
      expect(await mesh.isOn(), isFalse);
    });

    test('an entry that failed is the state, thrown at nobody and naming '
        'nothing', () async {
      final logs = LogCapture.install();
      final t = faked();
      final mesh = t.container.read(meshProvider.notifier);
      await mesh.turnOn();
      for (final entry in ['stats', 'start', 'keepOn', 'stop']) {
        t.mesh.throws[entry] = StateError('group 0xdeadbeefcafe');
      }

      expect(await mesh.turnOn(), MeshTurnOn.failed);
      expect(await mesh.keepOn(), isFalse);
      expect(await mesh.isOn(), isFalse, reason: 'unreadable is not on');
      await mesh.turnOff();
      await mesh.resetCounts();

      expect(t.container.read(meshProvider).hasError, isTrue);
      expect(logs.lines, isEmpty, reason: 'the mesh logs nothing');
    });

    test('belongs to the identity: a login and a logout drop it', () {
      expect(identityScopedProviders, contains(meshProvider));
    });
  });

  group('a mesh drive', () {
    final circle = TestCircleFactory.createCircle(
      mlsGroupId: const [1],
      nostrGroupId: const [10],
      members: [
        TestCircleFactory.createMember(pubkey: _self),
        TestCircleFactory.createMember(pubkey: _peer),
      ],
    );

    ({
      ProviderContainer container,
      FakeMeshService mesh,
      MockCircleService circles,
    })
    driven() {
      final mesh = FakeMeshService();
      final circles = MockCircleService(circles: [circle]);
      final relay = MockRelayService();
      final container = ProviderContainer(
        overrides: [
          meshServiceProvider.overrideWithValue(mesh),
          identityServiceProvider.overrideWithValue(_Identity()),
          circleServiceProvider.overrideWithValue(circles),
          relayServiceProvider.overrideWithValue(relay),
          locationSharingServiceProvider.overrideWithValue(
            LocationSharingService(
              circleService: circles,
              relayService: relay,
              identityService: _Identity(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, mesh: mesh, circles: circles);
    }

    // That what it read is stored where a relay receive stores it and shown
    // on the map, and that it asks no relay for anything, is
    // `location_sharing_provider_test.dart`'s ("the Bluetooth mesh"): that
    // file runs under both receive paths the build can have.
    test('that read nothing touches nothing', () async {
      final t = driven();

      await t.container.read(meshProvider.notifier).drive();

      expect(t.circles.methodCalls, isEmpty);
    });

    test(
      'that failed is thrown at nobody, and nothing of it is logged',
      () async {
        final logs = LogCapture.install();
        final t = driven()
          ..mesh.throws['drive'] = StateError('group 0xdeadbeefcafe');

        await t.container.read(meshProvider.notifier).drive();

        expect(t.circles.lastKnownRows, isEmpty);
        expect(logs.lines, isEmpty);
      },
    );
  });

  group('sharing turned off', () {
    Future<({FakeMeshService mesh, BackgroundSharingNotifier sharing})>
    sharingOn({required bool flag}) async {
      SharedPreferences.setMockInitialValues({
        kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });
      final mesh = FakeMeshService();
      final container = ProviderContainer(
        overrides: [
          meshServiceProvider.overrideWith(
            (ref) => ref.watch(meshEnabledProvider) ? mesh : null,
          ),
          meshEnabledProvider.overrideWithValue(flag),
        ],
      );
      addTearDown(container.dispose);
      final sharing = container.read(backgroundSharingProvider.notifier);
      await sharing.loaded;
      expect(sharing.state, isTrue, reason: 'premise: sharing is on');
      return (mesh: mesh, sharing: sharing);
    }

    test('withdraws what waits to go out by mesh, once', () async {
      final t = await sharingOn(flag: true);

      await t.sharing.setEnabled(enabled: false);
      await pumpEventQueue();

      expect(t.mesh.calls.where((c) => c == 'sharingStopped'), hasLength(1));
    });

    test('turning sharing on withdraws nothing', () async {
      final t = await sharingOn(flag: true);
      await t.sharing.setEnabled(enabled: false);
      await pumpEventQueue();
      t.mesh.calls.clear();

      await t.sharing.setEnabled(enabled: true);
      await pumpEventQueue();

      expect(t.mesh.calls, isNot(contains('sharingStopped')));
    });

    test('in a build without the mesh it calls nothing', () async {
      final t = await sharingOn(flag: false);

      await t.sharing.setEnabled(enabled: false);
      await pumpEventQueue();

      expect(t.mesh.calls, isEmpty);
    });

    test('a withdrawal that failed costs the toggle nothing', () async {
      final t = await sharingOn(flag: true);
      t.mesh.throws['sharingStopped'] = const MeshServiceException('boom');

      await t.sharing.setEnabled(enabled: false);
      await pumpEventQueue();

      expect(t.sharing.state, isFalse);
    });
  });

  test(
    'a drive hands its results over as the service-level type, whole',
    () async {
      // The bridge's results cross as the type every receive path hands over:
      // converted once, by the function a relay drive's are converted by.
      final converted = locationEventResultFromFfi(
        LocationMessageResultFfi(
          kind: LocationMessageResultKindFfi.groupUpdate,
          mlsGroupId: Uint8List.fromList(const [7]),
          epoch: BigInt.from(9),
        ),
      );

      expect(converted.kind, LocationEventKind.groupUpdate);
      expect(converted.mlsGroupId, const [7]);
      expect(converted.epoch, 9);
      expect(converted.location, isNull);
    },
  );
}
