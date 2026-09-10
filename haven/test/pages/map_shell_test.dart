/// Unit tests for [MapShell] pure helpers.
///
/// The widget itself depends on the Rust bridge and is exercised through the
/// integration suite; these cover the platform/lifecycle decision logic that
/// can be verified without pumping the widget.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/map_shell.dart';

void main() {
  group('MapShell.pausedRelayOwner', () {
    // REPLACES the four `shouldKeepRelayConnectedWhilePaused` rows this file
    // carried until P4. Those rows asserted a bool — "keep the socket warm for
    // the whole background window" on iOS+sharing, "close it here" everywhere
    // else — and the iOS row is no longer what happens: the burst coordinator
    // opens and closes the socket per publish tick. Flipping that row to
    // `false` would have been the weaker fix and a false statement: the pause
    // does not close it, the first burst does. So the answer became an enum,
    // and the row that encoded the old behaviour is replaced by one that names
    // the new owner rather than by nothing.
    //
    // The socket-closed-after-every-burst promise itself is proved
    // behaviourally, on the coordinator
    // (`background_burst_coordinator_test.dart`); what only this table can say
    // is WHO is expected to keep it, per platform and toggle state.
    test('the iOS background branch hands the socket to the burst plane', () {
      expect(
        MapShell.pausedRelayOwner(
          backgroundSharingEnabled: true,
          isIOS: true,
        ),
        PausedRelayOwner.burst,
        reason: 'the burst plane closes it — the burst this pause drove, or '
            'the idle close it took instead — R14: it rides the publish tick '
            'that already exists, and nothing here may add a background timer '
            'to reach it',
      );
    });

    // The eligible set used to be a third input, so an account with nothing
    // publishable fell through to `none` — an answer whose only effect is an
    // unawaited shutdown of the PUBLISH pool, while the standing REQs, the
    // engine socket and the 55 s pinger stayed up for the whole window
    // regardless. The branch now closes both planes on EVERY iOS background
    // pause, so no state is left for that parameter to select and the truth
    // table below enumerates every input this answer has.

    test('Android with background sharing on hands it to the service', () {
      // Android hands publishing to the foreground-service isolate, which
      // dials its own pool — this isolate's socket closes at the pause.
      expect(
        MapShell.pausedRelayOwner(
          backgroundSharingEnabled: true,
          isIOS: false,
        ),
        PausedRelayOwner.foregroundService,
      );
    });

    test('nobody owns it on iOS when background sharing is off', () {
      // No keep-alive is armed, so the app is genuinely going idle — and this
      // answer closes only the PUBLISH pool. The engine's socket, its standing
      // REQs and the crate's 55 s pinger are the other plane's, and they are
      // closed on the same branch by `shouldStopLiveSyncOnPause`, whose iOS
      // arm this state is exactly the one that reaches.
      expect(
        MapShell.pausedRelayOwner(
          backgroundSharingEnabled: false,
          isIOS: true,
        ),
        PausedRelayOwner.none,
      );
    });

    test('nobody owns it when neither condition holds', () {
      expect(
        MapShell.pausedRelayOwner(
          backgroundSharingEnabled: false,
          isIOS: false,
        ),
        PausedRelayOwner.none,
      );
    });

    test('only the burst state leaves the socket alone at the pause', () {
      // The call site reads exactly this: `!= burst` shuts the pool down. A
      // fourth state, or a rename that made two states compare equal, would
      // silently change which pauses leave a socket open.
      final owners = {
        for (final bg in const [true, false])
          for (final ios in const [true, false])
            (bg, ios): MapShell.pausedRelayOwner(
              backgroundSharingEnabled: bg,
              isIOS: ios,
            ),
      };
      expect(
        owners.entries
            .where((e) => e.value == PausedRelayOwner.burst)
            .map((e) => e.key),
        [(true, true)],
        reason: 'exactly one of the four pause states may keep a socket past '
            'the pause instant, and it is the one whose coordinator closes it '
            'again — at the next burst, or at once',
      );
    });
  });

  group('MapShell.shouldBurstImmediatelyOnPause', () {
    // Without this the iOS branch pauses with the foreground's standing REQ
    // and socket still up, until whichever circle ticks first — up to one
    // jittered publish interval of exactly the continuous connection P4
    // removes.
    final now = DateTime.utc(2026, 9, 7, 12);

    test('a mount that has never published bursts at once', () {
      expect(
        MapShell.shouldBurstImmediatelyOnPause(lastPublishAt: null, now: now),
        isTrue,
      );
    });

    test('a pause 5 s after a publish waits for the next tick', () {
      // The overlap guard's whole point: re-sending what was just sent buys
      // nothing and costs a radio wake.
      expect(
        MapShell.shouldBurstImmediatelyOnPause(
          lastPublishAt: now.subtract(const Duration(seconds: 5)),
          now: now,
        ),
        isFalse,
      );
    });

    test('a pause 61 s after a publish bursts at once', () {
      expect(
        MapShell.shouldBurstImmediatelyOnPause(
          lastPublishAt: now.subtract(const Duration(seconds: 61)),
          now: now,
        ),
        isTrue,
      );
    });

    test('the boundary is the overlap guard itself, exclusive', () {
      // Same convention as `shouldReanchorOnResume`, and the same constant.
      expect(
        MapShell.shouldBurstImmediatelyOnPause(
          lastPublishAt: now.subtract(kLocationPublishOverlapGuard),
          now: now,
        ),
        isFalse,
      );
      expect(
        MapShell.shouldBurstImmediatelyOnPause(
          lastPublishAt: now.subtract(
            kLocationPublishOverlapGuard + const Duration(milliseconds: 1),
          ),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('MapShell.shouldKeepPublishingWhilePaused', () {
    test('keeps publishing only on the iOS background branch', () {
      // The unified background-capable location stream keeps the process
      // executable, so the send scheduler and motion trigger stay live.
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: true,
        ),
        isTrue,
      );
    });

    test('stops on Android even with background sharing on', () {
      // Android hands publishing to the foreground-service isolate; the
      // foreground scheduler must stop (MLS single-writer handoff).
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: false,
        ),
        isFalse,
      );
    });

    test('stops on iOS when background sharing is off', () {
      // The stream carries no keep-alive; the app genuinely goes idle.
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: true,
        ),
        isFalse,
      );
    });

    test('stops when neither condition holds', () {
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: false,
        ),
        isFalse,
      );
    });
  });

  group('MapShell.shouldStopLiveSyncOnPause', () {
    // ONE exception, not one platform. The toggle used to be absent here
    // (`!isIOS`), which read as "iOS keeps the engine" — true only of the
    // sharing-ON branch, where the burst plane owns it. With sharing OFF the
    // iOS pause held every standing REQ, the inbox REQ, the engine socket and
    // the crate's 55 s pinger for the whole background window, for a user who
    // had explicitly said stop. Both iOS rows below are reachable from
    // production: the sharing-off one is the branch that now stops.
    test('stops on Android with background sharing on', () {
      expect(
        MapShell.shouldStopLiveSyncOnPause(
          isIOS: false,
          backgroundSharingEnabled: true,
        ),
        isTrue,
        reason: 'the MLS handoff stops it anyway — the engine holds its own '
            'Arc on the circle manager, so the foreground service cannot open '
            'the database until it lets go',
      );
    });

    test('stops on Android with background sharing off', () {
      expect(
        MapShell.shouldStopLiveSyncOnPause(
          isIOS: false,
          backgroundSharingEnabled: false,
        ),
        isTrue,
        reason: 'nobody in this isolate needs the engine while the app is away',
      );
    });

    test('stops on iOS with background sharing off', () {
      expect(
        MapShell.shouldStopLiveSyncOnPause(
          isIOS: true,
          backgroundSharingEnabled: false,
        ),
        isTrue,
        reason: 'a user who turned background sharing off has the strongest '
            'claim to no standing REQ: nothing publishes or receives, so the '
            'socket is a bare "this pubkey is online" signal',
      );
    });

    test('never stops on iOS with background sharing on', () {
      expect(
        MapShell.shouldStopLiveSyncOnPause(
          isIOS: true,
          backgroundSharingEnabled: true,
        ),
        isFalse,
        reason: 'the paused iOS process IS the receiver — stopping the engine '
            'there ends background delivery',
      );
    });
  });
}
