/// Unit tests for [resolveMemberDisplayName] and [isSelfMember].
///
/// These helpers encapsulate the "show the current user's settings display
/// name on their own member-tile row" behavior. The tests cover every
/// branch end-to-end so the widget layer above can remain dumb.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
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
}
