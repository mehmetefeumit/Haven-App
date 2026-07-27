/// Shared helper for triggering a batched public-profile refresh from the
/// widget layer (plan §6.2).
///
/// Wired at circle-select sites (`circle_list_tile.dart`,
/// `circle_selector.dart`), cold start and app-resume (`map_shell.dart`), the
/// invitation-accept path, and the explicit refresh affordances. Kept in
/// `utils/` (not a provider) since it is a plain fire-and-forget dispatch over
/// an already-existing provider — there is no new state to own.
///
/// The union-building, own-pubkey inclusion, staleness gating and concurrency
/// coalescing all live in [MemberProfileRefreshNotifier.refreshAll]; this is
/// only the `WidgetRef` adapter, so widget call sites and the (non-widget)
/// anti-entropy scheduler share one implementation.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/services/circle_service.dart';

/// Triggers a batched refresh of every known member profile (the **union**
/// of all circles' members — plan §1.7, never a clean per-circle partition)
/// plus the user's own profile.
///
/// [maxAge] is the caller's staleness tolerance; pick a tier from
/// `constants/profile_refresh_tiers.dart`. It is deliberately **required** —
/// each trigger should state its own tolerance at the call site, so the
/// refresh cadence stays reviewable by reading the triggers.
///
/// Pass [circles] only when they are already in hand, to skip a redundant
/// provider read. Passing `null` (or an unresolved provider value) is
/// correct and lets [MemberProfileRefreshNotifier.refreshAll] await the real
/// circle list — never substitute `const []`, which would silently narrow the
/// union to the own pubkey.
///
/// A no-op when `publicProfilesEnabled` is off, so no profile FFI calls are
/// made at all in that build. Fire-and-forget: never throws to the caller.
void triggerProfileRefresh(
  WidgetRef ref, {
  required Duration maxAge,
  List<Circle>? circles,
}) {
  unawaited(
    ref
        .read(memberProfileRefreshProvider.notifier)
        .refreshAll(maxAge: maxAge, circles: circles),
  );
}
