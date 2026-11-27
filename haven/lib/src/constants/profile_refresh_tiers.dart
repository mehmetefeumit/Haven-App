/// Staleness tiers for public (kind-0) profile refreshes.
///
/// Haven resolves other members' names and photos by **pulling** kind-0 — it
/// deliberately holds no standing kind-0 subscription (migration plan §1.6/D3),
/// unlike White Noise, which keeps one open over every locally known pubkey and
/// therefore needs no staleness policy at all. Freshness here instead comes
/// from several trigger layers, each declaring how stale a cached profile may
/// be before that trigger re-fetches it.
///
/// Every value is passed to `fetch_member_profiles(pubkeys, maxAgeSecs)`, whose
/// only job is the comparison. The policy lives here, in Dart, next to the
/// timer that drives it — the same "Dart owns cadence, Rust owns logic" split
/// the maintenance scheduler already uses.
///
/// Tuning note: a refresh with anything due opens fresh sockets to the profile
/// relay pool (one with nothing due contacts no relay). Shortening a tier
/// increases how often Haven contacts those relays; it does **not** widen what
/// is disclosed (the union of member pubkeys is identical every time, and each
/// pubkey's assigned relay is fixed for the install). Because every foreground
/// transition refreshes, the profile relays can infer when the user opens
/// Haven; the owner accepted that on 2026-11-26.
library;

/// Tolerance for the refresh every transition to the foreground makes: each
/// cold start and each resume (owner-directed 2026-11-26).
///
/// Not [profileForceMaxAge]: zero is the forced mode, which also skips the
/// per-author miss backoff in Rust. A minute is long enough that rapid app
/// switching asks no relay twice, short enough that every real return to the
/// app picks up a rename or a new photo.
const Duration profileForegroundMaxAge = Duration(minutes: 1);

/// Tolerance for a user-visible, intent-driven refresh: circle select, an
/// invitation accepted, a circle created or members invited, and roster
/// changes.
///
/// Short enough that switching circles picks up a rename, long enough that
/// circle-flipping collapses into a single fetch.
const Duration profileInteractiveMaxAge = Duration(minutes: 15);

/// Tolerance for the foreground anti-entropy sweep.
///
/// Deliberately shorter than [profileAntiEntropyInterval] so a due tick
/// actually fetches, while a tick landing just after an interactive refresh is
/// a cheap no-op.
const Duration profilePeriodicMaxAge = Duration(minutes: 30);

/// Nominal interval of the foreground anti-entropy sweep (jittered ±25 % per
/// tick, so ≈34–56 min).
///
/// This is what bounds staleness during a long uninterrupted session, where no
/// resume or circle-select ever fires.
///
/// Foreground only, enforced by an explicit app-lifecycle check in the tick
/// (`MaintenanceSchedulerNotifier`) — a backgrounded tick re-arms without
/// contacting any relay. The WorkManager background catch-up lane stays
/// receive-only and never refreshes profiles at all.
const Duration profileAntiEntropyInterval = Duration(minutes: 45);

/// Bypasses the cache entirely — every requested pubkey is re-fetched.
///
/// Reserved for explicit user intent ("refresh"), never for automatic triggers.
const Duration profileForceMaxAge = Duration.zero;
