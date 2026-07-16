/// Compile-time feature flags for Haven.
///
/// Mirrors the `liveSyncEnabled` precedent in `providers/live_sync_provider.dart`:
/// a `bool.fromEnvironment` const so the disabled branch tree-shakes out of a
/// release build entirely, while a build can still force either path with
/// `--dart-define=<FLAG>=<value>`.
library;

/// Master switch for the public-Nostr-profile UI (kind-0 + Blossom
/// migration, see `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md`).
///
/// Defaults to `true` — the feature is functional out of the box.
/// Publishing your OWN profile (display name / photo) is now public-by-default
/// and UNCONDITIONAL (owner-directed 2026-07-16, matching White Noise): there
/// is no consent flag and this build flag does **not** gate it — saving a name
/// or photo always publishes. This flag only controls whether member
/// tiles/markers/detail sheets fetch and display OTHER members' public
/// profiles, and whether the batched member-profile refresh trigger fires.
/// When `false`, member tiles/markers show npub-derived initials only (the
/// profile-unknown state the providers already return for every pubkey) — it
/// is a build-time kill switch for the profile-fetch/display machinery, not a
/// user-facing opt-out.
const publicProfilesEnabled = bool.fromEnvironment(
  'HAVEN_PUBLIC_PROFILES',
  defaultValue: true,
);
