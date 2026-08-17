// Static guard for Security Rule 14: "Run exactly ONE live
// `AccountDeviceSession` per MLS DB file across all isolates/processes."
//
// Every `CircleManagerFfi.newInstance(...)` takes a CLAIM on the Rust
// `LIVE_SESSIONS` registry, and only `dispose()` drops it. Android runs the UI
// and the location foreground service as two Dart isolates inside ONE OS
// process sharing one loaded `.so`, so a handle that falls out of scope
// undisposed holds the claim until the process dies and every later open in
// EVERY isolate is refused with "an MLS session is already open on this
// database". One missed release is therefore not a leak in the leaking isolate;
// it is a process-wide denial of the database.
//
// `scripts/ci/check_mls_session_single_owner.sh` pins the three sanctioned
// opener files, the pause-time handoff latch, and a per-file release FLOOR. A
// floor is not a matching: the UI service releases its one handle on three exit
// paths, so under the count alone two further undisposed opens in that file
// still passed. This test is the matching the count cannot be. The count stays
// where it is as the fast toolchain-free backstop — it needs no Dart SDK, and
// it catches the limit case (an opener file that releases nothing) without
// depending on this file being correct.
//
// # What this proves
//
// For each open it resolves the handle to the name that OWNS it, following the
// three value-forwarding shapes this repo actually uses: the
// `withFreshSecret(provider, (secret) => newInstance(...))` closure (the helper
// returns `await use(secret)` verbatim — `lib/src/services/fresh_secret.dart`),
// a local `Future<CircleManagerFfi> open() => ...` declaration fanned out to
// its call sites, and `await` / parentheses. Then:
//
//   * LOCAL owner — a real matching. An abstract interpreter walks the owning
//     function's statements and requires the handle to be released on EVERY
//     explicit exit path: `dispose()` on the local, or transfer to a field.
//     A `return` reached with the handle still live is a violation, as is
//     falling off the end of the body. `finally` blocks are credited on the
//     paths they actually cover.
//   * FIELD owner — the field must be disposed somewhere in its class, and at
//     most ONE open may sink into it. Two opens into one field means one
//     overwrites the other, and an overwritten handle is unreachable and
//     therefore unreleasable.
//   * ANY OTHER SHAPE fails closed. A discarded result, a handle handed to
//     another call, a method that returns one — none can be followed from a
//     single file, so each is reported rather than passed over. Adding an open
//     in a shape this lint does not model makes it red, not blind.
//
//   * EXCEPTION EDGES. A throw between the open and the release strands the
//     claim exactly like a `return` does, so it is reported the same way. A
//     statement counts as a throw site when evaluating it involves an `await`
//     or an explicit `throw` — every FFI, platform and I/O call in this
//     codebase is an await, while a field read and a plain assignment are not,
//     which is what keeps the UI service's `_runInitialization` (whose window
//     spans `_wiped`, `_handoffHolds` and two assignments) off the list.
//     Closure BODIES are not descended into: they run when called, not here.
//     A `catch` does not discharge the obligation, it MOVES it: the clause is
//     entered in the state the raise left behind, so a handler that swallows
//     without releasing leaks on that path and is reported. The state is
//     probed, not read off the guarded body's end state — the body ENDS in the
//     state of the path that did not throw, which is what let
//     `try { await use(h); h.dispose(); } on Object catch (_) {}` read as
//     released on every path. `dispose()` is not a raise site, so the
//     best-effort `try { handle.dispose(); } on Object catch (_) {}` idiom is
//     still credited: its clause is unreachable.
//
// # Residual
//
// Two things this deliberately does not claim.
//
//   * A RETHROW is read as an ordinary statement, not as an exit. A clause that
//     rethrows while the handle is live therefore leaks along its own outward
//     edge without being reported, unless the same clause also falls out of the
//     function live. Modelling it needs the enclosing handler chain, which a
//     single-region walk does not have.
//   * FIELD LIFETIME across methods is existence, not per-path. That the field
//     is disposed in its class does not prove the disposal runs before the
//     object is dropped; proving that needs object-lifetime analysis no
//     single-file AST pass can do. The one-open-per-field rule is what stops
//     the count of opens outrunning the count of owners.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// One MLS session handle whose release could not be proved.
class SessionHandleViolation {
  SessionHandleViolation({
    required this.path,
    required this.line,
    required this.reason,
  });

  final String path;
  final int line;
  final String reason;

  @override
  String toString() => '$path:$line — $reason';
}

/// The outcome of analysing one compilation unit.
class SessionHandleScan {
  SessionHandleScan({required this.opens, required this.violations});

  /// How many `CircleManagerFfi.newInstance(...)` calls were seen. The
  /// anti-vacuity floor: a scan that finds none has gone blind.
  final int opens;

  final List<SessionHandleViolation> violations;
}

/// Whether [node] is an MLS session open.
///
/// `target` is `CircleManagerFfi` for a bare reference and a
/// [PrefixedIdentifier] for one reached through an import prefix —
/// `nostr_circle_service.dart` itself imports the same `rust/api.dart` a
/// second time `as frb_api` for other calls, so `frb_api.CircleManagerFfi
/// .newInstance(...)` is one keystroke away from the shape already in this
/// file, not a hypothetical one. Missing it would not merely misclassify
/// the open as [_Unowned] (still a violation) — it would make the open
/// invisible to the anti-vacuity floor too, i.e. fail OPEN rather than
/// closed.
bool _isOpen(MethodInvocation node) {
  if (node.methodName.name != 'newInstance') return false;
  final target = node.target;
  if (target is SimpleIdentifier) return target.name == 'CircleManagerFfi';
  if (target is PrefixedIdentifier) {
    return target.identifier.name == 'CircleManagerFfi';
  }
  return false;
}

/// The innermost enclosing function body of [node].
FunctionBody? _enclosingBody(AstNode node) {
  for (var cur = node.parent; cur != null; cur = cur.parent) {
    if (cur is MethodDeclaration) return cur.body;
    if (cur is FunctionDeclaration) return cur.functionExpression.body;
    if (cur is FunctionExpression) return cur.body;
  }
  return null;
}

/// The name assigned to by [lhs], or `null` if the target is not a plain
/// identifier this analysis can track (`a[i]`, `x.y.z`, ...).
String? _assignedName(Expression lhs) {
  if (lhs is SimpleIdentifier) return lhs.name;
  if (lhs is PropertyAccess && lhs.target is ThisExpression) {
    return lhs.propertyName.name;
  }
  if (lhs is PrefixedIdentifier && lhs.prefix.name == 'this') {
    return lhs.identifier.name;
  }
  return null;
}

/// Every local name declared directly in [body] — parameters included, nested
/// closures excluded, so a name declared only inside a closure is not mistaken
/// for a local of the outer function.
Set<String> _localNames(FunctionBody body) {
  final finder = _LocalNameFinder(body);
  body.accept(finder);
  final owner = body.parent;
  if (owner is FunctionExpression) {
    for (final p in owner.parameters?.parameters ?? const <FormalParameter>[]) {
      final name = p.name;
      if (name != null) finder.names.add(name.lexeme);
    }
  }
  if (owner is MethodDeclaration) {
    for (final p in owner.parameters?.parameters ?? const <FormalParameter>[]) {
      final name = p.name;
      if (name != null) finder.names.add(name.lexeme);
    }
  }
  return finder.names;
}

class _LocalNameFinder extends RecursiveAstVisitor<void> {
  _LocalNameFinder(this._body);

  final FunctionBody _body;
  final Set<String> names = {};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (identical(_enclosingBody(node), _body)) names.add(node.name.lexeme);
    super.visitVariableDeclaration(node);
  }
}

/// Where an open's handle comes to rest.
sealed class _Owner {
  const _Owner();
}

/// The handle is bound to a local of [body].
class _LocalOwner extends _Owner {
  const _LocalOwner(this.name, this.body, this.binding);

  final String name;
  final FunctionBody body;
  final AstNode binding;
}

/// The handle is stored in a field named [name], declared in [scope] (the
/// enclosing class, or the compilation unit for a top-level field).
class _FieldOwner extends _Owner {
  const _FieldOwner(this.name, this.scope);

  final String name;
  final AstNode scope;
}

/// The handle escapes in a shape this analysis cannot follow.
class _Unowned extends _Owner {
  const _Unowned(this.reason);

  final String reason;
}

/// The scope a field named in [node] belongs to: its class, or the whole unit.
AstNode _fieldScope(AstNode node) =>
    node.thisOrAncestorOfType<ClassDeclaration>() ??
    node.thisOrAncestorOfType<CompilationUnit>()!;

/// Resolves every owner an open's handle can reach.
///
/// Returns more than one owner only via the local-`open()`-declaration fan-out,
/// where a single `newInstance` feeds several call sites.
List<_Owner> _resolveOwners(MethodInvocation open) {
  final owners = <_Owner>[];
  final seen = <int>{};
  final queue = <Expression>[open];

  while (queue.isNotEmpty) {
    final value = queue.removeLast();
    if (!seen.add(value.offset)) continue;
    owners.addAll(_consume(value, queue));
  }
  return owners;
}

/// Classifies what happens to [value], pushing onward-flowing expressions onto
/// [queue].
List<_Owner> _consume(Expression value, List<Expression> queue) {
  final parent = value.parent;
  switch (parent) {
    case null:
      return const [_Unowned('the handle is not consumed by anything')];

    case AwaitExpression() || ParenthesizedExpression():
      queue.add(parent as Expression);
      return const [];

    case VariableDeclaration():
      final body = _enclosingBody(parent);
      if (body == null) {
        return const [_Unowned('bound outside any function body')];
      }
      return [_LocalOwner(parent.name.lexeme, body, parent)];

    case AssignmentExpression():
      final name = _assignedName(parent.leftHandSide);
      final body = _enclosingBody(parent);
      if (name == null || body == null) {
        return const [_Unowned('assigned to a target that cannot be tracked')];
      }
      return _localNames(body).contains(name)
          ? [_LocalOwner(name, body, parent)]
          : [_FieldOwner(name, _fieldScope(parent))];

    // The handle is the value of a function body — either the closure handed
    // to `withFreshSecret`, or a local `open()` declaration.
    case ExpressionFunctionBody() || ReturnStatement():
      final body = parent.thisOrAncestorOfType<FunctionBody>();
      if (body == null) return const [_Unowned('returned from nothing')];
      return _fromFunctionBody(body, queue);

    case ExpressionStatement():
      return const [
        _Unowned('the handle is discarded — nothing can ever dispose it'),
      ];

    case ArgumentList():
      return const [
        _Unowned('the handle is handed to another call, so its release cannot '
            'be followed from this file; bind it to a local or a field'),
      ];

    default:
      return const [
        _Unowned('the handle escapes in a shape this lint does not model; '
            'bind it to a local or a field, or teach the lint the shape'),
      ];
  }
}

/// Follows a handle that is the value of [body] out to whatever consumes that
/// function's result.
List<_Owner> _fromFunctionBody(FunctionBody body, List<Expression> queue) {
  final fn = body.parent;
  if (fn is! FunctionExpression) {
    return const [_Unowned('a method returning a handle escapes this file')];
  }
  final holder = fn.parent;

  // `withFreshSecret(provider, (secret) => newInstance(...))` — the helper
  // returns `await use(secret)` unchanged, so its result IS the handle.
  if (holder is ArgumentList) {
    final call = holder.parent;
    if (call is MethodInvocation && call.methodName.name == 'withFreshSecret') {
      queue.add(call);
      return const [];
    }
    return const [
      _Unowned('a closure returning a handle is passed to an unmodelled call'),
    ];
  }

  // `Future<CircleManagerFfi> open() => ...;` — every call site receives it.
  if (holder is FunctionDeclaration) {
    final outer = _enclosingBody(holder);
    if (outer == null) {
      return const [_Unowned('a top-level function returns a handle')];
    }
    final calls = _InvocationFinder(holder.name.lexeme);
    outer.accept(calls);
    if (calls.found.isEmpty) {
      return [
        _Unowned('`${holder.name.lexeme}()` opens a session but is never '
            'called; the open is unreachable or the lint is stale'),
      ];
    }
    queue.addAll(calls.found);
    return const [];
  }

  return const [_Unowned('a closure returning a handle escapes this file')];
}

class _InvocationFinder extends RecursiveAstVisitor<void> {
  _InvocationFinder(this._name);

  final String _name;
  final List<MethodInvocation> found = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // Unqualified only: `open()`, never `other.open()`. Nested closures are
    // searched too — a call from inside one still binds a handle somewhere, and
    // that binding's own enclosing body is what the owner resolves against.
    if (node.target == null && node.methodName.name == _name) {
      found.add(node);
    }
    super.visitMethodInvocation(node);
  }
}

// ---------------------------------------------------------------------------
// Local-owner matching
// ---------------------------------------------------------------------------

/// A program point that drops an outstanding release obligation.
class _Leak {
  const _Leak(this.offset, {required this.throwSite});

  final int offset;

  /// True for an implicit exception edge, false for an explicit `return`.
  final bool throwSite;
}

/// Whether evaluating [node] can raise.
///
/// An `await` or an explicit `throw` counts; nothing else does. Every FFI,
/// platform and I/O call in this codebase is an await, so this is where a throw
/// realistically comes from — while a field read and a plain assignment are
/// not throw sites, which is what keeps `_runInitialization`'s window off the
/// list (see the header). Closure BODIES are skipped: they run when the closure
/// is called, not where it is written.
bool _throwsWhenEvaluated(AstNode? node) {
  if (node == null) return false;
  final finder = _ThrowSiteFinder();
  node.accept(finder);
  return finder.found;
}

class _ThrowSiteFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    found = true;
    super.visitAwaitExpression(node);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    found = true;
    super.visitThrowExpression(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

/// Whether an outstanding release obligation exists at a program point.
enum _Flow {
  /// Nothing to release: the handle is unbound here, or already released.
  clear,

  /// The handle is live and must be released before this path exits.
  live,

  /// Control does not reach the next statement (`return`, `break`, `throw`).
  gone,
}

_Flow _join(_Flow a, _Flow b) {
  if (a == _Flow.gone) return b;
  if (b == _Flow.gone) return a;
  return a == _Flow.live || b == _Flow.live ? _Flow.live : _Flow.clear;
}

/// Everything the statement walk needs about one tracked local.
class _Tracked {
  _Tracked({
    required this.binds,
    required this.releases,
    required this.transfers,
  });

  /// Offsets of the nodes that bind the handle to the local.
  final Set<int> binds;

  /// Offsets of the nodes that release it — `dispose()` or a field transfer.
  final Set<int> releases;

  /// Fields the handle is transferred into, which then own it.
  final List<_FieldOwner> transfers;
}

/// Collects the bind and release sites of local [name] directly in [body].
_Tracked _track(String name, FunctionBody body, Iterable<AstNode> bindings) {
  final collector = _ReleaseFinder(name, body);
  body.accept(collector);
  return _Tracked(
    binds: {for (final b in bindings) b.offset},
    releases: collector.releases,
    transfers: collector.transfers,
  );
}

class _ReleaseFinder extends RecursiveAstVisitor<void> {
  _ReleaseFinder(this._name, this._body);

  final String _name;
  final FunctionBody _body;
  final Set<int> releases = {};
  final List<_FieldOwner> transfers = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (node.methodName.name == 'dispose' &&
        target is SimpleIdentifier &&
        target.name == _name &&
        identical(_enclosingBody(node), _body)) {
      releases.add(node.offset);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final rhs = node.rightHandSide;
    final lhs = _assignedName(node.leftHandSide);
    if (rhs is SimpleIdentifier &&
        rhs.name == _name &&
        lhs != null &&
        !_localNames(_body).contains(lhs) &&
        identical(_enclosingBody(node), _body)) {
      releases.add(node.offset);
      transfers.add(_FieldOwner(lhs, _fieldScope(node)));
    }
    super.visitAssignmentExpression(node);
  }
}

/// Walks [statements] from [state], reporting any exit that still owes a
/// release. [reportExits] is false while probing a `finally` block, and while
/// walking a region whose `finally` releases on every way out of it.
/// [reportThrows] is additionally false inside a `try` that has a `catch`,
/// which intercepts the exception edge (see the header's residual).
_Flow _walk(
  List<Statement> statements,
  _Flow state,
  _Tracked tracked,
  List<_Leak> leaks, {
  required bool reportExits,
  required bool reportThrows,
}) {
  var flow = state;
  for (final statement in statements) {
    if (flow == _Flow.gone) break;
    flow = _walkOne(
      statement,
      flow,
      tracked,
      leaks,
      reportExits: reportExits,
      reportThrows: reportThrows,
    );
  }
  return flow;
}

/// Whether an exception raised anywhere in [statements] could leave the handle
/// live, starting from [state].
///
/// That is exactly what a reported throw-site leak means, so this walks the
/// region asking for them and throws the report away — the caller wants the
/// fact, not a second copy of the diagnostic. A nested `try` that intercepts,
/// or a nested `finally` that releases, suppresses its own sites for the same
/// reasons it does in the real walk.
bool _raisesWhileLive(
  List<Statement> statements,
  _Flow state,
  _Tracked tracked,
) {
  final probe = <_Leak>[];
  _walk(
    statements,
    state,
    tracked,
    probe,
    reportExits: false,
    reportThrows: true,
  );
  return probe.any((leak) => leak.throwSite);
}

_Flow _walkOne(
  Statement statement,
  _Flow state,
  _Tracked tracked,
  List<_Leak> leaks, {
  required bool reportExits,
  required bool reportThrows,
}) {
  // An exception edge is an exit like any other: the handle is live, control
  // leaves, and nothing released it. Reported against the state in which the
  // expression is EVALUATED, so the binding statement — where the handle does
  // not exist yet if the open itself throws — is not a leak.
  void throwEdge(_Flow at, AstNode? evaluated) {
    if (at == _Flow.live &&
        reportThrows &&
        _throwsWhenEvaluated(evaluated)) {
      leaks.add(_Leak(evaluated!.offset, throwSite: true));
    }
  }

  switch (statement) {
    case Block():
      return _walk(
        statement.statements,
        state,
        tracked,
        leaks,
        reportExits: reportExits,
        reportThrows: reportThrows,
      );

    case LabeledStatement():
      return _walkOne(
        statement.statement,
        state,
        tracked,
        leaks,
        reportExits: reportExits,
        reportThrows: reportThrows,
      );

    case IfStatement():
      // `expression`, not `condition`: an `if` can carry a pattern
      // (`if (x case P)`), so the analyzer names the tested value generically.
      throwEdge(state, statement.expression);
      final taken = _walkOne(
        statement.thenStatement,
        state,
        tracked,
        leaks,
        reportExits: reportExits,
        reportThrows: reportThrows,
      );
      final other = statement.elseStatement == null
          ? state
          : _walkOne(
              statement.elseStatement!,
              state,
              tracked,
              leaks,
              reportExits: reportExits,
              reportThrows: reportThrows,
            );
      return _join(taken, other);

    case TryStatement():
      final block = statement.finallyBlock;
      // A `finally` that releases covers every way out of the guarded region,
      // including the `return`s inside it. Probe it in isolation first.
      final covered = block != null &&
          _walk(
            block.statements,
            _Flow.live,
            tracked,
            leaks,
            reportExits: false,
            reportThrows: false,
          ) ==
              _Flow.clear;
      final inner = reportExits && !covered;
      // A `catch` intercepts the throw, so the guarded body is not an
      // UNPROTECTED window. The obligation is not discharged by that, only
      // moved: it is carried into the clauses below, which are entered in the
      // state the raise left behind.
      final innerThrows =
          reportThrows && !covered && statement.catchClauses.isEmpty;
      var out = _walk(
        statement.body.statements,
        state,
        tracked,
        leaks,
        reportExits: inner,
        reportThrows: innerThrows,
      );
      // Which state that is: probe the body for throw-site leaks, discarding
      // them. A leak means some raise inside the body would find the handle
      // live, so the clauses inherit `live` — an intercepted exception is only
      // handled if the handler releases. Probed rather than read off `out`
      // because the body's END state is the state of the path that did NOT
      // throw: in `try { await use(h); h.dispose(); } on Object catch (_) {}`
      // that is `clear`, while the throwing path strands the claim.
      final raisedLive =
          _raisesWhileLive(statement.body.statements, state, tracked);
      for (final clause in statement.catchClauses) {
        // Apart from that, a clause inherits nothing from the guarded body —
        // only what it itself binds or releases counts. Inheriting the ENTRY
        // state instead would make the best-effort
        // `try { handle.dispose(); } on Object catch (_)` idiom read as a path
        // that never released, because `dispose()` is not a raise site.
        out = _join(
          out,
          _walk(
            clause.body.statements,
            raisedLive ? _Flow.live : _Flow.clear,
            tracked,
            leaks,
            reportExits: inner,
            reportThrows: reportThrows && !covered,
          ),
        );
      }
      if (block == null) return out;
      final after = _walk(
        block.statements,
        out == _Flow.gone ? _Flow.clear : out,
        tracked,
        leaks,
        reportExits: reportExits,
        reportThrows: reportThrows,
      );
      return out == _Flow.gone ? _Flow.gone : after;

    case WhileStatement():
      // The body may run zero times, so its effect only ever joins with the
      // state that entered the loop.
      throwEdge(state, statement.condition);
      return _join(
        state,
        _walkOne(
          statement.body,
          state,
          tracked,
          leaks,
          reportExits: reportExits,
          reportThrows: reportThrows,
        ),
      );

    case ForStatement():
      throwEdge(state, statement.forLoopParts);
      return _join(
        state,
        _walkOne(
          statement.body,
          state,
          tracked,
          leaks,
          reportExits: reportExits,
          reportThrows: reportThrows,
        ),
      );

    case DoStatement():
      final out = _walkOne(
        statement.body,
        state,
        tracked,
        leaks,
        reportExits: reportExits,
        reportThrows: reportThrows,
      );
      // The condition runs AFTER the body, so it is judged against what the
      // body left behind, not against the entry state.
      throwEdge(out, statement.condition);
      return out;

    case SwitchStatement():
      throwEdge(state, statement.expression);
      var out = state;
      for (final member in statement.members) {
        out = _join(
          out,
          _walk(
            member.statements,
            state,
            tracked,
            leaks,
            reportExits: reportExits,
            reportThrows: reportThrows,
          ),
        );
      }
      return out;

    case ReturnStatement():
      throwEdge(state, statement.expression);
      if (state == _Flow.live && reportExits) {
        leaks.add(_Leak(statement.offset, throwSite: false));
      }
      return _Flow.gone;

    case BreakStatement() || ContinueStatement():
      return _Flow.gone;

    default:
      // A leaf. Its whole subtree is evaluated here, so it is judged against
      // the state on ENTRY — before the bind below can re-arm the obligation.
      throwEdge(state, statement);
      // Binding wins over releasing: a statement that does both has re-armed
      // the obligation by the time control leaves it.
      final span = (statement.offset, statement.end);
      if (tracked.binds.any((o) => o >= span.$1 && o < span.$2)) {
        return _Flow.live;
      }
      if (tracked.releases.any((o) => o >= span.$1 && o < span.$2)) {
        return _Flow.clear;
      }
      return state;
  }
}

// ---------------------------------------------------------------------------
// Field-owner check
// ---------------------------------------------------------------------------

/// Whether `<name>.dispose()` or `<name>?.dispose()` appears in [scope].
bool _disposesField(AstNode scope, String name) {
  final finder = _FieldDisposalFinder(name);
  scope.accept(finder);
  return finder.found;
}

class _FieldDisposalFinder extends RecursiveAstVisitor<void> {
  _FieldDisposalFinder(this._name);

  final String _name;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'dispose') {
      final target = node.target;
      final named = target is SimpleIdentifier
          ? target.name
          : target is PropertyAccess && target.target is ThisExpression
              ? target.propertyName.name
              : target is PrefixedIdentifier && target.prefix.name == 'this'
                  ? target.identifier.name
                  : null;
      if (named == _name) found = true;
    }
    super.visitMethodInvocation(node);
  }
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

/// Finds every MLS session open in [source] whose release cannot be proved.
SessionHandleScan analyzeSessionHandles(
  String source, {
  String path = '<memory>',
}) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final finder = _OpenFinder();
  parsed.unit.accept(finder);

  final violations = <SessionHandleViolation>[];
  // Keyed by "<scope offset>#<field>": one open per field, or an overwrite
  // strands the handle it replaced.
  final fieldSinks = <String, List<MethodInvocation>>{};

  SessionHandleViolation at(AstNode node, String reason) =>
      SessionHandleViolation(
        path: path,
        line: parsed.lineInfo.getLocation(node.offset).lineNumber,
        reason: reason,
      );

  void checkField(_FieldOwner owner, MethodInvocation open) {
    fieldSinks
        .putIfAbsent('${owner.scope.offset}#${owner.name}', () => [])
        .add(open);
    if (!_disposesField(owner.scope, owner.name)) {
      violations.add(
        at(
          open,
          'the handle is stored in `${owner.name}`, which is never '
          'disposed in its class — the Rule-14 claim outlives the process',
        ),
      );
    }
  }

  for (final open in finder.opens) {
    // Several call sites of one local `open()` declaration share a local
    // owner; walk each distinct (name, body) once.
    final walked = <String>{};
    for (final owner in _resolveOwners(open)) {
      switch (owner) {
        case _Unowned(:final reason):
          violations.add(at(open, reason));

        case _FieldOwner():
          checkField(owner, open);

        case _LocalOwner(:final name, :final body):
          if (body is! BlockFunctionBody) {
            violations.add(
              at(open, 'bound to `$name` in a body with no statements to walk'),
            );
            continue;
          }
          final bindings = _resolveOwners(open)
              .whereType<_LocalOwner>()
              .where((o) => o.name == name && identical(o.body, body))
              .map((o) => o.binding);
          if (!walked.add('$name@${body.offset}')) continue;
          final tracked = _track(name, body, bindings);
          final leaks = <_Leak>[];
          final end = _walk(
            body.block.statements,
            _Flow.clear,
            tracked,
            leaks,
            reportExits: true,
            reportThrows: true,
          );
          for (final leak in leaks) {
            violations.add(
              SessionHandleViolation(
                path: path,
                line: parsed.lineInfo.getLocation(leak.offset).lineNumber,
                reason: leak.throwSite
                    ? 'an exception here would leak `$name` — nothing between '
                        'the open and the disposal intercepts it; wrap the '
                        'region in a try whose finally disposes'
                    : 'returns while `$name` still holds an undisposed MLS '
                        'session handle',
              ),
            );
          }
          if (end == _Flow.live) {
            violations.add(
              at(
                open,
                '`$name` is still live where its function ends — dispose it '
                'or transfer it to a field that is disposed',
              ),
            );
          }
          for (final transfer in tracked.transfers) {
            checkField(transfer, open);
          }
      }
    }
  }

  for (final entry in fieldSinks.entries) {
    if (entry.value.length < 2) continue;
    final field = entry.key.split('#').last;
    for (final open in entry.value) {
      violations.add(
        at(
          open,
          '`$field` is the sink of ${entry.value.length} opens; whichever '
          'assignment runs second strands the handle the first stored',
        ),
      );
    }
  }

  return SessionHandleScan(opens: finder.opens.length, violations: violations);
}

class _OpenFinder extends RecursiveAstVisitor<void> {
  final List<MethodInvocation> opens = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_isOpen(node)) opens.add(node);
    super.visitMethodInvocation(node);
  }
}

void main() {
  group('detector self-tests', () {
    test('permits a local disposed in a finally that guards the whole body',
        () {
      const source = '''
Future<void> task() async {
  final circleManager = await withFreshSecret(
    provider,
    (secret) => CircleManagerFfi.newInstance(dataDir: d, identitySecretBytes: secret),
  );
  try {
    await use(circleManager);
  } finally {
    circleManager.dispose();
  }
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.opens, 1);
      expect(scan.violations, isEmpty);
    });

    test('credits a best-effort disposal wrapped in its own try/catch', () {
      const source = '''
Future<void> task() async {
  final circleManager = await CircleManagerFfi.newInstance(dataDir: d);
  try {
    await use(circleManager);
  } finally {
    try {
      circleManager.dispose();
    } on Object catch (_) {}
  }
}
''';
      expect(analyzeSessionHandles(source).violations, isEmpty);
    });

    test('flags a local that is never disposed', () {
      const source = '''
Future<void> task() async {
  final circleManager = await CircleManagerFfi.newInstance(dataDir: d);
  await use(circleManager);
}
''';
      final scan = analyzeSessionHandles(source);
      // Two distinct program points, not one defect counted twice: the handle
      // is unreleased where the function ends, AND it is live across an
      // unprotected await before that.
      expect(scan.violations, hasLength(2));
      expect(
        scan.violations.map((v) => v.reason),
        containsAll(<Matcher>[
          contains('still live'),
          contains('an exception here'),
        ]),
      );
    });

    test('flags an early return that skips the only disposal', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  if (wiped) {
    return;
  }
  manager.dispose();
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('returns while'));
    });

    test('permits an early return that disposes on its own path', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  if (wiped) {
    manager.dispose();
    return;
  }
  manager.dispose();
}
''';
      expect(analyzeSessionHandles(source).violations, isEmpty);
    });

    test('a conditional disposal does not cover the fall-through path', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  if (wiped) {
    manager.dispose();
  }
}
''';
      final scan = analyzeSessionHandles(source);
      expect(
        scan.violations,
        hasLength(1),
        reason: 'source order alone would find the dispose and clear this',
      );
      expect(scan.violations.single.reason, contains('still live'));
    });

    test('follows the withFreshSecret closure and the local open() fan-out',
        () {
      const source = '''
class S {
  Future<void> run() async {
    Future<CircleManagerFfi> open() => withFreshSecret(
      provider,
      (secret) => CircleManagerFfi.newInstance(dataDir: d, identitySecretBytes: secret),
    );
    CircleManagerFfi manager;
    try {
      manager = await open();
    } on Object {
      manager = await open();
    }
    if (wiped) {
      manager.dispose();
      return;
    }
    _manager = manager;
  }

  Future<void> close() async {
    _manager?.dispose();
  }
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.opens, 1);
      expect(scan.violations, isEmpty);
    });

    test('a transfer to a field the class never disposes is a violation', () {
      const source = '''
class S {
  Future<void> run() async {
    final manager = await CircleManagerFfi.newInstance(dataDir: d);
    _manager = manager;
  }

  void close() {
    _manager = null;
  }
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('never '));
    });

    test('two opens into one field are flagged even though it is disposed', () {
      const source = '''
class S {
  Future<void> a() async {
    _manager = await CircleManagerFfi.newInstance(dataDir: d);
  }

  Future<void> b() async {
    _manager = await CircleManagerFfi.newInstance(dataDir: d);
  }

  void close() {
    _manager?.dispose();
  }
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.opens, 2);
      expect(scan.violations, hasLength(2));
      expect(scan.violations.first.reason, contains('sink of 2 opens'));
    });

    test('a discarded open has no owner at all and fails closed', () {
      const source = '''
Future<void> task() async {
  await CircleManagerFfi.newInstance(dataDir: d);
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('discarded'));
    });

    test('a handle handed straight to another call fails closed', () {
      const source = '''
Future<void> task() async {
  register(await CircleManagerFfi.newInstance(dataDir: d));
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('handed to another call'));
    });

    test('a disposal in a sibling method cannot clear a local here', () {
      const source = '''
class S {
  Future<void> safe() async {
    final manager = await CircleManagerFfi.newInstance(dataDir: d);
    manager.dispose();
  }

  Future<void> unsafe() async {
    final manager = await CircleManagerFfi.newInstance(dataDir: d);
    await use(manager);
  }
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.opens, 2);
      final unsafeLine =
          source.substring(0, source.indexOf('unsafe()')).split('\n').length;
      expect(
        scan.violations.map((v) => v.line),
        everyElement(greaterThan(unsafeLine)),
        reason: 'a whole-file search for `manager.dispose()` would clear both, '
            'and a whole-file search for the LEAK would report safe() too',
      );
      // Both of unsafe()'s program points, and neither of safe()'s.
      expect(scan.violations, hasLength(2));
    });

    test(
      'an open reached through an import prefix is seen and, when '
      'discarded, flagged — not silently invisible to the opens count',
      () {
        // `nostr_circle_service.dart` already imports the same rust/api.dart
        // a second time `as frb_api` for other calls, so this shape is one
        // keystroke away, not hypothetical.
        const source = '''
Future<void> task() async {
  await frb_api.CircleManagerFfi.newInstance(dataDir: d);
}
''';
        final scan = analyzeSessionHandles(source);
        expect(
          scan.opens,
          1,
          reason: 'a prefixed open must still count toward the anti-vacuity '
              'floor',
        );
        expect(scan.violations, hasLength(1));
        expect(scan.violations.single.reason, contains('discarded'));
      },
    );

    test('an await between the open and the only disposal is a leak', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  await publish(manager);
  manager.dispose();
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('an exception here'));
    });

    test('the same await inside a try whose finally disposes is permitted', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  try {
    await publish(manager);
  } finally {
    manager.dispose();
  }
}
''';
      expect(analyzeSessionHandles(source).violations, isEmpty);
    });

    test('a catch that swallows the throw without releasing is a leak, not a '
        'credit', () {
      // The idiom above with `finally` replaced by `catch`: the non-throwing
      // path disposes, so the body ENDS clear, and reading the credit off that
      // end state passed this. `publish` throwing skips the disposal and holds
      // the Rule-14 claim for the life of the process, with the swallow making
      // it silent as well.
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  try {
    await publish(manager);
    manager.dispose();
  } on Object catch (_) {}
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('still live'));
    });

    test('a catch that does release on the exception path is credited', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  try {
    await publish(manager);
    manager.dispose();
  } on Object catch (_) {
    manager.dispose();
  }
}
''';
      expect(analyzeSessionHandles(source).violations, isEmpty);
    });

    test('field reads and plain assignments between open and transfer are not '
        'throw sites', () {
      const source = '''
class S {
  Future<void> run() async {
    final manager = await CircleManagerFfi.newInstance(dataDir: d);
    if (_wiped || _handoffHolds) {
      manager.dispose();
      return;
    }
    _handedOff = false;
    _manager = manager;
  }

  Future<void> close() async {
    _manager?.dispose();
  }
}
''';
      expect(analyzeSessionHandles(source).violations, isEmpty);
    });

    test('a disposal inside a nested closure does not release the local', () {
      const source = '''
Future<void> task() async {
  final manager = await CircleManagerFfi.newInstance(dataDir: d);
  register(() => manager.dispose());
}
''';
      final scan = analyzeSessionHandles(source);
      expect(scan.violations, hasLength(1));
      expect(scan.violations.single.reason, contains('still live'));
    });
  });

  group('repository scan', () {
    test('every MLS session open in lib/ is released on every path', () {
      final libDir = Directory('lib');
      expect(
        libDir.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );

      final sep = Platform.pathSeparator;
      final offenders = <String>[];
      var scanned = 0;
      var opens = 0;

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Generated FFI bindings — they DEFINE `newInstance`, never call it.
        if (entity.path.contains('${sep}rust$sep')) continue;
        scanned++;

        final scan = analyzeSessionHandles(
          entity.readAsStringSync(),
          path: entity.path,
        );
        opens += scan.opens;
        offenders.addAll(scan.violations.map((v) => v.toString()));
      }

      expect(
        scanned,
        greaterThan(50),
        reason: 'Only scanned $scanned files — the lib/ glob looks broken.',
      );
      expect(
        opens,
        greaterThanOrEqualTo(3),
        reason: 'Found $opens MLS session opens; the three sanctioned openers '
            '(pinned by scripts/ci/check_mls_session_single_owner.sh) each '
            'have one, so this detector has gone blind.',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'Security Rule 14: a CircleManagerFfi handle that is not disposed '
            'holds the Rust LIVE_SESSIONS claim until the process dies, and '
            'every later open in every isolate is then refused with "an MLS '
            'session is already open on this database".\n'
            'Offenders:\n  ${offenders.join('\n  ')}',
      );
    });
  });
}
