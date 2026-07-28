/// Widget tests for [HavenMoreDetailSection].
///
/// This widget is the single place the Privacy section's technical depth is
/// hidden behind, so its collapsed-by-default behaviour and its screen-reader
/// state reporting are load-bearing: if it silently defaulted to expanded, the
/// layering that keeps the Privacy pages readable by non-technical users would
/// be gone, and if it failed to report `expanded`, a screen-reader user could
/// not tell there was anything to open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/more_detail_section.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget subject() => const Scaffold(
    body: HavenMoreDetailSection(
      label: 'In more detail',
      expandHint: 'Show the technical detail',
      collapseHint: 'Hide the technical detail',
      expandedAnnouncement: 'Technical detail shown',
      collapsedAnnouncement: 'Technical detail hidden',
      children: [Text('The protocol depth')],
    ),
  );

  testWidgets('hides its children until expanded', (tester) async {
    await pumpLocalized(tester, subject());

    expect(find.text('In more detail'), findsOneWidget);
    expect(find.text('The protocol depth'), findsNothing);

    await tester.tap(find.text('In more detail'));
    await tester.pumpAndSettle();

    expect(find.text('The protocol depth'), findsOneWidget);
  });

  testWidgets('collapses again on a second tap', (tester) async {
    await pumpLocalized(tester, subject());

    await tester.tap(find.text('In more detail'));
    await tester.pumpAndSettle();
    expect(find.text('The protocol depth'), findsOneWidget);

    await tester.tap(find.text('In more detail'));
    await tester.pumpAndSettle();
    expect(find.text('The protocol depth'), findsNothing);
  });

  testWidgets('reports expanded state and hint to screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpLocalized(tester, subject());

    // Collapsed: the state must be present and false (not absent) so assistive
    // technology can announce "collapsed" before the user interacts, and the
    // hint must describe the action that is currently available.
    final collapsed = tester.getSemantics(find.text('In more detail'));
    expect(collapsed.flagsCollection.isExpanded.toBoolOrNull(), isFalse);
    expect(collapsed.hint, 'Show the technical detail');

    await tester.tap(find.text('In more detail'));
    await tester.pumpAndSettle();

    final expanded = tester.getSemantics(find.text('In more detail'));
    expect(expanded.flagsCollection.isExpanded.toBoolOrNull(), isTrue);
    expect(expanded.hint, 'Hide the technical detail');

    handle.dispose();
  });

  testWidgets('header stays a 48dp-minimum tap target', (tester) async {
    await pumpLocalized(tester, subject());

    final size = tester.getSize(find.byType(InkWell));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('drops the expand animation when animations are disabled', (
    tester,
  ) async {
    // Reduced-motion users must still get the content, immediately — the
    // rotation is decorative and for some users actively harmful.
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(home: subject()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('In more detail'));
    // A single frame is enough when the duration is zero.
    await tester.pump();
    expect(find.text('The protocol depth'), findsOneWidget);
  });
}
