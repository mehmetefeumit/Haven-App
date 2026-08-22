/// Default relay URLs used throughout Haven.
///
/// Centralizes relay configuration to avoid duplication across providers.
library;

import 'package:haven/src/rust/api.dart' as rust;

/// Compile-time fallback list of default relay URLs.
///
/// MUST agree, entry for entry and in order, with `PRODUCTION_DEFAULT_RELAYS`
/// in `haven-core/src/circle/types.rs` — a CHECKED invariant
/// (`scripts/ci/check_profile_privacy_boundaries.sh` check 13, run by the
/// `repo-guards` CI job, diffs the two literal lists). The runtime authority
/// is the [`defaultRelays`] getter, which calls the Rust FFI; this constant is
/// the safety net used when (a) the FFI is not initialized (unit tests)
/// or (b) the relay-preferences storage seed transiently fails and a
/// notifier needs a non-empty list to keep the UI usable instead of
/// stranding it in `AsyncError`.
const fallbackDefaultRelays = <String>[
  'wss://relay.damus.io',
  'wss://relay.primal.net',
  'wss://nos.lol',
];

/// The canonical list of default relay URLs.
///
/// Calls the synchronous Rust FFI getter `default_relays()` so the value
/// is always in sync with `haven-core`. If the FFI is not initialized
/// (e.g. unit tests that do not call `RustLib.init()`), falls back to
/// [`fallbackDefaultRelays`] which mirrors the same list at compile time.
List<String> get defaultRelays {
  try {
    return rust.defaultRelays();
  } on Object catch (_) {
    // Rust FFI not initialized — used by unit tests that exercise pure
    // Dart helpers without spinning up the bridge.
    return fallbackDefaultRelays;
  }
}

/// Compile-time fallback list of default profile-plane relay URLs.
///
/// MUST agree, entry for entry and in order, with `PRODUCTION_PROFILE_RELAYS`
/// in `haven-core/src/profile/relay_pool.rs`. That is a CHECKED invariant, not
/// a convention: `scripts/ci/check_profile_privacy_boundaries.sh` (check 13,
/// run by the `repo-guards` CI job) diffs the two literal lists and fails on
/// any drift. Enforcement matters more here than for the sibling mirrors
/// because there is no runtime FFI getter for this list (see below), so this
/// constant is not a fallback for a live value — it IS the only Dart-side
/// value. Deliberately DISJOINT from
/// [`fallbackDefaultRelays`] — falling back to the account-relay list here
/// on a transient seed failure would reproduce, in the fallback path alone,
/// the exact cross-plane join the profile/location relay split exists to
/// prevent. Two consumers: [`ProfileRelaysNotifier`] falls back to it when the
/// relay-preferences storage seed transiently fails and it needs a non-empty
/// list to keep the UI usable instead of stranding it in `AsyncError`; and
/// `relay_settings_page.dart` reads it to decide which Profile rows may offer a
/// remove control, since a curated entry is re-admitted by
/// `usable_profile_relays()` no matter what the stored list says. There is no
/// runtime FFI getter for this list (unlike [`defaultRelays`]) — the profile
/// plane deliberately keeps no relay URL crossing the FFI boundary outside of
/// direct CRUD reads/writes, so this constant is the only source.
const fallbackDefaultProfileRelays = <String>[
  'wss://purplepag.es',
  'wss://nostr.mom',
  'wss://offchain.pub',
  'wss://nostr.oxtr.dev',
  'wss://nostr.bitcoiner.social',
  'wss://yabu.me',
  'wss://soloco.nl',
  'wss://nostr.data.haus',
];

/// Compile-time fallback list of read-only discovery relay URLs.
///
/// MUST agree, entry for entry and in order, with `PRODUCTION_DISCOVERY_RELAYS`
/// in `haven-core/src/relay/discovery.rs` — a CHECKED invariant
/// (`scripts/ci/check_profile_privacy_boundaries.sh` check 13, run by the
/// `repo-guards` CI job, diffs the two literal lists). Mirrors the
/// [`fallbackDefaultRelays`] safety-net pattern: used when the Rust FFI is not
/// initialized (unit tests). It is checked rather than best-effort because
/// [`profileRelayContaminationProvider`] resolves the discovery plane through
/// [`discoveryRelays`], so in a widget test this list is what decides whether
/// a Profile row shows the contamination warning.
const fallbackDiscoveryRelays = <String>[
  'wss://index.hzrd149.com',
  'wss://indexer.coracle.social',
  'wss://relay.primal.net',
  'wss://relay.damus.io',
  'wss://relay.ditto.pub',
  'wss://nos.lol',
];

/// The read-only discovery relay list (public indexers).
///
/// These relays are queried ONLY to discover *other* users' metadata and
/// relay lists by bare pubkey — they are READ-ONLY and must NEVER be passed
/// as a publish or gift-wrap-poll target, or a private relay would leak onto
/// a public relay. The runtime authority is the Rust FFI getter
/// `discovery_relays()`; this falls back to [`fallbackDiscoveryRelays`] when
/// the FFI is not initialized (unit tests).
List<String> get discoveryRelays {
  try {
    return rust.discoveryRelays();
  } on Object catch (_) {
    return fallbackDiscoveryRelays;
  }
}
