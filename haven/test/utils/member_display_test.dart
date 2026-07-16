/// Unit tests for [resolveMemberDisplayName] and [isSelfMember].
///
/// These helpers encapsulate the "show the current user's settings display
/// name on their own member-tile row" behavior. The tests cover every
/// branch end-to-end so the widget layer above can remain dumb.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/utils/member_display.dart';

void main() {
  // Canonical lowercase hex pubkeys used throughout.
  const selfPubkey =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const otherPubkey =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  CircleMember buildMember({
    String pubkey = selfPubkey,
    String? displayName,
    bool isAdmin = false,
    MembershipStatus status = MembershipStatus.accepted,
  }) {
    return CircleMember(
      pubkey: pubkey,
      npub: 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
      displayName: displayName,
      isAdmin: isAdmin,
      status: status,
    );
  }

  group('isSelfMember', () {
    test('returns true for exact lowercase match', () {
      final member = buildMember();
      expect(isSelfMember(member, currentUserPubkey: selfPubkey), isTrue);
    });

    test('returns true for uppercase/mixed-case pubkey', () {
      final member = buildMember(pubkey: selfPubkey.toUpperCase());
      expect(
        isSelfMember(member, currentUserPubkey: selfPubkey),
        isTrue,
        reason: 'Comparison must be case-insensitive',
      );
    });

    test('returns true when current user pubkey is uppercase', () {
      final member = buildMember();
      expect(
        isSelfMember(member, currentUserPubkey: selfPubkey.toUpperCase()),
        isTrue,
      );
    });

    test('returns false for different pubkey', () {
      final member = buildMember(pubkey: otherPubkey);
      expect(isSelfMember(member, currentUserPubkey: selfPubkey), isFalse);
    });

    test('returns false when current pubkey is null', () {
      final member = buildMember();
      expect(isSelfMember(member, currentUserPubkey: null), isFalse);
    });

    test('returns false when current pubkey is empty', () {
      final member = buildMember();
      expect(isSelfMember(member, currentUserPubkey: ''), isFalse);
    });

    test('returns false when member pubkey is empty', () {
      final member = buildMember(pubkey: '');
      expect(isSelfMember(member, currentUserPubkey: selfPubkey), isFalse);
    });
  });

  group('resolveMemberDisplayName — self', () {
    test('returns settings display name when self and name is set', () {
      final member = buildMember();
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Alice',
      );
      expect(resolved, 'Alice');
    });

    test('trims surrounding whitespace on settings display name', () {
      final member = buildMember();
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: '  Alice  ',
      );
      expect(resolved, 'Alice');
    });

    test('falls back to contact display name when settings name is null', () {
      final member = buildMember(displayName: 'Local Nickname');
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: null,
      );
      expect(resolved, 'Local Nickname');
    });

    test('falls back to contact display name when settings name is empty', () {
      final member = buildMember(displayName: 'Local Nickname');
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: '',
      );
      expect(resolved, 'Local Nickname');
    });

    test(
      'falls back to contact display name when settings name is whitespace',
      () {
        final member = buildMember(displayName: 'Local Nickname');
        final resolved = resolveMemberDisplayName(
          member,
          currentUserPubkey: selfPubkey,
          currentUserDisplayName: '   \t\n  ',
        );
        expect(resolved, 'Local Nickname');
      },
    );

    test('returns null when self has no settings name and no contact name', () {
      final member = buildMember();
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: null,
      );
      expect(resolved, isNull);
    });

    test('settings display name wins over contact display name', () {
      final member = buildMember(displayName: 'Contact Name');
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Settings Name',
      );
      expect(resolved, 'Settings Name');
    });

    test('works when member pubkey is uppercase hex', () {
      final member = buildMember(pubkey: selfPubkey.toUpperCase());
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Alice',
      );
      expect(
        resolved,
        'Alice',
        reason: 'Case-insensitive self detection must still trigger',
      );
    });

    test('preserves internal whitespace in settings display name', () {
      final member = buildMember();
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Alice  Smith',
      );
      expect(resolved, 'Alice  Smith');
    });
  });

  group('resolveMemberDisplayName — other members', () {
    test('returns contact display name for non-self members', () {
      final member = buildMember(pubkey: otherPubkey, displayName: 'Bob');
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Alice',
      );
      expect(
        resolved,
        'Bob',
        reason:
            'Settings display name must never leak onto other members; it '
            'belongs to the current user only.',
      );
    });

    test('returns null for non-self member with no contact name', () {
      final member = buildMember(pubkey: otherPubkey);
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Alice',
      );
      expect(resolved, isNull);
    });

    test('behaves correctly when no identity exists (pubkey null)', () {
      final member = buildMember(pubkey: otherPubkey, displayName: 'Bob');
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: null,
        currentUserDisplayName: null,
      );
      expect(resolved, 'Bob');
    });

    test('returns null when no identity and no contact name', () {
      final member = buildMember(pubkey: otherPubkey);
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: null,
        currentUserDisplayName: null,
      );
      expect(resolved, isNull);
    });

    test('settings display name is ignored when identity is null', () {
      // Defensive: even if a caller somehow passes a settings name with a
      // null pubkey (shouldn't happen), the helper must not attribute it to
      // any random member.
      final member = buildMember(pubkey: otherPubkey, displayName: 'Bob');
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: null,
        currentUserDisplayName: 'Alice',
      );
      expect(resolved, 'Bob');
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases added after the first expert review.
  // ---------------------------------------------------------------------------

  group('resolveMemberDisplayName — combined null/empty edges', () {
    test('returns null when self has whitespace-only settings name AND no '
        'contact name', () {
      // This is the full fallback chain: settings trimmed to empty,
      // contact displayName absent, so caller must render pubkey.
      final member = buildMember();
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: '   ',
      );
      expect(resolved, isNull);
    });

    test(
      'returns null when self has empty settings name AND no contact name',
      () {
        final member = buildMember();
        final resolved = resolveMemberDisplayName(
          member,
          currentUserPubkey: selfPubkey,
          currentUserDisplayName: '',
        );
        expect(resolved, isNull);
      },
    );

    test('treats a mixed-case pubkey as self (case-insensitive)', () {
      // Guard against silent case-drift: a pubkey that mixes upper and lower
      // hex on either side must still be recognized as self.
      final mixedCase = selfPubkey
          .split('')
          .asMap()
          .entries
          .map((e) => e.key.isEven ? e.value.toUpperCase() : e.value)
          .join();
      final member = buildMember(pubkey: mixedCase);
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'Alice',
      );
      expect(resolved, 'Alice');
    });

    test(
      'preserves emoji / multi-code-unit characters in settings display name',
      () {
        // The raw value must pass through untouched so that the caller can
        // use grapheme-cluster-aware rendering for the avatar initial.
        final member = buildMember();
        final resolved = resolveMemberDisplayName(
          member,
          currentUserPubkey: selfPubkey,
          currentUserDisplayName: '🦊 Alice',
        );
        expect(resolved, '🦊 Alice');
      },
    );

    test('treats RTL-first display name the same as any other string', () {
      final member = buildMember();
      final resolved = resolveMemberDisplayName(
        member,
        currentUserPubkey: selfPubkey,
        currentUserDisplayName: 'أليس',
      );
      expect(resolved, 'أليس');
    });
  });

  // ---------------------------------------------------------------------------
  // resolveEffectiveMemberName — public-profile migration (plan D6 / Flutter
  // review F3). Four-tier precedence for NON-SELF members:
  //   local nickname -> profile.displayName -> profile.name -> npubFallback.
  // The self row deliberately keeps the dedicated resolveMemberDisplayName
  // path above and never routes through this resolver — asserted below.
  // ---------------------------------------------------------------------------

  group('resolveEffectiveMemberName — four-tier precedence (non-self)', () {
    const npubFallback = 'npub1qqqq…qqqq';

    Profile buildProfile({String? name, String? displayName}) => Profile(
      pubkeyHex: otherPubkey,
      name: name,
      displayName: displayName,
    );

    test('tier 1: local nickname wins over everything else', () {
      final resolved = resolveEffectiveMemberName(
        npubFallback: npubFallback,
        localOverride: 'Nickname',
        profile: buildProfile(name: 'name', displayName: 'display_name'),
      );
      expect(resolved, 'Nickname');
    });

    test(
      'tier 2: profile.displayName wins when no local nickname is set',
      () {
        final resolved = resolveEffectiveMemberName(
          npubFallback: npubFallback,
          profile: buildProfile(name: 'name', displayName: 'DisplayName'),
        );
        expect(resolved, 'DisplayName');
      },
    );

    test(
      'tier 3: profile.name wins when neither nickname nor displayName '
      'is set',
      () {
        final resolved = resolveEffectiveMemberName(
          npubFallback: npubFallback,
          profile: buildProfile(name: 'Name'),
        );
        expect(resolved, 'Name');
      },
    );

    test('tier 4: npubFallback wins when nothing else is known', () {
      final resolved = resolveEffectiveMemberName(npubFallback: npubFallback);
      expect(resolved, npubFallback);
    });

    test(
      'tier 4: npubFallback wins for a Known-but-empty profile (blank '
      'kind-0), not just an Unknown (null) one',
      () {
        final resolved = resolveEffectiveMemberName(
          npubFallback: npubFallback,
          profile: buildProfile(),
        );
        expect(resolved, npubFallback);
      },
    );

    test('never returns null — the contract is a non-nullable String', () {
      final resolved = resolveEffectiveMemberName(npubFallback: npubFallback);
      expect(resolved, isA<String>());
    });

    test('a whitespace-only nickname is treated as absent (tier 2 wins)', () {
      final resolved = resolveEffectiveMemberName(
        npubFallback: npubFallback,
        localOverride: '   ',
        profile: buildProfile(displayName: 'DisplayName'),
      );
      expect(resolved, 'DisplayName');
    });

    test(
      'a whitespace-only profile.displayName is treated as absent '
      '(tier 3 wins)',
      () {
        final resolved = resolveEffectiveMemberName(
          npubFallback: npubFallback,
          profile: buildProfile(name: 'Name', displayName: '   '),
        );
        expect(resolved, 'Name');
      },
    );

    test(
      'a whitespace-only profile.name is treated as absent (tier 4 wins)',
      () {
        final resolved = resolveEffectiveMemberName(
          npubFallback: npubFallback,
          profile: buildProfile(name: '   '),
        );
        expect(resolved, npubFallback);
      },
    );

    test('trims surrounding whitespace from the local nickname', () {
      final resolved = resolveEffectiveMemberName(
        npubFallback: npubFallback,
        localOverride: '  Nickname  ',
      );
      expect(resolved, 'Nickname');
    });

    test('preserves emoji / multi-code-unit graphemes intact', () {
      // Downstream callers (markerInitials / avatar glyphs) rely on getting
      // the raw string back untouched so they can apply grapheme-cluster-
      // aware truncation themselves — this resolver must never mangle a
      // surrogate pair by slicing it.
      final resolved = resolveEffectiveMemberName(
        npubFallback: npubFallback,
        localOverride: '🦊 Nickname',
      );
      expect(resolved, '🦊 Nickname');
    });
  });

  group('resolveEffectiveMemberName — self vs. other split (D6 / F3)', () {
    test(
      'self keeps the dedicated resolveMemberDisplayName path and never '
      'routes through resolveEffectiveMemberName',
      () {
        // A self member with a Contact-table displayName ("Contact Me") and
        // an authoritative settings name ("Settings Me") must resolve via
        // the settings-name-first self branch, exactly as the pre-migration
        // behavior (D6 requires the self row's resolution to be unaffected
        // by this new resolver).
        final selfMember = buildMember(displayName: 'Contact Me');
        final selfResolved = resolveMemberDisplayName(
          selfMember,
          currentUserPubkey: selfPubkey,
          currentUserDisplayName: 'Settings Me',
        );
        expect(selfResolved, 'Settings Me');

        // The generic resolver, called directly on the same member data as
        // if it were a non-self row, would instead prefer the (here, absent)
        // local override then the profile — demonstrating the two paths are
        // genuinely independent, not just coincidentally equal.
        final genericResolved = resolveEffectiveMemberName(
          npubFallback: 'npub1self…',
          localOverride: selfMember.displayName,
        );
        expect(genericResolved, 'Contact Me');
        expect(
          genericResolved,
          isNot(selfResolved),
          reason:
              'Self must never be routed through the generic resolver — the '
              'two paths would disagree here (Contact Me vs. Settings Me), '
              'which is exactly why D6 keeps them separate.',
        );
      },
    );
  });
}
