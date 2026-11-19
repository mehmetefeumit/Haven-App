/// What the Bluetooth mesh's widgets are pumped over: a fake engine and a
/// fake radio that share one journal, and the overrides that hand them to the
/// providers.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/location_settings_launcher.dart';
import 'package:haven/src/services/mesh_radio.dart';

import 'fake_mesh.dart';

/// Twelve hours, as a turn-on leaves the engine.
const int kTwelveHoursMs = 12 * 60 * 60 * 1000;

/// A mesh state with counts.
MeshStatsFfi meshCounts({
  bool on = true,
  bool linked = false,
  int onForMs = kTwelveHoursMs,
  int fromCirclesSinceOn = 0,
  int passedOnSinceOn = 0,
  int fromCirclesTotal = 0,
  int passedOnTotal = 0,
}) => MeshStatsFfi(
  on_: on,
  linked: linked,
  onForMs: BigInt.from(on ? onForMs : 0),
  fromCirclesSinceOn: BigInt.from(fromCirclesSinceOn),
  passedOnSinceOn: BigInt.from(passedOnSinceOn),
  fromCirclesTotal: BigInt.from(fromCirclesTotal),
  passedOnTotal: BigInt.from(passedOnTotal),
);

class _Launcher implements LocationSettingsLauncher {
  _Launcher(this.journal);

  final List<String> journal;

  @override
  Future<bool> openLocationSettings() async {
    journal.add('settings.location');
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    journal.add('settings.app');
    return true;
  }
}

/// A fake mesh for a widget test.
class MeshHarness {
  /// Mesh off, with a radio that would start.
  MeshHarness() {
    mesh
      ..journal = journal
      ..startsForMs = kTwelveHoursMs;
    radio.journal = journal;
  }

  /// Every call made of the engine, the radio and the system's settings, in
  /// order.
  final List<String> journal = [];

  /// The engine.
  final FakeMeshService mesh = FakeMeshService();

  /// The radio.
  final FakeMeshRadio radio = FakeMeshRadio();

  /// What hands the fakes to the providers.
  List<Override> get overrides => [
    meshServiceProvider.overrideWithValue(mesh),
    meshRadioProvider.overrideWithValue(radio),
    locationSettingsLauncherProvider.overrideWithValue(_Launcher(journal)),
  ];

  /// Mesh as a turn-on left it: the engine on, the radio as [state].
  void on({
    bool linked = false,
    MeshRadioState state = MeshRadioState.running,
    bool canSearch = true,
  }) {
    mesh.statsAnswer = meshCounts(linked: linked);
    radio.statusAnswer = radioStatus(state, wanted: true, canSearch: canSearch);
  }

  /// How often [call] was made.
  int count(String call) => journal.where((made) => made == call).length;
}

/// Loads the app's own typeface, for the few tests of whether real words fit
/// a real screen: the test font draws every letter as a full square.
Future<void> loadAppFont() async {
  final loader = FontLoader('Inter')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/Inter/InterVariable.ttf').readAsBytesSync(),
        ),
      ),
    );
  await loader.load();
}

/// Lets the engine's and the radio's answers land and the frame that shows
/// them be drawn.
Future<void> settleMesh(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}
