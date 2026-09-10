/// A fake `HavenLocationStreamHandler` for host tests.
///
/// There is no macOS machine in this repo and nothing runs Swift unit tests in
/// CI, so this fake IS the contract: what it accepts and what it reports is
/// what the native side is expected to implement. It is deliberately dumb —
/// the profile controller it stands in for is exercised directly in
/// `ios_location_source_test.dart`; here the interesting properties are which
/// intent reached the session, which coordinate the platform hands back, and
/// what the lifecycle read answers.
library;

import 'dart:async';

import 'package:haven/src/services/ios_location_source.dart';
import 'package:haven/src/services/location_service.dart';

/// Fake [IosLocationSource] recording every call the service makes.
class FakeIosLocationSource implements IosLocationSource {
  /// The `allowsBackgroundLocationUpdates` value of each [positions] call, in
  /// order — the carrier of the user's background-sharing intent.
  final List<bool> listenArguments = <bool>[];

  /// Every session handed out, in order; [session] is the live one.
  final List<StreamController<Position>> sessions =
      <StreamController<Position>>[];

  /// How many sessions have been cancelled.
  int cancels = 0;

  /// How many times the native last-Best copy was cleared.
  int clearCalls = 0;

  /// Each `onForeground` value, in order.
  final List<bool> foregroundCalls = <bool>[];

  /// What the native side holds as its last Best-profile fix.
  Position? nativeLastBestFix;

  /// What the native side reports as its last confirmation.
  DateTime? confirmedAt;

  /// What [status] answers. Defaults to a healthy foregrounded session under a
  /// confirmed Always; a test that cares sets its own.
  IosLocationStreamStatus statusValue = const IosLocationStreamStatus(
    running: true,
    allowsBackgroundLocationUpdates: true,
    showsBackgroundLocationIndicator: false,
    profile: IosLocationProfile.best,
    authorization: 'authorizedAlways',
    backgrounded: false,
  );

  /// The live session, for pushing fixes at the service.
  StreamController<Position> get session => sessions.last;

  @override
  Stream<Position> positions({required bool allowsBackgroundLocationUpdates}) {
    listenArguments.add(allowsBackgroundLocationUpdates);
    final controller = StreamController<Position>(onCancel: () => cancels++);
    sessions.add(controller);
    return controller.stream;
  }

  @override
  Future<Position?> lastBestFix() async => nativeLastBestFix;

  @override
  Future<void> clearLastBestFix() async {
    clearCalls++;
    nativeLastBestFix = null;
  }

  @override
  void onForeground({required bool foregrounded}) =>
      foregroundCalls.add(foregrounded);

  @override
  DateTime? get lastConfirmedAt => confirmedAt;

  @override
  Future<IosLocationStreamStatus> status() async => statusValue;
}
