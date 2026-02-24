/// Default relay URLs used throughout Haven.
///
/// Centralizes relay configuration to avoid duplication across providers.
library;

/// Default relay URLs for publishing and fetching Haven events.
///
/// Must match `DEFAULT_RELAYS` in `haven-core/src/circle/types.rs`.
const defaultRelays = [
  'wss://relay.damus.io',
  'wss://relay.nostr.wine',
  'wss://nos.lol',
];
