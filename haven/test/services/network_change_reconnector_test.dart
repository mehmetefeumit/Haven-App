import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/network_change_reconnector.dart';
import 'package:haven/src/services/network_change_source.dart';

import '../helpers/log_capture.dart';

/// A platform that reports a change when told to, and records whether anyone
/// is listening — a listen and a cancel are what reach the native side.
class _FakeSource implements NetworkChangeSource {
  StreamController<void>? _controller;
  int listens = 0;

  bool get listening => _controller != null;

  @override
  Stream<void> changes() {
    final controller = StreamController<void>(sync: true);
    controller
      ..onListen = () {
        listens++;
        _controller = controller;
      }
      ..onCancel = () {
        if (identical(_controller, controller)) _controller = null;
      };
    return controller.stream;
  }

  void change() => _controller?.add(null);
}

void main() {
  late _FakeSource source;
  late int calls;
  late List<bool> claims;
  var resumed = true;

  setUp(() {
    source = _FakeSource();
    calls = 0;
    claims = [];
    resumed = true;
  });

  /// A reconnector over [source]; each re-dial records the lifecycle read at
  /// its call and finishes when [gate] completes, or at once.
  NetworkChangeReconnector build({
    Duration floor = Duration.zero,
    Completer<void> Function()? gate,
    Exception? throwing,
  }) => NetworkChangeReconnector(
    source: source,
    floor: floor,
    isResumed: () => resumed,
    reconnect: () async {
      calls++;
      claims.add(resumed);
      if (throwing != null) throw throwing;
      await gate?.call().future;
    },
  );

  group('settle', () {
    test('a change re-dials once the settle has passed, not a moment '
        'before', () {
      fakeAsync((async) {
        build().start();
        source.change();
        async.elapse(kNetworkChangeSettle - const Duration(milliseconds: 1));
        expect(calls, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 1);
        expect(claims, [true]);
        async.elapse(const Duration(minutes: 5));
        expect(calls, 1, reason: 'one change is one re-dial');
      });
    });

    test('a burst of changes is one re-dial, a settle after the last', () {
      fakeAsync((async) {
        build().start();
        source.change();
        async.elapse(const Duration(seconds: 2));
        source.change();
        async.elapse(const Duration(seconds: 2));
        source.change();
        async.elapse(kNetworkChangeSettle - const Duration(milliseconds: 1));
        expect(calls, 0, reason: 'each change restarts the settle');
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 1);
        async.elapse(const Duration(minutes: 1));
        expect(calls, 1);
      });
    });

    test('the settle is between 2 and 5 seconds', () {
      // Long enough to fold cellular-then-Wi-Fi into one re-dial, short
      // enough that an app in front is not left on dead sockets.
      expect(kNetworkChangeSettle.inMilliseconds, inInclusiveRange(2000, 5000));
    });
  });

  group('one at a time', () {
    test('changes during a re-dial are handled by exactly one more', () {
      fakeAsync((async) {
        final gates = <Completer<void>>[];
        build(gate: () => gates.last).start();
        gates.add(Completer<void>());
        source.change();
        async.elapse(kNetworkChangeSettle);
        expect(calls, 1);

        gates.add(Completer<void>());
        source.change();
        async.elapse(kNetworkChangeSettle);
        source.change();
        async.elapse(kNetworkChangeSettle);
        expect(calls, 1, reason: 'never two re-dials at once');

        gates.first.complete();
        async.flushMicrotasks();
        expect(
          calls,
          2,
          reason: 'the trailing re-dial runs once the first ends',
        );
        gates.last.complete();
        async.elapse(const Duration(minutes: 1));
        expect(calls, 2, reason: 'and only one trailing re-dial');
      });
    });

    test('the trailing re-dial still waits out the settle of the last '
        'change', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        build(gate: () => gate).start();
        source.change();
        async.elapse(kNetworkChangeSettle);
        source.change();
        async.elapse(const Duration(seconds: 1));
        gate.complete();
        async.flushMicrotasks();
        expect(calls, 1);
        async.elapse(kNetworkChangeSettle - const Duration(seconds: 1));
        expect(calls, 2);
      });
    });
  });

  group('stop', () {
    test('cancels the listen and drops a settling change', () {
      fakeAsync((async) {
        final reconnector = build()..start();
        expect(source.listening, isTrue);
        source.change();
        reconnector.stop();
        async.flushMicrotasks();
        expect(
          source.listening,
          isFalse,
          reason: 'the native side unregisters',
        );
        async.elapse(const Duration(minutes: 1));
        expect(calls, 0);
      });
    });

    test('drops the trailing re-dial of one still running', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        final reconnector = build(gate: () => gate)..start();
        source.change();
        async.elapse(kNetworkChangeSettle);
        source.change();
        async.elapse(kNetworkChangeSettle);
        reconnector.stop();
        gate.complete();
        async.elapse(const Duration(minutes: 1));
        expect(calls, 1);
      });
    });

    test('a restart listens afresh and re-dials what changes after it', () {
      fakeAsync((async) {
        final reconnector = build()
          ..start()
          ..stop();
        async.flushMicrotasks();
        reconnector.start();
        expect(source.listens, 2);
        source.change();
        async.elapse(kNetworkChangeSettle);
        expect(calls, 1);
      });
    });

    test('starting again while listening keeps the listen', () {
      // A second listen re-takes the native baseline.
      fakeAsync((async) {
        build()
          ..start()
          ..start()
          ..onResumed();
        expect(source.listens, 1);
      });
    });
  });

  group('only an app that is resumed re-dials', () {
    test('a change while inactive is owed, and runs once at the resume, '
        'claiming the foreground', () {
      fakeAsync((async) {
        final reconnector = build()..start();
        resumed = false;
        source.change();
        async.elapse(const Duration(minutes: 5));
        expect(calls, 0, reason: 'the engine would refuse it');

        resumed = true;
        reconnector.onResumed();
        async.flushMicrotasks();
        expect(calls, 1);
        expect(claims, [true]);
        reconnector.onResumed();
        async.elapse(const Duration(minutes: 1));
        expect(calls, 1, reason: 'an owed change is run once');
      });
    });

    test('a pause forgets the owed change', () {
      fakeAsync((async) {
        final reconnector = build()..start();
        resumed = false;
        source.change();
        async.elapse(kNetworkChangeSettle);
        reconnector.stop();
        resumed = true;
        reconnector.onResumed();
        async.elapse(const Duration(minutes: 1));
        expect(calls, 0);
        expect(source.listening, isTrue, reason: 'the resume listens again');
      });
    });

    test('a mount listens only in an app that reads resumed', () {
      fakeAsync((async) {
        resumed = false;
        build().startAtMount();
        expect(source.listens, 0);
        resumed = true;
        build().startAtMount();
        expect(source.listens, 1);
      });
    });
  });

  group('the iOS floor', () {
    test('a second change 10 s after the first re-dials 30 s after the first '
        're-dial, not before, and the latest change is the one handled', () {
      fakeAsync((async) {
        build(floor: kIosNetworkReconnectFloor).start();
        source.change();
        async.elapse(kNetworkChangeSettle);
        expect(calls, 1);
        final firstRedial = async.elapsed;

        async.elapse(const Duration(seconds: 7));
        source.change();
        async.elapse(const Duration(seconds: 10));
        source.change();
        final dueAt = firstRedial + kIosNetworkReconnectFloor;
        async.elapse(
          dueAt - async.elapsed - const Duration(milliseconds: 1),
        );
        expect(calls, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 2, reason: 'one re-dial for both later changes');
        async.elapse(const Duration(minutes: 5));
        expect(calls, 2);
      });
    });

    test('is 30 s, and Android has none', () {
      fakeAsync((async) {
        expect(kIosNetworkReconnectFloor, const Duration(seconds: 30));
        build().start();
        source.change();
        async.elapse(kNetworkChangeSettle);
        source.change();
        async.elapse(kNetworkChangeSettle);
        expect(calls, 2);
      });
    });

    test('an owed change waits out the floor at the resume', () {
      fakeAsync((async) {
        final reconnector = build(floor: kIosNetworkReconnectFloor)..start();
        source.change();
        async.elapse(kNetworkChangeSettle);
        resumed = false;
        source.change();
        async.elapse(kNetworkChangeSettle);
        resumed = true;
        reconnector.onResumed();
        async.flushMicrotasks();
        expect(calls, 1);
        async.elapse(kIosNetworkReconnectFloor);
        expect(calls, 2);
      });
    });
  });

  test('a failed re-dial is not retried, and logs only its type', () {
    final logs = LogCapture.install();
    fakeAsync((async) {
      build(
        throwing: Exception('no route to wss://relay.example.invalid'),
      ).start();
      source.change();
      async.elapse(kNetworkChangeSettle + const Duration(minutes: 10));
      expect(calls, 1);
    });
    logs
      ..assertContains('[NetworkChange] re-dial failed: _Exception')
      ..assertNoNeedles(const ['wss://relay.example.invalid']);
  });
}
