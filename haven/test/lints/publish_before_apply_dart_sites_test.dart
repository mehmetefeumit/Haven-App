// Static guard for Security Rule 13's residual (docs/CI_HARDENING_BACKLOG.md,
// Workstream D): "the SHIPPED send path is Dart calling `confirmPublished` /
// `publishFailed` directly ... `publish_then_resolve` [the Rust E2E-tested
// decision] is production code for the RECEIVE path only ... so [the Rust
// suite] pins the decision and its engine consequences, not those Dart call
// sites."
//
// `NostrCircleService` cannot be driven behaviourally for this: its `manager`
// field is the Rust-backed `CircleManagerFfi` (an opaque FRB type, not an
// injectable interface — see `test/services/DEPENDENCY_INJECTION_EXAMPLES.md`
// "Limitations"), so every one of its public methods calls the real FFI
// bridge before a mock could intervene. This file is the source-level
// substitute for that one class.
//
// The receive-side mirror
// (`LocationSharingService._publishAndConfirmAutoCommit`) has NO such
// obstacle — both its `CircleService` and `RelayService`
// dependencies are injectable interfaces — so THAT half of Rule 13 is proven
// behaviourally in `location_sharing_service_test.dart`
// ("receive-side auto-commit publish (Rule 13)"), not here.
//
// `nostr_circle_service.dart` resolves a staged `PendingStateRefFfi` in
// exactly three structural shapes:
//
//   * if/else pairing — `createCircle`, `updateCircleRelays`, and the
//     `_publishAndConfirm` helper shared by `removeMember` and both
//     `leaveCircle` admin steps: `if (<ack>) { confirm-role } else { fail }`.
//     [_checkIfElsePairs]
//   * guard-clause pairing — `addMember`: `if (!<ack>) { fail; throw; }`
//     as a statement, followed by an unconditional sibling `confirmPublished`.
//     [_checkGuardClauses]
//   * bare passthrough — `confirmPendingCommit` / `failPendingCommit`, the
//     two halves the receive-side mirror above calls. The ack DECISION is
//     made entirely by that caller, so these two must stay unconditional
//     (no branching of their own) or the caller-side test would no longer
//     cover the real decision. [the "passthroughs" test]
//
// Each checker is self-tested against known-good and known-bad snippets
// below — including the exact "confirm always runs, fail runs only
// alongside it" shape a broken refactor could introduce — before it is run
// once against the real file, so it cannot pass by having gone blind.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// The FFI methods that resolve a staged commit as "applied". Grouped
/// because `finalizeRelayUpdate` plays `confirmPublished`'s role for
/// `updateCircleRelays` (its own doc comment: "use this instead of a bare
/// `confirm_published` for the `update_circle_relays` flow").
const _confirmRoleMethods = {'confirmPublished', 'finalizeRelayUpdate'};
const _failRoleMethod = 'publishFailed';

/// True if [node] invokes [methodName] on some receiver — any receiver, not
/// just a bare `manager` identifier.
///
/// An earlier revision required the receiver's NAME to be exactly `manager`:
/// every real call site in this file happens to rebind `_manager` to a local
/// or parameter spelled that way before calling it, so the name check never
/// missed a real site — but that made the receiver's spelling, not its role,
/// the signal. A future call written against `_manager!` directly, or a
/// differently-named local, would be a genuine Rule-13 call this file makes
/// that the check would never see — and, unlike a rename of an EXISTING call
/// (which shrinks the [_CallCounter] counts pinned by exact equality below,
/// and so fails loudly), an all-new call under a different name leaves those
/// counts untouched: nothing goes DOWN, so nothing trips. Matching on the
/// method name alone (still requiring SOME receiver, which rules out a
/// same-named bare top-level function) closes that gap; the three names
/// checked here — `confirmPublished`, `publishFailed`, `finalizeRelayUpdate`
/// — are specific enough, and this single scanned file small and
/// single-purpose enough, that dropping the receiver-name filter does not
/// trade a silent miss for a false alarm.
bool _isManagerCall(MethodInvocation node, String methodName) =>
    node.methodName.name == methodName && node.target != null;

class _CallFinder extends RecursiveAstVisitor<void> {
  _CallFinder(this._names);
  final Set<String> _names;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_names.any((name) => _isManagerCall(node, name))) found = true;
    super.visitMethodInvocation(node);
  }
}

/// Whether [root]'s subtree (including itself) contains a manager-call to
/// any name in [names].
bool _subtreeCallsAny(AstNode root, Set<String> names) {
  final finder = _CallFinder(names);
  root.accept(finder);
  return finder.found;
}

class _IfCollector extends RecursiveAstVisitor<void> {
  _IfCollector(this.out);
  final List<IfStatement> out;

  @override
  void visitIfStatement(IfStatement node) {
    out.add(node);
    super.visitIfStatement(node);
  }
}

List<IfStatement> _allIfStatements(AstNode root) {
  final out = <IfStatement>[];
  root.accept(_IfCollector(out));
  return out;
}

/// Whether [expr] is a boolean negation (`!x`, `x == false`, `x != true`,
/// or the operand order flipped), unwrapping parentheses.
///
/// Every real ack condition in this file is a bare identifier
/// (`published`, `anySent`) for a confirm-role branch and its negation
/// (`!published`) for a fail-role guard. Swapping an `if`'s polarity while
/// leaving its branch bodies untouched — e.g. `if (published)` silently
/// becoming `if (!published)` — inverts which outcome confirms and which
/// rolls back without changing which methods are called or how many times,
/// so neither a call-site inventory nor a "does an else exist" check can
/// see it. This is the one property that can. `== false`/`!= true` read the
/// same to a reviewer as `!x` and invert the same way, so they are checked
/// equally — a `!`-only check would silently miss an inversion written in
/// either of those two equivalent forms.
bool _isNegated(Expression expr) {
  var e = expr;
  while (e is ParenthesizedExpression) {
    e = e.expression;
  }
  if (e is PrefixExpression) return e.operator.lexeme == '!';
  if (e is BinaryExpression) {
    bool isBool(Expression x, {required bool value}) =>
        x is BooleanLiteral && x.value == value;
    return switch (e.operator.lexeme) {
      '==' =>
        isBool(e.leftOperand, value: false) ||
            isBool(e.rightOperand, value: false),
      '!=' =>
        isBool(e.leftOperand, value: true) ||
            isBool(e.rightOperand, value: true),
      _ => false,
    };
  }
  return false;
}

/// One structural violation, reported with the offending `if` statement's
/// line for a human to locate it.
class PairingViolation {
  PairingViolation(this.line, this.reason);
  final int line;
  final String reason;

  @override
  String toString() => 'line $line: $reason';
}

/// Checks the if/else shape: a confirm-role call in `then` must be paired
/// with a fail-role call in a non-null `else`, with no cross-contamination
/// (a branch calling both roles could resolve the pending ref twice, or
/// resolve it with the wrong outcome depending on evaluation order).
List<PairingViolation> checkIfElsePairs(CompilationUnit unit, LineInfo lines) {
  final violations = <PairingViolation>[];
  for (final ifStmt in _allIfStatements(unit)) {
    final then = ifStmt.thenStatement;
    if (!_subtreeCallsAny(then, _confirmRoleMethods)) continue;
    final line = lines.getLocation(ifStmt.offset).lineNumber;

    final elseStmt = ifStmt.elseStatement;
    if (elseStmt == null) {
      violations.add(
        PairingViolation(
          line,
          'confirm-role call with no else branch — a rejected publish '
          'would never roll back',
        ),
      );
      continue;
    }
    if (_subtreeCallsAny(then, {_failRoleMethod})) {
      violations.add(
        PairingViolation(
          line,
          'then-branch calls BOTH a confirm-role method and publishFailed',
        ),
      );
    }
    if (!_subtreeCallsAny(elseStmt, {_failRoleMethod})) {
      violations.add(
        PairingViolation(
          line,
          'else-branch does not roll back via publishFailed',
        ),
      );
    }
    if (_subtreeCallsAny(elseStmt, _confirmRoleMethods)) {
      violations.add(
        PairingViolation(
          line,
          'else-branch ALSO confirms — a rejected publish could still be '
          'applied',
        ),
      );
    }
    if (_isNegated(ifStmt.expression)) {
      violations.add(
        PairingViolation(
          line,
          'confirm-role branch is guarded by a NEGATED condition — the ack '
          'check is almost certainly inverted (confirms without an ack, '
          'rolls back an actual ack)',
        ),
      );
    }
  }
  return violations;
}

bool _alwaysExits(Statement stmt) {
  if (stmt is ReturnStatement) return true;
  return stmt is ExpressionStatement && stmt.expression is ThrowExpression;
}

/// Checks the guard-clause shape: `if (<not-acked>) { fail-role; throw; }`
/// with no else, followed — as a later statement in the SAME enclosing
/// block — by an unconditional confirm-role call. Two independent failure
/// modes are distinguished so a fix targets the right line:
///
///   * the guard doesn't end in throw/return, so a rejected publish could
///     fall through to the confirm below it (this is exactly the shape of
///     "confirm always runs, fail runs conditionally alongside it" — see
///     the self-test below);
///   * the guard exits correctly, but nothing after it ever confirms on the
///     ack path, so the staged commit is never resolved when the publish
///     actually succeeds.
List<PairingViolation> checkGuardClauses(
  CompilationUnit unit,
  LineInfo lines,
) {
  final violations = <PairingViolation>[];
  for (final ifStmt in _allIfStatements(unit)) {
    if (ifStmt.elseStatement != null) continue; // owned by the if/else check
    final then = ifStmt.thenStatement;
    if (!_subtreeCallsAny(then, {_failRoleMethod})) continue;
    if (_subtreeCallsAny(then, _confirmRoleMethods)) continue;
    final line = lines.getLocation(ifStmt.offset).lineNumber;

    if (!_isNegated(ifStmt.expression)) {
      violations.add(
        PairingViolation(
          line,
          'failure guard is not gated by a NEGATED ack condition — the ack '
          'check is almost certainly inverted (this guard would fire on '
          'success and roll back an actual ack, then fall through to '
          'confirm an unacked publish)',
        ),
      );
    }

    final lastStmt = then is Block
        ? (then.statements.isEmpty ? null : then.statements.last)
        : then;
    if (lastStmt == null || !_alwaysExits(lastStmt)) {
      violations.add(
        PairingViolation(
          line,
          'the failure guard does not end in throw/return — a rejected '
          'publish could fall through to an unconditional confirm',
        ),
      );
      continue;
    }

    final parent = ifStmt.parent;
    if (parent is! Block) {
      violations.add(
        PairingViolation(
          line,
          'guard is not a direct statement of an enclosing block — cannot '
          'locate a sibling confirm',
        ),
      );
      continue;
    }
    final idx = parent.statements.indexOf(ifStmt);
    final laterSiblings = parent.statements.skip(idx + 1);
    final hasConfirmSibling = laterSiblings.any(
      (s) => _subtreeCallsAny(s, _confirmRoleMethods),
    );
    if (!hasConfirmSibling) {
      violations.add(
        PairingViolation(
          line,
          'no unconditional confirm-role call follows this failure guard — '
          'the staged commit is never resolved on the ack path',
        ),
      );
    }
  }
  return violations;
}

class _CallCounter extends RecursiveAstVisitor<void> {
  final Map<String, int> counts = {};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    for (final name in {..._confirmRoleMethods, _failRoleMethod}) {
      if (_isManagerCall(node, name)) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    super.visitMethodInvocation(node);
  }
}

class _MethodBodyFinder extends RecursiveAstVisitor<void> {
  _MethodBodyFinder(this.name);
  final String name;
  MethodDeclaration? found;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (node.name.lexeme == name) found = node;
    super.visitMethodDeclaration(node);
  }
}

void main() {
  group('checker self-tests — if/else pairing', () {
    List<PairingViolation> run(String body) {
      final parsed = parseString(
        content: 'class _S { Future<void> go() async { $body } }',
        throwIfDiagnostics: false,
      );
      return checkIfElsePairs(parsed.unit, parsed.lineInfo);
    }

    test('a correctly paired if/else has no violations', () {
      expect(
        run('''
          if (published) {
            await manager.confirmPublished(pending: p);
          } else {
            await manager.publishFailed(pending: p);
          }
        '''),
        isEmpty,
      );
    });

    test('finalizeRelayUpdate is recognised as the confirm role', () {
      expect(
        run('''
          if (published) {
            await manager.finalizeRelayUpdate(pending: p, mlsGroupId: g);
          } else {
            await manager.publishFailed(pending: p);
          }
        '''),
        isEmpty,
      );
    });

    test('flags a confirm with no else branch', () {
      final v = run('''
        if (published) {
          await manager.confirmPublished(pending: p);
        }
      ''');
      expect(v, hasLength(1));
      expect(v.single.reason, contains('no else branch'));
    });

    test('flags an else branch that also confirms', () {
      final v = run('''
        if (published) {
          await manager.confirmPublished(pending: p);
        } else {
          await manager.publishFailed(pending: p);
          await manager.confirmPublished(pending: p);
        }
      ''');
      expect(v, hasLength(1));
      expect(v.single.reason, contains('ALSO confirms'));
    });

    test('flags a then branch that also fails', () {
      final v = run('''
        if (published) {
          await manager.confirmPublished(pending: p);
          await manager.publishFailed(pending: p);
        } else {
          await manager.publishFailed(pending: p);
        }
      ''');
      expect(v, hasLength(1));
      expect(v.single.reason, contains('BOTH a confirm-role'));
    });

    test('flags an else branch that never rolls back', () {
      final v = run('''
        if (published) {
          await manager.confirmPublished(pending: p);
        } else {
          debugPrint('nothing happens');
        }
      ''');
      expect(v, hasLength(1));
      expect(v.single.reason, contains('does not roll back'));
    });

    test('ignores an unrelated if statement entirely', () {
      expect(
        run('''
          if (someOtherCondition) {
            debugPrint('unrelated');
          }
        '''),
        isEmpty,
      );
    });

    test(
      'flags an inverted condition even though every call is present and '
      'correctly paired (branch bodies untouched, only the condition '
      'flipped)',
      () {
        final v = run('''
          if (!published) {
            await manager.confirmPublished(pending: p);
          } else {
            await manager.publishFailed(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('NEGATED condition'));
      },
    );

    test('a parenthesized negation is still recognised as inverted', () {
      final v = run('''
        if ((!published)) {
          await manager.confirmPublished(pending: p);
        } else {
          await manager.publishFailed(pending: p);
        }
      ''');
      expect(v, hasLength(1));
      expect(v.single.reason, contains('NEGATED condition'));
    });

    test(
      'an equality-form inversion (published == false) is recognised, not '
      'just the `!` form',
      () {
        final v = run('''
          if (published == false) {
            await manager.confirmPublished(pending: p);
          } else {
            await manager.publishFailed(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('NEGATED condition'));
      },
    );

    test(
      'an inequality-form inversion (published != true) is recognised',
      () {
        final v = run('''
          if (published != true) {
            await manager.confirmPublished(pending: p);
          } else {
            await manager.publishFailed(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('NEGATED condition'));
      },
    );

    test(
      'the flipped operand order (false == published) is recognised too',
      () {
        final v = run('''
          if (false == published) {
            await manager.confirmPublished(pending: p);
          } else {
            await manager.publishFailed(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('NEGATED condition'));
      },
    );

    test('an unrelated equality is not mistaken for a negation', () {
      final v = run('''
        if (status == published) {
          await manager.confirmPublished(pending: p);
        } else {
          await manager.publishFailed(pending: p);
        }
      ''');
      expect(v, isEmpty);
    });

    test(
      'a receiver spelled anything other than `manager` is still checked — '
      'an else branch that fails to roll back is caught even though the '
      'variable is not the one every real call site in this file happens '
      'to use',
      () {
        final v = run('''
          if (published) {
            await circleManager.confirmPublished(pending: p);
          } else {
            debugPrint('nothing happens');
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('does not roll back'));
      },
    );

    test(
      'a direct field receiver (no local rebind at all) is still checked',
      () {
        final v = run('''
          if (published) {
            await _manager!.confirmPublished(pending: p);
          } else {
            await _manager!.publishFailed(pending: p);
            await _manager!.confirmPublished(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('ALSO confirms'));
      },
    );
  });

  group('checker self-tests — guard-clause pairing', () {
    List<PairingViolation> run(String body) {
      final parsed = parseString(
        content: 'class _S { Future<void> go() async { $body } }',
        throwIfDiagnostics: false,
      );
      return checkGuardClauses(parsed.unit, parsed.lineInfo);
    }

    test('a correctly paired guard clause has no violations', () {
      expect(
        run('''
          if (!published) {
            await manager.publishFailed(pending: p);
            throw const CircleServiceException('x');
          }
          await manager.confirmPublished(pending: p);
        '''),
        isEmpty,
      );
    });

    test('a guard ending in return is also accepted', () {
      expect(
        run('''
          if (!published) {
            await manager.publishFailed(pending: p);
            return;
          }
          await manager.confirmPublished(pending: p);
        '''),
        isEmpty,
      );
    });

    test(
      'flags the exact live-defect shape: confirm always runs, fail runs '
      'conditionally alongside it (no throw/return in the guard)',
      () {
        final v = run('''
          await manager.confirmPublished(pending: p);
          if (!published) {
            await manager.publishFailed(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('does not end in throw/return'));
      },
    );

    test('flags a guard with no confirm anywhere after it', () {
      final v = run('''
        if (!published) {
          await manager.publishFailed(pending: p);
          throw const CircleServiceException('x');
        }
      ''');
      expect(v, hasLength(1));
      expect(v.single.reason, contains('never resolved on the ack path'));
    });

    test(
      'flags an inverted guard condition even though every call is '
      'present, correctly shaped, and the guard exits cleanly — this is '
      'the exact "confirm on failure, roll back on success" shape',
      () {
        final v = run('''
          if (published) {
            await manager.publishFailed(pending: p);
            throw const CircleServiceException('x');
          }
          await manager.confirmPublished(pending: p);
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('NEGATED ack condition'));
      },
    );

    test(
      'flags the same inverted guard written in equality form '
      '(published == true)',
      () {
        final v = run('''
          if (published == true) {
            await manager.publishFailed(pending: p);
            throw const CircleServiceException('x');
          }
          await manager.confirmPublished(pending: p);
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('NEGATED ack condition'));
      },
    );

    test('does not double-report an if/else-shaped statement', () {
      // `elseStatement != null` routes this to the if/else checker instead.
      expect(
        run('''
          if (!published) {
            await manager.publishFailed(pending: p);
          } else {
            await manager.confirmPublished(pending: p);
          }
        '''),
        isEmpty,
      );
    });

    test(
      'a receiver spelled anything other than `manager` is still checked — '
      'a guard that falls through to an unconditional confirm is caught',
      () {
        final v = run('''
          await circleManager.confirmPublished(pending: p);
          if (!published) {
            await circleManager.publishFailed(pending: p);
          }
        ''');
        expect(v, hasLength(1));
        expect(v.single.reason, contains('does not end in throw/return'));
      },
    );
  });

  group('checker self-tests — receiver-name independence (_CallCounter)', () {
    // `_isManagerCall` no longer requires the receiver to be spelled
    // `manager` (see its doc comment); this pins that the inventory counter
    // that check feeds inherits the same independence, not just the two
    // structural checkers above.
    int countOf(String body, String methodName) {
      final parsed = parseString(
        content: 'class _S { Future<void> go() async { $body } }',
        throwIfDiagnostics: false,
      );
      final counter = _CallCounter();
      parsed.unit.accept(counter);
      return counter.counts[methodName] ?? 0;
    }

    test('counts a confirmPublished call on a differently-named receiver',
        () {
      expect(
        countOf(
          'await circleManager.confirmPublished(pending: p);',
          'confirmPublished',
        ),
        1,
      );
    });

    test('counts a publishFailed call reached via a direct field, no local '
        'rebind at all', () {
      expect(
        countOf(
          'await _manager!.publishFailed(pending: p);',
          'publishFailed',
        ),
        1,
      );
    });
  });

  group('repository scan: nostr_circle_service.dart', () {
    final file = File('lib/src/services/nostr_circle_service.dart');

    test('the target file exists at the expected path', () {
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}), or the file moved — update '
            'this guard to follow it rather than deleting it.',
      );
    });

    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    );

    test('no if/else pairing violation', () {
      final violations = checkIfElsePairs(parsed.unit, parsed.lineInfo);
      expect(
        violations,
        isEmpty,
        reason:
            'Rule 13: a staged commit must be confirmed on an ack and '
            'rolled back on anything short of one — never both, never '
            'neither.\n${violations.join('\n')}',
      );
    });

    test('no guard-clause pairing violation', () {
      final violations = checkGuardClauses(parsed.unit, parsed.lineInfo);
      expect(
        violations,
        isEmpty,
        reason:
            'Rule 13: the addMember failure guard must exit before it can '
            'fall through to the confirm below it, and that confirm must '
            'still exist.\n${violations.join('\n')}',
      );
    });

    test(
      'if/else pairing found exactly the three known decision blocks '
      '(anti-vacuity)',
      () {
        // createCircle, updateCircleRelays, and the shared _publishAndConfirm
        // helper (which alone covers removeMember and both leaveCircle admin
        // steps). Equality, not a floor: this repo's convention is that
        // slack lets a site be deleted silently — see MDK Rule-14 guard.
        final matches = _allIfStatements(parsed.unit)
            .where(
              (s) => _subtreeCallsAny(s.thenStatement, _confirmRoleMethods),
            )
            .length;
        expect(matches, 3);
      },
    );

    test(
      'guard-clause check found exactly one decision block (anti-vacuity)',
      () {
        // addMember is the only guard-clause-shaped resolution in this file.
        final matches = _allIfStatements(parsed.unit)
            .where(
              (s) =>
                  s.elseStatement == null &&
                  _subtreeCallsAny(s.thenStatement, {_failRoleMethod}) &&
                  !_subtreeCallsAny(s.thenStatement, _confirmRoleMethods),
            )
            .length;
        expect(matches, 1);
      },
    );

    test('publish-before-apply site inventory is pinned by count', () {
      // Deleting a call site (e.g. a stray `publishFailed` cleanup during
      // a refactor) changes a count here even when it doesn't happen to
      // trip one of the structural checks above.
      final counter = _CallCounter();
      parsed.unit.accept(counter);
      expect(
        counter.counts['confirmPublished'],
        4,
        reason: 'createCircle, addMember, _publishAndConfirm, and '
            'confirmPendingCommit.',
      );
      expect(
        counter.counts['publishFailed'],
        5,
        reason: 'createCircle, addMember, updateCircleRelays, '
            '_publishAndConfirm, and failPendingCommit.',
      );
      expect(
        counter.counts['finalizeRelayUpdate'],
        1,
        reason: "updateCircleRelays' confirm-role call.",
      );
    });

    test(
      'confirmPendingCommit / failPendingCommit stay unconditional '
      'passthroughs',
      () {
        // The receive-side ack DECISION must live entirely in the caller
        // (LocationSharingService._publishAndConfirmAutoCommit, tested
        // behaviourally in location_sharing_service_test.dart). If either
        // passthrough grows its own branching, that caller-side test no
        // longer covers the real decision.
        for (final name in [
          'confirmPendingCommit',
          'failPendingCommit',
        ]) {
          final finder = _MethodBodyFinder(name);
          parsed.unit.accept(finder);
          final method = finder.found;
          expect(
            method,
            isNotNull,
            reason: '$name no longer exists on NostrCircleService — update '
                'this guard to follow it rather than deleting it.',
          );
          expect(
            _allIfStatements(method!),
            isEmpty,
            reason: '$name has grown conditional logic; the ack decision '
                'must stay entirely in the caller.',
          );
        }
      },
    );
  });
}
