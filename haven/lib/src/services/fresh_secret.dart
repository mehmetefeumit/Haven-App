import 'dart:typed_data';

import 'package:haven/src/services/circle_service.dart'
    show CircleServiceException;

/// Fetches the identity secret FRESH via [secretProvider], runs [use] with an
/// owned 32-byte copy, then scrubs that copy the instant [use] completes —
/// including when [use] throws — so the plaintext is never retained across a
/// settle-window wait (Rule 9: Dart has no `zeroize`, so minimise the secret's
/// lifetime). Re-fetching per stage attempt bounds each exposure to a single
/// FFI round-trip instead of the whole multi-window converge loop.
///
/// Throws [CircleServiceException] if the provider yields a non-32-byte secret.
///
/// Extracted as a free function so the fetch → validate → scrub contract is
/// unit-testable without the FFI bridge.
Future<T> withFreshSecret<T>(
  Future<List<int>> Function() secretProvider,
  Future<T> Function(Uint8List secret) use,
) async {
  final raw = await secretProvider();
  if (raw.length != 32) {
    throw CircleServiceException(
      'Invalid identity secret bytes length: expected 32, got ${raw.length}',
    );
  }
  final secret = Uint8List.fromList(raw);
  try {
    return await use(secret);
  } finally {
    secret.fillRange(0, secret.length, 0);
  }
}
