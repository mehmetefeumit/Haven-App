// Static guard: every Dart call of a Bluetooth mesh entry sits behind the
// `HAVEN_MESH` build flag (`docs/BLUETOOTH_MESH_PLAN.md` §16, "M2g-2a").
//
// The behaviour — that with the flag off nothing reaches the bridge whatever
// is asked of the mesh — is proved by execution in
// `test/providers/mesh_provider_test.dart` and, for the Android service's
// isolate, `test/services/background_location_task_mesh_test.dart`. What no
// behavioural test can notice is a NEW call site added later that reaches
// the bridge by another way. So this pins the inventory, by exact equality:
//
//  * the bridge's free mesh entries are named in one file, the service's;
//  * its two driven mesh entries are named in one file, the relay
//    service's, where every driven entry is registered for a teardown;
//  * the service is built in two places, each behind the flag — the
//    provider (`meshEnabledProvider`) and the Android service's isolate,
//    which has no provider container (`_mesh`, defaulting to the same
//    const);
//  * the radio's platform channels are named in one file, the radio's, and
//    the radio is built in one, behind the flag and the platform — by the
//    provider, and by the one function that stands in for it where no
//    container exists yet (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.1). With
//    either off no channel is touched, by execution in
//    `test/providers/mesh_radio_flow_test.dart`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every non-generated Dart source under `lib/`, comments stripped.
Map<String, String> _sources() {
  final sources = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(Platform.pathSeparator, '/');
    if (path.startsWith('lib/src/rust/') || path.startsWith('lib/l10n/')) {
      continue;
    }
    sources[path] = entity
        .readAsLinesSync()
        .map((line) => line.replaceFirst(RegExp(r'\s*//.*$'), ''))
        .join('\n');
  }
  return sources;
}

/// The files whose code matches [call].
Set<String> _filesCalling(Map<String, String> sources, Pattern call) => {
  for (final MapEntry(key: path, value: code) in sources.entries)
    if (code.contains(call)) path,
};

void main() {
  late Map<String, String> sources;

  setUpAll(() => sources = _sources());

  test(
    "the bridge's free mesh entries are called in the mesh service alone",
    () {
      for (final entry in [
        'meshStart',
        'meshResume',
        'meshKeepOn',
        'meshStop',
        'meshSharingStopped',
        'meshStats',
        'meshResetCounts',
      ]) {
        expect(_filesCalling(sources, RegExp('\\b$entry\\(')), {
          'lib/src/services/mesh_service.dart',
        }, reason: entry);
      }
    },
  );

  test("the bridge's driven mesh entries are called in the relay service "
      'alone', () {
    for (final entry in ['meshDriveDriven', 'sealLocationForMeshDriven']) {
      expect(_filesCalling(sources, RegExp('\\.$entry\\(')), {
        'lib/src/services/nostr_relay_service.dart',
      }, reason: entry);
    }
  });

  test('the mesh service is built only behind the build flag', () {
    expect(_filesCalling(sources, RegExp(r'\bNostrMeshService\(')), {
      // Its own constructor.
      'lib/src/services/mesh_service.dart',
      'lib/src/providers/mesh_provider.dart',
      'lib/src/services/background_location_task.dart',
    });

    String flat(String path) => sources[path]!.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      flat('lib/src/providers/mesh_provider.dart'),
      contains(
        'if (!ref.watch(meshEnabledProvider)) return null; '
        'return NostrMeshService(',
      ),
    );
    expect(
      flat('lib/src/providers/mesh_provider.dart'),
      contains("const meshEnabled = bool.fromEnvironment('HAVEN_MESH');"),
    );
    final task = flat('lib/src/services/background_location_task.dart');
    expect(task, contains('bool mesh = meshEnabled,'));
    expect(
      task,
      contains(
        'if (_mesh) { _meshService = overrideMeshService ?? '
        'NostrMeshService(',
      ),
    );
  });

  test("the radio's channels are named in the radio's file alone, and the "
      'radio is built only behind the build flag and the platform', () {
    expect(_filesCalling(sources, 'haven.app/mesh_radio'), {
      'lib/src/services/mesh_radio.dart',
    });
    expect(_filesCalling(sources, RegExp(r'\bAndroidMeshRadio\(')), {
      // Its own constructor.
      'lib/src/services/mesh_radio.dart',
      'lib/src/providers/mesh_provider.dart',
    });
    expect(_filesCalling(sources, 'meshRadioProvider'), {
      'lib/src/providers/mesh_provider.dart',
      // A logout, and the retry of its wipe before a new identity.
      'lib/src/providers/identity_provider.dart',
    });
    expect(_filesCalling(sources, RegExp(r'\bplatformMeshRadio\(')), {
      'lib/src/providers/mesh_provider.dart',
      // The launch's retry of a logout's wipe, before any container exists.
      'lib/main.dart',
    });

    String flat(String path) => sources[path]!.replaceAll(RegExp(r'\s+'), ' ');
    final provider = flat('lib/src/providers/mesh_provider.dart');
    expect(
      provider,
      contains(
        'if (!ref.watch(meshEnabledProvider) || '
        '!ref.watch(platformIsAndroidProvider)) { return null; } '
        'return const AndroidMeshRadio();',
      ),
    );
    expect(
      provider,
      contains(
        'MeshRadio? platformMeshRadio() => meshEnabled && Platform.isAndroid '
        '? const AndroidMeshRadio() : null;',
      ),
    );
    expect(flat('lib/main.dart'), contains('meshRadio: platformMeshRadio(),'));
  });
}
