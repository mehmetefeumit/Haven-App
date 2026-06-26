/// Tests for the direction-aware [BackArrow] / [ForwardArrow] widgets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/directional_arrow.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

Widget _wrap(Widget child, TextDirection dir) => MaterialApp(
  home: Directionality(
    textDirection: dir,
    child: Center(child: child),
  ),
);

void main() {
  group('BackArrow', () {
    testWidgets('points left (toward back) in LTR', (tester) async {
      await tester.pumpWidget(_wrap(const BackArrow(), TextDirection.ltr));
      expect(find.byIcon(LucideIcons.arrowLeft), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowRight), findsNothing);
    });

    testWidgets('mirrors to point right (toward back) in RTL', (tester) async {
      await tester.pumpWidget(_wrap(const BackArrow(), TextDirection.rtl));
      expect(find.byIcon(LucideIcons.arrowRight), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowLeft), findsNothing);
    });
  });

  group('ForwardArrow', () {
    testWidgets('points right (toward forward) in LTR', (tester) async {
      await tester.pumpWidget(_wrap(const ForwardArrow(), TextDirection.ltr));
      expect(find.byIcon(LucideIcons.arrowRight), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowLeft), findsNothing);
    });

    testWidgets('mirrors to point left in RTL', (tester) async {
      await tester.pumpWidget(_wrap(const ForwardArrow(), TextDirection.rtl));
      expect(find.byIcon(LucideIcons.arrowLeft), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowRight), findsNothing);
    });

    testWidgets('honours an explicit color and size', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const ForwardArrow(color: Color(0xFF123456), size: 30),
          TextDirection.ltr,
        ),
      );
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, const Color(0xFF123456));
      expect(icon.size, 30);
    });
  });
}
