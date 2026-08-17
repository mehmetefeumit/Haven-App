import 'dart:typed_data';

import 'package:haven/src/services/circle_service.dart'
    show CircleServiceException;

/// Takes ownership of a freshly-fetched secret buffer and returns it as a
/// [Uint8List] the caller alone is now responsible for scrubbing.
///
/// OWNERSHIP TRANSFERS: the provider of [raw] must not retain or read it
/// again. When [raw] is already a [Uint8List] — every real provider forwards
/// the buffer `flutter_rust_bridge` freshly allocated for this call — it is
/// returned AS IS, so no second copy of the secret is ever minted and the
/// caller's single scrub reaches the only buffer that holds it.
///
/// Only a foreign list shape forces a copy, and then the source is wiped
/// EAGERLY, before returning, never from a `finally`: a source that cannot be
/// wiped (`const []`, or anything else mixing in `UnmodifiableListMixin`,
/// whose `fillRange` throws unconditionally) is a secret nothing can scrub, so
/// it must fail loudly here rather than throw out of a `finally` and mask the
/// caller's real exception.
///
/// Security Rule 9: Dart has no `zeroize`, so a copy nothing holds a reference
/// to is a copy that survives until the GC happens to overwrite it.
Uint8List takeSecretOwnership(List<int> raw) {
  if (raw is Uint8List) return raw;
  final owned = Uint8List.fromList(raw);
  raw.fillRange(0, raw.length, 0);
  return owned;
}

/// Fetches the identity secret FRESH via [secretProvider], runs [use] with the
/// 32-byte buffer it now owns, then scrubs that buffer the instant [use]
/// completes — including when [use] throws — so the plaintext is never
/// retained across a settle-window wait (Rule 9: Dart has no `zeroize`, so
/// minimise the secret's lifetime). Re-fetching per stage attempt bounds each
/// exposure to a single FFI round-trip instead of the whole multi-window
/// converge loop.
///
/// [secretProvider] transfers ownership of what it returns — see
/// [takeSecretOwnership].
///
/// Throws [CircleServiceException] if the provider yields a non-32-byte
/// secret. That check sits INSIDE the `try` so the rejected buffer is scrubbed
/// too — a wrong-length secret is still a secret.
///
/// Extracted as a free function so the fetch → validate → scrub contract is
/// unit-testable without the FFI bridge.
Future<T> withFreshSecret<T>(
  Future<List<int>> Function() secretProvider,
  Future<T> Function(Uint8List secret) use,
) async {
  final secret = takeSecretOwnership(await secretProvider());
  try {
    if (secret.length != 32) {
      throw CircleServiceException(
        'Invalid identity secret bytes length: expected 32, got '
        '${secret.length}',
      );
    }
    return await use(secret);
  } finally {
    secret.fillRange(0, secret.length, 0);
  }
}
