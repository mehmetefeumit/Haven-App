/// Tests for [DisclosureChevron] — the trailing disclosure chevron that
/// mirrors with text direction (Lucide chevrons don't auto-flip).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/disclosure_chevron.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  Future<void> pump(WidgetTester tester, TextDirection direction) {
    return tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: const DisclosureChevron(),
      ),
    );
  }

  testWidgets('points toward the end edge (right) in LTR', (tester) async {
    await pump(tester, TextDirection.ltr);
    expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
    expect(find.byIcon(LucideIcons.chevronLeft), findsNothing);
  });

  testWidgets('mirrors toward the end edge (left) in RTL', (tester) async {
    await pump(tester, TextDirection.rtl);
    expect(find.byIcon(LucideIcons.chevronLeft), findsOneWidget);
    expect(find.byIcon(LucideIcons.chevronRight), findsNothing);
  });
}
