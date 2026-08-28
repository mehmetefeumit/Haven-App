/// Production implementation of [MemberDirectoryService].
///
/// A call-and-map shell: it reads the persistent member directory
/// (`rankedDirectoryMembers` — WHO and WHICH TIER, P3), reads the cached
/// profiles for that set in ONE batch, reads the user's local petnames in
/// ONE batch, and hands all three — plus the caller's already-loaded circles
/// list — to the pure functions in `member_directory_service.dart`, which own
/// every decision. The circles list exists SOLELY to break a display-name
/// collision between two current co-members (plan §7.2) — it never
/// contributes WHO or WHICH TIER, which come exclusively from the directory
/// table, and this service does no circle I/O of its own to get it.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

/// Reads the local co-member directory from the persistent `member_directory`
/// table and the on-device profile/contact caches.
class NostrMemberDirectoryService implements MemberDirectoryService {
  /// Creates a [NostrMemberDirectoryService].
  ///
  /// [circleServiceFactory] is re-read on every load rather than resolved
  /// once: `createIdentity`/`importFromNsec` RETIRE the circle service (the
  /// logged-out instance is wiped and latched, and answers empty forever),
  /// so a directory holding one instance for the life of the process would
  /// show a permanently empty list, with no error, to anyone who logged out
  /// and back in. Same shape, and the same reason, as
  /// `NostrProfileService`'s `circleManagerFactory`.
  NostrMemberDirectoryService({
    required CircleService Function() circleServiceFactory,
    required ProfileService profileService,
    required IdentityService identityService,
  }) : _circleServiceFactory = circleServiceFactory,
       _profileService = profileService,
       _identityService = identityService;

  final CircleService Function() _circleServiceFactory;
  final ProfileService _profileService;
  final IdentityService _identityService;

  /// Whether the once-per-process backfill reconcile ([_backfillOnce]) has
  /// been attempted and LATCHED — either it actually refreshed the table, or
  /// it genuinely failed.
  ///
  /// Deliberately never reset on a genuine failure: a transient reconcile
  /// failure must not turn every later picker open in this process into
  /// another roster-wide reconcile. The seven receive-path write sites (plan
  /// §5.5) keep the table fresh from here on, and the next membership change
  /// closes the gap regardless.
  ///
  /// NOT latched on a DEFERRAL, though —
  /// [CircleService.reconcileMemberDirectory] returning `false` means a
  /// circle's membership commit was still in flight, so nothing was written
  /// and nothing was purged. That is the
  /// cheap, transient case where a retry on the next picker open is exactly
  /// right: latching it here would leave an upgraded install's picker
  /// silently empty for the rest of the process if the one attempt landed in
  /// that window (e.g. add-member tapped immediately after create-circle).
  bool _backfillAttempted = false;

  /// Brings an UPGRADED install's directory up to date, once, the first time
  /// the picker opens in this process.
  ///
  /// The persistent directory (P3) is kept fresh by seven receive-path write
  /// sites during normal operation (confirm_published, publish_failed, a
  /// welcome accepted, decrypt, live-sync, and background catch-up), but an
  /// install that already had circles BEFORE this feature shipped starts
  /// with an EMPTY table: nothing in that list fires again until the next
  /// membership change, which could be days away, and the picker would be
  /// honestly empty for someone who has plenty of co-members.
  ///
  /// Scoped to once per process, not once per sheet-open:
  /// [CircleService.reconcileMemberDirectory] reads every circle's converged
  /// roster (a session-lock acquisition per circle), unlike
  /// [CircleService.rankedDirectoryMembers]'s single indexed read — paying
  /// that cost every time the picker opens would scale with how often the
  /// user invites people, for a gap ONE catch-up already closes. The one
  /// call this does make costs the same order as `circlesProvider`'s own
  /// cold-start read, which already walks every circle's roster to draw the
  /// map — so this adds no new category of cost, only a second read of the
  /// same shape, and only the first time this process needs the directory.
  /// Best-effort: a failure here still lets [loadDirectory] show whatever
  /// the table already holds.
  Future<void> _backfillOnce(CircleService circleService) async {
    if (_backfillAttempted) return;
    try {
      // `false` is a DEFERRAL (nothing written), not a failure — leave
      // `_backfillAttempted` clear so the NEXT `loadDirectory()` call in this
      // process tries again, rather than latching a directory that never
      // actually got its one-time backfill.
      if (await circleService.reconcileMemberDirectory()) {
        _backfillAttempted = true;
      }
    } on Object catch (e) {
      // A genuine failure DOES latch — see [_backfillAttempted]'s doc.
      _backfillAttempted = true;
      debugPrint('[Directory] backfill reconcile failed: ${e.runtimeType}');
    }
  }

  @override
  Future<MemberDirectory> loadDirectory({required List<Circle> circles}) async {
    final Identity? identity;
    try {
      identity = await _identityService.getIdentity();
    } on Object catch (e) {
      // Fails CLOSED, like the null-identity case below: without an
      // identity there is no way to tell which directory row is the user,
      // and the user must never be offered as someone to invite. Not
      // [MemberDirectory.readFailed] — a caller cannot act on "identity is
      // broken" any differently than on "no identity yet".
      debugPrint('[Directory] identity read failed: ${e.runtimeType}');
      return MemberDirectory.empty;
    }
    if (identity == null) return MemberDirectory.empty;

    try {
      final circleService = _circleServiceFactory();
      await _backfillOnce(circleService);

      final entries = await circleService.rankedDirectoryMembers();
      // Legitimately empty — the read succeeded and found nobody — so this
      // stays [MemberDirectory.empty], never [MemberDirectory.readFailed].
      if (entries.isEmpty) return MemberDirectory.empty;

      // One batch read for the whole directory, carrying no picture bytes: a
      // [MemberCandidate] keeps only the hash, so a per-person read would
      // decrypt, marshal and drop one 96px thumbnail for every person with a
      // picture, serially, before the picker could draw its first row.
      final profiles = await _profileService.getCachedMemberProfiles(
        [for (final entry in entries) entry.pubkeyHex],
      );

      return buildDirectory(
        entries: entries,
        profiles: profiles,
        petnames: await _petnames(circleService),
        circleNamesByPubkey: circleNamesForCollision(
          circles: circles,
          selfPubkeyHex: identity.pubkeyHex,
        ),
      );
    } on Object catch (e) {
      // A GENUINE failure guarding the ranked read, the profile read and the
      // directory build — as opposed to the two returns above, and distinct
      // from "the read succeeded and found nobody" — so this degrades to
      // [MemberDirectory.readFailed], never [MemberDirectory.empty]: a user
      // with real co-members must not be told they have nobody. Type only —
      // an FFI error message can carry remote-authored text and internal
      // identifiers (Security Rule 8).
      debugPrint('[Directory] load failed: ${e.runtimeType}');
      return MemberDirectory.readFailed;
    }
  }

  /// The user's local petnames, best-effort.
  ///
  /// Losing this input must cost each person only their nickname — never
  /// their whole row, and never the rest of the directory — so it is caught
  /// HERE rather than left to the outer catch in [loadDirectory].
  Future<Map<String, String>> _petnames(CircleService circleService) async {
    try {
      return await circleService.allContactDisplayNames();
    } on Object catch (e) {
      debugPrint('[Directory] petnames unavailable: ${e.runtimeType}');
      return const {};
    }
  }
}
