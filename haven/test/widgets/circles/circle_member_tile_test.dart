/// Widget tests for [CircleMemberTile].
///
/// These tests lock in the behavior documented on the tile:
///
///   "When `member` is the current user, the title and avatar use the
///    display name saved in settings (via `IdentityService.setDisplayName`)
///    rather than the pubkey hex."
///
/// We override [identityProvider] and [displayNameProvider] directly —
/// the tile only watches their values and does not care whether they come
/// from the real service or an override.
//
// Test readability trumps value compression: cases that test the "self"
// branch explicitly pass `pubkey: selfPubkey` even though it matches the
// helper default, so the reader sees the contract being tested on the
// same line as the expectation. Same for status / admin flags.
// ignore_for_file: avoid_redundant_argument_values
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_profile_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_profile_service.dart';

void main() {
  const selfPubkey =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const otherPubkey =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  // Real bech32 encodings of selfPubkey/otherPubkey (computed offline), so
  // title/subtitle assertions below exercise an authentic hex->npub mapping
  // rather than an arbitrary placeholder.
  const selfNpub =
      'npub1424242424242424242424242424242424242424242424242424qamrcaj';
  const otherNpub =
      'npub1hwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwamhwasxw04hu';

  // Mirrors the widget's private `_shortNpub` truncation so assertions below
  // stay in sync with production formatting without duplicating the magic
  // numbers at every call site.
  String shortNpub(String npub) =>
      NpubValidator.truncate(npub, prefixLength: 12, suffixLength: 6);

  Identity buildIdentity({String pubkeyHex = selfPubkey}) {
    return Identity(
      pubkeyHex: pubkeyHex,
      npub: 'npub1self',
      createdAt: DateTime(2025),
    );
  }

  CircleMember buildMember({
    String pubkey = selfPubkey,
    String? npub,
    String? displayName,
    bool isAdmin = false,
    MembershipStatus status = MembershipStatus.accepted,
  }) {
    return CircleMember(
      pubkey: pubkey,
      npub: npub ?? (pubkey == otherPubkey ? otherNpub : selfNpub),
      displayName: displayName,
      isAdmin: isAdmin,
      status: status,
    );
  }

  Future<void> pumpTile(
    WidgetTester tester, {
    required CircleMember member,
    Identity? identity,
    String? displayName,
    Widget? trailing,
    VoidCallback? onTap,
    VoidCallback? onRemove,
    bool hasLocation = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith((_) async => identity),
          displayNameProvider.overrideWith((_) async => displayName),
          // Both the self row (ownProfileProvider) and other-member rows
          // (memberProfileProvider) reach profileServiceProvider. These
          // cases assert names/styles, not avatar images, so a bare mock (no
          // profile set) keeps them off real FFI.
          profileServiceProvider.overrideWithValue(MockProfileService()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CircleMemberTile(
              member: member,
              trailing: trailing,
              onTap: onTap,
              onRemove: onRemove,
              hasLocation: hasLocation,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('CircleMemberTile — self member', () {
    testWidgets('shows settings display name for self instead of pubkey hex', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      expect(find.text('Alice'), findsOneWidget);

      // The npub must appear exactly once — as the truncated subtitle —
      // and must never be duplicated onto the title alongside the
      // display name (a regression would show it in both places).
      final truncatedNpub = shortNpub(selfNpub);
      expect(
        find.text(truncatedNpub),
        findsOneWidget,
        reason:
            'Self member must render the display name as the title, with '
            'the truncated npub appearing only once, as the subtitle',
      );
    });

    testWidgets(
      'renders truncated npub as subtitle when settings name is shown',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: selfPubkey),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.text(shortNpub(selfNpub)), findsOneWidget);
      },
    );

    testWidgets('falls back to pubkey when self has no settings display name', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: null,
      );

      expect(find.text(shortNpub(selfNpub)), findsOneWidget);
    });

    testWidgets(
      'falls back to pubkey when self settings name is whitespace-only',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: selfPubkey),
          identity: buildIdentity(),
          displayName: '   ',
        );

        expect(find.text(shortNpub(selfNpub)), findsOneWidget);
      },
    );

    testWidgets('uses contact displayName for self when no settings name', (
      tester,
    ) async {
      // Edge case: the user somehow has a Contact row for their own pubkey
      // (e.g., manually created). Settings name is the preferred source, but
      // when absent the contact nickname is still better than pubkey hex.
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey, displayName: 'Contact Me'),
        identity: buildIdentity(),
        displayName: null,
      );

      expect(find.text('Contact Me'), findsOneWidget);
    });

    testWidgets('settings name trumps contact displayName for self', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey, displayName: 'Contact Me'),
        identity: buildIdentity(),
        displayName: 'Settings Me',
      );

      expect(find.text('Settings Me'), findsOneWidget);
      expect(find.text('Contact Me'), findsNothing);
    });

    testWidgets('self detection is case-insensitive on pubkey hex', (
      tester,
    ) async {
      // Member pubkey stored with uppercase hex (defensive — Rust emits
      // lowercase today, but we guard against any future drift).
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey.toUpperCase()),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('avatar initial uses settings display name first letter', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: 'Zara',
      );

      // The avatar CircleAvatar contains a Text with the uppercase initial.
      expect(find.widgetWithText(CircleAvatar, 'Z'), findsOneWidget);
    });

    testWidgets('self member still renders Admin chip when admin', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey, isAdmin: true),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      expect(find.text('Admin'), findsOneWidget);
    });

    testWidgets('self member without admin has no Admin chip', (tester) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      expect(find.text('Admin'), findsNothing);
    });
  });

  group('CircleMemberTile — other members', () {
    testWidgets('shows contact display name for non-self members', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      expect(find.text('Bob'), findsOneWidget);
      expect(
        find.text('Alice'),
        findsNothing,
        reason:
            'Settings display name must never leak onto other members — '
            'it belongs to the current user only',
      );
    });

    testWidgets(
      'shows truncated npub as subtitle for a non-self member with a '
      'contact display name',
      (tester) async {
        // Companion to the self-member subtitle test above ('renders
        // truncated npub as subtitle when settings name is shown'): a
        // contact display name is rendered as the title, and the
        // truncated npub must still appear as the subtitle underneath it.
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.text(shortNpub(otherNpub)), findsOneWidget);
      },
    );

    testWidgets(
      'shows truncated pubkey for non-self members without a contact name',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.text(shortNpub(otherNpub)), findsOneWidget);
      },
    );

    testWidgets(
      'non-self member renders title with mono style when only pubkey shown',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        final text = tester.widget<Text>(find.text(shortNpub(otherNpub)));
        expect(text.style?.fontFamily, HavenTypography.mono.fontFamily);
      },
    );
  });

  group('CircleMemberTile — identity not yet loaded', () {
    testWidgets('falls back to current behavior when no identity', (
      tester,
    ) async {
      // No identity means no self-detection. The tile must still render
      // exactly as it did pre-change for whichever member is on screen.
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: null,
        displayName: null,
      );

      expect(find.text(shortNpub(selfNpub)), findsOneWidget);
    });

    testWidgets('ignores a settings display name when no identity is loaded', (
      tester,
    ) async {
      // Defensive: even if Riverpod somehow serves a display name while
      // identity is null (unlikely in practice), the helper must not
      // misattribute it. The tile renders the raw member — in this case
      // an unknown pubkey with no contact name.
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey),
        identity: null,
        displayName: 'Ghost',
      );

      expect(find.text('Ghost'), findsNothing);
      expect(find.text(shortNpub(otherNpub)), findsOneWidget);
    });
  });

  group('CircleMemberTile — pending subtitle', () {
    testWidgets(
      'pending status suppresses pubkey subtitle for self display name',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(
            pubkey: selfPubkey,
            status: MembershipStatus.pending,
          ),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Invitation Pending'), findsOneWidget);
        // Npub subtitle is replaced by the pending indicator — make sure
        // we don't accidentally render both.
        final subtitleText = shortNpub(selfNpub);
        expect(find.text(subtitleText), findsNothing);
      },
    );

    testWidgets('pending status renders for non-self members too', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(
          pubkey: otherPubkey,
          displayName: 'Bob',
          status: MembershipStatus.pending,
        ),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Invitation Pending'), findsOneWidget);
    });
  });

  group('CircleMemberTile — interaction', () {
    testWidgets('onTap callback is invoked when tile is tapped', (
      tester,
    ) async {
      var tapCount = 0;
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: 'Alice',
        onTap: () => tapCount++,
      );

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(tapCount, 1);
    });

    testWidgets('custom trailing widget overrides Admin chip', (tester) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey, isAdmin: true),
        identity: buildIdentity(),
        displayName: 'Alice',
        trailing: const Icon(LucideIcons.x, key: Key('custom-trailing')),
      );

      expect(find.byKey(const Key('custom-trailing')), findsOneWidget);
      expect(
        find.text('Admin'),
        findsNothing,
        reason:
            'Caller-provided trailing widget must replace the default '
            'Admin chip',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Async loading / error states for the providers the tile watches.
  // Added after expert review flagged that the production code's documented
  // "treat as null while loading" contract had no regression test.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — AsyncLoading / AsyncError states', () {
    testWidgets(
      'renders pubkey fallback while identityProvider is still loading',
      (tester) async {
        // Use a Completer whose future never completes so identityProvider
        // stays in the AsyncLoading state for the lifetime of the test.
        final never = Completer<Identity?>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) => never.future),
              displayNameProvider.overrideWith((_) async => 'Alice'),
              // While identity is loading, isSelf resolves false, so this
              // selfPubkey-labeled member falls through to the non-self
              // memberProfileProvider avatar path — override it off real FFI.
              profileServiceProvider.overrideWithValue(MockProfileService()),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: CircleMemberTile(
                  member: CircleMember(
                    pubkey: selfPubkey,
                    npub: selfNpub,
                    isAdmin: false,
                    status: MembershipStatus.accepted,
                  ),
                ),
              ),
            ),
          ),
        );
        // Deliberately do NOT call pumpAndSettle — we want the loading state.
        await tester.pump();

        // Without a resolved identity, self-detection cannot fire, so the
        // tile must render pre-change behavior: truncated pubkey, no 'Alice'.
        expect(find.text('Alice'), findsNothing);
        expect(find.text(shortNpub(selfNpub)), findsOneWidget);
      },
    );

    testWidgets(
      'renders pubkey fallback while displayNameProvider is still loading',
      (tester) async {
        final never = Completer<String?>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) async => buildIdentity()),
              displayNameProvider.overrideWith((_) => never.future),
              profileServiceProvider.overrideWithValue(MockProfileService()),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: CircleMemberTile(
                  member: CircleMember(
                    pubkey: selfPubkey,
                    npub: selfNpub,
                    isAdmin: false,
                    status: MembershipStatus.accepted,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Identity is known but the settings name has not arrived yet; the
        // tile must not render any name.
        expect(find.text(shortNpub(selfNpub)), findsOneWidget);
      },
    );

    testWidgets('renders pubkey fallback when identityProvider errors out', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith(
              (_) => Future<Identity?>.error(Exception('identity load failed')),
            ),
            displayNameProvider.overrideWith((_) async => 'Alice'),
            // With identityProvider erroring, isSelf resolves false (no
            // known current-user pubkey), so this selfPubkey-labeled member
            // falls through to the non-self memberProfileProvider avatar
            // path — override it off real FFI.
            profileServiceProvider.overrideWithValue(MockProfileService()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
                  npub: selfNpub,
                  isAdmin: false,
                  status: MembershipStatus.accepted,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Errored AsyncValue's valueOrNull is null, so the tile must fall
      // back to pubkey hex and NOT misattribute the settings name.
      expect(find.text('Alice'), findsNothing);
      expect(find.text(shortNpub(selfNpub)), findsOneWidget);
    });

    testWidgets('renders pubkey fallback when displayNameProvider errors out', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((_) async => buildIdentity()),
            displayNameProvider.overrideWith(
              (_) => Future<String?>.error(Exception('prefs read failed')),
            ),
            profileServiceProvider.overrideWithValue(MockProfileService()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
                  npub: selfNpub,
                  isAdmin: false,
                  status: MembershipStatus.accepted,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(shortNpub(selfNpub)), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Reactive invalidation: when the user saves a new display name, mounted
  // tiles must re-render with the updated value.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — reactive invalidation', () {
    testWidgets('re-renders with new settings display name after invalidate', (
      tester,
    ) async {
      var currentName = 'Alice';
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => buildIdentity()),
          displayNameProvider.overrideWith((_) async => currentName),
          profileServiceProvider.overrideWithValue(MockProfileService()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
                  npub: selfNpub,
                  isAdmin: false,
                  status: MembershipStatus.accepted,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);

      // Simulate the user saving a new display name: change the underlying
      // value and invalidate the provider. The tile must catch the new
      // value on its next build.
      currentName = 'Bob';
      container.invalidate(displayNameProvider);
      await tester.pumpAndSettle();

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Regression guards flagged by test-coverage reviewer.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — style / subtitle / avatar regression guards', () {
    testWidgets('self with settings display name renders title in the default '
        '(non-mono) style', (tester) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      final titleText = tester.widget<Text>(find.text('Alice'));
      expect(
        titleText.style?.fontFamily,
        isNot(HavenTypography.mono.fontFamily),
        reason:
            'When a display name is shown, the title must NOT use the '
            'monospaced hex-key font.',
      );
    });

    testWidgets(
      'subtitle widget is absent when status is accepted and only pubkey '
      'is shown',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey),
          identity: buildIdentity(),
          displayName: null,
        );

        // The pending-indicator subtitle is absent, and — since there is no
        // display name — the npub-subtitle branch is skipped too (the npub
        // is shown as the TITLE instead). Assert directly on
        // ListTile.subtitle rather than searching for the truncated-npub
        // text: the title and subtitle now share the same truncation
        // format (`_shortNpub`), so the text alone can no longer
        // distinguish "rendered as title" from "rendered as subtitle".
        expect(find.text('Invitation Pending'), findsNothing);
        final tile = tester.widget<ListTile>(find.byType(ListTile));
        expect(
          tile.subtitle,
          isNull,
          reason: 'No subtitle widget should be rendered in this case.',
        );
      },
    );

    testWidgets(
      'avatar initial for non-self member uses first letter of contact name',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Charlie'),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.widgetWithText(CircleAvatar, 'C'), findsOneWidget);
      },
    );

    testWidgets('avatar initial grapheme-cluster safe for emoji display name', (
      tester,
    ) async {
      // Regression guard for the old `displayName[0]` UTF-16 code-unit
      // indexing which would split emoji surrogate pairs. The new
      // grapheme-cluster logic must render the whole emoji.
      await pumpTile(
        tester,
        member: buildMember(pubkey: selfPubkey),
        identity: buildIdentity(),
        displayName: '🦊Fox',
      );

      // The fox emoji is the first grapheme; the avatar must display it
      // intact (not a mangled surrogate half).
      expect(find.widgetWithText(CircleAvatar, '🦊'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Defensive: malformed CircleMember values must not crash the list.
  // Before the avatar hardening, `pubkey[5]` on a short pubkey would throw
  // RangeError, taking down the whole bottom sheet.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — malformed member data', () {
    testWidgets('short pubkey does not crash the tile', (tester) async {
      // No display name, pubkey shorter than 6 chars. Previously this
      // crashed in _MemberAvatar at `pubkey[5]`.
      await pumpTile(
        tester,
        member: const CircleMember(
          pubkey: 'abc',
          npub: '',
          isAdmin: false,
          status: MembershipStatus.accepted,
        ),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      // Tile renders; fallback glyph is chosen deterministically.
      expect(find.byType(CircleAvatar), findsOneWidget);
    });

    testWidgets('empty pubkey does not crash the tile', (tester) async {
      await pumpTile(
        tester,
        member: const CircleMember(
          pubkey: '',
          npub: '',
          isAdmin: false,
          status: MembershipStatus.accepted,
        ),
        identity: buildIdentity(),
        displayName: null,
      );

      // The avatar falls back to the '?' placeholder, and self-detection
      // correctly refuses to match an empty pubkey.
      expect(find.widgetWithText(CircleAvatar, '?'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Tap-to-focus affordances: when a last-known location is available for the
  // member the tile becomes interactive and tappable (recentering the map).
  // The list intentionally renders NO per-member locator icon. When no
  // location is available, the tile disables itself and shows a
  // "No recent location" hint so the user understands why the row does not
  // react to taps.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — hasLocation / tap-to-focus', () {
    testWidgets(
      'renders no locator icon when interactive, but stays tappable',
      (tester) async {
        var tapped = false;
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: true,
          onTap: () => tapped = true,
        );

        // The per-member locator/crosshair icon was removed from the list.
        expect(find.byIcon(LucideIcons.locateFixed), findsNothing);
        // The tap-to-focus affordance itself is unchanged: an interactive tile
        // still forwards taps (the map recenters via onTap).
        await tester.tap(find.byType(CircleMemberTile));
        expect(tapped, isTrue);
      },
    );

    testWidgets('does NOT render my_location icon when hasLocation is false', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
        hasLocation: false,
        onTap: () {},
      );

      expect(find.byIcon(LucideIcons.locateFixed), findsNothing);
    });

    testWidgets(
      'does NOT render my_location icon when onTap is null even if hasLocation',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: true,
        );

        expect(find.byIcon(LucideIcons.locateFixed), findsNothing);
      },
    );

    testWidgets(
      'shows "No recent location" subtitle for accepted member without a fix',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: false,
          onTap: () {},
        );

        expect(find.text('No recent location'), findsOneWidget);
        // Npub subtitle is replaced by the no-location hint.
        final subtitleText = shortNpub(otherNpub);
        expect(find.text(subtitleText), findsNothing);
      },
    );

    testWidgets(
      'pending status keeps "Invitation Pending" regardless of hasLocation',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(
            pubkey: otherPubkey,
            displayName: 'Bob',
            status: MembershipStatus.pending,
          ),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: false,
          onTap: () {},
        );

        expect(find.text('Invitation Pending'), findsOneWidget);
        expect(
          find.text('No recent location'),
          findsNothing,
          reason:
              'Pending invitation status must take precedence over the '
              'no-location hint so users see the right call-to-action.',
        );
      },
    );

    testWidgets('tapping tile with hasLocation=false does NOT invoke onTap', (
      tester,
    ) async {
      var tapCount = 0;
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
        hasLocation: false,
        onTap: () => tapCount++,
      );

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(tapCount, 0);
    });

    testWidgets('tapping tile with hasLocation=true invokes onTap', (
      tester,
    ) async {
      var tapCount = 0;
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
        hasLocation: true,
        onTap: () => tapCount++,
      );

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(tapCount, 1);
    });

    testWidgets(
      'tapping pending member with onTap still does NOT invoke callback',
      (tester) async {
        var tapCount = 0;
        await pumpTile(
          tester,
          member: buildMember(
            pubkey: otherPubkey,
            displayName: 'Bob',
            status: MembershipStatus.pending,
          ),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: true,
          onTap: () => tapCount++,
        );

        await tester.tap(find.byType(ListTile));
        await tester.pumpAndSettle();

        expect(tapCount, 0);
      },
    );

    testWidgets(
      'admin chip renders with no locator icon when interactive',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(
            pubkey: otherPubkey,
            displayName: 'Bob',
            isAdmin: true,
          ),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: true,
          onTap: () {},
        );

        expect(find.text('Admin'), findsOneWidget);
        // The per-member locator/crosshair icon was removed; the Admin chip is
        // now the only trailing element for an interactive admin.
        expect(find.byIcon(LucideIcons.locateFixed), findsNothing);
      },
    );

    testWidgets(
      'admin chip renders alone when the member has no cached location',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(
            pubkey: otherPubkey,
            displayName: 'Bob',
            isAdmin: true,
          ),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: false,
          onTap: () {},
        );

        expect(find.text('Admin'), findsOneWidget);
        expect(find.byIcon(LucideIcons.locateFixed), findsNothing);
      },
    );

    testWidgets(
      'ListTile.onTap is null when non-interactive so taps are ignored while '
      'the title and avatar keep their full styling',
      (tester) async {
        // Interactive: onTap is wired through.
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: true,
          onTap: () {},
        );
        expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNotNull);

        // Non-interactive (no location): onTap is gated off but the tile is
        // not visually disabled — dimming the member's name would obscure
        // identity for a data-state condition.
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: false,
          onTap: () {},
        );
        final tile = tester.widget<ListTile>(find.byType(ListTile));
        expect(tile.onTap, isNull);
        expect(
          tile.enabled,
          isTrue,
          reason:
              'The tile must stay visually enabled so the member name and '
              'avatar are not dimmed. Interaction is gated via onTap only.',
        );
      },
    );

    testWidgets('semantics label reflects tap-to-center affordance', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
        hasLocation: true,
        onTap: () {},
      );

      expect(
        find.bySemanticsLabel('Bob, tap to center map on their location'),
        findsOneWidget,
      );
    });

    testWidgets('semantics label reflects no-location state', (tester) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
        hasLocation: false,
        onTap: () {},
      );

      expect(
        find.bySemanticsLabel('Bob, no location available'),
        findsOneWidget,
      );
    });

    testWidgets('semantics label reflects pending invitation state', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(
          pubkey: otherPubkey,
          displayName: 'Bob',
          status: MembershipStatus.pending,
        ),
        identity: buildIdentity(),
        displayName: 'Alice',
        hasLocation: false,
        onTap: () {},
      );

      expect(find.bySemanticsLabel('Bob, invitation pending'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // Public-profile avatar display via memberProfileProvider (plan D6).
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — public-profile avatar display', () {
    // Minimal valid JPEG header so Image.memory decodes without error.
    final jpegBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    ]);

    Future<void> pumpTileWithAvatar(
      WidgetTester tester, {
      required CircleMember member,
      required MockProfileService profileService,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((_) async => null),
            displayNameProvider.overrideWith((_) async => null),
            profileServiceProvider.overrideWithValue(profileService),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: CircleMemberTile(member: member)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'renders CircleAvatar initials when the member has no known profile',
      (tester) async {
        final svc = MockProfileService();
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          profileService: svc,
        );

        expect(find.byType(CircleAvatar), findsOneWidget);
        expect(find.byType(HavenAvatar), findsNothing);
        expect(
          svc.methodCalls.map((c) => c.method),
          contains('getMemberProfile'),
        );
      },
    );

    testWidgets(
      'renders HavenAvatar with picture bytes when the profile has one',
      (tester) async {
        final svc = MockProfileService(
          memberProfiles: {
            otherPubkey: Profile(
              pubkeyHex: otherPubkey,
              pictureBytes: jpegBytes,
              pictureHash: 'hash',
            ),
          },
        );
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          profileService: svc,
        );

        // HavenAvatar rendered — not the bare CircleAvatar fallback.
        expect(find.byType(HavenAvatar), findsOneWidget);
      },
    );

    // Regression guard for the reported bug: a member WITH a profile picture
    // rendered smaller (32dp) than a member showing initials (the 40dp default
    // CircleAvatar). Both branches must now render at the same 40dp so the
    // member list looks uniform. Pinned in two fresh-tester tests rather than
    // one double-pump test, since reusing a tester across pumps races the
    // avatar FutureProvider against the AnimatedSwitcher.
    testWidgets('initials avatar renders at 40dp', (tester) async {
      await pumpTileWithAvatar(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        profileService: MockProfileService(), // no picture → initials branch
      );

      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(tester.getSize(find.byType(CircleAvatar)), const Size(40, 40));
    });

    testWidgets(
      'profile-picture avatar renders at 40dp, matching the initials circle',
      (tester) async {
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          profileService: MockProfileService(
            memberProfiles: {
              otherPubkey: Profile(
                pubkeyHex: otherPubkey,
                pictureBytes: jpegBytes,
                pictureHash: 'hash',
              ),
            },
          ),
        );

        expect(find.byType(HavenAvatar), findsOneWidget);
        expect(
          tester.getSize(find.byType(HavenAvatar)),
          const Size(40, 40),
          reason:
              'A member with a profile picture must be the same size as one '
              'showing initials (40dp), not the smaller 32dp it used to be.',
        );
      },
    );

    testWidgets(
      'falls back to CircleAvatar when getMemberProfile throws',
      (tester) async {
        final svc = MockProfileService()..shouldThrowOnGetMemberProfile = true;
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          profileService: svc,
        );

        // The provider catches the error and returns null → initials shown.
        expect(find.byType(CircleAvatar), findsOneWidget);
        expect(find.byType(HavenAvatar), findsNothing);
      },
    );

    testWidgets(
      'direct memberProfileProvider override: bytes present renders '
      'HavenAvatar',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) async => null),
              displayNameProvider.overrideWith((_) async => null),
              // Inject bytes directly via provider override.
              memberProfileProvider(otherPubkey).overrideWith(
                (_) async => Profile(
                  pubkeyHex: otherPubkey,
                  pictureBytes: jpegBytes,
                  pictureHash: 'hash',
                ),
              ),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: CircleMemberTile(
                  member: buildMember(pubkey: otherPubkey),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(HavenAvatar), findsOneWidget);
      },
    );

    testWidgets(
      'direct memberProfileProvider override: null shows initials',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) async => null),
              displayNameProvider.overrideWith((_) async => null),
              memberProfileProvider(
                otherPubkey,
              ).overrideWith((_) async => null),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: CircleMemberTile(
                  member: buildMember(pubkey: otherPubkey),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(CircleAvatar), findsOneWidget);
        expect(find.byType(HavenAvatar), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Self avatar — the viewer's OWN row.
  //
  // Regression guard for: "I set a profile picture in settings but it does not
  // show on my own row in the circle member list." The viewer's own public
  // profile is resolved via `ownProfileProvider` (keyed only by pubkey),
  // never via the per-member `memberProfileProvider` — reading the member
  // store for self would always miss since a client never resolves its own
  // pubkey through that path in practice. The self tile must therefore read
  // `ownProfileProvider`, not `memberProfileProvider`.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — self avatar (own store)', () {
    // Minimal valid JPEG header so HavenAvatar's Image.memory accepts it.
    final jpegBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    ]);

    Future<void> pumpSelfTile(
      WidgetTester tester, {
      required MockProfileService profileService,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // Resolve identity synchronously (FutureOr without await) so the
            // tile sees the self pubkey on its very first build. This removes
            // the one-frame loading window during which isSelf is false and a
            // transient member-store read would otherwise occur — letting us
            // assert the steady-state invariant that self reads ONLY the own
            // store. In production identity is already loaded before the
            // member list opens, so that window never happens there either.
            identityProvider.overrideWith((_) => buildIdentity()),
            displayNameProvider.overrideWith((_) async => 'Alice'),
            profileServiceProvider.overrideWithValue(profileService),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleMemberTile(member: buildMember(pubkey: selfPubkey)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'self tile renders own avatar from the own store, not the member store',
      (tester) async {
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: selfPubkey,
            pictureBytes: jpegBytes,
            pictureHash: 'hash',
          ),
        );
        await pumpSelfTile(tester, profileService: svc);

        expect(find.byType(HavenAvatar), findsOneWidget);
        final methods = svc.methodCalls.map((c) => c.method);
        // The own-profile store was queried...
        expect(methods, contains('getOwnProfile'));
        // ...and the per-member received-profile store was NOT — the viewer's
        // own profile never resolves through that path.
        expect(
          methods,
          isNot(contains('getMemberProfile')),
          reason:
              'Self tile must read ownProfileProvider, never the member '
              'store.',
        );
      },
    );

    testWidgets('self tile falls back to initials when no own avatar is set', (
      tester,
    ) async {
      final svc = MockProfileService(); // ownProfile stays null
      await pumpSelfTile(tester, profileService: svc);

      expect(find.byType(HavenAvatar), findsNothing);
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(
        svc.methodCalls.map((c) => c.method),
        isNot(contains('getMemberProfile')),
      );
    });

    testWidgets('self tile updates reactively when the own avatar is set', (
      tester,
    ) async {
      final svc = MockProfileService(); // starts with no profile
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => buildIdentity()),
          displayNameProvider.overrideWith((_) async => 'Alice'),
          profileServiceProvider.overrideWithValue(svc),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
                  npub: selfNpub,
                  isAdmin: false,
                  status: MembershipStatus.accepted,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No avatar yet → initials only.
      expect(find.byType(HavenAvatar), findsNothing);

      // The user picks a photo in settings: bytes land in the store and the
      // controller invalidates ownProfileProvider. The mounted self tile must
      // re-fetch and show the image — this is exactly the reported scenario.
      svc.ownProfile = Profile(
        pubkeyHex: selfPubkey,
        pictureBytes: jpegBytes,
        pictureHash: 'hash',
      );
      container.invalidate(ownProfileProvider);
      await tester.pumpAndSettle();

      expect(find.byType(HavenAvatar), findsOneWidget);
    });

    testWidgets('other-member tile still reads the per-member profile store', (
      tester,
    ) async {
      // Guard against the self-branch accidentally capturing other members:
      // a non-self member must keep reading memberProfileProvider even when
      // the viewer happens to have an own avatar set.
      final svc = MockProfileService(
        ownProfile: Profile(
          pubkeyHex: selfPubkey,
          pictureBytes: jpegBytes,
          pictureHash: 'own-hash',
        ),
        memberProfiles: {
          otherPubkey: Profile(
            pubkeyHex: otherPubkey,
            pictureBytes: jpegBytes,
            pictureHash: 'member-hash',
          ),
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((_) async => buildIdentity()),
            displayNameProvider.overrideWith((_) async => 'Alice'),
            profileServiceProvider.overrideWithValue(svc),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CircleMemberTile(
                member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HavenAvatar), findsOneWidget);
      final methods = svc.methodCalls.map((c) => c.method);
      expect(methods, contains('getMemberProfile'));
      expect(
        methods,
        isNot(contains('getOwnProfile')),
        reason: 'Other members must never read the viewer own-profile store.',
      );
    });

    testWidgets(
      'self tile survives the identity-loading frame without crashing, '
      'then switches to the own avatar once identity resolves',
      (tester) async {
        // Regression guard for the transient window: before identityProvider
        // resolves, currentUserPubkey is null so isSelf is false and the
        // tile falls through to the (plain-pubkey-keyed) member-profile
        // branch for the self pubkey — which simply misses (returns null)
        // rather than crashing, unlike the old mlsGroupId-based null-safety
        // hazard. Once identity resolves, isSelf flips true and the tile
        // reads the own store and shows the image.
        final identityCompleter = Completer<Identity?>();
        final svc = MockProfileService(
          ownProfile: Profile(
            pubkeyHex: selfPubkey,
            pictureBytes: jpegBytes,
            pictureHash: 'hash',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) => identityCompleter.future),
              displayNameProvider.overrideWith((_) async => 'Alice'),
              profileServiceProvider.overrideWithValue(svc),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: CircleMemberTile(
                  member: buildMember(pubkey: selfPubkey),
                ),
              ),
            ),
          ),
        );

        // Identity still loading → isSelf false → member-store path is taken
        // for the self pubkey, which misses. No crash; initials shown.
        await tester.pump();
        expect(find.byType(HavenAvatar), findsNothing);
        expect(find.byType(CircleAvatar), findsOneWidget);

        // Identity resolves to the self pubkey → isSelf true → own store read.
        identityCompleter.complete(buildIdentity());
        await tester.pumpAndSettle();
        expect(find.byType(HavenAvatar), findsOneWidget);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Long-press to copy npub — the tile's public-key copy affordance.
  //
  // Long-pressing the row copies the member's FULL npub (never the
  // truncated display value) to the clipboard, fires a medium-impact
  // haptic, and shows a confirming SnackBar. `ListTile.onLongPress` is
  // wired whenever `member.npub` is non-empty (`canCopy`) — independent of
  // `hasLocation`/`isInteractive` and of `MembershipStatus` — so it works
  // for every row, including non-interactive ("No recent location") and
  // pending-invitation rows. The same action is also exposed as an
  // accessible, labeled CustomSemanticsAction on the outer Semantics node
  // in the common case (no admin remove button present) — discoverable by
  // both TalkBack and VoiceOver, unlike a raw Semantics.onLongPress.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — long-press to copy npub', () {
    // Captures platform-channel method calls (Clipboard.setData,
    // HapticFeedback.vibrate) so we can assert on the copy behaviour,
    // mirroring the mocking pattern already used for NpubQrCode's
    // identical copy-on-hold feature.
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

    MethodCall? clipboardCall() {
      for (final call in platformCalls) {
        if (call.method == 'Clipboard.setData') return call;
      }
      return null;
    }

    // The SnackBar shown after a successful copy auto-dismisses via a
    // 2-second Timer (see CircleMemberTile._copyNpub). Any test that
    // triggers it must drain that timer before finishing, otherwise
    // flutter_test fails the test for a still-pending Timer.
    Future<void> drainSnackBarTimer(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    testWidgets('copies the FULL npub, not the truncated display value', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      await tester.longPress(find.byType(ListTile));
      await tester.pumpAndSettle();

      final call = clipboardCall();
      expect(call, isNotNull, reason: 'Clipboard.setData should be invoked');
      final copied = (call!.arguments as Map)['text'] as String;
      expect(copied, otherNpub);
      expect(
        copied,
        isNot(shortNpub(otherNpub)),
        reason:
            'The clipboard must receive the full npub, never the '
            'truncated display value shown in the UI.',
      );

      await drainSnackBarTimer(tester);
    });

    testWidgets('shows a confirmation SnackBar after copying', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      await tester.longPress(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(find.text('Public key copied to clipboard'), findsOneWidget);

      await drainSnackBarTimer(tester);
    });

    testWidgets('triggers medium-impact haptic feedback', (tester) async {
      await pumpTile(
        tester,
        member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      await tester.longPress(find.byType(ListTile));
      await tester.pumpAndSettle();

      expect(
        platformCalls.any(
          (c) =>
              c.method == 'HapticFeedback.vibrate' &&
              c.arguments == 'HapticFeedbackType.mediumImpact',
        ),
        isTrue,
        reason:
            'Copying the npub must fire a medium-impact haptic, matching '
            "_copyNpub's HapticFeedback.mediumImpact() call.",
      );

      await drainSnackBarTimer(tester);
    });

    testWidgets(
      'copies the npub for a member with hasLocation false — copy is not '
      'gated by the disabled tap state',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          hasLocation: false,
          onTap: () {},
        );

        await tester.longPress(find.byType(ListTile));
        await tester.pumpAndSettle();

        final call = clipboardCall();
        expect(call, isNotNull);
        expect((call!.arguments as Map)['text'], otherNpub);

        await drainSnackBarTimer(tester);
      },
    );

    testWidgets('copies the npub for a pending (not-yet-accepted) member', (
      tester,
    ) async {
      await pumpTile(
        tester,
        member: buildMember(
          pubkey: otherPubkey,
          displayName: 'Bob',
          status: MembershipStatus.pending,
        ),
        identity: buildIdentity(),
        displayName: 'Alice',
      );

      await tester.longPress(find.byType(ListTile));
      await tester.pumpAndSettle();

      final call = clipboardCall();
      expect(call, isNotNull);
      expect((call!.arguments as Map)['text'], otherNpub);

      await drainSnackBarTimer(tester);
    });

    testWidgets(
      'exposes copy as an accessible custom action when no admin remove '
      'button is present',
      (tester) async {
        final handle = tester.ensureSemantics();

        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        // With excludeSemantics: true (no onRemove → hasInteractiveChild is
        // false), the ListTile's own semantics are dropped and the outer
        // Semantics node — found by walking up from the ListTile — is the
        // one that carries the copy action.
        final node = tester.getSemantics(find.byType(ListTile));
        final data = node.getSemanticsData();

        final customActions = (data.customSemanticsActionIds ?? const <int>[])
            .map((id) => CustomSemanticsAction.getAction(id)!)
            .toList();
        expect(
          customActions,
          contains(const CustomSemanticsAction(label: 'Copy public key')),
          reason:
              'The copy-npub action must be exposed as a labeled '
              'CustomSemanticsAction so it is discoverable in both '
              "TalkBack's actions menu and VoiceOver's Actions rotor, "
              'independent of the tap gesture and the enabled state '
              '(pumpTile never sets onRemove, so hasInteractiveChild is '
              'false and the outer Semantics node owns this action).',
        );

        handle.dispose();
      },
    );

    testWidgets(
      'exposes "member details" as an accessible custom action even when '
      'an admin remove button is present (NIT-b)',
      (tester) async {
        final handle = tester.ensureSemantics();

        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          onTap: () {},
          // Presence of a Remove button flips hasInteractiveChild ->
          // descendantsExcluded: false, previously dropping the
          // member-details action entirely for removable (e.g. admin) rows.
          onRemove: () {},
        );

        final node = tester.getSemantics(
          find.bySemanticsLabel('Bob, tap to center map on their location'),
        );
        final customActions =
            (node.getSemanticsData().customSemanticsActionIds ??
                    const <int>[])
                .map((id) => CustomSemanticsAction.getAction(id)!)
                .toList();

        expect(
          customActions,
          contains(const CustomSemanticsAction(label: 'Member Details')),
          reason:
              'The member-details action (nickname edit + copy-npub sheet) '
              'must stay reachable via a labeled CustomSemanticsAction even '
              'when a Remove button is present — the leading avatar '
              'GestureDetector carries no semantics label of its own, so '
              "without this action a removable member's detail sheet was "
              'unreachable to TalkBack/VoiceOver users.',
        );

        handle.dispose();
      },
    );

    testWidgets(
      'forwards tap-to-center to the outer semantics node for an '
      'interactive member',
      (tester) async {
        // Regression guard for the outer node previously declaring
        // `button: isInteractive` without ever wiring `onTap` — with
        // excludeSemantics: true the ListTile's own tap semantics are
        // dropped, so screen readers had no way to activate the row.
        final handle = tester.ensureSemantics();

        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          identity: buildIdentity(),
          displayName: 'Alice',
          onTap: () {},
        );

        final node = tester.getSemantics(find.byType(ListTile));
        final data = node.getSemanticsData();

        expect(
          data.hasAction(SemanticsAction.tap),
          isTrue,
          reason:
              'An interactive member must forward tap-to-center to the '
              'outer Semantics node so screen reader users can activate '
              'the row, not just sighted users tapping the ListTile.',
        );

        handle.dispose();
      },
    );
  });
}
