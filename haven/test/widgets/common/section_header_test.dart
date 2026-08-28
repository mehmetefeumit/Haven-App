/// Tests for [HavenSectionHeader].
///
/// The promise under test is the class doc's own claim: centralising the
/// header makes it "structurally impossible to ship a section title a
/// screen reader cannot navigate to" (plan F7). That promise is the
/// `Semantics(header: true)` flag TalkBack's Headings control and the
/// VoiceOver rotor key off — a test that only checks the label text is
/// present would stay green even if a future edit dropped the flag and
/// silently broke both.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/section_header.dart';

void main() {
  Future<void> pump(WidgetTester tester, {int? headingLevel}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HavenSectionHeader(
            label: 'Section title',
            headingLevel: headingLevel,
          ),
        ),
      ),
    );
  }

  testWidgets('is flagged as a header, the flag a heading-navigation '
      'control keys off', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    final node = tester.getSemantics(find.text('Section title'));
    expect(
      node.hasFlag(SemanticsFlag.isHeader),
      isTrue,
      reason: 'without this flag, TalkBack\'s Headings control and the '
          'VoiceOver rotor cannot navigate to this section',
    );
    handle.dispose();
  });

  testWidgets('carries the given heading level', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, headingLevel: 2);

    final node = tester.getSemantics(find.text('Section title'));
    expect(node.headingLevel, 2);
    handle.dispose();
  });

  testWidgets('leaves the heading level unset (unlevelled) when none is '
      'given', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);

    final node = tester.getSemantics(find.text('Section title'));
    expect(node.headingLevel, 0, reason: 'Semantics reports "no level" as 0');
    expect(
      node.hasFlag(SemanticsFlag.isHeader),
      isTrue,
      reason: 'unlevelled is still a header, not "not a header"',
    );
    handle.dispose();
  });

  testWidgets('renders the given label text', (tester) async {
    await pump(tester);
    expect(find.text('Section title'), findsOneWidget);
  });
}
