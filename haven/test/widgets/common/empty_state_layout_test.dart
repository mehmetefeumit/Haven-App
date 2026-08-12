/// Layout-robustness tests for the shared placeholder widgets.
///
/// Both widgets are routinely handed a TIGHT height — a whole `Scaffold.body`,
/// or an `Expanded` slot next to fixed chrome — so the height they get is
/// leftover space, not content-driven. When the software keyboard opens, the
/// locale is wordier than English, or the OS text scale is turned up, that
/// leftover shrinks below the content and the placeholder is clipped: the user
/// is told nothing at the exact moment the screen has nothing else to show.
///
/// CI run 31462924650 caught the keyboard case on an iPhone 15 simulator as
/// `A RenderFlex overflowed by 7.8 pixels on the bottom` — from a hand-rolled
/// copy of this widget, reported with a `DEFUNCT` creator chain that named no
/// source line.
///
/// These tests assert the promise directly: under a squeeze, the placeholder
/// stays legible (nothing clipped) and every affordance stays reachable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/widgets.dart';

/// iPhone 15 logical size — the surface the CI failure was observed on.
const _phone = Size(393, 852);

/// Portrait keyboard inset on that device. With the search field focused this
/// is what `Scaffold.resizeToAvoidBottomInset` removes from the body.
const _keyboardInset = 336.0;

/// German is the worst case among the shipped locales for these strings.
const _longLocale = Locale('de');

/// Pumps [child] as a whole `Scaffold.body` on a phone-sized surface, under
/// the real app theme.
///
/// The theme matters: the app ships `HavenTheme.light()`, whose typography
/// overrides Material's default sizes, so a test pumped under a bare
/// `ThemeData` measures text this app never renders.
Future<void> _pumpSqueezed(
  WidgetTester tester,
  Widget child, {
  double bottomInset = 0,
  TextScaler textScaler = TextScaler.noScaling,
  Locale locale = const Locale('en'),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = _phone;
  tester.view.viewInsets = FakeViewPadding(bottom: bottomInset);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);

  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: HavenTheme.light(),
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: inner!,
      ),
      // Fixed chrome above the placeholder, mirroring the two member-picker
      // pages: the placeholder gets what is left, which is what makes the
      // height tight rather than content-driven.
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 56, child: Placeholder()),
              const SizedBox(height: HavenSpacing.lg),
              // The host idiom the placeholders document as their contract.
              Expanded(child: HavenScrollFill(child: child)),
              const SizedBox(height: HavenSpacing.base),
              FilledButton(onPressed: () {}, child: const Text('Continue')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HavenEmptyState — squeezed', () {
    testWidgets('1. survives the keyboard on a phone', (tester) async {
      await _pumpSqueezed(
        tester,
        const HavenEmptyState(
          title: 'Add circle members',
          message: 'Search by ID or scan their QR code to add members.',
          icon: Icons.person_add,
        ),
        bottomInset: _keyboardInset,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('2. survives keyboard + 2x text scale in a long locale', (
      tester,
    ) async {
      await _pumpSqueezed(
        tester,
        const HavenEmptyState(
          title: 'Add circle members',
          message: 'Search by ID or scan their QR code to add members.',
          icon: Icons.person_add,
        ),
        bottomInset: _keyboardInset,
        textScaler: const TextScaler.linear(2),
        locale: _longLocale,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('3. the message stays reachable when it cannot all fit', (
      tester,
    ) async {
      await _pumpSqueezed(
        tester,
        const HavenEmptyState(
          title: 'Add circle members',
          message: 'Search by ID or scan their QR code to add members.',
          icon: Icons.person_add,
        ),
        bottomInset: _keyboardInset,
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);

      // The regression guard: `ensureVisible` needs a Scrollable ancestor, so
      // it fails outright if the placeholder ever loses its scroll parent —
      // which is the difference between "scrolled" and "clipped".
      await tester.ensureVisible(find.text('Add circle members'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('4. an action button stays reachable under a squeeze', (
      tester,
    ) async {
      await _pumpSqueezed(
        tester,
        HavenEmptyState(
          title: 'No circles yet',
          message: 'Create a circle to start sharing your location.',
          actionLabel: 'Create circle',
          actionKey: const Key('empty-state-cta'),
          onAction: () {},
        ),
        bottomInset: _keyboardInset,
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(const Key('empty-state-cta')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('5. with room to spare it is centred, not scrolled', (
      tester,
    ) async {
      await _pumpSqueezed(
        tester,
        const HavenEmptyState(
          title: 'Add circle members',
          message: 'Search by ID or scan their QR code to add members.',
          icon: Icons.person_add,
        ),
      );

      expect(tester.takeException(), isNull);

      // Centring is the normal-case behaviour the fix must not cost: the
      // content spans icon-top to message-bottom, and its midpoint sits on the
      // slot's midpoint.
      final slot = tester.getRect(find.byType(HavenEmptyState));
      final icon = tester.getRect(find.byIcon(Icons.person_add));
      final message = tester.getRect(
        find.text('Search by ID or scan their QR code to add members.'),
      );
      final contentMid = (icon.top + message.bottom) / 2;

      expect((contentMid - slot.center.dy).abs(), lessThan(1));
    });
  });

  group('HavenErrorDisplay — squeezed', () {
    testWidgets('6. survives keyboard + 2x text scale', (tester) async {
      await _pumpSqueezed(
        tester,
        const HavenErrorDisplay(
          title: 'Could not reach your relays',
          message: 'Check your connection and try again.',
        ),
        bottomInset: _keyboardInset,
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('7. the retry action stays reachable under a squeeze', (
      tester,
    ) async {
      await _pumpSqueezed(
        tester,
        HavenErrorDisplay(
          title: 'Could not reach your relays',
          message: 'Check your connection and try again.',
          onRetry: () {},
        ),
        bottomInset: _keyboardInset,
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byType(OutlinedButton));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
