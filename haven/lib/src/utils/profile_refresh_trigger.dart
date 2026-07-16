/// Shared helper for triggering a batched member-profile refresh plus an
/// own-profile refresh (plan §6.2).
///
/// Wired at circle-select sites (`circle_list_tile.dart`,
/// `circle_selector.dart`) and app-resume (`map_shell.dart`), and exposed as
/// a refresh affordance on the Identity page. Kept in `utils/` (not a
/// provider) since it is a plain fire-and-forget dispatch over two
/// already-existing providers — there is no new state to own.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/feature_flags.dart';
import 'package:haven/src/providers/member_profile_refresh_provider.dart';
import 'package:haven/src/providers/own_profile_provider.dart';
import 'package:haven/src/services/circle_service.dart';

/// Triggers a batched refresh of every known member profile (the **union**
/// of [circles]' members — plan §1.7, never a clean per-circle partition)
/// plus the user's own profile.
///
/// A no-op when [publicProfilesEnabled] is off, so no profile FFI calls are
/// made at all in that build. Fire-and-forget: both underlying triggers are
/// best-effort and never throw to the caller.
void triggerProfileRefresh(WidgetRef ref, List<Circle> circles) {
  if (!publicProfilesEnabled) return;

  final pubkeys = <String>{
    for (final circle in circles)
      for (final member in circle.members) member.pubkey,
  }.toList();

  ref.read(memberProfileRefreshProvider.notifier).refreshRoster(pubkeys);
  ref.read(ownProfileControllerProvider.notifier).refresh();
}
