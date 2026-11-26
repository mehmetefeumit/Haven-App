// Holds the one secure-storage configuration the identity key lives under
// (`lib/src/services/identity_secure_storage.dart`).
//
// Two halves:
//
// * Its options, compared whole against today's values. Android's
//   `resetOnError` defaults to true, and then any failed read or decrypt
//   deletes the stored data and reports success — which Haven read as "no
//   identity" and replaced with a new key. A changed cipher default runs the
//   plugin's algorithm migration, which deletes the old wrapping key before
//   re-encrypting. On iOS the account name and accessibility class are part
//   of the item's identity: a read under others misses the key. A plugin bump
//   that moves any of these fails here, before it ships.
// * Every site: in `lib/` and `integration_test/` no code but that file
//   - builds, tears off, extends, implements, mixes in or aliases
//     `FlutterSecureStorage`, under any import prefix;
//   - passes a per-call platform option (`aOptions`, `iOptions`, `lOptions`,
//     `wOptions`, `mOptions`, `webOptions`) to any call — which would replace
//     the shared options, `resetOnError: false` included, for that call; or
//   - spells the identity key in string text, adjacent literals and
//     interpolated literals joined (any text holding `haven.nostr` or
//     `nostr.identity` counts).
//   Parsed, not resolved: a comment never counts, and a key assembled from
//   variables is not seen. The detector is unit-tested against known-bad and
//   known-good snippets.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/identity_secure_storage.dart';

const _sharedFile = 'lib/src/services/identity_secure_storage.dart';

/// Finds the sites the header lists: a use of the storage class other than
/// as a type annotation, a per-call platform option, and the key's text.
class _StorageSiteVisitor extends RecursiveAstVisitor<void> {
  final List<String> found = [];

  static const _class = 'FlutterSecureStorage';
  static const _optionArgs = {
    'aOptions',
    'iOptions',
    'lOptions',
    'wOptions',
    'mOptions',
    'webOptions',
  };

  // `const`/`new` constructions, `.new` tear-offs, supertypes and aliases.
  @override
  void visitNamedType(NamedType node) {
    final parent = node.parent;
    if (node.name.lexeme == _class &&
        (parent is ConstructorName ||
            parent is ExtendsClause ||
            parent is ImplementsClause ||
            parent is WithClause ||
            parent is GenericTypeAlias)) {
      found.add(parent!.toSource());
    }
    super.visitNamedType(node);
  }

  // Unresolved, a construction without a keyword parses as a method
  // invocation (`fss.FlutterSecureStorage()` too) and a tear-off as an
  // identifier; a doc reference and an import's `show` are neither.
  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (node.name == _class &&
        node.thisOrAncestorOfType<Comment>() == null &&
        node.thisOrAncestorOfType<Combinator>() == null) {
      found.add(node.parent?.toSource() ?? node.name);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (_optionArgs.contains(node.name.label.name)) found.add(node.toSource());
    super.visitNamedExpression(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => _string(node);

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _string(node);
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _string(node);
    super.visitStringInterpolation(node);
  }

  /// Checks a string once, at its outermost literal.
  void _string(StringLiteral node) {
    final parent = node.parent;
    if (parent is AdjacentStrings || parent is InterpolationExpression) return;
    final text = _text(node);
    if (text.contains('haven.nostr') || text.contains('nostr.identity')) {
      found.add(node.toSource());
    }
  }

  /// A literal's text, adjacent parts and interpolated literals joined; any
  /// other interpolation breaks it.
  static String _text(StringLiteral node) => switch (node) {
    SimpleStringLiteral() => node.value,
    AdjacentStrings() => node.strings.map(_text).join(),
    StringInterpolation() => node.elements.map((e) {
      if (e is InterpolationString) return e.value;
      final expression = (e as InterpolationExpression).expression;
      return expression is StringLiteral ? _text(expression) : '\u0000';
    }).join(),
  };
}

List<String> findStorageSites(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final visitor = _StorageSiteVisitor();
  parsed.unit.accept(visitor);
  return visitor.found;
}

void main() {
  group('the identity storage options', () {
    test("Android: no reset on error, ciphers at the stored key's", () {
      expect(identitySecureStorage.aOptions.toMap(), {
        'encryptedSharedPreferences': 'false',
        'resetOnError': 'false',
        'migrateOnAlgorithmChange': 'true',
        'enforceBiometrics': 'false',
        'keyCipherAlgorithm': 'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
        'storageCipherAlgorithm': 'AES_GCM_NoPadding',
        'sharedPreferencesName': '',
        'preferencesKeyPrefix': '',
        'biometricPromptTitle': 'Authenticate to access',
        'biometricPromptSubtitle': 'Use biometrics or device credentials',
      });
    });

    test('iOS: the item the key was always stored as', () {
      expect(identitySecureStorage.iOptions.toMap(), {
        'accountName': 'flutter_secure_storage_service',
        'accessibility': 'first_unlock_this_device',
        'synchronizable': 'false',
      });
    });

    test('the key name', () {
      expect(identityStorageKey, 'haven.nostr.identity');
    });
  });

  group('storage-site detector', () {
    test('flags every way to build the class, under any prefix', () {
      expect(
        findStorageSites('''
const a = FlutterSecureStorage();
final b = FlutterSecureStorage();
final c = new FlutterSecureStorage();
const d = fss.FlutterSecureStorage();
final e = fss.FlutterSecureStorage();
final f = FlutterSecureStorage.new;
final g = fss.FlutterSecureStorage.new;
'''),
        hasLength(7),
      );
    });

    test('flags a subclass, an implementation, a mixin and an alias', () {
      expect(
        findStorageSites('''
class A extends FlutterSecureStorage {}
class B implements fss.FlutterSecureStorage {}
class C with FlutterSecureStorage {}
typedef D = FlutterSecureStorage;
'''),
        hasLength(4),
      );
    });

    test('flags a per-call platform option on any call', () {
      expect(
        findStorageSites('''
void f(s) {
  identitySecureStorage.read(key: identityStorageKey, aOptions: x);
  identitySecureStorage.write(key: k, value: v, iOptions: x);
  s.delete(key: k, lOptions: x, wOptions: x, mOptions: x, webOptions: x);
}
'''),
        hasLength(6),
      );
    });

    test('flags the key, whole, split or interpolated', () {
      expect(
        findStorageSites(r'''
const a = 'haven.nostr.identity';
const b = 'haven.nostr.' 'identity';
const c = 'haven.' 'nostr.identity';
final d = 'haven.nostr.$suffix';
final e = 'haven.${'nostr'}.identity';
final f = "${prefix}nostr.identity";
'''),
        hasLength(6),
      );
    });

    test('ignores comments, type annotations, imports and the shared '
        'constants', () {
      expect(
        findStorageSites('''
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
// FlutterSecureStorage() under 'haven.nostr.identity', aOptions: x
/// [FlutterSecureStorage]
class S {
  S(FlutterSecureStorage? storage, {String? key});
  final FlutterSecureStorage storage;
  final List<FlutterSecureStorage> all;
}
void f() => identitySecureStorage.read(key: identityStorageKey);
void g(s) => s.read(key: 'haven.other', options: x);
'''),
        isEmpty,
      );
    });
  });

  group('repository scan', () {
    test(
      'only the shared file builds secure storage, sets its options or names '
      'the identity key',
      () {
        final offenders = <String>[];
        var scanned = 0;
        for (final root in ['lib', 'integration_test']) {
          final dir = Directory(root);
          expect(
            dir.existsSync(),
            isTrue,
            reason: 'run this test from the `haven/` package root',
          );
          for (final file in dir.listSync(recursive: true).whereType<File>()) {
            final path = file.path.replaceAll(r'\', '/');
            if (!path.endsWith('.dart') || path.startsWith('lib/src/rust/')) {
              continue;
            }
            scanned++;
            if (path == _sharedFile) continue;
            for (final site in findStorageSites(file.readAsStringSync())) {
              offenders.add('$path: $site');
            }
          }
        }

        expect(scanned, greaterThan(100), reason: 'the scan saw the tree');
        expect(
          findStorageSites(File(_sharedFile).readAsStringSync()),
          hasLength(4),
          reason:
              'the shared file holds the one construction, its two '
              'option sets and the key',
        );
        expect(
          offenders,
          isEmpty,
          reason: 'use identitySecureStorage and identityStorageKey',
        );
      },
    );
  });
}
