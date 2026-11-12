/// Shared helper for triggering a batched public-profile refresh from the
/// widget layer (plan §6.2).
///
/// Wired at cold start and app resume (`map_shell.dart`), circle select
/// (`circle_selector.dart`), invitation accept (`invitation_card.dart`) and
/// the Identity page's explicit refresh. A roster change seen by live sync
/// (`service_providers.dart`) and the foreground anti-entropy tick
/// (`maintenance_scheduler_provider.dart`) call
/// [MemberProfileRefreshNotifier.refreshAll] directly. Kept in `utils/` (not
/// a provider) since it is a plain fire-and-forget dispatch over an
/// already-existing provider — there is no new state to own.
///
/// The union-building, own-pubkey inclusion, staleness gating and concurrency
/// coalescing all live in [MemberProfileRefreshNotifier.refreshAll]; this is
/// only the `WidgetRef` adapter, so widget call sites and the (non-widget)
/// anti-entropy scheduler share one implementation.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';

/// Triggers a batched refresh of every known member profile (the **union**
/// of all circles' members — plan §1.7, never a clean per-circle partition)
/// plus the user's own profile.
///
/// [maxAge] is the caller's staleness tolerance; pick a tier from
/// `constants/profile_refresh_tiers.dart`. It is deliberately **required** —
/// each trigger should state its own tolerance at the call site, so the
/// refresh cadence stays reviewable by reading the triggers.
///
/// A no-op when `publicProfilesEnabled` is off, so no profile FFI calls are
/// made at all in that build. Fire-and-forget: never throws to the caller.
void triggerProfileRefresh(WidgetRef ref, {required Duration maxAge}) {
  unawaited(
    ref.read(memberProfileRefreshProvider.notifier).refreshAll(maxAge: maxAge),
  );
}

/// [triggerProfileRefresh] for a caller that has outlived its widget — an
/// accept that finished after the card left the tree — and so holds the
/// container rather than a `WidgetRef`.
void triggerProfileRefreshIn(
  ProviderContainer container, {
  required Duration maxAge,
}) {
  unawaited(
    container
        .read(memberProfileRefreshProvider.notifier)
        .refreshAll(maxAge: maxAge),
  );
}
