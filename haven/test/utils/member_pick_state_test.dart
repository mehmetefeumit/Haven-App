/// Tests for the picker's eligibility rules (plan §9.5).
///
/// These decide the one thing the picker must never get wrong: whether a
/// person can be added to the invitation being built. Two of the three
/// refusals are the fix for a shipped defect — `create_circle_page.dart`
/// carried no identity check at all, so a user could stage their own key,
/// and `add_member_page.dart` only caught self incidentally, AFTER a
/// KeyPackage fetch, so offline it failed open.
library;

import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/utils/member_pick_state.dart';

const _aliceHex =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';
const _bobHex =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _selfHex =
    '5e1f0000000000000000000000000000000000000000000000000000000000ff';
const _selfNpub =
    'npub1tc0sqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql7pytwqgs';

MemberCandidate _candidate({String hex = _aliceHex, String npub = _aliceNpub}) {
  return buildMemberCandidate(
    entry: DirectoryEntry(
      pubkeyHex: hex,
      npub: npub,
      tier: DirectoryTier.current,
    ),
    fold: (value) => value.toLowerCase(),
  );
}

/// A [Set] that throws if anything iterates it, so a test using it fails the
/// moment `resolveMemberPickState` falls back to a linear scan (`.any`,
/// `for`, spread, `toSet`) instead of the O(1) `contains` the fix requires.
/// `contains` is the only operation this leaves usable.
class _NoIterationSet extends SetBase<String> {
  _NoIterationSet(this._inner);

  final Set<String> _inner;

  @override
  bool contains(Object? element) => _inner.contains(element);

  @override
  int get length => _inner.length;

  @override
  Iterator<String> get iterator =>
      throw StateError('unexpected iteration over circleMemberPubkeysHex');

  @override
  bool add(String value) => throw UnimplementedError();

  @override
  bool remove(Object? value) => throw UnimplementedError();

  @override
  String? lookup(Object? element) => throw UnimplementedError();

  @override
  Set<String> toSet() => throw UnimplementedError();
}

void main() {
  group('resolveMemberPickState', () {
    test('offers a co-member who is neither staged nor already in the circle',
        () {
      expect(
        resolveMemberPickState(
          _candidate(),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.selectable,
      );
    });

    test('refuses the user themselves', () {
      // The directory excludes self, so this is a non-conforming directory —
      // and the promise "you are never offered yourself" must hold at the
      // render layer independently of the layer that builds the list.
      expect(
        resolveMemberPickState(
          _candidate(hex: _selfHex, npub: _selfNpub),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.self,
      );
    });

    test('names self ahead of circle membership, because self is always both',
        () {
      // On the add-to-existing-circle screen the user IS in the roster. If
      // membership were checked first, the only refusal they could ever see
      // for their own key is "Already in this circle" — literally true and
      // the exact confusion §9.5 requires three distinct reasons to end.
      expect(
        resolveMemberPickState(
          _candidate(hex: _selfHex, npub: _selfNpub),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {_selfHex},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.self,
      );
    });

    test('refuses someone already in the target circle', () {
      expect(
        resolveMemberPickState(
          _candidate(),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {_aliceHex},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.alreadyInCircle,
      );
    });

    test('refuses someone already staged on this screen', () {
      expect(
        resolveMemberPickState(
          _candidate(),
          stagedNpubs: const {_aliceNpub},
          circleMemberPubkeysHex: const {},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.alreadyStaged,
      );
    });

    test('names circle membership ahead of staging', () {
      // Staging is undoable on this screen; membership is a fact about the
      // circle. Reporting the reason the user cannot change would leave them
      // un-staging a row that would still be refused.
      expect(
        resolveMemberPickState(
          _candidate(),
          stagedNpubs: const {_aliceNpub},
          circleMemberPubkeysHex: const {_aliceHex},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.alreadyInCircle,
      );
    });

    test('still offers people when the identity has not resolved', () {
      // A null identity is the app still starting up, not a signal that
      // everyone is a stranger. Refusing every row would empty the picker
      // for a reason no user could act on; the entry path repeats the check
      // when the identity is known.
      expect(
        resolveMemberPickState(
          _candidate(),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {},
          selfPubkeyHex: null,
        ),
        MemberPickState.selectable,
      );
    });

    test('looks up circle membership in O(1) — never iterates the set',
        () {
      // The defect this replaced: `.any((m) => m.toLowerCase() == hex)`
      // lower-cases and compares EVERY member on EVERY rendered row, per
      // keystroke. `_NoIterationSet.iterator` throws, so this only passes if
      // the implementation reaches for `Set.contains` — an allocation-free
      // O(1) lookup — rather than any form of linear scan.
      final set = _NoIterationSet({_aliceHex});

      expect(
        resolveMemberPickState(
          _candidate(),
          stagedNpubs: const {},
          circleMemberPubkeysHex: set,
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.alreadyInCircle,
      );
      expect(
        resolveMemberPickState(
          _candidate(hex: _bobHex),
          stagedNpubs: const {},
          circleMemberPubkeysHex: set,
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.selectable,
      );
    });

    test('matches hex case-insensitively for self and for membership', () {
      expect(
        resolveMemberPickState(
          _candidate(hex: _selfHex.toUpperCase(), npub: _selfNpub),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.self,
      );
      expect(
        resolveMemberPickState(
          _candidate(hex: _aliceHex.toUpperCase()),
          stagedNpubs: const {},
          circleMemberPubkeysHex: const {_aliceHex},
          selfPubkeyHex: _selfHex,
        ),
        MemberPickState.alreadyInCircle,
      );
    });
  });

  group('resolveEntryPickState', () {
    test('accepts an npub that is nobody the screen already knows', () {
      expect(
        resolveEntryPickState(
          _aliceNpub,
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        MemberPickState.selectable,
      );
    });

    test('refuses the user typing their own npub', () {
      // The shipped defect: create-circle had no identity read at all, so
      // this npub was staged, validated against the user's own KeyPackage,
      // marked valid and carried into circle creation.
      expect(
        resolveEntryPickState(
          _selfNpub,
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        MemberPickState.self,
      );
    });

    test('refuses an existing circle member with no relay lookup involved', () {
      // The check that shipped ran on a hex pubkey read out of a fetched
      // KeyPackage, so with no network there was nothing to compare and the
      // add proceeded. Roster npubs are already on the device.
      expect(
        resolveEntryPickState(
          _aliceNpub,
          stagedNpubs: const {},
          circleMemberNpubs: const {_aliceNpub},
          selfNpub: _selfNpub,
        ),
        MemberPickState.alreadyInCircle,
      );
    });

    test('refuses an npub already staged', () {
      expect(
        resolveEntryPickState(
          _aliceNpub,
          stagedNpubs: const {_aliceNpub},
          circleMemberNpubs: const {},
          selfNpub: _selfNpub,
        ),
        MemberPickState.alreadyStaged,
      );
    });

    test('names self first here too', () {
      expect(
        resolveEntryPickState(
          _selfNpub,
          stagedNpubs: const {_selfNpub},
          circleMemberNpubs: const {_selfNpub},
          selfNpub: _selfNpub,
        ),
        MemberPickState.self,
      );
    });

    test('accepts when the identity has not resolved', () {
      expect(
        resolveEntryPickState(
          _selfNpub,
          stagedNpubs: const {},
          circleMemberNpubs: const {},
          selfNpub: null,
        ),
        MemberPickState.selectable,
      );
    });
  });
}
