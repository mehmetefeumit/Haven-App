/// What the self-marker's pulse costs the rest of the map.
///
/// `flutter_map` wraps the WHOLE map — tiles, member markers, attribution — in
/// a single `RepaintBoundary`. A widget inside it that repaints at the display
/// refresh rate therefore repaints all of that with it, at 60 Hz, for as long
/// as the map is on screen. The pulse animates forever by design (it is the
/// "this is live" affordance), so the marker has to own the boundary that stops
/// the repaint at itself.
///
/// The oracle is a sibling that counts its own `paint` calls. Painting a
/// repaint boundary paints every descendant that is not itself a boundary, so
/// a growing count IS the leak, and a flat one is its absence — proved in both
/// directions here (the control below has no boundary and must grow).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';

import '../../helpers/localized_app_harness.dart';

/// Mutable paint tally, shared with the painter.
class _Tally {
  int value = 0;
}

/// Counts every time it is asked to paint.
class _CountingPainter extends CustomPainter {
  const _CountingPainter(this.tally);

  final _Tally tally;

  @override
  void paint(Canvas canvas, Size size) => tally.value++;

  // Never dirty itself: every count must come from an ANCESTOR repaint, which
  // is the thing being measured.
  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}

/// A sibling standing in for the tiles and the attribution.
class _PaintCounter extends StatelessWidget {
  const _PaintCounter(this.tally);

  final _Tally tally;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size.square(20),
        painter: _CountingPainter(tally),
      );
}

/// The control: an endlessly animating widget with NO boundary of its own.
class _UnboundedPulse extends StatefulWidget {
  const _UnboundedPulse();

  @override
  State<_UnboundedPulse> createState() => _UnboundedPulseState();
}

class _UnboundedPulseState extends State<_UnboundedPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 1500),
    vsync: this,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => SizedBox.square(
          dimension: 10 + 10 * _controller.value,
          child: const ColoredBox(color: Colors.red),
        ),
      );
}

Future<void> _pumpUnderSharedBoundary(
  WidgetTester tester,
  Widget animating,
  _Tally tally,
) async {
  await pumpLocalized(
    tester,
    Scaffold(
      // Stands in for `flutter_map`'s one boundary around the whole map.
      body: RepaintBoundary(
        child: Stack(
          children: [_PaintCounter(tally), animating],
        ),
      ),
    ),
    // The pulse never settles by design.
    settle: false,
  );
  await tester.pump();
}

/// The pulse's own animated node — `AnimatedBuilder` also appears in the
/// framework's page/scaffold machinery, so it is scoped to the marker.
final Finder _pulse = find.descendant(
  of: find.byType(UserLocationMarker),
  matching: find.byType(AnimatedBuilder),
);

void main() {
  testWidgets('the pulse repaints nothing but itself', (tester) async {
    final tally = _Tally();
    await _pumpUnderSharedBoundary(
      tester,
      const UserLocationMarker(),
      tally,
    );

    final before = tally.value;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tally.value,
      before,
      reason: 'every one of these frames would otherwise redraw the tiles and '
          'the attribution, for a dot that moved four pixels',
    );
  });

  testWidgets('the oracle sees the leak when the boundary is absent', (
    tester,
  ) async {
    // Anti-vacuity: without this, a marker that stopped animating altogether
    // would pass the test above.
    final tally = _Tally();
    await _pumpUnderSharedBoundary(tester, const _UnboundedPulse(), tally);

    final before = tally.value;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tally.value,
      greaterThan(before),
      reason: 'an animation with no boundary of its own repaints its siblings',
    );
  });

  testWidgets('the pulse still pulses', (tester) async {
    // The other half of the same promise: the boundary is a paint-scope
    // change, never a reason for the live-location affordance to go static.
    final tally = _Tally();
    await _pumpUnderSharedBoundary(
      tester,
      const UserLocationMarker(),
      tally,
    );

    final first = tester.getSize(_pulse);
    await tester.pump(const Duration(milliseconds: 300));
    final later = tester.getSize(_pulse);

    expect(later, isNot(first));
  });

  testWidgets('reduced motion still removes the pulse entirely', (
    tester,
  ) async {
    // WCAG 2.3.3: the boundary must not resurrect an animation the user asked
    // the OS to switch off.
    final tally = _Tally();
    await pumpLocalized(
      tester,
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: RepaintBoundary(
            child: Stack(
              children: [
                _PaintCounter(tally),
                const UserLocationMarker(),
              ],
            ),
          ),
        ),
      ),
      settle: false,
    );
    await tester.pump();

    expect(_pulse, findsNothing);
  });
}
