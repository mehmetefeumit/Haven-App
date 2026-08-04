// Static guard: every screen-reader ANNOUNCEMENT string must be reachable
// from code.
//
// ## The defect class this catches
//
// `clockSkewAnnouncement` was written, given an `@description` explaining that
// it is "spoken once when the clock warning appears (WCAG 2.1 SC 4.1.3 status
// message)", reviewed, and translated into thirteen locales — and no code path
// ever reached it. Thirteen translators' work, and a promise to screen-reader
// users, that executed nowhere.
//
// ## Why announcements specifically, and not every ARB key
//
// Because this is the one class of string whose absence is invisible to every
// other check Haven has. A visual string that nothing renders shows up the
// moment someone opens the screen, and the widget tests assert against the
// getters. An announcement is heard by one group of users, once, in a
// transient moment that leaves no trace in a screenshot, a widget tree or a
// golden. Nothing but reachability will find it.
//
// A blanket "every key must be referenced" guard was considered and rejected:
// it would fire on keys legitimately staged ahead of the UI that uses them,
// which would train people to add allowlist entries — and an allowlist that is
// routinely appended to is not a guard.
//
// ## Why the unwired set is pinned exactly rather than allowlisted
//
// [_knownUnwired] is asserted by EQUALITY, not containment. So it fails if a
// new announcement goes dark, AND it fails once a listed key is finally
// removed — which forces the entry out of this file instead of letting it sit
// here forever as a permanent exemption. An allowlist you cannot forget to
// clean up.
//
// The detector is self-tested below against known-bad and known-good snippets,
// including the two ways a naive implementation would go vacuous: matching a
// key named only in a comment, and matching one named only inside a string.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Announcement keys that are known to be reachable from no code path.
///
/// MUST be empty in the steady state. Each entry needs an owner and a reason,
/// and disappears the moment the key does — see the file header for why this
/// is an equality check.
const Set<String> _knownUnwired = {
  // EMPTY, and that is the steady state. `clockSkewAnnouncement` lived here
  // while it was queued for deletion; it was removed from all 13 ARBs on
  // 2026-08-04 and this entry went with it, which is exactly what the equality
  // check below is for.
  //
  // Why it was deleted rather than wired, since the question will recur:
  // `ClockSkewBanner`'s live region already discharges SC 4.1.3, and with
  // strictly MORE than that key carried — the label is title + body, which
  // names the remedy and distinguishes the two faults `resolveClockSkewCopy`
  // exists to keep apart. Wiring it would have been an accessibility
  // REGRESSION (a sighted user reads the fix; a screen-reader user hears only
  // "it is broken"), and firing it in addition would speak two overlapping
  // utterances for one event. `LocationAccessBanner` has no
  // appearance-announcement key at all, for the same reason. The one
  // announcement a live region genuinely cannot express is the RECOVERY edge
  // — a live region announces its appearance, never its removal — and both
  // banners have that key and both wire it.
};

/// Directories excluded from the "is it used" scan.
///
/// `lib/l10n` is generated: it DEFINES every key, so scanning it would report
/// all of them as used.
const List<String> _excludedPrefixes = ['lib/l10n/'];

/// Extracts the message keys from an ARB document, dropping `@`-prefixed
/// metadata entries.
Set<String> arbMessageKeys(String arbSource) {
  final decoded = jsonDecode(arbSource) as Map<String, dynamic>;
  return decoded.keys.where((k) => !k.startsWith('@')).toSet();
}

/// The subset of [keys] this guard covers.
Set<String> announcementKeys(Set<String> keys) =>
    keys.where((k) => k.toLowerCase().contains('announcement')).toSet();

/// Every identifier NAME that appears in [source] as real code.
///
/// AST-based on purpose. A textual scan would count a key named in a doc
/// comment or quoted in a string literal as a use, which is precisely how a
/// reachability guard rots into prose-matching: the comment explaining that a
/// string is spoken would itself satisfy the check that it is spoken.
Set<String> identifiersUsedIn(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final visitor = _IdentifierVisitor();
  unit.accept(visitor);
  return visitor.names;
}

class _IdentifierVisitor extends RecursiveAstVisitor<void> {
  final Set<String> names = {};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    names.add(node.name);
    super.visitSimpleIdentifier(node);
  }

  // Doc comments are part of the AST, and a `[bracketed]` reference inside one
  // parses to a real `SimpleIdentifier`. Descending into them would let the
  // comment that PROMISES a string is spoken be the thing that proves it is —
  // caught by this file's own self-test before it ever shipped.
  @override
  void visitComment(Comment node) {}

  @override
  void visitCommentReference(CommentReference node) {}
}

/// Collects every `.dart` file under [root] that this guard scans.
List<File> scannedDartFiles(String root) {
  return Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where(
        (f) => !_excludedPrefixes.any((prefix) => f.path.startsWith(prefix)),
      )
      .toList();
}

void main() {
  group('detector self-tests', () {
    test('reads message keys and drops the @metadata twins', () {
      const arb = '''
{
  "@@locale": "en",
  "fooAnnouncement": "Foo happened",
  "@fooAnnouncement": { "description": "spoken when foo happens" },
  "barTitle": "Bar"
}
''';
      expect(arbMessageKeys(arb), {'fooAnnouncement', 'barTitle'});
      expect(announcementKeys(arbMessageKeys(arb)), {'fooAnnouncement'});
    });

    test('counts a real property access as a use', () {
      const source = '''
class W {
  void go(AppLocalizations l10n) {
    SemanticsService.announce(l10n.fooAnnouncement, dir);
  }
}
''';
      expect(identifiersUsedIn(source), contains('fooAnnouncement'));
    });

    test('does NOT count a key named only in a comment', () {
      // The trap this guard exists to avoid: the comment that promises a
      // string is spoken must not be what proves it.
      const source = '''
class W {
  /// Announces [fooAnnouncement] when this appears.
  // TODO: wire fooAnnouncement
  void go() {}
}
''';
      expect(identifiersUsedIn(source), isNot(contains('fooAnnouncement')));
    });

    test('does NOT count a key named only inside a string literal', () {
      const source = '''
class W {
  final String note = 'fooAnnouncement is spoken on appearance';
}
''';
      expect(identifiersUsedIn(source), isNot(contains('fooAnnouncement')));
    });

    test('excludes the generated and shim l10n directories', () {
      final scanned = scannedDartFiles('lib').map((f) => f.path);
      expect(
        scanned.where((p) => p.startsWith('lib/l10n/')),
        isEmpty,
        reason: 'lib/l10n DEFINES every key; scanning it would report all of '
            'them as used and the guard would never fire',
      );
      expect(
        scanned,
        isNotEmpty,
        reason: 'the scan found no files at all — it has gone blind',
      );
    });
  });

  group('the real ARB', () {
    late Set<String> announcements;
    late Set<String> usedIdentifiers;

    setUpAll(() {
      final arb = File('lib/l10n/app_en.arb');
      expect(
        arb.existsSync(),
        isTrue,
        reason: 'app_en.arb moved — update this guard, do not delete it',
      );
      announcements = announcementKeys(arbMessageKeys(arb.readAsStringSync()));
      usedIdentifiers = {
        for (final file in scannedDartFiles('lib'))
          ...identifiersUsedIn(file.readAsStringSync()),
      };
    });

    test('there are announcement keys to check', () {
      // Anti-vacuity: if the naming convention ever changes, this guard would
      // silently start covering nothing.
      expect(
        announcements.length,
        greaterThanOrEqualTo(10),
        reason: 'far fewer announcement keys than expected — has the naming '
            'convention changed? The guard is now covering almost nothing.',
      );
    });

    test('every announcement string is spoken by some code path', () {
      final unwired = announcements.difference(usedIdentifiers);
      expect(
        unwired,
        _knownUnwired,
        reason: 'An announcement key that no code reaches is thirteen '
            'locales of translated work, and a promise to screen-reader '
            'users, that executes nowhere.\n'
            'Either wire it or delete it from every ARB — and if a key here '
            'was just removed, take it out of `_knownUnwired` too.',
      );
    });
  });
}
