/// Default relay URLs used throughout Haven.
///
/// Centralizes relay configuration to avoid duplication across providers.
library;

import 'package:haven/src/rust/api.dart' as rust;

/// Compile-time fallback list of default relay URLs.
///
/// MUST agree with `DEFAULT_RELAYS` in
/// `haven-core/src/circle/types.rs`. The runtime authority is the
/// [`defaultRelays`] getter, which calls the Rust FFI; this constant is
/// the safety net used when (a) the FFI is not initialized (unit tests)
/// or (b) the relay-preferences storage seed transiently fails and a
/// notifier needs a non-empty list to keep the UI usable instead of
/// stranding it in `AsyncError`.
const fallbackDefaultRelays = <String>[
  'wss://relay.damus.io',
  'wss://relay.snort.social',
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
