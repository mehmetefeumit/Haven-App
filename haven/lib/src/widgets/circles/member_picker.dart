/// The list of people the invite screens offer as picks.
///
/// Everything it draws is already on the device — the persistent member
/// directory and the local kind-0 cache — so opening it, and every keystroke
/// that filters it, costs no wire traffic at all (plan R2/R4). Two sections,
/// by tier: a person is offered under "Members of your circles" because
/// their pubkey is on the member list of a circle stored here, placed there
/// by an MLS-authenticated commit; under "Recently in your circles" because
/// it was, within the retention window (R5). That is ALL either heading
/// claims: Haven has no way to observe whether anyone ever accepted an
/// invitation, so nothing here may say or imply joined, accepted, active or
/// connected (§7.2).
///
/// A sliver, not a box: both host pages put their whole body in one
/// [CustomScrollView] with only the primary action pinned, because pinning
/// the field and the heading above a pinned button made the fixed chrome
/// taller than the body at a 2x text scale and the page could not lay out at
/// all (CI run 31462924650).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_directory_provider.dart';
import 'package:haven/src/providers/stranger_profile_provider.dart';
import 'package:haven/src/services/circle_service.dart' show DirectoryTier;
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_pick_state.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/member_avatar.dart';
import 'package:haven/src/widgets/common/section_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// How long a query must stand still before the result count is spoken.
///
/// The LIST does not wait — visual filtering is synchronous and undebounced.
/// Only the announcement waits, because a screen reader interrupted on every
/// keystroke reads nothing at all. A private const rather than a constructor
/// parameter: `testWidgets` already runs in fake time, so there is nothing to
/// inject.
const _announceAfter = Duration(milliseconds: 400);

/// The picker's results, as a sliver.
class MemberPickerResults extends ConsumerStatefulWidget {
  /// Creates a [MemberPickerResults].
  const MemberPickerResults({
    required this.query,
    required this.stagedNpubs,
    required this.circleMemberPubkeysHex,
    required this.circleMemberNpubs,
    required this.onSelected,
    required this.onStrangerSelected,
    super.key,
  });

  /// The current search text, owned by the field that renders the caret.
  ///
  /// Passed in rather than read from a provider: an `autoDispose` provider
  /// holding the query would reset to `''` the moment nothing listened,
  /// snapping the list back to everyone with no keystroke to explain it.
  final String query;

  /// npubs already staged on the host screen.
  final Set<String> stagedNpubs;

  /// Hex pubkeys already on the target circle's member list. Empty on the
  /// create-circle screen, which has no target circle yet.
  final Set<String> circleMemberPubkeysHex;

  /// The same members as [circleMemberPubkeysHex], in npub form.
  ///
  /// A separate set rather than one derived from the hex set: there is no
  /// hex→npub decoder on the Dart side (plan §10 D2), and
  /// [resolveEntryPickState] — the gate a typed-stranger candidate must pass
  /// before this widget ever asks a relay about them — compares npubs, the
  /// same form the search field already validates entries in. Empty on the
  /// create-circle screen, which has no target circle yet.
  final Set<String> circleMemberNpubs;

  /// Called when a pickable directory row is tapped.
  final void Function(MemberCandidate candidate) onSelected;

  /// Called when the typed-stranger row (D2) is tapped, with the npub it
  /// resolved for.
  ///
  /// A separate callback rather than folding a synthesized [MemberCandidate]
  /// into [onSelected]: a stranger's hex pubkey is not available on this
  /// device until AFTER a resolve succeeds (and never at all when nothing
  /// resolves), so there is no honest [MemberCandidate.pubkeyHex] to hand
  /// back. Both host screens stage by npub alone
  /// (`_onMemberAdded(String npub)`), which is exactly this signature.
  final void Function(String npub) onStrangerSelected;

  @override
  ConsumerState<MemberPickerResults> createState() =>
      _MemberPickerResultsState();
}

class _MemberPickerResultsState extends ConsumerState<MemberPickerResults> {
  Timer? _announceTimer;

  /// The result set last spoken, or `null` if nothing has been spoken yet —
  /// which is why the FIRST settled query is announced even when it matched
  /// nobody and the list was already empty.
  List<String>? _lastAnnounced;

  /// Whether the directory was still loading the last time [build] ran, or
  /// `null` before the first build.
  ///
  /// Detects the loading→settled transition, because nothing else does: the
  /// QUERY does not change across it, so [didUpdateWidget]'s guard never
  /// fires, and a query typed while the directory was still on its
  /// first-open backfill (seconds, on an upgraded install) would otherwise
  /// stay silenced by [_announce]'s own loading guard forever (plan F1).
  bool? _directoryWasLoading;

  /// The [_lastAnnounced] value [_announce] records for a read failure
  /// (plan F2) — distinct from any value a real result set can ever take,
  /// which is either the empty list (no matches) or a list of pubkey-hex or
  /// npub strings, neither of which take this shape. Sharing one field with
  /// the ordinary result copy, rather than a second `bool` tracked
  /// alongside it, is what keeps the two paths from being able to announce
  /// the same state twice out of sync with each other.
  static const _directoryErrorSentinel = ['__directory_error__'];

  @override
  void didUpdateWidget(MemberPickerResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _scheduleAnnouncement();
  }

  @override
  void dispose() {
    _announceTimer?.cancel();
    super.dispose();
  }

  void _scheduleAnnouncement() {
    _announceTimer?.cancel();
    _announceTimer = Timer(_announceAfter, _announce);
  }

  void _announce() {
    if (!mounted) return;
    final directory = ref.read(memberDirectoryProvider);
    // The directory may still be running a first-open backfill (seconds, on
    // an upgraded install) after the query already settled — speaking "no
    // matches" here would tell the user something the screen does not yet
    // know, and the correction would never follow: `build`'s loading→settled
    // transition is what re-arms this call once the read finishes (plan F1).
    if (directory.isLoading) return;

    // A read failure (plan F2) has no result set to describe, and must not
    // be spoken as "no matches" — the visible branch below already renders
    // it as a message distinct from both "no matches" and the silent
    // fresh-install state; the spoken side needs the same third option,
    // reusing the identical, already-reviewed string rather than staying
    // silent until a screen-reader user happens to swipe onto the row.
    // De-duped through the same [_lastAnnounced] guard as the ordinary copy
    // below, against a sentinel no real result set can ever equal, so a
    // standing failure is spoken once and never repeated per keystroke.
    if (directory.hasError) {
      if (_lastAnnounced != null &&
          listEquals(_lastAnnounced, _directoryErrorSentinel)) {
        return;
      }
      _lastAnnounced = _directoryErrorSentinel;
      final l10n = AppLocalizations.of(context);
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          l10n.memberPickerDirectoryUnavailable,
          Directionality.of(context),
        ),
      );
      return;
    }

    final results = ref.read(
      memberDirectoryResultsProvider(widget.query),
    );
    // A pending/resolved typed-stranger row is itself an offered match — it
    // must not be announced as "no matches" while it is exactly what answers
    // the query (D2).
    final strangerNpub = publicProfilesEnabled
        ? eligibleStrangerNpub(
            widget.query,
            localResults: results,
            stagedNpubs: widget.stagedNpubs,
            circleMemberNpubs: widget.circleMemberNpubs,
            selfNpub: ref.read(identityProvider).valueOrNull?.npub,
          )
        : null;
    final keys = strangerNpub != null
        ? [strangerNpub]
        : [for (final c in results) c.pubkeyHex];
    // Only when the result set actually CHANGED: holding a key down against
    // a query that matches nobody must not repeat "no matches" per character.
    if (_lastAnnounced != null && listEquals(_lastAnnounced, keys)) return;
    _lastAnnounced = keys;

    // Mirrors the visible branch's fresh-install gate (`build`, below): "No
    // matches" answers a query, and someone who shares no circles yet has
    // not asked one. A read failure is handled above, before `results` is
    // even computed, so reaching here means the directory has genuinely
    // settled with data — `directory.valueOrNull` is never null at this
    // point, and the `?? true` is defensive only.
    if (keys.isEmpty && (directory.valueOrNull?.entries.isEmpty ?? true)) {
      return;
    }

    final l10n = AppLocalizations.of(context);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        keys.isEmpty
            ? l10n.memberPickerNoMatches
            : l10n.memberPickerMatchesAnnouncement(keys.length),
        Directionality.of(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final directory = ref.watch(memberDirectoryProvider);
    final results = ref.watch(memberDirectoryResultsProvider(widget.query));
    final identity = ref.watch(identityProvider).valueOrNull;
    final selfPubkeyHex = identity?.pubkeyHex;

    // The directory settling under a STANDING query is a correction the
    // user is owed (plan F1): re-arm the announcement here, because the
    // query itself never changes across this transition, so nothing else
    // would. Gated on a non-empty query — an empty one is the auto-populate
    // view, which was never silently misannounced in the first place.
    final wasLoading = _directoryWasLoading;
    _directoryWasLoading = directory.isLoading;
    if ((wasLoading ?? false) &&
        !directory.isLoading &&
        widget.query.trim().isNotEmpty) {
      _scheduleAnnouncement();
    }

    if (directory.isLoading) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: HavenSpacing.base),
          child: Center(
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: l10n.memberPickerLoading,
              ),
            ),
          ),
        ),
      );
    }

    // Computed only once the directory has settled (never while `isLoading`
    // above): until it has, `results` is unconditionally empty regardless of
    // the query, so gate 2 ("not already known locally") would read as
    // trivially satisfied for someone who actually IS a known co-member —
    // firing a network request for them the instant the directory finishes
    // loading a moment later. `publicProfilesEnabled` is the build-time kill
    // switch for the profile-fetch machinery (`constants/feature_flags.dart`)
    // — off means this call site never even constructs the eligibility
    // check, exactly like `MemberAvatar` never watching its own profile
    // provider under the same flag.
    final strangerNpub = publicProfilesEnabled
        ? eligibleStrangerNpub(
            widget.query,
            localResults: results,
            stagedNpubs: widget.stagedNpubs,
            circleMemberNpubs: widget.circleMemberNpubs,
            selfNpub: identity?.npub,
          )
        : null;

    if (results.isEmpty) {
      // A typed-stranger row REPLACES "no matches" for this specific query —
      // D2 turns "nobody found locally" into "ask a relay", so the row that
      // used to be silence is now exactly what answers the query. This can
      // coexist with an otherwise-empty (even fresh-install) directory: it is
      // a lookup for the one key just typed, not a claim about who else is
      // known.
      if (strangerNpub != null) {
        return SliverToBoxAdapter(
          child: _TypedStrangerRow(
            npub: strangerNpub,
            onSelected: widget.onStrangerSelected,
          ),
        );
      }
      // A read failure is NOT "you know nobody" (plan F2): the directory
      // provider's own doc promises `loadDirectory` never throws, so this
      // fires only for a failure ABOVE that call — resolving the directory
      // SERVICE itself (`memberDirectoryServiceProvider`'s dependencies)
      // rather than reading it. Rendered distinctly from both the silent
      // fresh-install branch below and the "no matches" text: neither may
      // stand in for a read that never actually completed.
      if (directory.hasError) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.base,
              vertical: HavenSpacing.base,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.circleAlert,
                  size: 20,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Text(
                    l10n.memberPickerDirectoryUnavailable,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      // "No matches" answers a query. Someone who shares no circles yet has
      // not asked one, so they get the page's own guidance instead — and a
      // heading over an empty section is omitted entirely (§9.2).
      final directoryIsEmpty = directory.valueOrNull?.entries.isEmpty ?? true;
      if (directoryIsEmpty) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.base,
            vertical: HavenSpacing.base,
          ),
          child: Text(
            l10n.memberPickerNoMatches,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    // Two sections, in tier order (plan §7.2). Partitioning is over
    // REFERENCES already sorted by `buildDirectory`, never a widget build, so
    // the list stays lazily built below — a roster is as long as the user's
    // social graph, and the visible window is a handful of rows. A section
    // with no results in it is omitted header and all (§9.2), which is why
    // this reads `results` (post-filter) rather than the tier composition of
    // the whole directory.
    final current = [
      for (final c in results)
        if (c.tier == DirectoryTier.current) c,
    ];
    final recent = [
      for (final c in results)
        if (c.tier == DirectoryTier.recent) c,
    ];
    final currentHeaderCount = current.isEmpty ? 0 : 1;
    final recentHeaderCount = recent.isEmpty ? 0 : 1;

    // The population `_markCollidingNames` (member_directory_service.dart)
    // walks to choose `collisionCircleName` — the FULL directory, never the
    // post-search `current` above, so this fact stays stable while the user
    // types, exactly like `collisionCircleName` itself already does.
    final collidingNames = collidingDisplayNames(
      directory.valueOrNull?.entries ?? const <MemberCandidate>[],
    );

    Widget row(MemberCandidate candidate) => MemberCandidateTile(
      candidate: candidate,
      // `collisionCircleName == null` alone cannot distinguish "never
      // collided" from "collided, but no circle disambiguates it" (plan
      // F3) — carry that second fact separately so the row can put the key
      // into its spoken label when it is genuinely the only differentiator
      // left.
      undistinguishedCollision:
          candidate.tier == DirectoryTier.current &&
          candidate.collisionCircleName == null &&
          candidate.displayName != null &&
          collidingNames.contains(candidate.displayName),
      state: resolveMemberPickState(
        candidate,
        stagedNpubs: widget.stagedNpubs,
        circleMemberPubkeysHex: widget.circleMemberPubkeysHex,
        selfPubkeyHex: selfPubkeyHex,
      ),
      onSelected: widget.onSelected,
    );

    return SliverList.builder(
      itemCount:
          currentHeaderCount +
          current.length +
          recentHeaderCount +
          recent.length,
      itemBuilder: (context, index) {
        var i = index;
        if (currentHeaderCount == 1) {
          if (i == 0) {
            return HavenSectionHeader(
              label: l10n.memberPickerSectionRoster,
              headingLevel: 2,
            );
          }
          i -= currentHeaderCount;
        }
        if (i < current.length) return row(current[i]);
        i -= current.length;
        if (recentHeaderCount == 1) {
          if (i == 0) {
            return HavenSectionHeader(
              label: l10n.memberPickerSectionRecent,
              headingLevel: 2,
            );
          }
          i -= recentHeaderCount;
        }
        return row(recent[i]);
      },
    );
  }
}

/// Every [MemberCandidate.displayName] shared by two or more CURRENT
/// (tier-0) entries in [entries] — the same population and scope
/// `_markCollidingNames` (`member_directory_service.dart`) walks to choose
/// [MemberCandidate.collisionCircleName].
///
/// A separate computation, not a read of [MemberCandidate.collisionCircleName]
/// itself, because that field is `null` for two different reasons a caller
/// must not conflate: never having collided with anyone, and colliding with
/// no circle available to tell the rows apart (plan F3). Recomputing over
/// [entries] gives the second fact its own, checkable existence.
///
/// Extracted and `@visibleForTesting` so the grouping is provable
/// independent of the widget tree, matching [eligibleStrangerNpub] above.
@visibleForTesting
Set<String> collidingDisplayNames(Iterable<MemberCandidate> entries) {
  final seen = <String>{};
  final colliding = <String>{};
  for (final candidate in entries) {
    if (candidate.tier != DirectoryTier.current) continue;
    final name = candidate.displayName;
    if (name == null) continue;
    if (!seen.add(name)) colliding.add(name);
  }
  return colliding;
}

/// The complete, valid npub eligible for D2's network resolve, or `null` when
/// any of the three caller-side gates fails — in which case NO network call
/// may be made (plan §10 D2).
///
/// The three gates, all of which must hold:
/// 1. [query] is a COMPLETE match for [NpubValidator.extract] — never a
///    partial prefix mid-keystroke, and never a substring found inside a
///    longer pasted string.
/// 2. [query] does not already resolve to a [MemberCandidate] in
///    [localResults] — the caller's already-computed, zero-wire-cost local
///    search. If it did, that row renders and the network is never asked.
/// 3. [resolveEntryPickState] returns [MemberPickState.selectable] for
///    [query] against [stagedNpubs]/[circleMemberNpubs]/[selfNpub] — not
///    self, not already staged, not already in the target circle.
///
/// Extracted and `@visibleForTesting` so the gating is provable independent
/// of the widget tree, and reused identically by both the row that renders
/// and the announcement that describes it — one function, not two
/// re-implementations that could drift.
@visibleForTesting
String? eligibleStrangerNpub(
  String query, {
  required List<MemberCandidate> localResults,
  required Set<String> stagedNpubs,
  required Set<String> circleMemberNpubs,
  required String? selfNpub,
}) {
  if (NpubValidator.extract(query) != query) return null;
  if (localResults.any((c) => c.npub == query)) return null;
  final state = resolveEntryPickState(
    query,
    stagedNpubs: stagedNpubs,
    circleMemberNpubs: circleMemberNpubs,
    selfNpub: selfNpub,
  );
  if (state != MemberPickState.selectable) return null;
  return query;
}

/// The ONE row offered for a complete, valid, D2-eligible npub — the only
/// place in the picker that touches the network, and only ever built when
/// [eligibleStrangerNpub] has already said yes (gating lives in the parent's
/// `build()`, never here: Riverpod providers are lazy, so gating the
/// `ref.watch` call below IS gating the network call).
///
/// Always tappable, unlike [MemberCandidateTile]: by the time this widget
/// exists, [eligibleStrangerNpub] has already confirmed [MemberPickState
/// .selectable], so there is no refusal state left to render.
class _TypedStrangerRow extends ConsumerWidget {
  const _TypedStrangerRow({required this.npub, required this.onSelected});

  /// The npub this row resolves and stages, unchanged.
  final String npub;

  /// Called with [npub] when the row is tapped.
  final void Function(String npub) onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    // `npub` is the family key: a query change is a DIFFERENT provider
    // instance, so a stale in-flight resolve for a since-abandoned key is
    // never observed here (see the provider's own doc for why that is
    // correct by construction, not by a manually-tracked "latest" flag).
    final resolve = ref.watch(strangerProfileResolveProvider(npub));
    final profile = resolve.valueOrNull;
    final isLoading = resolve.isLoading;
    final name = profile?.displayName ?? profile?.name;
    final shortNpub = NpubValidator.shortenForDisplay(npub);
    final lookupNote = l10n.memberPickerStrangerLookupNote;

    // Same no-ellipsis, forced-LTR rule the rest of the picker applies to an
    // npub — see `MemberCandidateTile.npubLine`'s doc.
    Widget npubLine(TextStyle style) => Text(
      shortNpub,
      textDirection: TextDirection.ltr,
      style: style,
    );

    Widget leading;
    if (profile != null) {
      // Only ever cache-driven: `MemberAvatar` calls `memberProfileProvider`,
      // which reads the LOCAL cache and never downloads a picture on its own
      // (Rule 8/D2) — the resolve above is what populated this pubkey's row,
      // if anything did.
      leading = MemberAvatar(pubkey: profile.pubkeyHex, displayName: name);
    } else {
      leading = CircleAvatar(
        radius: memberAvatarDiameter / 2,
        backgroundColor: colorScheme.surfaceContainerHighest,
        foregroundColor: colorScheme.onSurfaceVariant,
        child: isLoading
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.onSurfaceVariant,
                  semanticsLabel: lookupNote,
                ),
              )
            : const Icon(LucideIcons.userRound),
      );
    }

    return Semantics(
      button: true,
      excludeSemantics: true,
      onTap: () => onSelected(npub),
      label: [
        _bidiIsolate(name ?? _chunkForSpeech(shortNpub)),
        lookupNote,
      ].join(', '),
      customSemanticsActions: {
        // Same reasoning as `MemberCandidateTile`: a resolved name keeps the
        // raw key out of the main label, so this is the only way a
        // screen-reader user can still hear it for verification — and the
        // label is a CONSTANT (Flutter interns custom actions in a
        // process-wide map with no prune path; the key is spoken from the
        // callback, never held in the label itself).
        CustomSemanticsAction(label: l10n.memberPickerReadPublicKey): () =>
            _speakNpub(context, shortNpub),
      },
      child: ListTile(
        leading: leading,
        title: name == null
            ? npubLine(HavenTypography.mono.copyWith(fontSize: 14))
            : Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name != null)
              npubLine(
                HavenTypography.monoSmall.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            Text(
              lookupNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        onTap: () => onSelected(npub),
      ),
    );
  }
}

/// One person, offered as a pick.
///
/// Always renders BOTH a name (when one resolved) and the npub. A name is
/// chosen by whoever published it, and what this screen produces is live
/// location sharing, so a name-only row would be an invitation to add the
/// wrong person on a string an attacker picked.
///
/// A row that cannot be picked is rendered with its reason and WITHOUT
/// Material's disabled treatment: that dims the title and avatar, which
/// obscures the identity being confirmed for a condition that is a fact
/// about the screen rather than a control being momentarily unavailable
/// (the same call `CircleMemberTile` makes for members with no location).
/// Unavailability is carried by the stated reason and by the semantics node,
/// which is where a screen reader looks for it.
class MemberCandidateTile extends StatelessWidget {
  /// Creates a [MemberCandidateTile].
  const MemberCandidateTile({
    required this.candidate,
    required this.state,
    required this.undistinguishedCollision,
    required this.onSelected,
    super.key,
  });

  /// The person this row stands for.
  final MemberCandidate candidate;

  /// Whether they can be picked, and if not, why.
  final MemberPickState state;

  /// Whether [candidate] shares its resolved name with another CURRENT
  /// row, but no circle exists that is unique to either of them (plan F3).
  ///
  /// The npub always tells these rows apart visually (plan §7.1), but it is
  /// NOT in the semantics label by default, so without this a screen reader
  /// hears the same name and tier twice with nothing else to go on. True
  /// only when [MemberCandidate.collisionCircleName] is `null` for a reason
  /// OTHER than "never collided" — see [collidingDisplayNames].
  final bool undistinguishedCollision;

  /// Called when a pickable row is tapped.
  final void Function(MemberCandidate candidate) onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final shortNpub = NpubValidator.shortenForDisplay(candidate.npub);
    final name = candidate.displayName;
    final selectable = state == MemberPickState.selectable;
    final reason = memberPickRefusalMessage(l10n, state);
    final hasNickname = candidate.petname != null;
    // The circle name is remote-supplied — chosen by whoever created the
    // group (`haven-core/src/circle/manager.rs`), not by the local user — so
    // the RENDERED copy isolates it before it shares a paragraph with app
    // text, same as `_bidiIsolate` in invitation_card.dart. The label below
    // is built from the un-isolated name: see `_semanticsLabel`'s doc for
    // why a label needs isolation only where something follows the
    // untrusted text within the SAME string, which is not the case here.
    final collisionCircleName = candidate.collisionCircleName;
    final collisionLabel = collisionCircleName == null
        ? null
        : l10n.memberPickerCollisionCircleLabel(collisionCircleName);
    final renderedCollisionLabel = collisionCircleName == null
        ? null
        : l10n.memberPickerCollisionCircleLabel(
            _bidiIsolate(collisionCircleName),
          );

    // The npub, in the one form Haven displays it: no maxLines and no
    // overflow, because clipping the tail drops the bech32 checksum and
    // takes an impersonation from ~2^65 back to ~2^35. Forced LTR — a
    // bech32 key laid out right-to-left is a different string to the eye.
    // It carries the row when nothing else identifies the person, and steps
    // down beside a name, matching `CircleMemberTile`'s two positions.
    Widget npubLine(TextStyle style) => Text(
      shortNpub,
      textDirection: TextDirection.ltr,
      style: style,
    );

    return Semantics(
      button: selectable,
      enabled: selectable,
      excludeSemantics: true,
      onTap: selectable ? () => onSelected(candidate) : null,
      label: _semanticsLabel(l10n, name, shortNpub, reason, collisionLabel),
      customSemanticsActions: {
        // The label is a CONSTANT. Flutter interns custom actions on
        // (label, hint, action) in static maps with no prune path, so a
        // label containing the key would hold identifier text for the life
        // of the process — outside SQLCipher, unreachable by the logout
        // wipe. The key is spoken from the callback instead.
        CustomSemanticsAction(label: l10n.memberPickerReadPublicKey): () =>
            _speakNpub(context, shortNpub),
      },
      child: ListTile(
        leading: MemberAvatar(
          pubkey: candidate.pubkeyHex,
          displayName: name,
        ),
        title: name == null
            ? npubLine(HavenTypography.mono.copyWith(fontSize: 14))
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // INSIDE the excludeSemantics subtree above (unlike
                  // `_NicknameMark` on the invitation card, whose enclosing
                  // Semantics carries no excludeSemantics and so lets it
                  // survive as a sibling node): this mark's own node is
                  // swallowed on purpose, because `_semanticsLabel` below
                  // already speaks the nickname note once for the whole
                  // row — a surviving node here would announce it twice.
                  // The tooltip is what a sighted long-press still gets.
                  if (hasNickname)
                    _PickerNicknameMark(label: l10n.memberPickerNicknameNote),
                ],
              ),
        subtitle: (name == null && reason == null && collisionLabel == null)
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (name != null)
                    npubLine(
                      HavenTypography.monoSmall.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (renderedCollisionLabel != null)
                    Text(
                      renderedCollisionLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (reason != null)
                    Text(
                      reason,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
        onTap: selectable ? () => onSelected(candidate) : null,
      ),
    );
  }

  /// The row's spoken label: who, which tier, any nickname/collision note,
  /// and any reason it is refused.
  ///
  /// The tier is repeated on every row because a reader swiping row by row
  /// never hears the section heading above them (§7.2). `identity` alone
  /// is wrapped in [_bidiIsolate]: within this ONE joined string it is
  /// followed by the tier, the nickname note, the collision note and any
  /// refusal reason, so an unterminated override inside it could otherwise
  /// swallow all of them — not for TTS or braille, which read codepoints in
  /// logical order regardless, but for whatever else renders this same
  /// string visibly (an accessibility inspector, a semantics-tree dump). See
  /// [_bidiIsolate]'s doc for the full doctrine. [collisionLabel] is passed
  /// through un-isolated: nothing follows it in this string, so there is
  /// nothing left for an isolate to protect.
  ///
  /// When [undistinguishedCollision] holds, the chunked key follows the
  /// identity clause even though [name] is non-null: the npub differentiates
  /// two colliding rows visually (§7.1), but is not otherwise in this
  /// label, so without this a reader hears the same name and tier twice
  /// with nothing to tell the rows apart by (plan F3).
  String _semanticsLabel(
    AppLocalizations l10n,
    String? name,
    String shortNpub,
    String? reason,
    String? collisionLabel,
  ) {
    final identity = name ?? _chunkForSpeech(shortNpub);
    final tier = switch (candidate.tier) {
      DirectoryTier.current => l10n.memberPickerTierRoster,
      DirectoryTier.recent => l10n.memberPickerTierRecent,
    };
    return [
      _bidiIsolate(identity),
      if (name != null && undistinguishedCollision) _chunkForSpeech(shortNpub),
      tier,
      if (candidate.petname != null) l10n.memberPickerNicknameNote,
      if (collisionLabel != null) collisionLabel,
      if (reason != null) reason,
    ].join(', ');
  }

}

/// Speaks [shortNpub] aloud, chunked into pronounceable groups.
///
/// A free function (not a `MemberCandidateTile` method) so [_TypedStrangerRow]
/// can share it: both rows carry the same "Read public key aloud" custom
/// action for the same reason — a resolved name (published or a nickname)
/// keeps the raw key out of the main label, so this action is the only way a
/// screen-reader user can still hear it for verification.
Future<void> _speakNpub(BuildContext context, String shortNpub) {
  return SemanticsService.sendAnnouncement(
    View.of(context),
    _chunkForSpeech(shortNpub),
    TextDirection.ltr,
  );
}

/// The elision [NpubValidator.shortenForDisplay] puts between the retained
/// prefix and suffix. Bech32's data charset has no `.`, so this substring
/// can only ever be the elision itself, never a data character.
const _npubElision = '...';

/// Groups [shortNpub] into runs of four so a screen reader reads a key as
/// separable pieces instead of one unpronounceable word.
///
/// Purely a rendering of the SAME characters, in the same order: strip the
/// spaces and the original is back, which is what makes it usable for
/// checking a key against one read aloud elsewhere.
///
/// The retained prefix and suffix either side of the elision are chunked
/// INDEPENDENTLY, with the elision left as its own token, rather than
/// chunking the whole string end to end (plan F5): a flat every-four split
/// cuts across the elision boundary at Haven's 12/6 format, fusing the dots
/// to the first checksum character and leaving a one-character final
/// chunk — so depending on a TTS engine's punctuation verbosity the elision
/// is spoken, paused over, or dropped, and in the last case the two
/// retained runs are heard as one contiguous key, exactly what the
/// truncation exists to prevent. A string with no elision (an untruncated
/// npub) falls back to one flat run.
String _chunkForSpeech(String shortNpub) {
  final splitAt = shortNpub.indexOf(_npubElision);
  if (splitAt == -1) return _chunkRun(shortNpub).join(' ');
  final prefix = shortNpub.substring(0, splitAt);
  final suffix = shortNpub.substring(splitAt + _npubElision.length);
  return [..._chunkRun(prefix), _npubElision, ..._chunkRun(suffix)].join(' ');
}

/// Splits [run] into consecutive four-character groups, the last as short
/// as one character when [run]'s length is not a multiple of four.
List<String> _chunkRun(String run) {
  final chunks = <String>[];
  for (var i = 0; i < run.length; i += 4) {
    chunks.add(run.substring(i, (i + 4).clamp(0, run.length)));
  }
  return chunks;
}

/// Wraps [text] in U+2068 FIRST STRONG ISOLATE / U+2069 POP DIRECTIONAL
/// ISOLATE.
///
/// A near-duplicate of `_bidiIsolate` in invitation_card.dart — private to
/// that library, so not importable from here. See its doc for the full
/// doctrine: unnecessary for TTS or braille, which both read a string's
/// codepoints in logical order with no paragraph layout for an override to
/// escape, but free (never spoken, never a braille cell) and worth keeping
/// wherever OTHER text — in a rendered paragraph OR a joined semantics
/// label — follows the untrusted substring, since that is exactly what an
/// unterminated override could otherwise swallow.
String _bidiIsolate(String text) => '\u2068$text\u2069';

/// The mark that says the name beside it is the user's own local petname,
/// not the person's published name.
///
/// Deliberately not a chip, a badge, or a colour: it answers "where did this
/// name come from", which is provenance, not trust. Nothing on this row may
/// look like a verification, so it inherits the muted colour of the line it
/// annotates rather than taking an accent. `HavenSecurityColors.encrypted`
/// and `warning` are doubly excluded: both fail WCAG AA at text contrast
/// (3.30:1 and 3.19:1), and the green already means "KeyPackage validated"
/// on the staged tile. Same shape as `invitation_card.dart`'s `_NicknameMark`
/// — except its `Icon` carries no `semanticLabel`: this mark is always used
/// inside the row's `Semantics(excludeSemantics: true)`, which drops every
/// descendant node unconditionally, so a label here would never be spoken —
/// `_semanticsLabel` already speaks the same note once for the whole row —
/// and would be dead weight liable to mislead a future reader into thinking
/// otherwise.
class _PickerNicknameMark extends StatelessWidget {
  const _PickerNicknameMark({required this.label});

  /// Shown on long-press. The mark carries no visible text of its own: a
  /// running caption beside every nicknamed name would be louder than the
  /// name. Never reaches a screen reader from here — see the class doc.
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scaled by hand because `Icon` does not follow the text scaler: at 2x
    // an unscaled 14dp glyph beside 28dp text reads as a rendering artefact
    // rather than as a mark.
    final glyphSize = MediaQuery.textScalerOf(context).scale(14);
    // The glyph's own box is the Tooltip's whole hit region, and at default
    // text scale that box is 14x14 — below the 24x24dp WCAG 2.2 minimum
    // long-press target, reached only once the glyph itself has grown past
    // it (~1.72x). Pad the HIT REGION out to 24dp without touching the
    // glyph's rendered size (plan F6).
    final hitTargetSize = glyphSize < 24 ? 24.0 : glyphSize;

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: HavenSpacing.xs),
      // excludeFromSemantics is belt-and-suspenders here — the row's
      // ancestor Semantics already drops this whole subtree — but keeps this
      // widget correct in isolation if it is ever reused outside that
      // wrapper.
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: SizedBox(
          width: hitTargetSize,
          height: hitTargetSize,
          child: Center(
            child: Icon(
              LucideIcons.tag,
              size: glyphSize,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
