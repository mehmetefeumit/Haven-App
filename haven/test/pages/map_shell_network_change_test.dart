import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/services/network_change_reconnector.dart';
import 'package:haven/src/services/network_change_source.dart';
import 'package:haven/src/services/subscription_service.dart';

/// A platform that reports a change when told to.
class _FakeSource implements NetworkChangeSource {
  final StreamController<void> _changes = StreamController<void>(sync: true);

  @override
  Stream<void> changes() => _changes.stream;

  void change() => _changes.add(null);
}

/// The engine as the resume and the re-dial reach it: every open it is asked
/// for, by kind.
class _Engine implements SubscriptionService {
  int reanchors = 0;
  int redials = 0;
  bool paused = false;
  bool redialSucceeds = true;

  @override
  bool get isPaused => paused;

  @override
  Future<void> resumeAfterBackground() async {
    reanchors++;
    paused = false;
  }

  @override
  Future<bool> reconnectAfterNetworkChange() async {
    redials++;
    // A failed re-dial leaves the session paused (the engine re-pauses).
    paused = !redialSucceeds;
    return redialSucceeds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  group('a resume and a network re-dial open the engine once between them', () {
    test('a change seen while inactive, then a resume inside the settle: one '
        'open, the re-dial, and no re-anchor', () {
      fakeAsync((async) {
        final engine = _Engine();
        final source = _FakeSource();
        var resumed = true;
        DateTime? lastReanchorAt;
        final reconnector = NetworkChangeReconnector(
          source: source,
          isResumed: () => resumed,
          reconnect: () => MapShell.redialBehindStamp(
            redial: engine.reconnectAfterNetworkChange,
            at: DateTime(2026, 11, 20, 12).add(async.elapsed),
            stamped: () => lastReanchorAt,
            stamp: (at) => lastReanchorAt = at,
          ),
        )..start();

        // Control Center down, Wi-Fi toggled, back up within the settle.
        resumed = false;
        source.change();
        async.elapse(const Duration(seconds: 1));
        resumed = true;

        // What `_onResumed` does, in its order.
        reconnector.onResumed();
        if (engine.isPaused ||
            MapShell.liveReanchorDue(
              redialDue: reconnector.redialDue,
              throttlePassed: MapShell.shouldReanchorOnResume(
                lastReanchorAt: lastReanchorAt,
                now: DateTime(2026, 11, 20, 12).add(async.elapsed),
              ),
            )) {
          unawaited(engine.resumeAfterBackground());
        }
        async.elapse(kNetworkChangeSettle + const Duration(minutes: 1));

        expect(engine.reanchors, 0, reason: 'the re-dial re-opens every REQ');
        expect(engine.redials, 1);
      });
    });

    test('with no re-dial due, the throttle alone decides', () {
      for (final throttlePassed in [false, true]) {
        expect(
          MapShell.liveReanchorDue(
            redialDue: false,
            throttlePassed: throttlePassed,
          ),
          throttlePassed,
        );
        expect(
          MapShell.liveReanchorDue(
            redialDue: true,
            throttlePassed: throttlePassed,
          ),
          isFalse,
        );
      }
    });
  });

  group('the re-anchor stamp a re-dial writes', () {
    final t0 = DateTime(2026, 11, 20, 12);

    test('a failed re-dial leaves the heal re-anchor unthrottled', () async {
      final engine = _Engine()..redialSucceeds = false;
      DateTime? lastReanchorAt;
      await MapShell.redialBehindStamp(
        redial: engine.reconnectAfterNetworkChange,
        at: t0,
        stamped: () => lastReanchorAt,
        stamp: (at) => lastReanchorAt = at,
      );
      expect(engine.isPaused, isTrue, reason: 'premise: the session re-paused');

      final took = await MapShell.reanchorPausedEngine(
        engine: engine,
        foregrounded: true,
        now: t0.add(const Duration(seconds: 10)),
        lastReanchorAt: lastReanchorAt,
      );
      expect(took, isTrue, reason: 'the next heal re-anchors at once');
      expect(engine.reanchors, 1);
    });

    test('a re-dial that succeeded keeps the stamp, and the throttle with '
        'it', () async {
      final engine = _Engine();
      DateTime? lastReanchorAt;
      await MapShell.redialBehindStamp(
        redial: engine.reconnectAfterNetworkChange,
        at: t0,
        stamped: () => lastReanchorAt,
        stamp: (at) => lastReanchorAt = at,
      );
      expect(lastReanchorAt, t0);
      expect(
        MapShell.shouldReanchorOnResume(
          lastReanchorAt: lastReanchorAt,
          now: t0.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
    });

    test('the stamp is written before the re-dial is asked, and a later '
        "re-anchor's stamp survives the re-dial's failure", () async {
      final gate = Completer<bool>();
      DateTime? lastReanchorAt;
      final redial = MapShell.redialBehindStamp(
        redial: () => gate.future,
        at: t0,
        stamped: () => lastReanchorAt,
        stamp: (at) => lastReanchorAt = at,
      );
      expect(lastReanchorAt, t0, reason: 'a heal behind it must decline');
      final resumeAt = t0.add(const Duration(seconds: 2));
      lastReanchorAt = resumeAt;
      gate.complete(false);
      await redial;
      expect(lastReanchorAt, resumeAt);
    });
  });
}
