/// The Bluetooth mesh lane's drive target, push A
/// (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §O.2, §O.7).
///
/// One target, three legs, and it does not know which one it is: it does the
/// same things in the same order and REPORTS what happened, one `[mesh]` line
/// per fact. What each leg requires of those facts is the runner's
/// (`tooling/e2e/ci/run-mesh-lever.sh`), whose oracle is the part of this lane
/// that is tested without a device.
///
///  * a flag-off build on API 34 (S0): no mesh channel has a native end;
///  * a flag-on build on API 34 (the probe): the channel answers what push A
///    answers, the three methods behind the log lever are missing, and the
///    turn-on a user makes ends `failed` with nothing started;
///  * a flag-on build on API 29 (S2): `supported` is false.
///
/// Three lines are planted in the device's log through `liblog`, the library
/// `android.util.Log` ends in: one under a platform Bluetooth tag, one under
/// `flutter` by the same call, one string event. Each carries a token minted
/// here, random per run and naming nothing; the runner reads them back under
/// this process's pid. None of it exists in `haven/lib`: the product has no
/// marker and no test surface (§O.4, Q-20).
///
/// The markers are fixed words and numbers. Nothing a channel answers is
/// printed but the words `mesh_radio.dart` defines for it.
library;

import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:io' show File, pid;
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/mesh_radio.dart' show kMeshRadioBound;
import 'package:haven/src/widgets/map/mesh_button.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/throw_time_error_capture.dart';

// ---------------------------------------------------------------------------
// VERBATIM markers. MUST match the `MARK_*` constants in
// tooling/e2e/ci/run-mesh-lever.sh — change both together.
// ---------------------------------------------------------------------------
const String kPhaseMarker = '[mesh] PHASE';
const String kUiMarker = '[mesh] UI';
const String kChannelMarker = '[mesh] CHANNEL';
const String kAnswerMarker = '[mesh] ANSWER';
const String kPlantMarker = '[mesh] PLANT';
const String kTurnOnMarker = '[mesh] TURN_ON';
const String kAfterMarker = '[mesh] AFTER';
const String kReadyMarker = '[mesh] READY';
const String kReleasedMarker = '[mesh] RELEASED';
const String kHoldExpiredMarker = '[mesh] HOLD_EXPIRED';
const String kDoneMarker = '[mesh] DONE';

/// The radio's method channel, by name: a second handle on the channel
/// `AndroidMeshRadio` asks, so that what is observed here is the native end
/// and not the Dart seam's reading of it.
const MethodChannel _radio = MethodChannel('haven.app/mesh_radio');

/// Every method the Dart seam can ask (`ChannelWords.METHODS`).
const List<String> _allMethods = <String>[
  'permission',
  'requestPermission',
  'bluetoothOn',
  'bluetoothName',
  'openBluetoothSettings',
  'start',
  'sync',
  'stop',
  'status',
  'supported',
  'takeAction',
];

/// The three no push-A build answers (`ChannelWords.BEHIND_THE_LEVER`).
const List<String> _behindTheLever = <String>[
  'bluetoothOn',
  'bluetoothName',
  'start',
];

/// What a flag-on build is asked here beyond those three: the methods that
/// answer without doing anything. `requestPermission` and
/// `openBluetoothSettings` open a system screen, and `sync` and `stop` write
/// the service's stored copy, which this target must find untouched.
const List<String> _harmless = <String>[
  'permission',
  'status',
  'supported',
  'takeAction',
];

/// The six strings a `start` or a `sync` carries, as fixed text.
const Map<String, String> _copy = <String, String>{
  'channel': 'lane',
  'on': 'lane',
  'paused': 'lane',
  'reminder': 'lane',
  'keepOn': 'lane',
  'stopped': 'lane',
};

/// Where the runner tells this target its inspection is over: a file it
/// makes in the app's own data directory with `run-as`. Nothing of the
/// product reads it.
const String _releasePath =
    '/data/data/com.oblivioustech.haven/mesh-lane-release';

/// How long the target stays alive for the runner's inspection. Past it the
/// target goes on and says so; the runner reads that as a window it did not
/// hold, never as a pass. Mirrors `HOLD_BOUND_SECS` in the runner.
const Duration _holdBound = Duration(seconds: 240);

/// How long the radio's first answer may take before the tree is counted.
const Duration _supportedBound = Duration(seconds: 30);

// liblog's `log_id_t` and priorities (`android/log.h`).
const int _logIdMain = 0;
const int _priorityDebug = 3;
const int _priorityInfo = 4;

/// The event tag of the planted string event: a number no platform event
/// uses, so the entry is this target's and nobody else's.
const int _eventTag = 0x4D455348;

/// A plant token's alphabet and the positions forced out of the hex digits:
/// `e2e/_lib/log_needles.dart`'s rule, so that no structural rule of the log
/// scanner can fire inside a token.
const String _plantAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const String _plantNonHex = 'GHJKLMNPQRSTUVWXYZ';
const List<int> _plantForced = <int>[0, 3, 6, 9];

String _mintToken(String id, Random rng) {
  final suffix = StringBuffer();
  for (var i = 0; i < 10; i++) {
    final alphabet = _plantForced.contains(i) ? _plantNonHex : _plantAlphabet;
    suffix.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return 'mesh-lane-plant-$id-$suffix';
}

/// Runs [write] with [strings] as C strings. `nolib`: `liblog` did not open;
/// `nosym`: it has no such function for an app; `refused`: the call answered
/// an error; `ok` otherwise.
String _plant(
  String symbol,
  List<String> strings,
  int Function(DynamicLibrary liblog, List<Pointer<Uint8>> c) write,
) {
  final DynamicLibrary liblog;
  try {
    liblog = DynamicLibrary.open('liblog.so');
  } on Object {
    return 'nolib';
  }
  if (!liblog.providesSymbol(symbol)) return 'nosym';
  final libc = DynamicLibrary.process();
  final malloc = libc
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  final free = libc
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  final c = <Pointer<Uint8>>[];
  try {
    for (final string in strings) {
      final bytes = utf8.encode(string);
      final at = malloc(bytes.length + 1);
      at.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      c.add(at);
    }
    return write(liblog, c) < 0 ? 'refused' : 'ok';
  } finally {
    c.forEach(free);
  }
}

/// One line in the main buffer under [tag], by the function
/// `android.util.Log` ends in.
String _plantLine(int priority, String tag, String token) => _plant(
  '__android_log_buf_write',
  <String>[tag, token],
  (liblog, c) =>
      liblog.lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Uint8>, Pointer<Uint8>),
        int Function(int, int, Pointer<Uint8>, Pointer<Uint8>)
      >('__android_log_buf_write')(_logIdMain, priority, c[0], c[1]),
);

/// One string event in the events buffer.
String _plantEvent(String token) => _plant(
  '__android_log_bswrite',
  <String>[token],
  (liblog, c) =>
      liblog.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('__android_log_bswrite')(_eventTag, c[0]),
);

/// Asks the radio's channel [method] and says how it ended: `missing` where
/// no native end answered, `answered`, or `failed`.
Future<(String, Object?)> _ask(String method, [Object? arguments]) async {
  try {
    final answer = await _radio
        .invokeMethod<Object?>(method, arguments)
        .timeout(kMeshRadioBound);
    return ('answered', answer);
  } on MissingPluginException {
    return ('missing', null);
  } on Object {
    return ('failed', null);
  }
}

/// [answer] where it is one of [words], and `other` where it is anything
/// else: only words this file names are ever printed.
String _word(Object? answer, List<String> words) {
  if (answer == null) return 'none';
  final text = '$answer';
  return words.contains(text) ? text : 'other';
}

const List<String> _bools = <String>['true', 'false'];
const List<String> _permissions = <String>[
  'granted',
  'denied',
  'deniedForGood',
];
const List<String> _states = <String>['stopped', 'running', 'paused'];

/// The channel's `status` as two words.
Future<String> _status() async {
  final (_, answer) = await _ask('status');
  final status = answer is Map<Object?, Object?> ? answer : null;
  final state = _word(status?['state'], _states);
  final wanted = _word(status?['wanted'], _bools);
  return 'state=$state wanted=$wanted';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    try {
      await RustLib.init();
    } on Object catch (e) {
      // Idempotent; see `app_test.dart`.
      debugPrint('[mesh] RustLib.init() note: ${e.runtimeType}');
    }
  });

  testWidgets(
    'the mesh, as this build and this Android release have it',
    (tester) async {
      installThrowTimeErrorLogging();
      debugPrint('$kPhaseMarker flag=${meshEnabled ? 'on' : 'off'} pid=$pid');

      // The app past onboarding, as `app_test.dart` mounts it: the map is
      // where the mesh button is, in a build and on a phone that has one.
      // The lane compiles the live-sync engine out, so there is no session to
      // claim the foreground for (`test/e2e/app_lifecycle_test.dart`).
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            onboardingControllerProvider.overrideWith(
              (ref) => OnboardingController(
                const OnboardingFlags(introSeen: true, completed: true),
              ),
            ),
            identityProvider.overrideWith(
              (ref) async => Identity(
                pubkeyHex:
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                npub:
                    'npub1'
                    '0000000000000000000000000000'
                    '000000000000000000000000000000',
                createdAt: DateTime.utc(2024),
              ),
            ),
          ],
          child: const HavenApp(),
        ),
      );
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
      );

      // The button is drawn only once the radio has said the phone can run
      // the mesh, so the tree is counted behind that answer.
      final asked = Stopwatch()..start();
      while (!container.read(meshSupportedProvider).hasValue &&
          asked.elapsed < _supportedBound) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 100));
      final supportedRead = container.read(meshSupportedProvider).valueOrNull;
      final shells = find
          .byKey(const ValueKey<String>('map_shell'))
          .evaluate()
          .length;
      final buttons = find.byType(MeshButton).evaluate().length;
      debugPrint(
        '$kUiMarker shell=$shells button=$buttons '
        'available=${container.read(meshAvailableProvider)} '
        'supported_read=${supportedRead ?? 'unread'}',
      );

      // The channel, method by method. A flag-off build is asked all eleven:
      // with no native end none of them can do anything.
      final sweep = meshEnabled
          ? <String>[..._harmless, ..._behindTheLever]
          : _allMethods;
      final ended = <String, int>{'missing': 0, 'answered': 0, 'failed': 0};
      var leverMissing = 0;
      for (final method in sweep) {
        final arguments = method == 'start' || method == 'sync' ? _copy : null;
        final (how, _) = await _ask(method, arguments);
        ended[how] = ended[how]! + 1;
        if (how == 'missing' && _behindTheLever.contains(method)) {
          leverMissing++;
        }
      }
      final swept = sweep.length;
      debugPrint(
        '$kChannelMarker asked=$swept missing=${ended['missing']} '
        'answered=${ended['answered']} failed=${ended['failed']} '
        'lever_missing=$leverMissing',
      );
      final (_, supported) = await _ask('supported');
      final (_, permission) = await _ask('permission');
      final supportedWord = _word(supported, _bools);
      final permissionWord = _word(permission, _permissions);
      final before = await _status();
      debugPrint(
        '$kAnswerMarker supported=$supportedWord '
        'permission=$permissionWord $before',
      );

      // The plants: no log lever is in this process in any push-A build, so
      // each is expected in the device's log.
      final rng = Random.secure();
      final p1 = _mintToken('p1', rng);
      final p2 = _mintToken('p2', rng);
      final p3 = _mintToken('p3', rng);
      final wrote1 = _plantLine(_priorityDebug, 'BluetoothGatt', p1);
      final wrote2 = _plantLine(_priorityInfo, 'flutter', p2);
      final wrote3 = _plantEvent(p3);
      debugPrint('$kPlantMarker id=p1 token=$p1 call=$wrote1');
      debugPrint('$kPlantMarker id=p2 token=$p2 call=$wrote2');
      debugPrint('$kPlantMarker id=p3 token=$p3 call=$wrote3');

      // The turn-on a user makes. In push A it cannot succeed in any build;
      // how it ended, and how long it took, are the runner's to judge. Asked
      // only where the system would show no dialog: under one, the answer
      // would be the dialog's bound and not the channel's.
      if (!meshEnabled || permission == 'granted') {
        final took = Stopwatch()..start();
        final outcome = await container.read(meshProvider.notifier).turnOn();
        debugPrint(
          '$kTurnOnMarker ended=${outcome.name} ms=${took.elapsedMilliseconds}',
        );
      } else {
        debugPrint('$kTurnOnMarker ended=skipped ms=0');
      }
      final after = await _status();
      debugPrint('$kAfterMarker $after');

      // Alive for the runner's inspection, until it says so.
      debugPrint(kReadyMarker);
      final release = File(_releasePath);
      final held = Stopwatch()..start();
      while (!release.existsSync() && held.elapsed < _holdBound) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      debugPrint(release.existsSync() ? kReleasedMarker : kHoldExpiredMarker);
      debugPrint(kDoneMarker);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
