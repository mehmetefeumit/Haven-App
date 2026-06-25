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
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../mocks/mock_circle_service.dart';

void main() {
  const selfPubkey =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const otherPubkey =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  Identity buildIdentity({String pubkeyHex = selfPubkey}) {
    return Identity(
      pubkeyHex: pubkeyHex,
      npub: 'npub1self',
      createdAt: DateTime(2025),
    );
  }

  CircleMember buildMember({
    String pubkey = selfPubkey,
    String? displayName,
    bool isAdmin = false,
    MembershipStatus status = MembershipStatus.accepted,
  }) {
    return CircleMember(
      pubkey: pubkey,
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
    bool hasLocation = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith((_) async => identity),
          displayNameProvider.overrideWith((_) async => displayName),
          // The self tile reads ownAvatarProvider, which reaches the circle
          // service. These cases assert names/styles, not avatar images, so a
          // bare mock (no avatar set) keeps them off the real keyring.
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CircleMemberTile(
              member: member,
              trailing: trailing,
              onTap: onTap,
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

      // The pubkey hex must not leak into the title area — only the
      // truncated subtitle should contain pubkey fragments.
      final title = NpubValidator.truncate(selfPubkey);
      expect(
        find.text(title),
        findsNothing,
        reason:
            'Self member must NOT render the truncated pubkey as the '
            'title when a settings display name is available',
      );
    });

    testWidgets(
      'renders truncated pubkey as subtitle when settings name is shown',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: selfPubkey),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        final subtitleText = NpubValidator.truncate(
          selfPubkey,
          prefixLength: 8,
          suffixLength: 4,
        );
        expect(find.text(subtitleText), findsOneWidget);
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

      expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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

        expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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
      'shows truncated pubkey for non-self members without a contact name',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: otherPubkey),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.text(NpubValidator.truncate(otherPubkey)), findsOneWidget);
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

        final text = tester.widget<Text>(
          find.text(NpubValidator.truncate(otherPubkey)),
        );
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

      expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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
      expect(find.text(NpubValidator.truncate(otherPubkey)), findsOneWidget);
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
        // Pubkey subtitle is replaced by the pending indicator — make sure
        // we don't accidentally render both.
        final subtitleText = NpubValidator.truncate(
          selfPubkey,
          prefixLength: 8,
          suffixLength: 4,
        );
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
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: CircleMemberTile(
                  member: CircleMember(
                    pubkey: selfPubkey,
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
        expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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
              circleServiceProvider.overrideWithValue(MockCircleService()),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: CircleMemberTile(
                  member: CircleMember(
                    pubkey: selfPubkey,
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
        expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
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
      expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
                  isAdmin: false,
                  status: MembershipStatus.accepted,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
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
          circleServiceProvider.overrideWithValue(MockCircleService()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: CircleMember(
                  pubkey: selfPubkey,
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

        // The pending-indicator and the truncated-pubkey-subtitle are both
        // absent in this configuration. The only pubkey text rendered is
        // the title.
        expect(find.text('Invitation Pending'), findsNothing);
        final subtitleText = NpubValidator.truncate(
          otherPubkey,
          prefixLength: 8,
          suffixLength: 4,
        );
        expect(
          find.text(subtitleText),
          findsNothing,
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
        // Pubkey subtitle is replaced by the no-location hint.
        final subtitleText = NpubValidator.truncate(
          otherPubkey,
          prefixLength: 8,
          suffixLength: 4,
        );
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
  // M2 — encrypted avatar display via memberAvatarThumbnailProvider.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — M2 avatar display', () {
    final groupId = [0x01, 0x02, 0x03, 0x04];
    // Minimal valid JPEG header so Image.memory decodes without error.
    final jpegBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    ]);

    Future<void> pumpTileWithAvatar(
      WidgetTester tester, {
      required CircleMember member,
      required MockCircleService circleService,
      List<int>? mlsGroupId,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((_) async => null),
            displayNameProvider.overrideWith((_) async => null),
            circleServiceProvider.overrideWithValue(circleService),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: member,
                mlsGroupId: mlsGroupId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'renders CircleAvatar initials when mlsGroupId is null '
      '(no avatar provider queried)',
      (tester) async {
        final svc = MockCircleService();
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          circleService: svc,
          mlsGroupId: null,
        );

        // CircleAvatar should be present (initials path).
        expect(find.byType(CircleAvatar), findsOneWidget);
        // HavenAvatar must NOT appear — no bytes, no mlsGroupId.
        expect(find.byType(HavenAvatar), findsNothing);
        // No thumbnail fetch attempted.
        expect(svc.methodCalls, isNot(contains('getMemberAvatarThumbnail')));
      },
    );

    testWidgets(
      'renders CircleAvatar initials when thumbnail returns null',
      (tester) async {
        // Service returns null thumbnail — fallback to initials.
        final svc = MockCircleService();
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          circleService: svc,
          mlsGroupId: groupId,
        );

        expect(find.byType(CircleAvatar), findsOneWidget);
        expect(find.byType(HavenAvatar), findsNothing);
        // The provider was queried.
        expect(svc.methodCalls, contains('getMemberAvatarThumbnail'));
      },
    );

    testWidgets(
      'renders HavenAvatar with image bytes when thumbnail is available',
      (tester) async {
        final svc = MockCircleService()
          ..memberAvatarThumbnailBytes = jpegBytes;
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          circleService: svc,
          mlsGroupId: groupId,
        );

        // HavenAvatar rendered — not the bare CircleAvatar fallback.
        expect(find.byType(HavenAvatar), findsOneWidget);
      },
    );

    testWidgets(
      'falls back to CircleAvatar when getMemberAvatarThumbnail throws',
      (tester) async {
        final svc = MockCircleService()
          ..shouldThrowOnGetMemberAvatarThumbnail = true;
        await pumpTileWithAvatar(
          tester,
          member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
          circleService: svc,
          mlsGroupId: groupId,
        );

        // The provider catches the error and returns null → initials shown.
        expect(find.byType(CircleAvatar), findsOneWidget);
        expect(find.byType(HavenAvatar), findsNothing);
      },
    );

    testWidgets(
      'direct memberAvatarThumbnailProvider override: bytes present renders '
      'HavenAvatar',
      (tester) async {
        final key = MemberAvatarKey(
          mlsGroupId: groupId,
          pubkeyHex: otherPubkey,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) async => null),
              displayNameProvider.overrideWith((_) async => null),
              // Inject bytes directly via provider override.
              memberAvatarThumbnailProvider(key).overrideWith(
                (_) async => jpegBytes,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: CircleMemberTile(
                  member: buildMember(pubkey: otherPubkey),
                  mlsGroupId: groupId,
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
      'direct memberAvatarThumbnailProvider override: null shows initials',
      (tester) async {
        final key = MemberAvatarKey(
          mlsGroupId: groupId,
          pubkeyHex: otherPubkey,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) async => null),
              displayNameProvider.overrideWith((_) async => null),
              memberAvatarThumbnailProvider(key).overrideWith(
                (_) async => null,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: CircleMemberTile(
                  member: buildMember(pubkey: otherPubkey),
                  mlsGroupId: groupId,
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
  // show on my own row in the circle member list." The viewer never receives
  // their own avatar broadcast back, so it lives ONLY in the own-avatar store
  // (ownAvatarProvider), never in the per-circle received-member store. The
  // self tile must therefore read ownAvatarProvider, not
  // memberAvatarThumbnailProvider.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — self avatar (own store)', () {
    final groupId = [0x09, 0x08, 0x07, 0x06];
    // Minimal valid JPEG header so HavenAvatar's Image.memory accepts it.
    final jpegBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    ]);

    Future<void> pumpSelfTile(
      WidgetTester tester, {
      required MockCircleService circleService,
      List<int>? mlsGroupId,
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
            circleServiceProvider.overrideWithValue(circleService),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: buildMember(pubkey: selfPubkey),
                mlsGroupId: mlsGroupId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'self tile renders own avatar from the own store, not the member store',
      (tester) async {
        final svc = MockCircleService()..avatarThumbnailBytes = jpegBytes;
        await pumpSelfTile(tester, circleService: svc, mlsGroupId: groupId);

        expect(find.byType(HavenAvatar), findsOneWidget);
        // The own-avatar store was queried...
        expect(svc.methodCalls, contains('getMyAvatarThumbnail'));
        // ...and the per-circle received-member store was NOT — the viewer's
        // own avatar never lives there, so querying it would always miss.
        expect(
          svc.methodCalls,
          isNot(contains('getMemberAvatarThumbnail')),
          reason:
              'Self tile must read ownAvatarProvider, never the member store.',
        );
      },
    );

    testWidgets('self tile falls back to initials when no own avatar is set', (
      tester,
    ) async {
      final svc = MockCircleService(); // avatarThumbnailBytes stays null
      await pumpSelfTile(tester, circleService: svc, mlsGroupId: groupId);

      expect(find.byType(HavenAvatar), findsNothing);
      expect(find.byType(CircleAvatar), findsOneWidget);
      expect(svc.methodCalls, isNot(contains('getMemberAvatarThumbnail')));
    });

    testWidgets('self tile shows own avatar even when mlsGroupId is null', (
      tester,
    ) async {
      // The own avatar is independent of any circle, so a self tile rendered
      // without a circle context (mlsGroupId == null) still shows it.
      final svc = MockCircleService()..avatarThumbnailBytes = jpegBytes;
      await pumpSelfTile(tester, circleService: svc, mlsGroupId: null);

      expect(find.byType(HavenAvatar), findsOneWidget);
    });

    testWidgets('self tile updates reactively when the own avatar is set', (
      tester,
    ) async {
      final svc = MockCircleService(); // starts with no avatar
      final container = ProviderContainer(
        overrides: [
          identityProvider.overrideWith((_) async => buildIdentity()),
          displayNameProvider.overrideWith((_) async => 'Alice'),
          circleServiceProvider.overrideWithValue(svc),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: const CircleMember(
                  pubkey: selfPubkey,
                  isAdmin: false,
                  status: MembershipStatus.accepted,
                ),
                mlsGroupId: groupId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No avatar yet → initials only.
      expect(find.byType(HavenAvatar), findsNothing);

      // The user picks a photo in settings: bytes land in the store and the
      // controller invalidates ownAvatarProvider. The mounted self tile must
      // re-fetch and show the image — this is exactly the reported scenario.
      svc.avatarThumbnailBytes = jpegBytes;
      container.invalidate(ownAvatarProvider);
      await tester.pumpAndSettle();

      expect(find.byType(HavenAvatar), findsOneWidget);
    });

    testWidgets('other-member tile still reads the per-circle member store', (
      tester,
    ) async {
      // Guard against the self-branch accidentally capturing other members:
      // a non-self member must keep reading memberAvatarThumbnailProvider even
      // when the viewer happens to have an own avatar set.
      final svc = MockCircleService()
        ..memberAvatarThumbnailBytes = jpegBytes
        ..avatarThumbnailBytes = jpegBytes;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            identityProvider.overrideWith((_) async => buildIdentity()),
            displayNameProvider.overrideWith((_) async => 'Alice'),
            circleServiceProvider.overrideWithValue(svc),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: CircleMemberTile(
                member: buildMember(pubkey: otherPubkey, displayName: 'Bob'),
                mlsGroupId: groupId,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HavenAvatar), findsOneWidget);
      expect(svc.methodCalls, contains('getMemberAvatarThumbnail'));
      expect(
        svc.methodCalls,
        isNot(contains('getMyAvatarThumbnail')),
        reason: 'Other members must never read the viewer own-avatar store.',
      );
    });

    testWidgets(
      'self tile survives the identity-loading frame with a non-null '
      'mlsGroupId, then switches to the own avatar once identity resolves',
      (tester) async {
        // Regression guard for the transient window: before identityProvider
        // resolves, currentUserPubkey is null so isSelf is false. A
        // self-pubkey tile with a non-null mlsGroupId therefore falls THROUGH
        // to the member-store branch and evaluates `groupId!`. That must not
        // crash and must render initials (the member store never holds the
        // viewer's own avatar). Once identity resolves, isSelf flips true and
        // the tile reads the own store and shows the image. A future refactor
        // that moves the null-groupId guard would trip this test.
        final identityCompleter = Completer<Identity?>();
        final svc = MockCircleService()..avatarThumbnailBytes = jpegBytes;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) => identityCompleter.future),
              displayNameProvider.overrideWith((_) async => 'Alice'),
              circleServiceProvider.overrideWithValue(svc),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: CircleMemberTile(
                  member: buildMember(pubkey: selfPubkey),
                  mlsGroupId: groupId,
                ),
              ),
            ),
          ),
        );

        // Identity still loading → isSelf false → non-null-groupId member-store
        // path is taken (groupId! exercised). No crash; initials shown.
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
}
