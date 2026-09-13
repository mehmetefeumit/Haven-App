/// Dart-side mirror of `haven_core::log_alias` (Security Rule 15).
///
/// A log line may never carry a real identifier — a circle, peer, event,
/// relay, KeyPackage slot or subscription id — in any encoding or at any
/// truncation. Where a line genuinely needs to say "the same X as that other
/// line", it uses the per-process, salted handle this file's [logAliasHandle]
/// computes over the FFI boundary (`circle#a91f3c`); where it needs a
/// magnitude, [magnitudeBucket] buckets it; where it needs to say "how long
/// ago", [relativeSecs] gives an offset instead of a wall-clock instant.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart' as rust;

/// Which kind of value a [logAliasHandle] call is aliasing.
///
/// Mirrors `haven_core::log_alias::LogAliasClass` / the generated
/// `LogAliasClassFfi` — kept as Haven's own enum so a call site does not need
/// to know the generated bridge's type name.
enum LogAliasClass { circle, peer, event, relay, keyPackage, subscription }

/// The snake_case wire tag for each [LogAliasClass] variant.
extension LogAliasClassTag on LogAliasClass {
  /// Matches `haven_core::log_alias::LogAliasClass::tag()` exactly (see the
  /// parity test in `test/utils/log_alias_test.dart`) — used for BOTH the
  /// degraded fallback marker and the memo key, so `keyPackage` never
  /// diverges from the real handle's `key_package#…` prefix by rendering as
  /// `keyPackage#……` instead.
  String get tag => switch (this) {
    LogAliasClass.circle => 'circle',
    LogAliasClass.peer => 'peer',
    LogAliasClass.event => 'event',
    LogAliasClass.relay => 'relay',
    LogAliasClass.keyPackage => 'key_package',
    LogAliasClass.subscription => 'subscription',
  };

  rust.LogAliasClassFfi get _ffi => switch (this) {
    LogAliasClass.circle => rust.LogAliasClassFfi.circle,
    LogAliasClass.peer => rust.LogAliasClassFfi.peer,
    LogAliasClass.event => rust.LogAliasClassFfi.event,
    LogAliasClass.relay => rust.LogAliasClassFfi.relay,
    LogAliasClass.keyPackage => rust.LogAliasClassFfi.keyPackage,
    LogAliasClass.subscription => rust.LogAliasClassFfi.subscription,
  };
}

/// The FFI call [logAliasHandle] delegates to.
///
/// A mutable top-level binding — the same shape `debugPrint` itself uses —
/// rather than a constructor parameter, because `logAlias` is a free
/// function with no class to inject through (see
/// `test/services/DEPENDENCY_INJECTION_EXAMPLES.md`). Tests override this
/// with a fake so the memo/bounding logic is provable without the Rust
/// bridge, which `flutter test` never initialises.
@visibleForTesting
String Function({required rust.LogAliasClassFfi class_, required String value})
logAliasFfiCall = rust.logAlias;

/// The FFI call [rotateLogAliasSaltNow] delegates to. Same shape and same
/// reason as [logAliasFfiCall] — injectable so a test can prove the
/// swallow-and-log-type-only behaviour of the catch branch without the Rust
/// bridge.
@visibleForTesting
void Function() rotateLogAliasSaltCall = rust.rotateLogAliasSalt;

/// Per-isolate memo: `"<tag>#<value>"` → the handle already computed for it.
/// Cleared ENTIRELY (never LRU-evicted) once it reaches [_maxMemoEntries] —
/// a handle is one HMAC call away either way, so a partial evict would only
/// add bookkeeping for no privacy or performance gain over a full clear.
final Map<String, String> _memo = {};

/// Bound on [_memo]'s size before it is cleared. 512 comfortably covers a
/// session's worth of distinct circles/peers/relays without letting the map
/// grow for the life of the process.
const int _maxMemoEntries = 512;

/// Whether the bridge-unavailable degradation has already been reported in
/// this isolate. Reset by [clearLogAliasMemo] so a genuinely new isolate (or
/// a test) observes the warning again.
bool _warnedBridgeUnavailable = false;

/// Returns the per-process, salted log handle for [value] in class [c] —
/// e.g. `circle#a91f3c`. Renders the SAME handle for the hex and `npub1…`
/// spellings of one pubkey, and a DIFFERENT handle for the same bytes in a
/// different [LogAliasClass] (Security Rule 15).
///
/// Never throws. If the FFI call itself fails — only possible in a process
/// that never called `RustLib.init()`, which is every `flutter test` run and
/// never production — this degrades to a fixed `<tag>#??????` marker. The
/// failure is reported by TYPE ONLY (never [value]) and only ONCE per
/// isolate: every later degraded call in the same process would otherwise
/// repeat the identical line on every single log call that follows, which is
/// itself a per-cycle timing/volume signal worth not creating.
String logAliasHandle(LogAliasClass c, String value) {
  final key = '${c.tag}#$value';
  final cached = _memo[key];
  if (cached != null) return cached;

  try {
    final handle = logAliasFfiCall(class_: c._ffi, value: value);
    // Only a genuine handle is memoized. A degraded fallback (below) is
    // deliberately NOT cached, so a transient bridge failure cannot poison
    // every later call for the same value for the rest of the process.
    if (_memo.length >= _maxMemoEntries) {
      _memo.clear();
    }
    _memo[key] = handle;
    return handle;
  } on Object catch (e) {
    if (!_warnedBridgeUnavailable) {
      _warnedBridgeUnavailable = true;
      debugPrint('[LogAlias] bridge unavailable: ${e.runtimeType}');
    }
    return '${c.tag}#??????';
  }
}

/// Clears the memo and re-arms the one-shot bridge-unavailable warning.
///
/// Called from the identity wipe/logout path alongside
/// [rotateLogAliasSaltNow]: once the process salt is re-minted, a stale memo
/// entry would otherwise keep answering with the PRE-rotation handle for a
/// value that recurs after login, silently defeating the rotation. Also
/// called on app pause (see `identity_provider.dart`), because the memo
/// holds every raw circle/peer/relay/event id it has been asked to alias,
/// process-wide, for as long as the process lives — pause is the same
/// "assume nothing else will read this again soon" boundary the app's other
/// in-memory caches already clear on.
void clearLogAliasMemo() {
  _memo.clear();
  _warnedBridgeUnavailable = false;
}

/// Re-mints the process salt over the FFI boundary (see
/// `haven_core::log_alias::rotate_salt`) so no handle already emitted
/// survives a wipe. Best-effort and never throws: a wipe is already
/// in progress, and nothing downstream depends on this step succeeding —
/// worst case, a handle computed post-rotation still traces back to the same
/// salt as one from before it, which is a narrower correlation window, not a
/// key or identifier leak.
void rotateLogAliasSaltNow() {
  try {
    rotateLogAliasSaltCall();
  } on Object catch (e) {
    debugPrint('[LogAlias] salt rotation unavailable: ${e.runtimeType}');
  }
}

/// Buckets an exact count into a magnitude that cannot single out a specific
/// circle/member/relay/event by its precise size: `0 | 1 | 2-4 | 5+` —
/// mirrors `haven_core::log_alias::bucket` so a Rust-side and Dart-side line
/// about the same collection read the same bucket.
String magnitudeBucket(int count) {
  if (count <= 0) return '0';
  if (count == 1) return '1';
  if (count <= 4) return '2-4';
  return '5+';
}

/// A relative-time origin for [relativeSecs].
///
/// Constructible ONLY via [LogOrigin.now]: the origin a log line measures
/// against must be THIS PROCESS'S OWN observation of the current instant,
/// never an arbitrary `DateTime` a caller has lying around — epoch 0, or
/// (the concrete failure mode this closes off) an inbound event's own
/// embedded timestamp, which would let remote input choose what "relative"
/// is relative to.
class LogOrigin {
  LogOrigin._(this._at);

  /// Captures the current instant as a fresh origin.
  factory LogOrigin.now() => LogOrigin._(DateTime.now());

  /// Test-only escape hatch so [relativeSecs]'s formatting is testable
  /// deterministically. `invalid_use_of_visible_for_testing_member` fails
  /// `flutter analyze` (a warning, and warnings are fatal in this repo's CI)
  /// on any non-test call site — the enforcement [LogOrigin]'s class comment
  /// promises, backed by tooling rather than by convention alone.
  @visibleForTesting
  factory LogOrigin.forTest(DateTime at) => LogOrigin._(at);

  final DateTime _at;
}

/// Formats [t] as a relative offset from [origin] — `t+34s` if after,
/// `t-34s` if before, `t+0s` if equal — so a log line can say how far apart
/// two instants are without ever stating either one's wall-clock value on a
/// publish/receive path (Security Rule 15).
String relativeSecs(LogOrigin origin, DateTime t) {
  final deltaSecs = t.difference(origin._at).inSeconds;
  final sign = deltaSecs < 0 ? '-' : '+';
  return 't$sign${deltaSecs.abs()}s';
}
