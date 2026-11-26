/// Widget tests for [CircularSaveButton], the save affordance shared by the
/// display-name card and the member nickname editor.
///
/// Pins what each [SaveStatus] shows (icon, tooltip, accessible name,
/// colours), the 48dp target, that the key lands on the [FilledButton], and
/// that reduced motion drops the icon animation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/common/circular_save_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _buttonKey = Key('save');

Widget _harness({
  required SaveStatus status,
  VoidCallback? onPressed,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: CircularSaveButton(
          buttonKey: _buttonKey,
          status: status,
          onPressed: onPressed,
          savedLabel: 'is-saved',
          saveLabel: 'do-save',
          savingLabel: 'is-saving',
          retryLabel: 'do-retry',
        ),
      ),
    ),
  );
}

Finder _inButton(Finder matching) =>
    find.descendant(of: find.byKey(_buttonKey), matching: matching);

void main() {
  final cases = <(SaveStatus, Finder Function(), String)>[
    (SaveStatus.saved, () => find.byIcon(LucideIcons.check), 'is-saved'),
    (SaveStatus.unsaved, () => find.byIcon(LucideIcons.arrowUp), 'do-save'),
    (
      SaveStatus.saving,
      () => find.byType(CircularProgressIndicator),
      'is-saving',
    ),
    (SaveStatus.failed, () => find.byIcon(LucideIcons.rotateCcw), 'do-retry'),
  ];

  for (final (status, glyph, label) in cases) {
    testWidgets('$status shows its own glyph, tooltip and accessible name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_harness(status: status, onPressed: () {}));
      await tester.pump();

      expect(_inButton(glyph()), findsOneWidget);
      expect(find.byTooltip(label), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(_buttonKey)),
        matchesSemantics(
          label: label,
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });
  }

  testWidgets('the key is on the FilledButton, which is a 48dp circle', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(status: SaveStatus.unsaved));

    expect(tester.widget(find.byKey(_buttonKey)), isA<FilledButton>());
    expect(tester.getSize(find.byKey(_buttonKey)), const Size(48, 48));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  });

  testWidgets('a null onPressed disables the button', (tester) async {
    await tester.pumpWidget(_harness(status: SaveStatus.saved));

    expect(
      tester.widget<FilledButton>(find.byKey(_buttonKey)).enabled,
      isFalse,
    );
  });

  testWidgets('failed uses the error-container colours; others the default', (
    tester,
  ) async {
    Color? background() => tester
        .widget<FilledButton>(find.byKey(_buttonKey))
        .style
        ?.backgroundColor
        ?.resolve({});

    await tester.pumpWidget(
      _harness(status: SaveStatus.failed, onPressed: () {}),
    );
    final context = tester.element(find.byKey(_buttonKey));
    final scheme = Theme.of(context).colorScheme;
    expect(background(), scheme.errorContainer);

    await tester.pumpWidget(
      _harness(status: SaveStatus.unsaved, onPressed: () {}),
    );
    expect(background(), isNot(scheme.errorContainer));
  });

  testWidgets('a state change animates the icon swap', (tester) async {
    await tester.pumpWidget(_harness(status: SaveStatus.saved));
    await tester.pumpWidget(
      _harness(status: SaveStatus.unsaved, onPressed: () {}),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(_inButton(find.byType(AnimatedSwitcher)), findsOneWidget);
    expect(
      _inButton(find.byIcon(LucideIcons.check)),
      findsOneWidget,
      reason: 'mid-transition the outgoing icon is still on screen',
    );
    expect(_inButton(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
  });

  testWidgets('reduced motion swaps the icon at once, with no animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(status: SaveStatus.saved, disableAnimations: true),
    );
    await tester.pumpWidget(
      _harness(
        status: SaveStatus.unsaved,
        onPressed: () {},
        disableAnimations: true,
      ),
    );

    expect(_inButton(find.byType(AnimatedSwitcher)), findsNothing);
    expect(_inButton(find.byIcon(LucideIcons.check)), findsNothing);
    expect(_inButton(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
  });
}
