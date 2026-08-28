/// Widget tests for [MemberSearchField].
///
/// Two promises meet in this one widget.
///
/// **Privacy.** The field takes a Nostr public key, so what the operating
/// system is allowed to KEEP of what is typed here is a guarantee rather than
/// a keyboard preference: the learned-word dictionary and the platform
/// autofill service both live outside Haven's encrypted storage, outside its
/// logout wipe, and inside the OS backup.
///
/// **The E2E contract (plan §9.2).** Both `flutter drive` lanes type into
/// [WidgetKeys.memberSearchInput] and submit with [TextInputAction.done].
/// If submitting stops staging, the lanes do not fail — they hang to a 60 s
/// timeout, twice. Every clause of that contract is pinned below.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/member_pick_state.dart';
import 'package:haven/src/widgets/circles/member_search_field.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';

const _npub =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5';
const _otherNpub =
    'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs9n5u';

class _Harness {
  final List<String> staged = [];
  final List<String> queries = [];
  int qrRequests = 0;
}

Future<_Harness> _pumpField(
  WidgetTester tester, {
  MemberPickState Function(String npub)? entryState,
}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MemberSearchField(
          onMemberAdded: harness.staged.add,
          onQueryChanged: harness.queries.add,
          onQrScanRequested: () => harness.qrRequests++,
          entryStateFor:
              entryState ?? (_) => MemberPickState.selectable,
        ),
      ),
    ),
  );
  return harness;
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(WidgetKeys.memberSearchInput));

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(MemberSearchField)));

void main() {
  group('MemberSearchField — what the OS is allowed to keep', () {
    testWidgets('opts the field out of IME personalized learning', (
      tester,
    ) async {
      await _pumpField(tester);

      expect(
        _field(tester).enableIMEPersonalizedLearning,
        isFalse,
        reason:
            'This is the flag that gates the system keyboard learned-word '
            'dictionary. autocorrect/enableSuggestions do not.',
      );
    });

    testWidgets('keeps autocorrect and suggestions off', (tester) async {
      await _pumpField(tester);

      expect(_field(tester).autocorrect, isFalse);
      expect(_field(tester).enableSuggestions, isFalse);
    });

    testWidgets('offers the field to no platform autofill service', (
      tester,
    ) async {
      await _pumpField(tester);

      expect(
        _field(tester).autofillHints,
        isNull,
        reason:
            'An empty hint list — the framework default — still enables '
            'autofill and hands the current editing value to the platform '
            'service. Only null disables it.',
      );
    });
  });

  group('MemberSearchField — the E2E contract', () {
    testWidgets('the keyed field is exactly one focusable editable', (
      tester,
    ) async {
      await _pumpField(tester);

      expect(find.byKey(WidgetKeys.memberSearchInput), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(WidgetKeys.memberSearchInput),
          matching: find.byType(EditableText),
        ),
        findsOneWidget,
        reason:
            'receiveAction() drives whichever editable owns the TextInput '
            'connection; a second one under this key makes which is driven '
            'undefined.',
      );
    });

    testWidgets('carries the done action the drivers submit with', (
      tester,
    ) async {
      await _pumpField(tester);

      expect(_field(tester).textInputAction, TextInputAction.done);
    });

    testWidgets('submitting stages the entered npub', (tester) async {
      final harness = await _pumpField(tester);

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(harness.staged, [_npub]);
    });

    testWidgets('submitting clears the field and keeps the caret in it', (
      tester,
    ) async {
      final harness = await _pumpField(tester);

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(_field(tester).controller!.text, isEmpty);
      expect(harness.queries.last, isEmpty);
      expect(
        tester
            .widget<TextField>(find.byKey(WidgetKeys.memberSearchInput))
            .focusNode!
            .hasFocus,
        isTrue,
        reason: 'the next ID can be typed without re-tapping the field',
      );
    });

    testWidgets('the add button stages too', (tester) async {
      final harness = await _pumpField(tester);

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.tap(find.byIcon(LucideIcons.circlePlus));
      await tester.pump();

      expect(harness.staged, [_npub]);
    });

    testWidgets('an empty field stages nothing and reports no error', (
      tester,
    ) async {
      final harness = await _pumpField(tester);

      await tester.tap(find.byIcon(LucideIcons.circlePlus));
      await tester.pump();

      expect(harness.staged, isEmpty);
      expect(find.text(_l10n(tester).memberSearchHelper), findsOneWidget);
    });

    testWidgets('the QR button reaches the scanner', (tester) async {
      final harness = await _pumpField(tester);

      await tester.tap(find.byIcon(LucideIcons.scanQrCode));
      await tester.pump();

      expect(harness.qrRequests, 1);
    });

    testWidgets('pasting an npub stages it', (tester) async {
      final harness = await _pumpField(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': _npub}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.tap(find.byIcon(LucideIcons.clipboard));
      await tester.pumpAndSettle();

      expect(harness.staged, [_npub]);
    });
  });

  group('MemberSearchField — refusals name their own reason', () {
    testWidgets('malformed input is rejected without staging', (tester) async {
      final harness = await _pumpField(tester);

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        'not-an-id',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(harness.staged, isEmpty);
      expect(find.text(_l10n(tester).memberSearchNoValidId), findsOneWidget);
    });

    testWidgets('the user entering their own ID is told so, and not staged', (
      tester,
    ) async {
      // The shipped defect this fixes: create-circle had no identity read at
      // all, so this npub was staged and validated against the user's own
      // KeyPackage.
      final harness = await _pumpField(
        tester,
        entryState: (_) => MemberPickState.self,
      );

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(harness.staged, isEmpty);
      expect(find.text(_l10n(tester).memberPickerReasonSelf), findsOneWidget);
      expect(
        find.text(_l10n(tester).addMemberAlreadyInCircle),
        findsNothing,
        reason:
            '"Already in this circle" is true of the user themselves and was '
            'the only thing the shipped code could say — the three reasons '
            'exist to end exactly that confusion.',
      );
    });

    testWidgets('an existing circle member is refused, with no relay in the '
        'path', (tester) async {
      final harness = await _pumpField(
        tester,
        entryState: (_) => MemberPickState.alreadyInCircle,
      );

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(harness.staged, isEmpty);
      expect(
        find.text(_l10n(tester).addMemberAlreadyInCircle),
        findsOneWidget,
      );
    });

    testWidgets('an already-staged npub is refused', (tester) async {
      final harness = await _pumpField(
        tester,
        entryState: (npub) => npub == _npub
            ? MemberPickState.alreadyStaged
            : MemberPickState.selectable,
      );

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(harness.staged, isEmpty);
      expect(find.text(_l10n(tester).memberSearchAlreadyAdded), findsOneWidget);

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        _otherNpub,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(harness.staged, [_otherNpub]);
    });

    testWidgets('an error is spoken, not just drawn', (tester) async {
      await _pumpField(tester);
      final announcements = captureAccessibilityAnnouncements(tester);

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        'not-an-id',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        announcements,
        contains(_l10n(tester).memberSearchNoValidId),
        reason:
            'the message moved out of InputDecoration.errorText, which the '
            'framework announced for us',
      );
    });
  });

  group('MemberSearchField — the field does not move under the caret', () {
    testWidgets('its rect is unchanged when an error appears and clears', (
      tester,
    ) async {
      await _pumpField(tester);
      final before = tester.getRect(find.byKey(WidgetKeys.memberSearchInput));

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        'not-an-id',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text(_l10n(tester).memberSearchNoValidId), findsOneWidget);

      expect(
        tester.getRect(find.byKey(WidgetKeys.memberSearchInput)),
        before,
        reason:
            'errorText grew the decoration mid-keystroke; the message now '
            'lives on a sibling line BELOW the field',
      );

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(tester.getRect(find.byKey(WidgetKeys.memberSearchInput)), before);
    });

    testWidgets('the "where an ID comes from" line comes back after an error', (
      tester,
    ) async {
      await _pumpField(tester);
      final l10n = _l10n(tester);

      expect(find.text(l10n.memberSearchHelper), findsOneWidget);

      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        'not-an-id',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text(l10n.memberSearchHelper), findsNothing);

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), _npub);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(
        find.text(l10n.memberSearchHelper),
        findsOneWidget,
        reason:
            'it is the only place the app says where an ID comes from, so it '
            'may be replaced by an error but never lost',
      );
    });
  });

  group('MemberSearchField — the query reaches the list undebounced', () {
    testWidgets('every keystroke is reported in the same frame', (
      tester,
    ) async {
      final harness = await _pumpField(tester);

      // No pump between the keystroke and the read, and no clock advanced:
      // the fold behind the filter is a #[frb(sync)] call on the calling
      // thread, so a debounce here would be a debounce on the filter itself.
      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), 'a');
      expect(harness.queries.last, 'a');

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), 'al');
      expect(harness.queries.last, 'al');

      await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), '');
      expect(harness.queries.last, isEmpty);
    });
  });
}
