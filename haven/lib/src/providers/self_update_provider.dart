/// Provider for periodic MLS key rotation (MIP-02/03).
///
/// **Engine-internal under Dark Matter.** The pre-migration MDK stack left
/// leaf-key rotation to the application (query-groups-needing-update +
/// per-group self-update), which is why this provider originally drove it on
/// a timer. The Dark Matter engine now owns rotation lifecycle internally —
/// there is no `groups_needing_self_update` / `self_update` FFI surface left
/// to drive from Dart (see `docs/MDK_DARKMATTER_MIGRATION_PLAN.md` §5.2 #19,
/// #20). This provider is kept as a documented no-op — rather than deleted —
/// so its call sites (the 1-hour timer, app-resume hook) do not need to be
/// torn out, and so it stays a single, easy-to-find place to re-wire if a
/// future engine version re-exposes an app-driven rotation trigger.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the LEADERLESS periodic + post-join self-update is enabled.
///
/// **Disabled.** Superseded by the Dark Matter engine's internal rotation
/// lifecycle — see the library doc comment above. Kept as the single source
/// of truth so call sites keep gating on a named constant rather than a
/// magic `false`.
const enablePeriodicSelfUpdate = false;

/// Self-update rotation threshold in seconds (1 hour). Unused while
/// [enablePeriodicSelfUpdate] is `false`; retained for call-site continuity.
const selfUpdateThresholdSecs = 3600;

/// No-op under Dark Matter — see the library doc comment. Always resolves to
/// `0` immediately without any FFI or network call.
///
/// Trigger via `ref.invalidate(selfUpdateProvider)` + `ref.read(...)`.
final selfUpdateProvider = FutureProvider<int>((ref) async => 0);
