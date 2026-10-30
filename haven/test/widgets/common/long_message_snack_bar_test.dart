/// Tests for [longMessageSnackBar].
///
/// The promises: the snackbar stays until the user closes it — with its
/// Dismiss, or with a given action or the close button — never on a timer
/// (WCAG 2.2.1); a given action runs once however fast it is tapped; and the
/// cue that the message scrolls is visible against the snackbar in both the
/// light and the dark theme (WCAG 1.4.11).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/common/long_message_snack_bar.dart';

const _message = 'Something to read and act on.';
const _opener = Key('show_long_message');

Future<void> _show(
  WidgetTester tester, {
  SnackBarAction? action,
  ThemeData? theme,
  bool error = false,
  String message = _message,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: _opener,
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              longMessageSnackBar(
                context,
                message,
                action: action,
                error: error,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_opener));
  await tester.pumpAndSettle();
}

/// WCAG relative luminance.
double _luminance(Color c) {
  double linear(double v) => v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  testWidgets('with only Dismiss it stays until dismissed', (tester) async {
    await _show(tester);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text(_message), findsOneWidget, reason: 'no timeout');

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text(_message), findsNothing);
  });

  testWidgets('with an action it stays until the action or the close button', (
    tester,
  ) async {
    var runs = 0;
    await _show(
      tester,
      action: SnackBarAction(label: 'Act', onPressed: () => runs++),
    );
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text(_message), findsOneWidget, reason: 'no timeout');
    expect(find.text('Act'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text(_message), findsNothing);
    expect(runs, 0, reason: 'closing is not acting');
  });

  testWidgets('its action closes it and runs once, however fast it is tapped', (
    tester,
  ) async {
    var runs = 0;
    await _show(
      tester,
      action: SnackBarAction(label: 'Act', onPressed: () => runs++),
    );
    await tester.tap(find.text('Act'));
    await tester.tap(find.text('Act'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(runs, 1);
    expect(find.text(_message), findsNothing);
  });

  for (final (name, theme) in [
    ('light', HavenTheme.light()),
    ('dark', HavenTheme.dark()),
  ]) {
    for (final error in [false, true]) {
      final variant = error ? '$name, error' : name;
      testWidgets('the scroll cue stands out against the snackbar ($variant)', (
        tester,
      ) async {
        tester.view
          ..physicalSize = const Size(320, 568)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _show(
          tester,
          theme: theme,
          message: List.filled(80, _message).join(' '),
          error: error,
        );

        final scrollbar = tester.widget<RawScrollbar>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(RawScrollbar),
          ),
        );
        final position = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byType(SnackBar),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        expect(position.maxScrollExtent, greaterThan(0), reason: 'it scrolls');
        expect(scrollbar.thumbVisibility, isTrue);
        final background = tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(SnackBar),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;
        final thumb = Color.alphaBlend(scrollbar.thumbColor!, background);
        expect(
          _contrast(thumb, background),
          greaterThanOrEqualTo(3),
          reason: 'a cue nobody can see is no cue (WCAG 1.4.11)',
        );
      });
    }
  }
}
