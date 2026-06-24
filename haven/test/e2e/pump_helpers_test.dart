/// Widget tests for the E2E frame-pump helpers — in particular
/// [tapWhenHittable], whose correctness gates every UI tap in the (green)
/// Android e2e_combined lane as well as the iOS lane it was added to fix.
///
/// These run under plain `flutter test` (no Rust bridge / no device) because
/// the helpers only depend on `flutter_test`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/pump_helpers.dart';

void main() {
  group('tapWhenHittable', () {
    testWidgets('taps an immediately-hittable widget', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('t'),
                onPressed: () => taps++,
                child: const Text('t'),
              ),
            ),
          ),
        ),
      );

      await tapWhenHittable(tester, find.byKey(const Key('t')));

      expect(taps, 1);
    });

    testWidgets(
      'taps a button revealed by a route push, mid-transition '
      '(the production failure scenario)',
      (tester) async {
        var targetTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('go'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: Center(
                            child: ElevatedButton(
                              key: const Key('target'),
                              onPressed: () => targetTaps++,
                              child: const Text('target'),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('go')));
        // Mirror the production pattern exactly: pumpUntilFound returns the
        // instant the pushed route MOUNTS — i.e. at the START of its
        // transition, while it is still pointer-absorbing. We deliberately do
        // NOT settle here.
        await pumpUntilFound(tester, find.byKey(const Key('target')));

        await tapWhenHittable(tester, find.byKey(const Key('target')));

        expect(targetTaps, 1, reason: 'tap must land once the route settles');
      },
    );

    testWidgets(
      'scrolls a below-the-fold button into view, then taps it '
      '(the NameCirclePage / autofocus-keyboard scenario)',
      (tester) async {
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    // Pushes the button far below the viewport — its logical
                    // centre is off-screen, so a tap there would miss until it
                    // is scrolled in (the production failure: an autofocus
                    // keyboard shrinks the viewport and shoves the bottom
                    // "Create" button off-screen).
                    const SizedBox(height: 2000),
                    ElevatedButton(
                      key: const Key('deep'),
                      onPressed: () => taps++,
                      child: const Text('deep'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tapWhenHittable(tester, find.byKey(const Key('deep')));

        expect(taps, 1);
      },
    );

    testWidgets('waits for an absorbing barrier to lift, then taps', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _DelayedBarrier(
            delay: const Duration(milliseconds: 500),
            child: ElevatedButton(
              key: const Key('t'),
              onPressed: () => taps++,
              child: const Text('t'),
            ),
          ),
        ),
      );

      // Absorbing for the first 500ms — an immediate tap would be swallowed.
      await tapWhenHittable(tester, find.byKey(const Key('t')));

      expect(taps, 1);
    });

    testWidgets('throws when the target never becomes hittable', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AbsorbPointer(
            child: Center(
              child: ElevatedButton(
                key: const Key('t'),
                onPressed: () {},
                child: const Text('t'),
              ),
            ),
          ),
        ),
      );

      // Fully await the helper (so its internal pumps complete) and capture
      // the throw via try/catch — passing the in-flight future to
      // expectLater would trip flutter_test's "guarded function conflict".
      Object? caught;
      try {
        await tapWhenHittable(
          tester,
          find.byKey(const Key('t')),
          timeout: const Duration(milliseconds: 200),
          pumpInterval: const Duration(milliseconds: 20),
        );
      } on Object catch (e) {
        caught = e;
      }

      expect(caught, isStateError);
    });
  });
}

/// Wraps [child] in an [AbsorbPointer] that absorbs for [delay], then lifts —
/// a deterministic stand-in for the transient pointer barrier a route push
/// installs while it animates.
class _DelayedBarrier extends StatefulWidget {
  const _DelayedBarrier({required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  State<_DelayedBarrier> createState() => _DelayedBarrierState();
}

class _DelayedBarrierState extends State<_DelayedBarrier> {
  bool _absorbing = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _absorbing = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AbsorbPointer(
        absorbing: _absorbing,
        child: Center(child: widget.child),
      ),
    );
  }
}
