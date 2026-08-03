import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/foreground_liveness_probe.dart';

/// The probe authorises a DESTRUCTIVE recovery step: a "dead" verdict lets the
/// foreground service stop the process-global live-sync engine. If the main
/// isolate is actually alive, that engine is its engine, nothing restarts it,
/// and live location receive stays dead until the app is relaunched.
///
/// So the asymmetry these tests pin is: reporting "alive" when unsure costs one
/// deferred recovery attempt; reporting "dead" when unsure costs a working
/// session. Every uncertain path must resolve to "alive".
void main() {
  group('ForegroundLivenessProbe', () {
    test('a matching reply means alive', () async {
      final probe = ForegroundLivenessProbe();
      // The plugin channel is unavailable under `flutter test`, so drive the
      // receive side directly: capture the nonce the probe is waiting on by
      // replaying it back through `onData`.
      final future = probe.mainIsolateIsAlive(
        timeout: const Duration(seconds: 30),
        channelReady: () => true,
      );
      // The probe assigns nonces from 1 upward.
      expect(probe.onData(<String, Object>{kLivenessPongKey: 1}), isTrue);
      expect(await future, isTrue);
    });

    test('no reply within the timeout means dead', () async {
      final probe = ForegroundLivenessProbe();
      expect(
        await probe.mainIsolateIsAlive(
          timeout: const Duration(milliseconds: 50),
          channelReady: () => true,
        ),
        isFalse,
        reason: 'a silent main isolate is the ONLY condition that may '
            'authorise a reclaim',
      );
    });

    test('a reply carrying the WRONG nonce does not count as alive', () async {
      // A late reply to an abandoned earlier ping says nothing about now.
      // Accepting it would let stale traffic vouch for a dead isolate — but the
      // failure direction here is the safe one, so this pins that the probe
      // still waits rather than resolving early on unrelated data.
      final probe = ForegroundLivenessProbe();
      final future = probe.mainIsolateIsAlive(
        timeout: const Duration(milliseconds: 80),
        channelReady: () => true,
      );
      probe.onData(<String, Object>{kLivenessPongKey: 9999});
      expect(await future, isFalse);
    });

    test('non-probe payloads are passed through, not swallowed', () {
      // The task handler routes ALL incoming data here first. If the probe
      // claimed application traffic, that traffic would silently vanish.
      final probe = ForegroundLivenessProbe();
      expect(probe.onData(<String, Object>{'some.app.key': 1}), isFalse);
      expect(probe.onData('a bare string'), isFalse);
      expect(probe.onData(<String, Object>{kLivenessPongKey: 1}), isTrue);
    });

    test('a late reply within the round still counts as proof of life',
        () async {
      // Deliberately changed from "a reply to an abandoned ping is ignored".
      // Discarding it was the defect: a reply arriving after its own probe gave
      // up is direct evidence the isolate is alive and answering, and the
      // realistic cause of the delay is the main isolate blocked on a sync FFI
      // call while the service holds the same SQLCipher locks — exactly the
      // situation this runs in. Throwing that proof away let one sustained
      // stall read as death and authorise tearing down a live session.
      final probe = ForegroundLivenessProbe()..resetRound();
      expect(
        await probe.mainIsolateIsAlive(
          timeout: const Duration(milliseconds: 50),
          channelReady: () => true,
        ),
        isFalse,
      );

      // Nonce 1's reply lands after probe 1 gave up.
      probe.onData(<String, Object>{kLivenessPongKey: 1});
      expect(
        probe.sawRecentReply,
        isTrue,
        reason: 'the caller must be able to abandon a reclaim on this',
      );
    });

    test('a reply from a PREVIOUS round does not count', () async {
      // The boundary that still matters. Evidence from an earlier decision says
      // nothing about the isolate now, so `resetRound` must actually forget it
      // — otherwise one old reply would suppress every future reclaim.
      final probe = ForegroundLivenessProbe()..resetRound();
      expect(
        await probe.mainIsolateIsAlive(
          timeout: const Duration(milliseconds: 50),
          channelReady: () => true,
        ),
        isFalse,
      );
      probe.onData(<String, Object>{kLivenessPongKey: 1});
      expect(probe.sawRecentReply, isTrue);

      probe.resetRound();
      expect(
        probe.sawRecentReply,
        isFalse,
        reason: 'a new decision starts with no evidence',
      );
      probe.onData(<String, Object>{kLivenessPongKey: 1});
      expect(
        probe.sawRecentReply,
        isFalse,
        reason: 'a stale nonce from the previous round must be rejected',
      );
    });

  });

  group('an unregistered channel is never read as death', () {
    // The CI-30786149786 regression. `sendDataToMain` is `sendPort?.send(data)`
    // — a SILENT no-op when nothing is registered — so an entrypoint that never
    // installed the channel produced identical symptoms to a dead isolate: two
    // timed-out probes, and the foreground service releasing the session of a
    // UI isolate that was alive and running the test.
    test('no port registered means alive, without waiting', () async {
      final probe = ForegroundLivenessProbe()..resetRound();
      final started = DateTime.now();

      final alive = await probe.mainIsolateIsAlive(
        timeout: const Duration(seconds: 30),
        channelReady: () => false,
      );

      expect(
        alive,
        isTrue,
        reason: 'silence on a channel that cannot deliver is not evidence of '
            'anything, and the caller acts destructively on "dead"',
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'it must short-circuit rather than burn the full timeout',
      );
    });

    test('a registered channel still reports a silent isolate as dead', () async {
      // The check must not swallow the real signal it guards.
      final probe = ForegroundLivenessProbe()..resetRound();
      expect(
        await probe.mainIsolateIsAlive(
          timeout: const Duration(milliseconds: 50),
          channelReady: () => true,
        ),
        isFalse,
      );
    });
  });

  group('the port name matches the plugin', () {
    test('kForegroundTaskPortName is not stale', () {
      // Duplicated from the plugin, where it is private. If the plugin renames
      // it, the lookup silently returns null forever and every probe reports
      // "alive" — safe, but it disables the reclaim entirely and silently.
      final pkg = Directory(
        '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev',
      );
      if (!pkg.existsSync()) return; // not resolvable in this environment
      final dirs = pkg
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('flutter_foreground_task-'))
          .toList();
      if (dirs.isEmpty) return;
      final src = File(
        '${dirs.last.path}/lib/flutter_foreground_task.dart',
      );
      if (!src.existsSync()) return;
      expect(
        src.readAsStringSync(),
        contains("'$kForegroundTaskPortName'"),
        reason: 'the plugin no longer uses this port name; update '
            'kForegroundTaskPortName or the channel check is inert',
      );
    });
  });

  group('probe constants', () {
    test('the timeout is generous relative to a publish cycle', () {
      // A tight timeout turns a merely-busy isolate into a "dead" verdict and
      // costs a live session. This must stay well above a normal round trip.
      expect(kLivenessProbeTimeout.inSeconds, greaterThanOrEqualTo(3));
    });

    test('ping and pong keys are distinct', () {
      // Sharing one key would make the responder answer its own reply.
      expect(kLivenessPingKey, isNot(equals(kLivenessPongKey)));
    });
  });
}
