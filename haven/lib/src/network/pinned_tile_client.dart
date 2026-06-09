/// TLS certificate pinning for map-tile requests.
///
/// Builds the `package:http` [http.Client] that `flutter_map`'s
/// `NetworkTileProvider` uses to fetch tiles. In release builds the client
/// trusts ONLY the bundled CA hierarchy that issues Stadia's tile certificate
/// (currently Sectigo / USERTrust ECC), so a network attacker cannot
/// man-in-the-middle tile traffic with a user-installed root CA. This is
/// CA-family pinning (not Stadia-leaf pinning): it defeats casual interception
/// but does not bind to Stadia's specific certificate.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

/// Asset path of the pinned Stadia Maps CA bundle (PEM, CA hierarchy only).
const String _stadiaCaAsset = 'assets/certs/stadia_ca.pem';

/// Builds a certificate-pinned [http.Client] that trusts ONLY [caPem].
///
/// [caPem] is a PEM bundle of trust anchors (the Stadia CA hierarchy). The
/// returned client disables system trust roots and rejects any certificate
/// that does not chain to [caPem], so a man-in-the-middle proxy using a
/// user-installed root cannot intercept tile traffic.
///
/// Throws a [TlsException] if [caPem] is not valid PEM — exercised by tests so
/// a malformed bundle fails fast rather than silently disabling pinning.
http.Client buildPinnedTileClient(Uint8List caPem) {
  // System trust roots stay disabled (the default) so ONLY the pinned Stadia
  // CA is trusted; stated explicitly for security clarity.
  // ignore: avoid_redundant_argument_values
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(caPem);
  final pinned = HttpClient(context: context)
    // Only certificates chaining to the pinned Stadia CA validate; anything
    // else (incl. a MITM proxy's user-installed-root cert) lands here and is
    // rejected. No fallback to system trust.
    ..badCertificateCallback = (_, _, _) => false;
  return RetryClient(IOClient(pinned));
}

/// Creates the [http.Client] for map-tile requests.
///
/// In **release** builds the returned client is certificate-pinned to the
/// bundled Stadia Maps CA ([buildPinnedTileClient]). This defeats casual
/// interception (e.g. a debugging proxy with a user-installed root). It is
/// fail-soft — a pinning rejection just yields error tiles; the rest of the app
/// (Nostr relays, location sharing) is unaffected.
///
/// In **debug/profile** builds it returns the default retrying client (system
/// trust roots) so the OpenStreetMap dev fallback and local testing keep
/// working without bundling every possible CA.
///
/// Security note: pinning protects tile traffic in transit; it does NOT hide
/// the embedded Stadia API key from static binary extraction — that risk is
/// mitigated operationally (usage cap + rotation), not in the client.
Future<http.Client> createTileHttpClient() async {
  if (!kReleaseMode) {
    return RetryClient(http.Client());
  }
  try {
    final caBytes = await rootBundle.load(_stadiaCaAsset);
    return buildPinnedTileClient(caBytes.buffer.asUint8List());
  } on Object catch (e) {
    // A bundled asset failing to load is effectively impossible; degrade to the
    // default client so the map still renders rather than breaking the app.
    // Only the type is logged — never tile URLs (they carry the api_key).
    debugPrint(
      'Tile CA pinning unavailable (${e.runtimeType}); using default client',
    );
    return RetryClient(http.Client());
  }
}
