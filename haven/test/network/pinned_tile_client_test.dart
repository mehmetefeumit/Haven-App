import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/network/pinned_tile_client.dart';
import 'package:http/http.dart' as http;

void main() {
  group('buildPinnedTileClient', () {
    test('accepts the bundled Stadia CA PEM (valid, parseable bundle)', () {
      // Reading the real asset proves BoringSSL can parse the committed bundle
      // (incl. its comment lines); a malformed bundle would silently disable
      // pinning in release, so failing here is the point.
      final pem = File('assets/certs/stadia_ca.pem').readAsBytesSync();
      final client = buildPinnedTileClient(pem);
      addTearDown(client.close);
      expect(client, isA<http.Client>());
    });

    test('rejects malformed PEM with a TlsException', () {
      expect(
        () => buildPinnedTileClient(Uint8List.fromList(utf8.encode('nope'))),
        throwsA(isA<TlsException>()),
      );
    });
  });

  group('createTileHttpClient', () {
    test('returns a client in non-release (test) builds', () async {
      // kReleaseMode is false under `flutter test`, so this exercises the
      // default (unpinned) path and must not throw.
      final client = await createTileHttpClient();
      addTearDown(client.close);
      expect(client, isA<http.Client>());
    });
  });

  group('cert asset wiring', () {
    test('the CA bundle is declared as an asset in pubspec.yaml', () {
      // Dropping this asset entry would make rootBundle.load throw at runtime,
      // silently degrading release builds to the unpinned client — so guard it.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec.contains('assets/certs/stadia_ca.pem'),
        isTrue,
        reason: 'removing the asset silently disables release cert pinning',
      );
    });
  });
}
