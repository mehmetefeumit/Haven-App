/// Widget tests for [MemberDetailSheet] and [showMemberDetailSheet] (plan
/// §6.3 F10).
///
/// Covers nickname save/clear/cancel (always-set `CircleService.
/// setContactDisplayName`, plan D6), copy-npub, the self-row nickname-editor
/// hiding, and the sheet's own semantics.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/member_detail_sheet.dart';
import 'package:haven/src/widgets/identity/avatar.dart';

import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';

const _memberPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _memberNpub =
    'npub1hwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwasxw04hu';

/// Mirrors the sheet's private `_shortNpub` truncation (12/6) so assertions
/// stay in sync with production formatting.
String _shortNpub(String npub) =>
    NpubValidator.truncate(npub, prefixLength: 12, suffixLength: 6);

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _selfNpub =
    'npub1424242424242424242424242424242424242424242424242424qamrcaj';

CircleMember _buildMember({String? displayName}) => CircleMember(
  pubkey: _memberPubkey,
  npub: _memberNpub,
  displayName: displayName,
  isAdmin: false,
  status: MembershipStatus.accepted,
);

Widget _buildHarness({
  required CircleMember member,
  bool isSelf = false,
  MockCircleService? circleService,
  MockProfileService? profileService,
  String? selfDisplayName,
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
      home: Scaffold(
        body: MemberDetailSheet(member: member, isSelf: isSelf),
      ),
    ),
  );
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
            status: MembershipStatus.accepted,
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
              status: MembershipStatus.accepted,
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
    testWidgets(
      'Save Nickname calls setContactDisplayName with the trimmed text',
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
      'Clear Nickname calls setContactDisplayName with null and clears the '
      'field',
      (tester) async {
        final svc = MockCircleService();
        await tester.pumpWidget(
          _buildHarness(
            member: _buildMember(displayName: 'Bobby'),
            circleService: svc,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(WidgetKeys.memberNicknameClear));
        await tester.pumpAndSettle();

        expect(svc.methodCalls, contains('setContactDisplayName'));
        expect(svc.nicknames[_memberPubkey], isNull);
        expect(
          tester
              .widget<TextField>(find.byKey(WidgetKeys.memberNicknameField))
              .controller
              ?.text,
          isEmpty,
        );
      },
    );

    testWidgets(
      'typing then leaving without saving never calls '
      'setContactDisplayName (cancel)',
      (tester) async {
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

        // The user navigates away without tapping Save/Clear.
        expect(svc.methodCalls, isNot(contains('setContactDisplayName')));
      },
    );

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

    testWidgets('the nickname save/clear buttons are reachable by key', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_buildHarness(member: _buildMember()));
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.memberNicknameSave), findsOneWidget);
      expect(find.byKey(WidgetKeys.memberNicknameClear), findsOneWidget);

      handle.dispose();
    });
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
                          status: MembershipStatus.accepted,
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
