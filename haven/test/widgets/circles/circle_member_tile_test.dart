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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/circle_member_tile.dart';

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
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith((_) async => identity),
          displayNameProvider.overrideWith((_) async => displayName),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CircleMemberTile(
              member: member,
              trailing: trailing,
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('CircleMemberTile — self member', () {
    testWidgets(
      'shows settings display name for self instead of pubkey hex',
      (tester) async {
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
      },
    );

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

    testWidgets(
      'falls back to pubkey when self has no settings display name',
      (tester) async {
        await pumpTile(
          tester,
          member: buildMember(pubkey: selfPubkey),
          identity: buildIdentity(),
          displayName: null,
        );

        expect(find.text(NpubValidator.truncate(selfPubkey)), findsOneWidget);
      },
    );

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
        member: buildMember(
          pubkey: selfPubkey,
          displayName: 'Contact Me',
        ),
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
        member: buildMember(
          pubkey: selfPubkey,
          displayName: 'Contact Me',
        ),
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

    testWidgets(
      'ignores a settings display name when no identity is loaded',
      (tester) async {
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
      },
    );
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
        trailing: const Icon(Icons.close, key: Key('custom-trailing')),
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

    testWidgets(
      'renders pubkey fallback when identityProvider errors out',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith(
                (_) => Future<Identity?>.error(
                  Exception('identity load failed'),
                ),
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
      },
    );

    testWidgets(
      'renders pubkey fallback when displayNameProvider errors out',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              identityProvider.overrideWith((_) async => buildIdentity()),
              displayNameProvider.overrideWith(
                (_) => Future<String?>.error(Exception('prefs read failed')),
              ),
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
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Reactive invalidation: when the user saves a new display name, mounted
  // tiles must re-render with the updated value.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — reactive invalidation', () {
    testWidgets(
      're-renders with new settings display name after invalidate',
      (tester) async {
        var currentName = 'Alice';
        final container = ProviderContainer(
          overrides: [
            identityProvider.overrideWith((_) async => buildIdentity()),
            displayNameProvider.overrideWith((_) async => currentName),
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
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Regression guards flagged by test-coverage reviewer.
  // ---------------------------------------------------------------------------

  group('CircleMemberTile — style / subtitle / avatar regression guards', () {
    testWidgets(
      'self with settings display name renders title in the default '
      '(non-mono) style',
      (tester) async {
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
      },
    );

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
          member: buildMember(
            pubkey: otherPubkey,
            displayName: 'Charlie',
          ),
          identity: buildIdentity(),
          displayName: 'Alice',
        );

        expect(find.widgetWithText(CircleAvatar, 'C'), findsOneWidget);
      },
    );

    testWidgets(
      'avatar initial grapheme-cluster safe for emoji display name',
      (tester) async {
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
      },
    );
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
}
