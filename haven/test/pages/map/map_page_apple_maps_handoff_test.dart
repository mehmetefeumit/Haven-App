/// Tests for the Apple Maps handoff URL built by `MapPage._openInAppleMaps`.
///
/// `mapOpenInAppleMapsBody` tells the user, in a confirmation sheet shown
/// before the handoff runs, "Only the map coordinate is sent to Apple Maps,
/// never a name or identity". Nothing else in this tree proves that; this
/// file does, by pinning what the handoff URL carries: the query-parameter
/// KEY SET (nothing beside `ll`), the coordinate VALUES inside it (both
/// signs), and the scheme and host — the sentence names Apple Maps as the
/// destination, so where the coordinate goes is half of what it promises.
/// What is deliberately NOT pinned is the URL as a golden string: path,
/// parameter order and percent-encoding can all change without touching the
/// promise, and a whole-URL comparison would go red on each of them while
/// still going green with a `q=` label attached.
///
/// See `map_page_location_access_test.dart` for why this exercises the pure
/// static [MapPage.appleMapsHandoffUri] rather than pumping [MapPage]:
/// `initState` calls `HavenCore.newInstance()` across the Rust FFI, which
/// crashes the widget-test runner. The same file is where the AST-guard
/// pattern the wiring group below uses comes from.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map/map_page.dart';

/// Counts `<className>.<method>(...)` calls inside the declaration of
/// [enclosingMethod].
///
/// Scoped to one method rather than swept over the file, so a doc comment or
/// an unrelated call site cannot stand in for the wiring being proved.
int countStaticCallsInMethod(
  String source, {
  required String enclosingMethod,
  required String className,
  required String method,
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _ScopedStaticCallVisitor(
    enclosingMethod: enclosingMethod,
    className: className,
    method: method,
  );
  unit.accept(visitor);
  return visitor.count;
}

/// Counts the string literals in [source] whose text contains [host].
///
/// Literals, not raw substrings, so a doc comment naming the host is not
/// mistaken for a construction site; and any literal, not just the argument
/// of a `Uri.https` call, so a URL smuggled through `Uri.parse('https://…')`
/// is counted too.
int countHostLiterals(String source, {required String host}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _HostLiteralVisitor(host: host);
  unit.accept(visitor);
  return visitor.count;
}

/// The fixed text of [literal], with any interpolated expressions dropped.
String _literalText(StringLiteral literal) {
  if (literal is SimpleStringLiteral) return literal.value;
  if (literal is AdjacentStrings) {
    return literal.strings.map(_literalText).join();
  }
  if (literal is StringInterpolation) {
    return literal.elements
        .whereType<InterpolationString>()
        .map((e) => e.value)
        .join();
  }
  return '';
}

class _ScopedStaticCallVisitor extends RecursiveAstVisitor<void> {
  _ScopedStaticCallVisitor({
    required this.enclosingMethod,
    required this.className,
    required this.method,
  });

  final String enclosingMethod;
  final String className;
  final String method;
  int count = 0;
  bool _inScope = false;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme != enclosingMethod) {
      super.visitMethodDeclaration(node);
      return;
    }
    _inScope = true;
    super.visitMethodDeclaration(node);
    _inScope = false;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (_inScope &&
        target is SimpleIdentifier &&
        target.name == className &&
        node.methodName.name == method) {
      count++;
    }
    super.visitMethodInvocation(node);
  }
}

class _HostLiteralVisitor extends RecursiveAstVisitor<void> {
  _HostLiteralVisitor({required this.host});

  final String host;
  int count = 0;

  /// Adjacent and interpolated literals are counted as the one string they
  /// concatenate to, so a host split across pieces is one hit, not zero.
  void _record(StringLiteral node) {
    if (node.parent is StringLiteral) return;
    if (_literalText(node).contains(host)) count++;
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _record(node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _record(node);
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _record(node);
    super.visitStringInterpolation(node);
  }
}

void main() {
  group('MapPage.appleMapsHandoffUri (the mapOpenInAppleMapsBody promise)', () {
    test('carries exactly the coordinate parameter, nothing else', () {
      final uri = MapPage.appleMapsHandoffUri(
        latitude: 51.5074,
        longitude: -0.1278,
      );
      expect(
        uri.queryParameters.keys.toSet(),
        equals({'ll'}),
        reason:
            'mapOpenInAppleMapsBody promises "Only the map coordinate is '
            'sent to Apple Maps, never a name or identity" — a second query '
            'parameter (a q= label, a member name, a pubkey, a circle name) '
            'would break that promise even though the coordinate itself is '
            'still correct.',
      );
    });

    test('the coordinate parameter is exactly the lat/lon pair given', () {
      const latitude = 37.42199;
      const longitude = -122.08405;
      final uri = MapPage.appleMapsHandoffUri(
        latitude: latitude,
        longitude: longitude,
      );
      final parts = uri.queryParameters['ll']!.split(',');
      expect(
        parts,
        hasLength(2),
        reason:
            'the "ll" parameter must be a single lat,lon pair — a third '
            'comma-joined field would be a smuggled identifier that this '
            'length check catches even though the key set is still {"ll"}.',
      );
      expect(double.parse(parts[0]), latitude);
      expect(double.parse(parts[1]), longitude);
    });

    test('a negative latitude reaches the URL with its sign intact', () {
      // Completes the sign matrix the test above starts (+lat, -lon). Asserting
      // the VALUES, not the key set: the key set is what the first test pins and
      // is the same for every coordinate, so a sign-dropping bug — the handoff
      // sending the user's antipode to Apple — would ship green behind it.
      const latitude = -33.8688;
      const longitude = 151.2093;
      final uri = MapPage.appleMapsHandoffUri(
        latitude: latitude,
        longitude: longitude,
      );
      final parts = uri.queryParameters['ll']!.split(',');
      expect(parts, hasLength(2));
      expect(double.parse(parts[0]), latitude);
      expect(double.parse(parts[1]), longitude);
    });

    test('targets Apple Maps over https', () {
      // "sent to Apple Maps" names the destination, so the destination is part
      // of the promise: a plain-http link, or another host entirely, would send
      // the coordinate somewhere the sentence does not describe.
      final uri = MapPage.appleMapsHandoffUri(latitude: 0, longitude: 0);
      expect(uri.scheme, 'https');
      expect(uri.host, 'maps.apple.com');
    });
  });

  group('detector self-tests', () {
    test('a call is counted only inside the named method', () {
      const source = '''
class _S {
  Future<void> _openInAppleMaps() async {
    final uri = MapPage.appleMapsHandoffUri(latitude: 1, longitude: 2);
    await launchUrl(uri);
  }

  void _elsewhere() {
    MapPage.appleMapsHandoffUri(latitude: 3, longitude: 4);
  }
}
''';
      expect(
        countStaticCallsInMethod(
          source,
          enclosingMethod: '_openInAppleMaps',
          className: 'MapPage',
          method: 'appleMapsHandoffUri',
        ),
        1,
      );
      expect(
        countStaticCallsInMethod(
          source,
          enclosingMethod: '_neverDeclared',
          className: 'MapPage',
          method: 'appleMapsHandoffUri',
        ),
        0,
      );
    });

    test('a doc comment naming the helper does not count as a call', () {
      // The defect this detector replaces: a whole-file `source.contains`
      // was satisfied by exactly this.
      const source = '''
class _S {
  /// See MapPage.appleMapsHandoffUri( for the URL itself.
  Future<void> _openInAppleMaps() async {
    await launchUrl(Uri.parse('https://maps.apple.com/?ll=1,2&q=\$name'));
  }
}
''';
      expect(
        countStaticCallsInMethod(
          source,
          enclosingMethod: '_openInAppleMaps',
          className: 'MapPage',
          method: 'appleMapsHandoffUri',
        ),
        0,
      );
    });

    test('a host literal is counted however the URL is built', () {
      const viaUriHttps = '''
final uri = Uri.https('maps.apple.com', '/', {'ll': ll});
''';
      const viaUriParse = r'''
final uri = Uri.parse('https://maps.apple.com/?ll=$ll&q=$name');
''';
      const viaAdjacentStrings = '''
final uri = Uri.parse('https://maps.' 'apple.com/?ll=1,2');
''';
      for (final source in [viaUriHttps, viaUriParse, viaAdjacentStrings]) {
        expect(
          countHostLiterals(source, host: 'maps.apple.com'),
          1,
          reason:
              'every one of these is a construction site the single-site '
              'guard must see:\n$source',
        );
      }
    });

    test('a comment naming the host is not a construction site', () {
      const source = '''
/// Opens the coordinate on maps.apple.com.
void f() {}
''';
      expect(countHostLiterals(source, host: 'maps.apple.com'), 0);
    });
  });

  group(
    'the real handoff calls the tested helper, not an inline duplicate',
    () {
      late String source;

      setUpAll(() {
        final file = File('lib/src/pages/map/map_page.dart');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'map_page.dart moved — update this guard, do not delete it',
        );
        source = file.readAsStringSync();
      });

      test('_openInAppleMaps builds its URL through the tested helper', () {
        expect(
          countStaticCallsInMethod(
            source,
            enclosingMethod: '_openInAppleMaps',
            className: 'MapPage',
            method: 'appleMapsHandoffUri',
          ),
          1,
          reason:
              'the coordinate-only promise tested above only holds for the '
              'app if _openInAppleMaps actually builds the URL it launches '
              'through the tested helper — otherwise the pure-function tests '
              'prove nothing about the URL Haven really opens.',
        );
      });

      test('no second, untested Apple Maps URL construction site exists', () {
        expect(
          countHostLiterals(source, host: 'maps.apple.com'),
          1,
          reason:
              'exactly one literal should name the Apple Maps host — the one '
              'inside MapPage.appleMapsHandoffUri. A second one (a URL rebuilt '
              "inline as Uri.parse('https://maps.apple.com/?ll=…&q=\$name'), "
              'say) could carry a q= label or an identifier without any test '
              'here ever exercising it.',
        );
      });
    },
  );
}
