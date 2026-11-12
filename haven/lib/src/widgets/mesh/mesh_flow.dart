/// Turning the Bluetooth mesh on and off as the user asks: one flow, whether
/// it is asked from the mesh button, from the notice beside it or from the
/// statistics sheet (`docs/BLUETOOTH_MESH_PLAN.md` §7.4;
/// `docs/BLUETOOTH_MESH_M3_DESIGN.md` §C.2, §E.1–§E.2).
///
/// It decides nothing about where its outcome is said: the button says it at
/// the bottom of the map, the sheet in the sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/widgets/mesh/mesh_intro_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether a turn-on or turn-off the user asked for is under way: they run
/// one at a time, wherever each was asked from.
final meshAskedProvider = StateProvider<bool>((ref) => false);

/// Whether the engine and the radio are being started now, with nothing of
/// the flow's own on screen: what the button's progress mark follows.
final meshStartingProvider = StateProvider<bool>((ref) => false);

/// Whether the user asked for mesh to be off and it has not been on since:
/// the stop that follows is theirs, whenever the radio gets round to saying
/// so, and is not told to them as somebody else's.
final meshUserOffProvider = StateProvider<bool>((ref) => false);

/// What to tell the user of a turn-on or turn-off that did not do what was
/// asked: fixed copy, and the way to put it right where there is one.
class MeshFailure {
  /// A failure with nothing to be done about it but to try again.
  const MeshFailure(this.message) : remedyLabel = null, remedy = null;

  /// A failure with a remedy.
  const MeshFailure.withRemedy(
    this.message, {
    required String this.remedyLabel,
    required Future<void> Function() this.remedy,
  });

  /// What happened.
  final String message;

  /// The remedy's button.
  final String? remedyLabel;

  /// What the remedy's button does.
  final Future<void> Function()? remedy;
}

/// How a turn-on or turn-off ended: `done` when mesh is as asked; a
/// `failure` to say when it is not; neither when the user backed out or
/// another one was under way.
typedef MeshAsked = ({bool done, MeshFailure? failure});

const MeshAsked _done = (done: true, failure: null);
const MeshAsked _nothing = (done: false, failure: null);

MeshAsked _failed(MeshFailure failure) => (done: false, failure: failure);

/// Runs [transition] unless one is under way already.
Future<MeshAsked> _asked(
  BuildContext context,
  Future<MeshAsked> Function(ProviderContainer container) transition,
) async {
  // The container outlives whatever asked: a sheet may close under a turn-on.
  final container = ProviderScope.containerOf(context, listen: false);
  final asked = container.read(meshAskedProvider.notifier);
  if (asked.state) return _nothing;
  asked.state = true;
  try {
    return await transition(container);
  } finally {
    asked.state = false;
    // Whatever turned mesh off inside it, its outcome told the user.
    container.read(meshStoppedNoticeProvider.notifier).state = false;
  }
}

/// Turns mesh on. The first time on this device the disclosure comes first,
/// and — once the permission that lets it be read is held — the phone's
/// Bluetooth name, before anything is stored.
Future<MeshAsked> meshTurnOn(BuildContext context) => _asked(context, (
  container,
) async {
  final l10n = AppLocalizations.of(context);
  final mesh = container.read(meshProvider.notifier);
  final launcher = container.read(locationSettingsLauncherProvider);
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return _nothing;
  final first = !(prefs.getBool(kMeshIntroSeenKey) ?? false);
  if (first &&
      !(await showMeshIntroSheet(context, offerTurnOn: true) ?? false)) {
    return _nothing;
  }
  final starting = container.read(meshStartingProvider.notifier)..state = true;
  final MeshTurnOn ended;
  try {
    ended = await mesh.turnOn(
      confirm: !first
          ? null
          : () async {
              // The name is read and shown: the user is answering, not
              // waiting.
              starting.state = false;
              try {
                return await _nameSeen(context, mesh, prefs);
              } finally {
                starting.state = true;
              }
            },
    );
  } finally {
    starting.state = false;
  }
  return switch (ended) {
    MeshTurnOn.on => _done,
    MeshTurnOn.cancelled => _nothing,
    MeshTurnOn.noPermission => _failed(MeshFailure(l10n.meshErrorNoPermission)),
    MeshTurnOn.noPermissionForGood => _failed(
      MeshFailure.withRemedy(
        l10n.meshErrorNoPermission,
        remedyLabel: l10n.commonOpenSettings,
        remedy: launcher.openAppSettings,
      ),
    ),
    MeshTurnOn.bluetoothOff => _failed(
      MeshFailure.withRemedy(
        l10n.meshErrorBluetoothOff,
        remedyLabel: l10n.meshBluetoothSettings,
        remedy: mesh.openBluetoothSettings,
      ),
    ),
    MeshTurnOn.unsupported => _failed(MeshFailure(l10n.meshErrorUnsupported)),
    MeshTurnOn.failed => _failed(MeshFailure(l10n.meshErrorStartFailed)),
  };
});

/// The first turn-on's step between the permission and anything stored: the
/// phone's Bluetooth name, now that it can be read. One that cannot be read
/// has the disclosure's general sentence alone. The disclosure counts as read
/// once this is passed.
Future<bool> _nameSeen(
  BuildContext context,
  MeshNotifier mesh,
  SharedPreferences prefs,
) async {
  final name = await mesh.bluetoothName();
  if (!context.mounted) return false;
  if (name != null && !await showMeshNameStep(context, name)) return false;
  await prefs.setBool(kMeshIntroSeenKey, true);
  return true;
}

/// Turns mesh off, at once and with no question.
Future<MeshAsked> meshTurnOff(BuildContext context) =>
    _asked(context, (container) async {
      final l10n = AppLocalizations.of(context);
      final mesh = container.read(meshProvider.notifier);
      bool off() => switch (container.read(meshProvider)) {
        AsyncData(:final value) => !(value?.on_ ?? false),
        _ => false,
      };
      final userOff = container.read(meshUserOffProvider.notifier)
        ..state = true;
      await mesh.turnOff();
      // A stop that failed is left as the state, though the turn-off's own
      // closing reconcile may have made it after all: a read decides.
      if (!off()) await mesh.refresh();
      if (off()) return _done;
      // It was not turned off: what stops it from here on is not the user's.
      userOff.state = false;
      return _failed(MeshFailure(l10n.meshErrorStopFailed));
    });
