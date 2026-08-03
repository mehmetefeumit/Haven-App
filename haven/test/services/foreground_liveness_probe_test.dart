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
