/// Location publishing constants shared across the app.
///
/// `kLocationUpdateInterval` is used in two places and MUST stay in sync:
///   1. `Timer.periodic` in `map_shell.dart` (publish cadence).
///   2. `updateIntervalSecs` argument to `CircleService.encryptLocation`,
///      which jitters the outer kind:445 NIP-40 `expiration` tag uniformly
///      in `[interval, 2 * interval]`.
///
/// `kLocationPublishOverlapGuard` is the publish-skip guard (~90% of the
/// interval). The two values are deliberately independent `const Duration`s
/// because `Duration` does not support multiplication by a `double`.
///
/// TODO: when user-configurable update intervals are added (settings UI),
/// source from a Riverpod provider analogous to `senderRetentionProvider`.
/// The FFI already accepts the value per-call.
library;

const Duration kLocationUpdateInterval = Duration(minutes: 5);
const Duration kLocationPublishOverlapGuard = Duration(minutes: 4, seconds: 30);
