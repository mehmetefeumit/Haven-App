/// Tests for InvitationCard widget.
///
/// Verifies that:
/// - Accepting an invitation republishes a fresh KeyPackage (GAP 6)
/// - The card claims only what Haven knows before the Welcome is decrypted:
///   no circle name, no member count
/// - The inviter is identified by their npub at the canonical 12/6 form,
///   with a resolved Nostr name as a convenience beside it — never instead
///   of it (docs/MEMBER_PICKER_PLAN.md §7.1/§7.3)
/// - The user's own petname outranks the inviter's public name, and says so
///   (docs/MEMBER_PICKER_PLAN.md §7.2)
/// - The attacker-chosen name is bidi-isolated where it is RENDERED beside
///   app text, and announced without those invisible code points
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/services/publish_stagger.dart'
    show kMaxCirclesPerAccount;
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/invitation_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';
import '../../mocks/mock_profile_service.dart';

/// The inviter's hex pubkey — the profile cache key.
///
/// Sourced with [_inviterNpub] from the one place that holds the pair, so
/// the hex and the bech32 below are the SAME key: an independent literal
/// would make "never renders the hex" a search for a string this card was
/// never going to produce.
const String _inviterHex = kTestPubkeyHex;

/// The same key in bech32, which is the form the inviter can hand a user
/// out of band and the only form a user can cross-check.
const String _inviterNpub = kTestNpub;

/// What the card must render: 12 leading characters (5 of them the constant
/// `npub1` HRP) plus the 6-character bech32 checksum from the very end.
const _shortNpub = 'npub140qj8hh...kwpam3';

/// A strong-RTL display name. Attacker-chosen — anyone can publish any
/// kind-0 name — and the reason the key never shares a paragraph with it.
const _rtlName = 'مرحبا';

/// U+2068 FIRST STRONG ISOLATE / U+2069 POP DIRECTIONAL ISOLATE, as the card
/// wraps an attacker-chosen name before rendering it beside app text.
String _isolated(String name) => '\u2068$name\u2069';

/// The pre-join stand-in `CircleManager` puts in `Invitation.circleName`
/// because the real name is inside the still-encrypted Welcome. Nothing on
/// the card may render it, whatever it happens to say.
const _standInCircleName = 'Test Circle';

Invitation _invitation({DateTime? invitedAt}) => Invitation(
  mlsGroupId: const [1, 2, 3, 4],
  circleName: _standInCircleName,
  inviterPubkey: _inviterHex,
  inviterNpub: _inviterNpub,
  invitedAt: invitedAt ?? DateTime(2024),
);

/// The two mocks a card is pumped against, for tests that assert on what it
/// asked them for.
typedef _CardServices = ({
  MockProfileService profile,
  MockCircleService circle,
});

/// Pumps a single card with [profile] (if any) already in the local profile
/// cache and [nickname] (if any) already in the local contact table.
Future<_CardServices> _pumpCard(
  WidgetTester tester, {
  Profile? profile,
  String? nickname,
  bool throwOnGetMemberProfile = false,
  bool throwOnGetContactDisplayName = false,
  DateTime? invitedAt,
  TextScaler textScaler = TextScaler.noScaling,
  Locale locale = kDefaultTestLocale,
}) async {
  final profileService = MockProfileService(
    memberProfiles: profile == null ? {} : {_inviterHex: profile},
  )..shouldThrowOnGetMemberProfile = throwOnGetMemberProfile;
  final circleService = MockCircleService()
    ..shouldThrowOnGetContactDisplayName = throwOnGetContactDisplayName;
  if (nickname != null) {
    circleService.nicknames[_inviterHex] = nickname;
  }

  await pumpLocalized(
    tester,
    Scaffold(
      body: InvitationCard(invitation: _invitation(invitedAt: invitedAt)),
    ),
    locale: locale,
    textScaler: textScaler,
    overrides: [
      circleServiceProvider.overrideWithValue(circleService),
      profileServiceProvider.overrideWithValue(profileService),
    ],
  );
  return (profile: profileService, circle: circleService);
}

/// Every string this card actually renders, in tree order.
List<String> _renderedStrings(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .toList();

/// Every shipped locale, sourced from [AppLocalizations] so the sweep below
/// cannot drift from the actual ARB set.
final List<String> _allLocaleCodes = AppLocalizations.supportedLocales
    .map((locale) => locale.languageCode)
    .toList();

/// Constrains the test view to a narrow phone for the layout sweeps.
void _useNarrowPhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(320, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Every non-empty label a screen reader would announce, in tree order.
///
/// Read off the compiled semantics tree rather than the widget tree, because
/// that is where Flutter's node merging — which decides what is actually
/// spoken — has already happened.
List<String> _announcements(WidgetTester tester) {
  final labels = <String>[];
  void walk(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(tester.semantics.find(find.byType(InvitationCard)));
  return labels;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InvitationCard', () {
    testWidgets('republishes key package after accepting invitation', (
      tester,
    ) async {
      final mockCircleService = _AcceptingCircleService();
      var keyPackageReadCount = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            circleServiceProvider.overrideWithValue(mockCircleService),
            profileServiceProvider.overrideWithValue(MockProfileService()),
            // Track how many times keyPackagePublisherProvider is built
            keyPackagePublisherProvider.overrideWith((ref) {
              keyPackageReadCount++;
              return Future.value(
                const KeyPackageMaintenanceHealthy(
                  canonicalOnRelays: 1,
                  respondersProbed: 1,
                ),
              );
            }),
            // Stub out providers that get invalidated on accept
            pendingInvitationsProvider.overrideWith(
              (ref) => Future.value(<Invitation>[]),
            ),
            circlesProvider.overrideWith((ref) => Future.value(<Circle>[])),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  // Watch keyPackagePublisherProvider so invalidation
                  // triggers a rebuild of its factory function.
                  Consumer(
                    builder: (context, ref, _) {
                      ref.watch(keyPackagePublisherProvider);
                      return const SizedBox.shrink();
                    },
                  ),
                  InvitationCard(invitation: _invitation()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Record the count after initial build
      final countBeforeTap = keyPackageReadCount;

      // Tap the Accept button
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      // Verify acceptInvitation was called
      expect(mockCircleService.methodCalls, contains('acceptInvitation'));

      // Verify keyPackagePublisherProvider was invalidated and rebuilt.
      // The Consumer widget watches the provider, so invalidation triggers
      // a rebuild which re-runs the factory function.
      expect(
        keyPackageReadCount,
        greaterThan(countBeforeTap),
        reason: 'keyPackagePublisherProvider should be rebuilt after accept',
      );
    });

    testWidgets(
      'at the roster bound the refusal names the limit and the remedy, and '
      'the card stays acceptable',
      (tester) async {
        // The service refuses before ingesting the held Welcome (see
        // `test/services/nostr_circle_service_roster_bound_test.dart`), so the
        // invitation is still there afterwards. What this pins is the half the
        // user sees: not the generic "please try again", which would send them
        // back to a button that can never succeed while they hold ten circles.
        final circleService = _RosterFullCircleService();

        await pumpLocalized(
          tester,
          Scaffold(body: InvitationCard(invitation: _invitation())),
          overrides: [
            circleServiceProvider.overrideWithValue(circleService),
            profileServiceProvider.overrideWithValue(MockProfileService()),
          ],
        );
        final l10n = l10nOf(tester, InvitationCard);

        await tester.tap(find.text(l10n.invitationCardAccept));
        await tester.pumpAndSettle();

        final refusal = l10n.invitationRosterFullError(kMaxCirclesPerAccount);
        expect(find.text(refusal), findsOneWidget);
        // The copy itself, not only the key: `find.text(l10n...)` would pass
        // for any wording at all, including the transient phrasing this
        // snackbar must never carry. English only — the test pumps the default
        // `en` locale; the other twelve are held by
        // `test/l10n/roster_bound_copy_accuracy_test.dart`.
        expect(
          refusal,
          contains('$kMaxCirclesPerAccount'),
          reason: 'the user cannot act on a limit they are not told',
        );
        expect(
          refusal,
          matches(
            RegExp(
              'up to|at most|a maximum of|no more than|only',
              caseSensitive: false,
            ),
          ),
          reason: 'the ceiling must be MARKED: a bare positive ("you can be '
              'in 10 circles") reads as capability, and eleven of the twelve '
              'locales had to add a limiter to the unmarked wording',
        );
        expect(
          refusal,
          matches(RegExp(r'\bleave\b', caseSensitive: false)),
          reason: 'the remedy is leaving a circle; without it the refusal is a '
              'dead end',
        );
        expect(
          refusal.toLowerCase(),
          isNot(contains('try again')),
          reason: 'retrying while the roster is full can never succeed',
        );
        expect(
          find.text(l10n.invitationAcceptError),
          findsNothing,
          reason: 'a retry prompt for something that can never succeed',
        );
        // Security Rule 8: no exception text reaches the screen — the refusal
        // is copy, not a rendered error.
        expect(
          find.textContaining('Exception', findRichText: true),
          findsNothing,
        );
        // The card is still offering Accept, which is what makes "leave a
        // circle, then accept this invitation" honest advice.
        expect(find.text(l10n.invitationCardAccept), findsOneWidget);
      },
    );
  });

  // ========================================================================
  // What the card may claim before the Welcome is decrypted
  // ========================================================================
  group('InvitationCard — claims nothing it cannot know', () {
    testWidgets('heads the card with a localized invitation label', (
      tester,
    ) async {
      await _pumpCard(tester);
      final l10n = l10nOf(tester, InvitationCard);

      expect(l10n.invitationCardHeading, 'Circle invitation');
      expect(find.text(l10n.invitationCardHeading), findsOneWidget);
    });

    testWidgets('never renders the pre-join circle-name stand-in', (
      tester,
    ) async {
      // `CircleManager` fills `Invitation.circleName` with a hard-coded
      // English literal because the real name lives inside the still-
      // encrypted Welcome. Rendering it as the card's largest, boldest
      // element presented a placeholder as a fact — in one language, to
      // every locale.
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      for (final rendered in _renderedStrings(tester)) {
        expect(rendered, isNot(contains(_standInCircleName)));
      }
    });

    testWidgets('never announces the pre-join circle-name stand-in', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      for (final label in _announcements(tester)) {
        expect(label, isNot(contains(_standInCircleName)));
      }
      handle.dispose();
    });

    testWidgets('states no member count, on screen or to a screen reader', (
      tester,
    ) async {
      // Pre-join the roster is encrypted, so the only member the device can
      // count is the NIP-59 seal author. "1 member" told the user the circle
      // was nearly empty, which Haven cannot know, and a screen reader said
      // the ungrammatical "1 members" in all 13 locales because the count
      // could never be anything else. `Invitation` no longer carries a count
      // at all; `commonMemberCount` is the last member-count string in the
      // app, so it is what a regression would reach for.
      final handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
        invitedAt: DateTime.now(),
      );
      final l10n = l10nOf(tester, InvitationCard);

      for (var n = 0; n <= 10; n++) {
        final count = l10n.commonMemberCount(n);
        for (final rendered in _renderedStrings(tester)) {
          expect(rendered, isNot(contains(count)));
        }
        for (final label in _announcements(tester)) {
          expect(label, isNot(contains(count)));
        }
      }
      handle.dispose();
    });
  });

  // ========================================================================
  // The user's own nickname (docs/MEMBER_PICKER_PLAN.md §7.2)
  // ========================================================================
  group('InvitationCard — the name the user chose', () {
    testWidgets('prefers the local nickname over the inviter kind-0 name', (
      tester,
    ) async {
      // The petname is the one name on this card an attacker cannot
      // publish. Losing it to a kind-0 name — on the screen that authorises
      // live location sharing — is losing the only naming signal the user
      // authored themselves.
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Dave'),
        nickname: 'Mum',
      );
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        find.text(l10n.invitationCardInvitedBy(_isolated('Mum'))),
        findsOneWidget,
      );
      expect(find.textContaining('Dave'), findsNothing);
      // ...and the key still never leaves the card.
      expect(find.text(_shortNpub), findsOneWidget);
    });

    testWidgets('uses the nickname when no kind-0 is cached at all', (
      tester,
    ) async {
      await _pumpCard(tester, nickname: 'Mum');
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        find.text(l10n.invitationCardInvitedBy(_isolated('Mum'))),
        findsOneWidget,
      );
      expect(find.text(_shortNpub), findsOneWidget);
    });

    testWidgets('marks a nicknamed name as the user\'s own', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpCard(tester, nickname: 'Mum');
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        l10n.invitationCardNicknameNote,
        'Your nickname for them, not their public name',
      );
      expect(find.byIcon(LucideIcons.tag), findsOneWidget);
      // The mark is quiet to the eye but not to a screen reader: a listener
      // otherwise has no way to tell a name they chose from a name a
      // stranger published. Substring match because the card's rows carry
      // no actions of their own and Flutter folds them into one
      // announcement.
      expect(
        _announcements(tester),
        contains(contains(l10n.invitationCardNicknameNote)),
      );
      handle.dispose();
    });

    testWidgets('leaves a network-resolved name unmarked', (tester) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      expect(find.byIcon(LucideIcons.tag), findsNothing);
    });

    testWidgets('leaves a whitespace-only nickname unused and unmarked', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
        nickname: '   ',
      );
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        find.text(l10n.invitationCardInvitedBy(_isolated('Alice'))),
        findsOneWidget,
      );
      expect(find.byIcon(LucideIcons.tag), findsNothing);
    });

    testWidgets('gives the mark no colour of its own', (tester) async {
      await _pumpCard(tester, nickname: 'Mum');

      final icon = tester.widget<Icon>(find.byIcon(LucideIcons.tag));
      final theme = Theme.of(tester.element(find.byType(InvitationCard)));
      // A trust-coloured mark on the screen that authorises live location
      // sharing gets read as a verification. Both Haven security colours
      // are additionally below WCAG AA as text (3.30:1 and 3.19:1), and the
      // green already means "KeyPackage validated" elsewhere in the app.
      expect(icon.color, theme.colorScheme.onSurfaceVariant);
      expect(icon.color, isNot(HavenSecurityColors.encrypted));
      expect(icon.color, isNot(HavenSecurityColors.warning));
      expect(icon.color, isNot(HavenSecurityColors.danger));
    });

    testWidgets('scales the mark with the text beside it', (tester) async {
      // `Icon` does not follow the text scaler on its own, so at 2x an
      // unscaled glyph beside 28dp text reads as a rendering artefact and
      // falls under the long-press target the tooltip needs.
      await _pumpCard(tester, nickname: 'Mum');
      final unscaled = tester.widget<Icon>(find.byIcon(LucideIcons.tag)).size;

      await _pumpCard(
        tester,
        nickname: 'Mum',
        textScaler: const TextScaler.linear(2),
      );
      final scaled = tester.widget<Icon>(find.byIcon(LucideIcons.tag)).size;

      expect(unscaled, isNotNull);
      expect(scaled, unscaled! * 2);
    });

    for (final (code, direction) in [
      ('en', TextDirection.ltr),
      ('ar', TextDirection.rtl),
    ]) {
      testWidgets('places the mark after the name in "$code"', (tester) async {
        await _pumpCard(tester, nickname: 'Mum', locale: Locale(code));
        final l10n = l10nOf(tester, InvitationCard);

        expect(
          Directionality.of(tester.element(find.byType(InvitationCard))),
          direction,
        );
        // Reading order, not pixel order: "after the name" is to its LEFT
        // in an RTL layout. A hard-coded left padding passes one of these
        // and fails the other.
        final line = tester.getRect(
          find.text(l10n.invitationCardInvitedBy(_isolated('Mum'))),
        );
        final mark = tester.getRect(find.byIcon(LucideIcons.tag));
        if (direction == TextDirection.ltr) {
          expect(mark.left, greaterThanOrEqualTo(line.right));
        } else {
          expect(mark.right, lessThanOrEqualTo(line.left));
        }
      });
    }

    testWidgets('degrades to the public name when the lookup throws', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
        throwOnGetContactDisplayName: true,
      );
      final l10n = l10nOf(tester, InvitationCard);

      // A failed petname read is not an error state on this screen: the
      // card still names the inviter, and claims no nickname it could not
      // read.
      expect(
        find.text(l10n.invitationCardInvitedBy(_isolated('Alice'))),
        findsOneWidget,
      );
      expect(find.byIcon(LucideIcons.tag), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reads the nickname locally, never from a relay', (
      tester,
    ) async {
      final services = await _pumpCard(tester, nickname: 'Mum');

      expect(services.circle.methodCalls, contains('getContactDisplayName'));
      // The inviter is a stranger until Accept: resolving a name here must
      // not put their pubkey on the wire.
      expect(
        services.profile.methodCalls.map((call) => call.method),
        isNot(contains('refreshMemberProfiles')),
      );
    });
  });

  // ========================================================================
  // Inviter identity (docs/MEMBER_PICKER_PLAN.md §7.1/§7.3)
  // ========================================================================
  group('InvitationCard — inviter identity', () {
    testWidgets(
      'renders a resolved name as the inviter AND keeps the npub on the card',
      (tester) async {
        await _pumpCard(
          tester,
          profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
        );
        final l10n = l10nOf(tester, InvitationCard);

        expect(
          find.text(l10n.invitationCardInvitedBy(_isolated('Alice'))),
          findsOneWidget,
        );
        // The name is the convenience; the key is the identity. A name-only
        // row must not exist on the screen that decides live location
        // sharing — anyone can publish any kind-0 name.
        expect(find.text(_shortNpub), findsOneWidget);
      },
    );

    testWidgets('renders the npub alone when no profile is cached', (
      tester,
    ) async {
      await _pumpCard(tester);
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        find.text(l10n.invitationCardInvitedBy(_shortNpub)),
        findsOneWidget,
      );
      // No second, redundant key row when the line already IS the key.
      expect(find.text(_shortNpub), findsNothing);
    });

    testWidgets('falls through to the npub when the cached name is blank', (
      tester,
    ) async {
      // A kind-0 that resolved but carries only whitespace in both name
      // fields must not produce an empty "Invited by:" line.
      await _pumpCard(
        tester,
        profile: const Profile(
          pubkeyHex: _inviterHex,
          name: '  ',
          displayName: '   ',
        ),
      );
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        find.text(l10n.invitationCardInvitedBy(_shortNpub)),
        findsOneWidget,
      );
    });

    testWidgets('shows the canonical 12/6 npub, checksum suffix intact', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      final rendered = tester.widget<Text>(find.text(_shortNpub)).data!;
      // 12 leading characters pin only 7 bech32 data characters (~2^35, a
      // grindable ~34 s); the trailing 6 are the bech32 checksum, which an
      // attacker can only sample, never solve for — that is what takes the
      // cost to ~2^65. Dropping either end is a real downgrade.
      expect(rendered.substring(0, 12), _inviterNpub.substring(0, 12));
      expect(
        rendered.substring(rendered.length - 6),
        _inviterNpub.substring(_inviterNpub.length - 6),
      );
      expect(rendered, NpubValidator.shortenForDisplay(_inviterNpub));
    });

    testWidgets('never renders the inviter pubkey as hex', (tester) async {
      // The 8/4 hex fragment this replaced pinned 48 bits and could not be
      // cross-checked against the npub an inviter actually hands out.
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      for (final rendered in _renderedStrings(tester)) {
        expect(rendered, isNot(contains(_inviterHex.substring(0, 8))));
      }
    });

    testWidgets('forces the npub Text to LTR', (tester) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      expect(
        tester.widget<Text>(find.text(_shortNpub)).textDirection,
        TextDirection.ltr,
      );
      expect(
        tester
            .renderObject<RenderParagraph>(find.text(_shortNpub))
            .textDirection,
        TextDirection.ltr,
      );
    });

    testWidgets('keeps the name and the npub in separate widgets', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      // Bidi resolves run boundaries across a whole paragraph, so the only
      // structural defence is that the key and an attacker-chosen name never
      // share one. Separate widgets cannot interact.
      for (final rendered in _renderedStrings(tester)) {
        expect(
          rendered.contains('Alice') && rendered.contains('npub1'),
          isFalse,
          reason: 'name and npub must never be concatenated: "$rendered"',
        );
      }
    });

    testWidgets('bidi-isolates the name in the rendered "Invited by" line', (
      tester,
    ) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: _rtlName),
      );
      final l10n = l10nOf(tester, InvitationCard);

      // This is the one paragraph on the card that lays an attacker-chosen
      // string out beside app text. The bidi algorithm resolves run
      // boundaries across a whole paragraph, and an unterminated U+202E
      // inside the name would run to the end of it, so the isolate — not the
      // placeholder happening to sit last in today's ARB — is the defence.
      expect(
        find.text(l10n.invitationCardInvitedBy(_isolated(_rtlName))),
        findsOneWidget,
      );
    });

    testWidgets('announces no invisible bidi characters', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: _rtlName),
      );
      final l10n = l10nOf(tester, InvitationCard);

      // A label is spoken or brailled, never laid out, so an isolate there
      // protects nothing and only pads every announcement. The rendered line
      // above therefore carries its own un-isolated label.
      for (final label in _announcements(tester)) {
        expect(label, isNot(contains('\u2068')));
        expect(label, isNot(contains('\u2069')));
      }
      // ...and the un-isolated line is what a screen reader reads.
      expect(
        _announcements(tester),
        contains(contains(l10n.invitationCardInvitedBy(_rtlName))),
      );
      handle.dispose();
    });

    testWidgets('an RTL display name cannot reorder the npub', (tester) async {
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: _rtlName),
        locale: const Locale('ar'),
      );

      // Ambient direction is RTL...
      expect(
        Directionality.of(tester.element(find.byType(InvitationCard))),
        TextDirection.rtl,
      );
      // ...and the key still lays out LTR, character order untouched, in a
      // paragraph the name is not part of.
      final npubText = tester.widget<Text>(find.text(_shortNpub));
      expect(npubText.data, _shortNpub);
      expect(
        tester
            .renderObject<RenderParagraph>(find.text(_shortNpub))
            .textDirection,
        TextDirection.ltr,
      );
      for (final rendered in _renderedStrings(tester)) {
        expect(
          rendered.contains(_rtlName) && rendered.contains('npub1'),
          isFalse,
          reason: 'RTL name and npub must never share a paragraph',
        );
      }
    });

    testWidgets('exposes both the name and the npub to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );
      final l10n = l10nOf(tester, InvitationCard);

      // The card's rows carry no actions of their own, so Flutter folds them
      // into one announcement — hence substring matches: what matters is that
      // BOTH the name and the key are in what a screen reader reads out.
      expect(_announcements(tester), contains(contains('Alice')));
      // ...and the key is announced as what it is, not spelled out as raw
      // text a listener cannot place.
      expect(
        _announcements(tester),
        contains(contains(l10n.invitationCardInvitedBySemantics(_shortNpub))),
      );
      // The card summary names the inviter.
      expect(
        _announcements(tester),
        contains(l10n.invitationCardSemantics('Alice')),
      );
      handle.dispose();
    });

    testWidgets('announces the npub when no name resolved', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpCard(tester);
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        _announcements(tester),
        contains(contains(l10n.invitationCardInvitedBySemantics(_shortNpub))),
      );
      expect(
        _announcements(tester),
        contains(l10n.invitationCardSemantics(_shortNpub)),
      );
      handle.dispose();
    });

    testWidgets('degrades to the npub when the profile service throws', (
      tester,
    ) async {
      await _pumpCard(tester, throwOnGetMemberProfile: true);
      final l10n = l10nOf(tester, InvitationCard);

      expect(
        find.text(l10n.invitationCardInvitedBy(_shortNpub)),
        findsOneWidget,
      );
      // A failed name lookup is not an error state on this screen: no error
      // UI, and nothing escapes to the caller.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text(l10n.invitationsLoadError), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('resolves the inviter from the cache without a relay fetch', (
      tester,
    ) async {
      // Nothing on this screen may put an inviter's pubkey on the wire: they
      // are a stranger until the invitation is accepted, and every pubkey
      // handed to a batch refresh is also handed to the picture download —
      // a GET to a host THEY chose, from the user's real IP. A name here is
      // whatever the local cache already holds, or nothing.
      final services = await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
      );

      expect(
        services.profile.methodCalls.map((call) => call.method),
        isNot(contains('refreshMemberProfiles')),
      );
      final reads = services.profile.methodCalls.where(
        (call) => call.method == 'getMemberProfile',
      );
      expect(reads, isNotEmpty);
      for (final read in reads) {
        expect(read.args['forceRefresh'], isFalse);
      }
    });
  });

  // ========================================================================
  // Layout
  // ========================================================================
  group('InvitationCard — layout robustness', () {
    // Sweep every shipped locale rather than a hand-picked "longest" one:
    // which translation is widest is a property of wrapping at 320 px, not of
    // character count, and a hand-picked sample quietly stops containing the
    // worst case as the ARB changes.
    for (final code in _allLocaleCodes) {
      testWidgets('"$code" at 2x on a 320dp phone lays out without overflow', (
        tester,
      ) async {
        // The 12/6 npub is materially wider than the 12-character hex
        // fragment it replaces, on a card that already carries a circle name,
        // a member count, a timestamp and two action buttons.
        _useNarrowPhone(tester);

        await _pumpCard(
          tester,
          profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
          locale: Locale(code),
          textScaler: const TextScaler.linear(2),
        );

        expect(tester.takeException(), isNull);
        // Both actions stay on screen — stacked, not clipped.
        expect(find.byType(OutlinedButton), findsOneWidget);
        expect(find.byType(FilledButton), findsOneWidget);
        expect(
          tester.getRect(find.byType(FilledButton)).right,
          lessThanOrEqualTo(320),
        );
      });
    }

    testWidgets('the npub is never truncated at 2x on a 320dp phone', (
      tester,
    ) async {
      // Ellipsizing the key would drop the bech32 checksum the 12/6 form
      // exists for, silently taking the grind cost from ~2^65 back to ~2^35.
      _useNarrowPhone(tester);

      await _pumpCard(
        tester,
        profile: const Profile(pubkeyHex: _inviterHex, displayName: 'Alice'),
        textScaler: const TextScaler.linear(2),
      );

      expect(find.text(_shortNpub), findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(_shortNpub),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        tester.widget<Text>(find.text(_shortNpub)).overflow,
        isNot(TextOverflow.ellipsis),
      );
    });

    testWidgets('the nickname mark fits beside a long name at 2x', (
      tester,
    ) async {
      // The mark shares the inviter line's width and grows with the text
      // scale, so it is the one element that can push that line past the
      // edge. The name wraps; the mark stays on screen.
      _useNarrowPhone(tester);

      await _pumpCard(
        tester,
        nickname: 'Mum on the landline',
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
      final mark = tester.getRect(find.byIcon(LucideIcons.tag));
      expect(mark.left, greaterThanOrEqualTo(0));
      expect(mark.right, lessThanOrEqualTo(320));
    });

    testWidgets('the npub-only line lays out at 2x on a 320dp phone', (
      tester,
    ) async {
      // The unresolved case puts the whole key inside the "Invited by" line,
      // which is the widest single line this card can produce.
      _useNarrowPhone(tester);

      await _pumpCard(tester, textScaler: const TextScaler.linear(2));
      final l10n = l10nOf(tester, InvitationCard);

      expect(tester.takeException(), isNull);
      expect(
        find.text(l10n.invitationCardInvitedBy(_shortNpub)),
        findsOneWidget,
      );
    });
  });
}

// ==========================================================================
// Mock Implementations
// ==========================================================================

/// A circle service at the account roster bound: every accept is refused.
class _RosterFullCircleService extends MockCircleService {
  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    methodCalls.add('acceptInvitation');
    throw const CircleRosterFullException();
  }
}

/// A circle service that succeeds on acceptInvitation.
class _AcceptingCircleService extends MockCircleService {
  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    methodCalls.add('acceptInvitation');
    return TestCircleFactory.createCircle(mlsGroupId: mlsGroupId);
  }
}
