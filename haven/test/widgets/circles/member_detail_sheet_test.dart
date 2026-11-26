/// Widget tests for [MemberDetailSheet] and [showMemberDetailSheet] (plan
/// §6.3 F10).
///
/// Covers nickname save/clear/cancel (always-set `CircleService.
/// setContactDisplayName`, plan D6) and the save button's state machine,
/// shared with the display-name card (saved / unsaved / saving / failed),
/// the title following the saved nickname, viewing the member's photo full
/// screen, copy-npub, the self-row nickname-editor hiding, and the sheet's
/// own semantics.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/member_detail_sheet.dart';
import 'package:haven/src/widgets/common/circular_save_button.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/identity/avatar_fullscreen_viewer.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../helpers/log_capture.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';

const _memberPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _memberNpub =
    'npub1hwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwasxw04hu';

/// The sheet's private `_shortNpub` is [NpubValidator.shortenForDisplay];
/// calling the canonical helper keeps assertions in sync with production
/// formatting instead of restating the 12/6 literals.
String _shortNpub(String npub) => NpubValidator.shortenForDisplay(npub);

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _selfNpub =
    'npub1424242424242424242424242424242424242424242424242424qamrcaj';

CircleMember _buildMember({String? displayName}) => CircleMember(
  pubkey: _memberPubkey,
  npub: _memberNpub,
  displayName: displayName,
  isAdmin: false,
);

Widget _buildHarness({
  required CircleMember member,
  bool isSelf = false,
  MockCircleService? circleService,
  MockProfileService? profileService,
  String? selfDisplayName,
  bool disableAnimations = false,
}) {
  return ProviderScope(
    overrides: [
      circleServiceProvider.overrideWithValue(
        circleService ?? MockCircleService(),
      ),
      profileServiceProvider.overrideWithValue(
        profileService ?? MockProfileService(),
      ),
      identityProvider.overrideWith(
        (_) async => isSelf
            ? Identity(
                pubkeyHex: member.pubkey,
                npub: member.npub,
                createdAt: DateTime(2024),
              )
            : null,
      ),
      displayNameProvider.overrideWith((_) async => selfDisplayName),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: MemberDetailSheet(member: member, isSelf: isSelf),
      ),
    ),
  );
}

ButtonStyleButton _saveButton(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(find.byKey(WidgetKeys.memberNicknameSave));

Finder _inSave(Finder matching) => find.descendant(
  of: find.byKey(WidgetKeys.memberNicknameSave),
  matching: matching,
);

/// The header row's title — the sheet's resolved name for the member.
String? _titleText(WidgetTester tester) {
  final headerTile = tester.widget<ListTile>(
    find.ancestor(
      of: find.byType(HavenAvatar),
      matching: find.byType(ListTile),
    ),
  );
  return (headerTile.title! as Text).data;
}

/// Opens the sheet for [member] the way the member list does, through
/// [showMemberDetailSheet], and taps to open it; the caller pumps.
Future<void> _openSheet(
  WidgetTester tester, {
  required CircleMember member,
  MockProfileService? profileService,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        circleServiceProvider.overrideWithValue(MockCircleService()),
        profileServiceProvider.overrideWithValue(
          profileService ?? MockProfileService(),
        ),
        identityProvider.overrideWith((_) async => null),
        displayNameProvider.overrideWith((_) async => null),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showMemberDetailSheet(context, ref, member),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemberDetailSheet — content', () {
    testWidgets('renders the member name and npub', (tester) async {
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(displayName: 'Bob')),
      );
      await tester.pumpAndSettle();

      // "Bob" appears twice: the header title AND the nickname field's
      // prefilled text (the local petname) — assert the header specifically.
      expect(
        find.widgetWithText(ListTile, 'Bob'),
        findsOneWidget,
        reason: 'header title shows the resolved name',
      );
      expect(find.textContaining(_shortNpub(_memberNpub)), findsOneWidget);
    });

    testWidgets('falls back to the npub when no nickname/profile is known', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      // Both the header title (falls back to the npub) and the subtitle
      // (always the npub) show it — the nickname field stays empty, not
      // prefilled with the npub.
      expect(find.textContaining(_shortNpub(_memberNpub)), findsWidgets);
    });

    testWidgets('the nickname field is prefilled from the local petname', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(displayName: 'Bobby')),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(WidgetKeys.memberNicknameField),
      );
      expect(field.controller?.text, 'Bobby');
    });

    testWidgets(
      'the nickname field has a persistent label, not hint-only (NIT-c)',
      (tester) async {
        await tester.pumpWidget(_buildHarness(member: _buildMember()));
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(
          find.byKey(WidgetKeys.memberNicknameField),
        );
        expect(
          field.decoration?.labelText,
          'Nickname',
          reason:
              'Once text is entered the hint disappears — a persistent '
              "labelText keeps the field's purpose announced to screen "
              'readers.',
        );
      },
    );

    testWidgets(
      'the npub subtitle is forced LTR regardless of ambient text '
      'direction (#3)',
      (tester) async {
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(displayName: 'Bob')),
        );
        await tester.pumpAndSettle();

        final headerTile = tester.widget<ListTile>(
          find.ancestor(
            of: find.byType(HavenAvatar),
            matching: find.byType(ListTile),
          ),
        );
        final subtitle = headerTile.subtitle! as Text;
        expect(subtitle.data, _shortNpub(_memberNpub));
        expect(subtitle.textDirection, TextDirection.ltr);
      },
    );

    testWidgets(
      'the title is forced-LTR mono when it falls back to the npub (#3)',
      (tester) async {
        await tester.pumpWidget(_buildHarness(member: _buildMember()));
        await tester.pumpAndSettle();

        final headerTile = tester.widget<ListTile>(
          find.ancestor(
            of: find.byType(HavenAvatar),
            matching: find.byType(ListTile),
          ),
        );
        final title = headerTile.title! as Text;
        expect(title.data, _shortNpub(_memberNpub));
        expect(title.textDirection, TextDirection.ltr);
        expect(
          title.style?.fontFamily,
          HavenTypography.mono.fontFamily,
          reason:
              'Mirrors CircleMemberTile: an npub-fallback title must render '
              'in the mono style, matching the always-mono subtitle.',
        );
      },
    );

    testWidgets(
      'the title does NOT force LTR/mono when a real name is resolved '
      '(#3 regression guard)',
      (tester) async {
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(displayName: 'Bob')),
        );
        await tester.pumpAndSettle();

        final headerTile = tester.widget<ListTile>(
          find.ancestor(
            of: find.byType(HavenAvatar),
            matching: find.byType(ListTile),
          ),
        );
        final title = headerTile.title! as Text;
        expect(title.data, 'Bob');
        expect(title.textDirection, isNull);
        expect(title.style, isNull);
      },
    );
  });

  group('MemberDetailSheet — self hides the nickname editor', () {
    testWidgets('no nickname field/save/clear button for the self row', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHarness(
          member: const CircleMember(
            pubkey: _selfPubkey,
            npub: _selfNpub,
            isAdmin: false,
          ),
          isSelf: true,
          selfDisplayName: 'Alice',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.memberNicknameField), findsNothing);
      expect(find.byKey(WidgetKeys.memberNicknameSave), findsNothing);
      expect(find.byKey(WidgetKeys.memberNicknameClear), findsNothing);
      // Copy-npub stays available for self too.
      expect(find.byKey(WidgetKeys.memberDetailCopyPublicKey), findsOneWidget);
    });

    testWidgets(
      'the self row resolves its name via the settings display name, not '
      'the generic resolver',
      (tester) async {
        await tester.pumpWidget(
          _buildHarness(
            member: const CircleMember(
              pubkey: _selfPubkey,
              npub: _selfNpub,
              isAdmin: false,
            ),
            isSelf: true,
            selfDisplayName: 'Alice',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Alice'), findsOneWidget);
      },
    );
  });

  group('MemberDetailSheet — nickname save / clear / cancel', () {
    testWidgets('opts the nickname field out of IME personalized learning', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      // A petname is a contact name the user chose to keep only on this
      // device; the keyboard's learned-word dictionary is outside Haven's
      // encrypted storage, outside its logout wipe, and inside the OS backup.
      final field = tester.widget<TextField>(
        find.byKey(WidgetKeys.memberNicknameField),
      );
      expect(field.enableIMEPersonalizedLearning, isFalse);
    });

    testWidgets('offers the nickname field to no platform autofill service', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      // A petname the user invented is not something an autofill service
      // holds, so the feature buys nothing here while still handing it the
      // current editing value — an empty hint list is the framework default
      // and does NOT disable autofill.
      final field = tester.widget<TextField>(
        find.byKey(WidgetKeys.memberNicknameField),
      );
      expect(field.autofillHints, isNull);
    });

    testWidgets(
      'the save button calls setContactDisplayName with the trimmed text',
      (tester) async {
        final svc = MockCircleService();
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(), circleService: svc),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          '  Bobby  ',
        );
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pumpAndSettle();

        expect(svc.methodCalls, contains('setContactDisplayName'));
        expect(svc.nicknames[_memberPubkey], 'Bobby');
      },
    );

    testWidgets(
      'the clear icon only empties the field: retyping replaces the saved '
      'nickname and nothing is ever deleted',
      (tester) async {
        final svc = MockCircleService();
        await tester.pumpWidget(
          _buildHarness(
            member: _buildMember(displayName: 'Mom'),
            circleService: svc,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.memberNicknameClear));
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<TextField>(find.byKey(WidgetKeys.memberNicknameField))
              .controller
              ?.text,
          isEmpty,
        );
        expect(svc.methodCalls, isNot(contains('setContactDisplayName')));
        expect(_titleText(tester), 'Mom', reason: 'still the saved nickname');
        expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);

        // The field kept focus, so typing goes straight into it.
        tester.testTextInput.enterText('Mum');
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pumpAndSettle();

        expect(
          svc.methodCalls.where((c) => c == 'setContactDisplayName').length,
          1,
        );
        expect(svc.nicknames[_memberPubkey], 'Mum');
      },
    );

    testWidgets(
      'the clear icon leaves the field focused, its semantics node included, '
      'as the icon goes away',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(displayName: 'Mom')),
        );
        await tester.pumpAndSettle();
        final editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        expect(editable.widget.focusNode.hasFocus, isFalse);

        await tester.tap(find.byKey(WidgetKeys.memberNicknameClear));
        await tester.pumpAndSettle();

        expect(find.byKey(WidgetKeys.memberNicknameClear), findsNothing);
        expect(editable.widget.focusNode.hasFocus, isTrue);
        expect(
          tester.getSemantics(find.byType(EditableText)),
          isSemantics(isTextField: true, isFocused: true),
        );
        handle.dispose();
      },
    );

    testWidgets('typing then leaving without saving never calls '
        'setContactDisplayName (cancel)', (tester) async {
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(), circleService: svc),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(WidgetKeys.memberNicknameField),
        'Unsaved Name',
      );
      await tester.pump();

      // The user navigates away without tapping save or clear.
      expect(svc.methodCalls, isNot(contains('setContactDisplayName')));
    });

    testWidgets('an empty Save clears the nickname (treated as clear)', (
      tester,
    ) async {
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHarness(
          member: _buildMember(displayName: 'Bobby'),
          circleService: svc,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(WidgetKeys.memberNicknameField), '');
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
      await tester.pumpAndSettle();

      expect(svc.nicknames[_memberPubkey], isNull);
    });
  });

  group('MemberDetailSheet — nickname save button state', () {
    testWidgets(
      'with no nickname it starts saved, disabled, "No nickname set"',
      (tester) async {
        await tester.pumpWidget(_buildHarness(member: _buildMember()));
        await tester.pumpAndSettle();

        expect(
          find.ancestor(
            of: find.byKey(WidgetKeys.memberNicknameSave),
            matching: find.byType(CircularSaveButton),
          ),
          findsOneWidget,
          reason: "the display-name card's button, so the two cannot drift",
        );
        expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNull);
        expect(find.byTooltip('No nickname set'), findsOneWidget);
        expect(
          find.byKey(WidgetKeys.memberNicknameClear),
          findsNothing,
          reason: 'an empty field has nothing to clear',
        );
      },
    );

    testWidgets('with a nickname it starts saved, "Nickname saved"', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(displayName: 'Bobby')),
      );
      await tester.pumpAndSettle();

      expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      expect(find.byTooltip('Nickname saved'), findsOneWidget);
    });

    testWidgets('an edit flips it to unsaved; undoing the edit flips it back', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(displayName: 'Bobby')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(WidgetKeys.memberNicknameField), 'Bo');
      await tester.pumpAndSettle();
      expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
      expect(_inSave(find.byIcon(LucideIcons.check)), findsNothing);
      expect(_saveButton(tester).onPressed, isNotNull);
      expect(find.byTooltip('Save nickname'), findsOneWidget);

      await tester.enterText(
        find.byKey(WidgetKeys.memberNicknameField),
        ' Bobby ',
      );
      await tester.pumpAndSettle();
      expect(
        _inSave(find.byIcon(LucideIcons.check)),
        findsOneWidget,
        reason: 'a whitespace-only difference is not an edit',
      );
      expect(_saveButton(tester).onPressed, isNull);
    });

    testWidgets(
      'a save shows the spinner while in flight, then the check, the new '
      'title and a polite announcement',
      (tester) async {
        final svc = MockCircleService()
          ..setContactDisplayNameGate = Completer<void>();
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(), circleService: svc),
        );
        await tester.pumpAndSettle();
        final announcements = captureAccessibilityAnnouncementsWithPriority(
          tester,
        );

        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Bobby',
        );
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pump();

        expect(_inSave(find.byType(CircularProgressIndicator)), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNull);
        expect(find.byTooltip('Saving nickname'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(WidgetKeys.memberNicknameField))
              .enabled,
          isNot(isFalse),
          reason: 'the field stays editable during a save',
        );
        expect(
          _titleText(tester),
          _shortNpub(_memberNpub),
          reason: 'the title changes only once the save has landed',
        );
        expect(announcements, isEmpty, reason: 'no progress announcement');

        svc.setContactDisplayNameGate!.complete();
        await tester.pumpAndSettle();

        expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
        expect(_inSave(find.byType(CircularProgressIndicator)), findsNothing);
        expect(_saveButton(tester).onPressed, isNull);
        expect(find.byTooltip('Nickname saved'), findsOneWidget);
        expect(svc.nicknames[_memberPubkey], 'Bobby');
        expect(_titleText(tester), 'Bobby');
        expect(
          tester.widget<HavenAvatar>(find.byType(HavenAvatar)).initials,
          'B',
        );
        expect(announcements, [
          (message: 'Nickname saved', assertiveness: Assertiveness.polite),
        ]);
      },
    );

    testWidgets(
      'a failed save shows retry, announces assertively, keeps the old title '
      'and logs neither the nickname nor the pubkey',
      (tester) async {
        // Restored inside the body: testWidgets checks that debugPrint is
        // back before tear-down callbacks run.
        final logs = LogCapture();
        addTearDown(logs.restore);
        final svc = MockCircleService()
          ..shouldThrowOnSetContactDisplayName = true;
        await tester.pumpWidget(
          _buildHarness(
            member: _buildMember(displayName: 'Bob'),
            circleService: svc,
          ),
        );
        await tester.pumpAndSettle();
        final announcements = captureAccessibilityAnnouncementsWithPriority(
          tester,
        );

        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Quillon Marsh',
        );
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pumpAndSettle();

        expect(_inSave(find.byIcon(LucideIcons.rotateCcw)), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNotNull, reason: 'retry');
        expect(find.byTooltip('Nickname not saved. Retry'), findsOneWidget);
        expect(announcements, [
          (
            message: 'Nickname not saved, try again',
            assertiveness: Assertiveness.assertive,
          ),
        ]);
        expect(_titleText(tester), 'Bob');
        expect(
          find.textContaining('Mock setContactDisplayName error'),
          findsNothing,
          reason: 'never a raw error in the UI (Security Rule 8)',
        );
        logs
          ..assertContains('[MemberDetail] setContactDisplayName failed')
          ..assertNoNeedles([
            'Quillon Marsh',
            _memberPubkey,
            _memberNpub,
            'Mock setContactDisplayName error',
          ])
          ..restore();

        svc.shouldThrowOnSetContactDisplayName = false;
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pumpAndSettle();
        expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
        expect(svc.nicknames[_memberPubkey], 'Quillon Marsh');
      },
    );

    testWidgets(
      'a keystroke during the save keeps the spinner; the save then ends '
      'unsaved because the newer text still needs saving',
      (tester) async {
        final svc = MockCircleService()
          ..setContactDisplayNameGate = Completer<void>();
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(), circleService: svc),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Bobby',
        );
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pump();
        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Bobby2',
        );
        await tester.pump();

        expect(_inSave(find.byType(CircularProgressIndicator)), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNull);

        svc.setContactDisplayNameGate!.complete();
        await tester.pumpAndSettle();

        expect(svc.nicknames[_memberPubkey], 'Bobby');
        expect(_titleText(tester), 'Bobby');
        expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
        expect(_saveButton(tester).onPressed, isNotNull);
      },
    );

    testWidgets(
      'the clear icon writes nothing; saving the emptied field removes the '
      'nickname with the save animation, then the title falls back',
      (tester) async {
        final svc = MockCircleService()
          ..setContactDisplayNameGate = Completer<void>();
        await tester.pumpWidget(
          _buildHarness(
            member: _buildMember(displayName: 'Bobby'),
            circleService: svc,
          ),
        );
        await tester.pumpAndSettle();
        final announcements = captureAccessibilityAnnouncements(tester);

        await tester.tap(find.byKey(WidgetKeys.memberNicknameClear));
        await tester.pumpAndSettle();

        expect(svc.methodCalls, isNot(contains('setContactDisplayName')));
        expect(
          find.byKey(WidgetKeys.memberNicknameClear),
          findsNothing,
          reason: 'the emptied field has nothing left to clear',
        );
        expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
        expect(_titleText(tester), 'Bobby');
        expect(announcements, isEmpty);

        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pump();
        expect(_inSave(find.byType(CircularProgressIndicator)), findsOneWidget);

        svc.setContactDisplayNameGate!.complete();
        await tester.pumpAndSettle();

        expect(svc.nicknames.containsKey(_memberPubkey), isTrue);
        expect(svc.nicknames[_memberPubkey], isNull);
        expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
        expect(find.byTooltip('No nickname set'), findsOneWidget);
        expect(_titleText(tester), _shortNpub(_memberNpub));
        expect(announcements, ['Nickname cleared']);
      },
    );

    testWidgets('a failed save of the emptied field shows retry, and retry '
        'clears', (tester) async {
      final svc = MockCircleService()
        ..shouldThrowOnSetContactDisplayName = true;
      await tester.pumpWidget(
        _buildHarness(
          member: _buildMember(displayName: 'Bobby'),
          circleService: svc,
        ),
      );
      await tester.pumpAndSettle();
      final announcements = captureAccessibilityAnnouncementsWithPriority(
        tester,
      );

      await tester.tap(find.byKey(WidgetKeys.memberNicknameClear));
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
      await tester.pumpAndSettle();

      expect(_inSave(find.byIcon(LucideIcons.rotateCcw)), findsOneWidget);
      expect(_titleText(tester), 'Bobby');
      expect(announcements.single.assertiveness, Assertiveness.assertive);

      svc.shouldThrowOnSetContactDisplayName = false;
      await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
      await tester.pumpAndSettle();

      expect(svc.nicknames[_memberPubkey], isNull);
      expect(svc.nicknames.containsKey(_memberPubkey), isTrue);
      expect(_titleText(tester), _shortNpub(_memberNpub));
    });

    testWidgets('clearing text that was never saved writes nothing', (
      tester,
    ) async {
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(), circleService: svc),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(WidgetKeys.memberNicknameField), 'Bo');
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.memberNicknameClear));
      await tester.pumpAndSettle();

      expect(svc.methodCalls, isNot(contains('setContactDisplayName')));
      expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
    });

    testWidgets('a save refreshes the circles list', (tester) async {
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(), circleService: svc),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MemberDetailSheet)),
      );
      final sub = container.listen(circlesProvider, (_, _) {});
      addTearDown(sub.close);
      await tester.pumpAndSettle();
      int reads() =>
          svc.methodCalls.where((c) => c == 'getVisibleCircles').length;
      expect(reads(), 1);

      await tester.enterText(
        find.byKey(WidgetKeys.memberNicknameField),
        'Bobby',
      );
      await tester.pump();
      await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
      await tester.pumpAndSettle();

      expect(reads(), 2);
    });

    testWidgets(
      'a save that lands after the sheet is gone still refreshes the circles '
      'list',
      (tester) async {
        final svc = MockCircleService()
          ..setContactDisplayNameGate = Completer<void>();
        final shown = ValueNotifier<bool>(true);
        addTearDown(shown.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              circleServiceProvider.overrideWithValue(svc),
              profileServiceProvider.overrideWithValue(MockProfileService()),
              identityProvider.overrideWith((_) async => null),
              displayNameProvider.overrideWith((_) async => null),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: shown,
                  builder: (_, on, _) => on
                      ? MemberDetailSheet(member: _buildMember(), isSelf: false)
                      : const SizedBox(),
                ),
              ),
            ),
          ),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold)),
        );
        final sub = container.listen(circlesProvider, (_, _) {});
        addTearDown(sub.close);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Bobby',
        );
        await tester.pump();
        await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
        await tester.pump();
        shown.value = false;
        await tester.pump();
        expect(find.byType(MemberDetailSheet), findsNothing);

        svc.setContactDisplayNameGate!.complete();
        await tester.pumpAndSettle();

        expect(svc.nicknames[_memberPubkey], 'Bobby');
        expect(
          svc.methodCalls.where((c) => c == 'getVisibleCircles').length,
          2,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Done on the keyboard saves an edit', (tester) async {
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(), circleService: svc),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(WidgetKeys.memberNicknameField))
            .textInputAction,
        TextInputAction.done,
      );

      await tester.enterText(
        find.byKey(WidgetKeys.memberNicknameField),
        ' Bobby ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(svc.nicknames[_memberPubkey], 'Bobby');
      expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
    });

    testWidgets(
      'Done saves nothing without an edit, and nothing twice while a save '
      'is in flight',
      (tester) async {
        final svc = MockCircleService()
          ..setContactDisplayNameGate = Completer<void>();
        await tester.pumpWidget(
          _buildHarness(
            member: _buildMember(displayName: 'Bobby'),
            circleService: svc,
          ),
        );
        await tester.pumpAndSettle();
        int saves() =>
            svc.methodCalls.where((c) => c == 'setContactDisplayName').length;

        await tester.showKeyboard(find.byKey(WidgetKeys.memberNicknameField));
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(saves(), 0, reason: 'the field matches the saved nickname');

        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Bob',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.enterText(
          find.byKey(WidgetKeys.memberNicknameField),
          'Bo',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(saves(), 1);

        svc.setContactDisplayNameGate!.complete();
        await tester.pumpAndSettle();
        expect(saves(), 1);
        expect(svc.nicknames[_memberPubkey], 'Bob');
      },
    );

    testWidgets('a tap on save while its icon is still swapping takes '
        'effect', (tester) async {
      final svc = MockCircleService();
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(), circleService: svc),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(WidgetKeys.memberNicknameField), 'Bo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Mid-swap: the outgoing and incoming icons are both on screen.
      expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
      expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);

      await tester.tap(find.byKey(WidgetKeys.memberNicknameSave));
      await tester.pumpAndSettle();

      expect(svc.nicknames[_memberPubkey], 'Bo');
      expect(_titleText(tester), 'Bo');
    });

    testWidgets('the save button animates its icon swap', (tester) async {
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(WidgetKeys.memberNicknameField), 'Bo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(_inSave(find.byType(AnimatedSwitcher)), findsOneWidget);
      expect(_inSave(find.byIcon(LucideIcons.check)), findsOneWidget);
      expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
    });

    testWidgets('reduced motion swaps the save icon with no animation', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(), disableAnimations: true),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(WidgetKeys.memberNicknameField), 'Bo');
      await tester.pump();

      expect(_inSave(find.byType(AnimatedSwitcher)), findsNothing);
      expect(_inSave(find.byIcon(LucideIcons.check)), findsNothing);
      expect(_inSave(find.byIcon(LucideIcons.arrowUp)), findsOneWidget);
    });
  });

  group('MemberDetailSheet — photo full screen', () {
    final photo = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]);

    testWidgets("tapping a member's photo opens it full screen", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _buildHarness(
          member: _buildMember(displayName: 'Bob'),
          profileService: MockProfileService(
            memberProfiles: {
              _memberPubkey: Profile(
                pubkeyHex: _memberPubkey,
                pictureBytes: photo,
              ),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The header ListTile merges its row into one node, so the photo's
      // button role and action ride on it, its label leading.
      final header = tester.getSemantics(
        find.byKey(WidgetKeys.memberDetailPhoto),
      );
      expect(header, isSemantics(isButton: true, hasTapAction: true));
      expect(header.label, startsWith('View profile photo'));
      expect(
        tester.getSize(find.byKey(WidgetKeys.memberDetailPhoto)),
        const Size(48, 48),
      );

      await tester.tap(find.byKey(WidgetKeys.memberDetailPhoto));
      await tester.pumpAndSettle();

      final viewer = tester.widget<AvatarFullscreenViewer>(
        find.byType(AvatarFullscreenViewer),
      );
      expect(viewer.imageBytes, same(photo));
      handle.dispose();
    });

    testWidgets('the self row opens the own profile photo', (tester) async {
      await tester.pumpWidget(
        _buildHarness(
          member: const CircleMember(
            pubkey: _selfPubkey,
            npub: _selfNpub,
            isAdmin: false,
          ),
          isSelf: true,
          selfDisplayName: 'Alice',
          profileService: MockProfileService(
            ownProfile: Profile(pubkeyHex: _selfPubkey, pictureBytes: photo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.memberDetailPhoto));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<AvatarFullscreenViewer>(find.byType(AvatarFullscreenViewer))
            .imageBytes,
        same(photo),
      );
    });

    testWidgets('without a photo the avatar offers nothing to tap', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _buildHarness(member: _buildMember(displayName: 'Bob')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.memberDetailPhoto), findsNothing);
      expect(
        tester.getSemantics(find.byType(HavenAvatar)),
        isSemantics(isButton: false, hasTapAction: false),
      );
      expect(find.bySemanticsLabel(RegExp('View profile photo')), findsNothing);

      await tester.tap(find.byType(HavenAvatar));
      await tester.pumpAndSettle();
      expect(find.byType(AvatarFullscreenViewer), findsNothing);
      handle.dispose();
    });

    testWidgets(
      "the viewer opens at once on the member's thumbnail, then shows the "
      'full-size copy the device holds, read from the store alone',
      (tester) async {
        final full = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x03]);
        final profiles = MockProfileService(
          memberProfiles: {
            _memberPubkey: Profile(
              pubkeyHex: _memberPubkey,
              pictureBytes: photo,
            ),
          },
        )..memberPictureGate = Completer<void>();
        profiles.memberPictures[_memberPubkey] = full;
        await tester.pumpWidget(
          _buildHarness(
            member: _buildMember(displayName: 'Bob'),
            profileService: profiles,
          ),
        );
        await tester.pumpAndSettle();
        final before = profiles.methodCalls.length;

        await tester.tap(find.byKey(WidgetKeys.memberDetailPhoto));
        await tester.pumpAndSettle();

        // The full-size read has not landed: the thumbnail is on screen.
        Uint8List shown() => tester
            .widget<AvatarFullscreenViewer>(
              find.byType(AvatarFullscreenViewer),
            )
            .imageBytes;
        expect(shown(), same(photo));

        profiles.memberPictureGate!.complete();
        await tester.pumpAndSettle();

        expect(shown(), same(full));
        expect(
          profiles.methodCalls.skip(before).map((c) => c.method),
          ['getMemberPicture'],
          reason: 'one local read; nothing that fetches from the network',
        );
        expect(
          profiles.methodCalls.last.args['pubkeyHex'],
          _memberPubkey,
        );
      },
    );

    testWidgets('with no full-size copy the viewer keeps the thumbnail', (
      tester,
    ) async {
      final profiles = MockProfileService(
        memberProfiles: {
          _memberPubkey: Profile(pubkeyHex: _memberPubkey, pictureBytes: photo),
        },
      );
      await tester.pumpWidget(
        _buildHarness(
          member: _buildMember(displayName: 'Bob'),
          profileService: profiles,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.memberDetailPhoto));
      await tester.pumpAndSettle();

      expect(
        profiles.methodCalls.map((c) => c.method),
        contains('getMemberPicture'),
      );
      expect(
        tester
            .widget<AvatarFullscreenViewer>(find.byType(AvatarFullscreenViewer))
            .imageBytes,
        same(photo),
      );
    });

    testWidgets('a tap on the photo while the sheet is still sliding in opens '
        'the viewer', (tester) async {
      await _openSheet(
        tester,
        member: _buildMember(displayName: 'Bob'),
        profileService: MockProfileService(
          memberProfiles: {
            _memberPubkey: Profile(
              pubkeyHex: _memberPubkey,
              pictureBytes: photo,
            ),
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final route = ModalRoute.of(
        tester.element(find.byType(MemberDetailSheet)),
      )!;
      expect(
        route.animation!.status,
        AnimationStatus.forward,
        reason: 'the tap must land mid-slide',
      );

      await tester.tap(find.byKey(WidgetKeys.memberDetailPhoto));
      await tester.pumpAndSettle();

      expect(find.byType(AvatarFullscreenViewer), findsOneWidget);
    });
  });

  group('MemberDetailSheet — keyboard', () {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'at text scale $textScale on a small phone the keyboard covers '
        'neither the nickname field nor its save button',
        (tester) async {
          const screen = Size(320, 568);
          const keyboard = 260.0;
          tester.view
            ..physicalSize = screen
            ..devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await _openSheet(
            tester,
            member: _buildMember(displayName: 'Bob'),
            textScale: textScale,
          );
          await tester.pumpAndSettle();

          await tester.showKeyboard(find.byKey(WidgetKeys.memberNicknameField));
          tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          for (final key in [
            WidgetKeys.memberNicknameField,
            WidgetKeys.memberNicknameSave,
          ]) {
            final rect = tester.getRect(find.byKey(key));
            expect(rect.top, greaterThanOrEqualTo(0), reason: '$key');
            expect(
              rect.bottom,
              lessThanOrEqualTo(screen.height - keyboard),
              reason: '$key is above the keyboard',
            );
          }
        },
      );
    }
  });

  group('MemberDetailSheet — copy public key', () {
    late List<MethodCall> platformCalls;

    setUp(() {
      platformCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            platformCalls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('copies the full npub, fires haptics, shows a SnackBar', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(WidgetKeys.memberDetailCopyPublicKey));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final clipboardCall = platformCalls.firstWhere(
        (c) => c.method == 'Clipboard.setData',
      );
      expect((clipboardCall.arguments as Map)['text'], _memberNpub);
      expect(
        platformCalls.any(
          (c) =>
              c.method == 'HapticFeedback.vibrate' &&
              c.arguments == 'HapticFeedbackType.mediumImpact',
        ),
        isTrue,
      );
      expect(find.text('Public key copied to clipboard'), findsOneWidget);
    });
  });

  group('MemberDetailSheet — semantics', () {
    testWidgets('the copy-key row exposes a tap action', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      expect(find.text('Copy Public Key'), findsOneWidget);
      final node = tester.getSemantics(
        find.byKey(WidgetKeys.memberDetailCopyPublicKey),
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      handle.dispose();
    });

    testWidgets(
      'the nickname save and clear buttons are labelled 48dp buttons',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _buildHarness(member: _buildMember(displayName: 'Bobby')),
        );
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(find.byKey(WidgetKeys.memberNicknameSave)),
          isSemantics(label: 'Nickname saved', isButton: true),
        );
        expect(
          tester.getSemantics(find.byKey(WidgetKeys.memberNicknameClear)),
          isSemantics(
            tooltip: 'Clear nickname',
            isButton: true,
            hasTapAction: true,
          ),
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        handle.dispose();
      },
    );
  });

  group('showMemberDetailSheet', () {
    testWidgets(
      'opens a modal bottom sheet with the member detail content',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              circleServiceProvider.overrideWithValue(MockCircleService()),
              profileServiceProvider.overrideWithValue(MockProfileService()),
              identityProvider.overrideWith((_) async => null),
              displayNameProvider.overrideWith((_) async => null),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => showMemberDetailSheet(
                        context,
                        ref,
                        _buildMember(displayName: 'Bob'),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.byType(MemberDetailSheet), findsOneWidget);
        expect(find.widgetWithText(ListTile, 'Bob'), findsOneWidget);
        expect(find.text('Member Details'), findsOneWidget);
      },
    );

    testWidgets(
      'detects self from the currently loaded identity and hides the '
      'nickname editor',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              circleServiceProvider.overrideWithValue(MockCircleService()),
              profileServiceProvider.overrideWithValue(MockProfileService()),
              identityProvider.overrideWith(
                (_) async => Identity(
                  pubkeyHex: _selfPubkey,
                  npub: _selfNpub,
                  createdAt: DateTime(2024),
                ),
              ),
              displayNameProvider.overrideWith((_) async => 'Alice'),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => showMemberDetailSheet(
                        context,
                        ref,
                        const CircleMember(
                          pubkey: _selfPubkey,
                          npub: _selfNpub,
                          isAdmin: false,
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Pre-warm identityProvider before tapping — showMemberDetailSheet
        // reads it via `ref.read` (a lazy Riverpod FutureProvider never
        // resolves synchronously on its first read), so this isolated tree
        // must explicitly start + settle it first. In production the
        // Consumer that renders CircleMemberTile already watches
        // identityProvider well before the user can tap anything, so this
        // race never occurs there.
        ProviderScope.containerOf(
          tester.element(find.text('open')),
        ).read(identityProvider);
        await tester.pumpAndSettle();

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.byKey(WidgetKeys.memberNicknameField), findsNothing);
      },
    );
  });
}
