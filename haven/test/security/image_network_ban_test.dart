/// Security gate: assert no Image.network call exists under lib/.
///
/// Image.network contacts an external URL — for a privacy-first app
/// that must never leak avatar or user data to relays or CDNs, it is
/// permanently banned from production library code.
///
/// This test reads the lib/ source tree at runtime and fails the suite
/// if any file contains the literal string "Image.network(".
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Walks up directory ancestors from [start] until it finds a
/// directory that contains both a `pubspec.yaml` and a `lib/`
/// subdirectory, which identifies the Flutter package root.
Directory _findPackageRoot(Directory start) {
  var dir = start;
  for (var depth = 0; depth < 20; depth++) {
    final hasPubspec = File('${dir.path}/pubspec.yaml').existsSync();
    final hasLib = Directory('${dir.path}/lib').existsSync();
    if (hasPubspec && hasLib) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break; // filesystem root
    dir = parent;
  }
  throw StateError('Could not locate Flutter package root from ${start.path}');
}

void main() {
  test(
    'no Image.network( call exists anywhere under lib/',
    () async {
      final packageRoot = _findPackageRoot(Directory.current);
      final libDir = Directory('${packageRoot.path}/lib');

      expect(
        libDir.existsSync(),
        isTrue,
        reason: 'lib/ directory not found at ${libDir.path}',
      );

      final violations = <String>[];

      await for (final entity in libDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;

        final content = entity.readAsStringSync();
        if (content.contains('Image.network(')) {
          violations.add(entity.path);
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'Image.network() found in lib/ — use Image.memory() instead '
            'to prevent leaking user data to external servers.\n'
            'Offending files:\n${violations.join('\n')}',
      );
    },
  );

  test(
    'no CachedNetworkImage( call exists anywhere under lib/',
    () async {
      // The public-profile migration (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md
      // D2) fetches profile picture bytes entirely in Rust — including the
      // anti-SSRF connect-time IP filter — and only ever hands Flutter
      // already-downloaded, sha256-verified bytes. `CachedNetworkImage`
      // would let a member's attacker-controlled kind-0 `picture` URL
      // reach Flutter's own HTTP stack directly, bypassing that filter and
      // reopening the same SSRF / co-member IP-harvesting primitive the
      // `Image.network` ban above exists to prevent. Banned alongside
      // `Image.network(` for the same reason, belt-and-braces.
      final packageRoot = _findPackageRoot(Directory.current);
      final libDir = Directory('${packageRoot.path}/lib');

      expect(
        libDir.existsSync(),
        isTrue,
        reason: 'lib/ directory not found at ${libDir.path}',
      );

      final violations = <String>[];

      await for (final entity in libDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;

        final content = entity.readAsStringSync();
        if (content.contains('CachedNetworkImage(')) {
          violations.add(entity.path);
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'CachedNetworkImage() found in lib/ — use Image.memory() with '
            'bytes resolved via the Rust core instead; URLs must never '
            'cross the FFI boundary or reach a Flutter-side HTTP client.\n'
            'Offending files:\n${violations.join('\n')}',
      );
    },
  );

  test('cached_network_image is not a pubspec dependency', () async {
    final packageRoot = _findPackageRoot(Directory.current);
    final pubspec = File('${packageRoot.path}/pubspec.yaml');

    expect(
      pubspec.existsSync(),
      isTrue,
      reason: 'pubspec.yaml not found at ${pubspec.path}',
    );

    final content = pubspec.readAsStringSync();

    expect(
      content.contains('cached_network_image'),
      isFalse,
      reason:
          'cached_network_image must not be a dependency — it fetches '
          'images directly from a URL, which would bypass the Rust-side '
          'anti-SSRF picture-download filter (see the CachedNetworkImage '
          'ban above and docs/PUBLIC_PROFILE_MIGRATION_PLAN.md D2).',
    );
  });
}
