// A background burst runs while the app is PAUSED, and a paused app renders
// no frames.
//
// That one fact invalidates the default Riverpod reflex. `ref.watch` makes the
// reading widget/provider rebuild when the watched value changes — and a
// rebuild is a frame. While the process is backgrounded on iOS holding the
// location keep-alive, timers and futures still run but nothing rebuilds, so a
// `ref.watch` on the burst path reads its value ONCE, at install time, and
// then silently never updates. The consent toggle, the circle roster and the
// relay set would all freeze at whatever they were when the app went away.
//
// Nothing about that failure is visible: no exception, no dropped publish, no
// log line — a burst simply keeps acting on a stale value for the whole
// background window. So it is pinned statically, on the files a burst executes:
//
//   * `background_burst_coordinator.dart` — must not touch Riverpod at all.
//     It takes injected collaborators precisely so that the burst sequence is
//     executable, and testable, without a container.
//   * the two schedulers a burst calls into — no `ref.watch` outside `build()`.
//     `build()` is exempt because it only ever runs in the foreground, on a
//     frame, and that is where a scheduler is SUPPOSED to react to the roster.
//
// ## The coordinator promises three things, not one
//
// Its header documents no Riverpod, **no `Timer` of its own**, and **no FFI
// call**. Only the first was pinned, in the one phase whose entire purpose is
// removing background wake sources: a `Timer.periodic` dropped into the burst
// passed this lint, every targeted test, and `flutter analyze`.
//
// **No timer.** The coordinator legitimately awaits `Future.delayed` for the
// inter-publish stagger gap, which is a `Timer` underneath, so "no Timer" has
// to be drawn on what a timer DOES rather than on what it is made of. The line
// is whether work is scheduled to run after the scheduling call returns:
//
//   * `Timer`, in any shape — construction, `Timer.periodic`, a `Timer` field —
//     hands a callback to the event loop and returns. Banned outright.
//   * `Stream.periodic` — recurring by definition. Banned.
//   * `Future.delayed` NOT directly awaited — `unawaited(...)`, a bare
//     statement, a `.then` chain, an assignment — is a callback handed to the
//     event loop, which is what re-arming from inside a burst looks like.
//     Banned.
//   * `await Future.delayed(gap)` — the awaiting frame is suspended for the
//     gap and nothing else is scheduled. It cannot wake anything: the burst is
//     already running and already holding the process awake. Allowed, and its
//     presence in the real file is asserted, so the rule is not passing by
//     seeing nothing.
//
// **No FFI.** The coordinator may name the generated bindings only to READ a
// value an injected interface handed back (`outcome == BacklogOutcomeFfi.x`).
// Importing them without a `show`, naming one in a type, constructing one or
// calling a static on one all mean an FFI object is being held or called here
// and the injected-collaborator shape is broken. `dart:ffi` itself is banned.
// The bound is honest but partial: an FFI call reached THROUGH an injected
// interface is invisible to any syntactic check, and that indirection is
// exactly the shape this file exists to have.
//
// Every checker is self-tested in both directions against fixtures it has
// never seen, an inventory pass proves it still sees the real `ref.` call
// sites, and each new checker is additionally fired against the REAL
// coordinator with a mutation spliced into it — a fixture proves a checker
// CAN fire, only a mutation of the guarded file proves it fires THERE.
@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// The coordinator: no Riverpod, no timer, no FFI.
const _coordinator = 'lib/src/services/background_burst_coordinator.dart';

/// Everything else a burst calls into. `build()` is exempt (see the header).
///
/// Deliberately NOT subject to the timer rule: a scheduler's whole job is to
/// own the timers, so that the coordinator does not.
const _burstPath = <String>[
  'lib/src/providers/location_publish_scheduler_provider.dart',
  'lib/src/providers/maintenance_scheduler_provider.dart',
];

/// One `ref.<member>` use, with the method that encloses it.
class RefUse {
  RefUse(this.line, this.member, this.enclosing);

  /// Line of the `ref.` use.
  final int line;

  /// `watch`, `read`, `listen`, …
  final String member;

  /// Name of the enclosing method/function declaration, or `<top-level>`.
  final String enclosing;

  @override
  String toString() => 'line $line: ref.$member in $enclosing()';
}

/// One thing the coordinator may not do, and where.
class Finding {
  Finding(this.line, this.what);

  /// Line of the offending construct.
  final int line;

  /// What it is, and why it is not allowed here.
  final String what;

  @override
  String toString() => 'line $line: $what';
}

class _RefCollector extends RecursiveAstVisitor<void> {
  _RefCollector(this.lines, this.out);

  final LineInfo lines;
  final List<RefUse> out;

  /// Name of the declaration currently being walked.
  String _enclosing = '<top-level>';

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final previous = _enclosing;
    _enclosing = node.name.lexeme;
    super.visitMethodDeclaration(node);
    _enclosing = previous;
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final previous = _enclosing;
    _enclosing = node.name.lexeme;
    super.visitFunctionDeclaration(node);
    _enclosing = previous;
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    _record(node.target, node.propertyName.name, node.offset);
    super.visitPropertyAccess(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _record(node.target, node.methodName.name, node.offset);
    super.visitMethodInvocation(node);
  }

  /// `ref..watch(p)..read(q)` — every section has an IMPLICIT (null) target,
  /// so [_record] alone would see none of them. Both schedulers already write
  /// their `build()` this way, so this is the shape a real regression would
  /// most likely take.
  @override
  void visitCascadeExpression(CascadeExpression node) {
    final text = node.target.toSource();
    if (text == 'ref' || text == 'this.ref') {
      for (final section in node.cascadeSections) {
        final member = switch (section) {
          MethodInvocation(:final methodName) => methodName.name,
          PropertyAccess(:final propertyName) => propertyName.name,
          _ => null,
        };
        if (member == null) continue;
        out.add(
          RefUse(
            lines.getLocation(section.offset).lineNumber,
            member,
            _enclosing,
          ),
        );
      }
    }
    super.visitCascadeExpression(node);
  }

  void _record(Expression? target, String member, int offset) {
    // `ref.x`, `this.ref.x` and the cascade `ref..x` all reduce to a target
    // whose source text ends in `ref`.
    final text = target?.toSource();
    if (text != 'ref' && text != 'this.ref') return;
    out.add(
      RefUse(lines.getLocation(offset).lineNumber, member, _enclosing),
    );
  }
}

/// Every `ref.<member>` use in [source].
List<RefUse> refUses(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final out = <RefUse>[];
  parsed.unit.accept(_RefCollector(parsed.lineInfo, out));
  return out;
}

/// `ref.watch` uses outside `build()`.
List<RefUse> illegalWatches(String source) => refUses(source)
    .where((u) => u.member == 'watch' && u.enclosing != 'build')
    .toList();

// ---------------------------------------------------------------------------
// No timer of its own
// ---------------------------------------------------------------------------

/// Everything in [source] that schedules work to run after the scheduling call
/// returns. See the header for where the line is drawn.
List<Finding> timerFindings(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final out = <Finding>[];
  parsed.unit.accept(_ScheduleCollector(parsed.lineInfo, out, null));
  return out;
}

/// How many `Future.delayed`s in [source] are the awaited gap shape.
///
/// The allowed side of the rule, counted so the ban above can prove it is
/// reading a file that really does schedule something.
int awaitedDelayGaps(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final gaps = <Finding>[];
  parsed.unit.accept(_ScheduleCollector(parsed.lineInfo, <Finding>[], gaps));
  return gaps.length;
}

class _ScheduleCollector extends RecursiveAstVisitor<void> {
  _ScheduleCollector(this.lines, this.out, this.gaps);

  final LineInfo lines;

  /// Where banned constructs land.
  final List<Finding> out;

  /// Where the ALLOWED awaited gaps land, when the caller wants them.
  final List<Finding>? gaps;

  void _add(List<Finding> into, int offset, String what) =>
      into.add(Finding(lines.getLocation(offset).lineNumber, what));

  @override
  void visitNamedType(NamedType node) {
    if (node.name.lexeme == 'Timer') {
      _add(out, node.offset, '`Timer` named as a type — the coordinator owns '
          'no timer; ticks arrive from the schedulers');
    }
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // `Timer(d, cb)` and `Timer.periodic(d, cb)` both reduce to a plain
    // identifier: the parser cannot tell a constructor from a static call.
    if (node.name == 'Timer') {
      _add(out, node.offset, '`Timer` constructed here — it hands a callback '
          'to the event loop and returns, which is a second background wake '
          'source in the phase that exists to remove them');
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _factory(
      _baseName(node.target?.toSource()),
      node.methodName.name,
      node,
      node.argumentList,
    );
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    // `Future<void>.delayed(d)` — explicit type arguments are what let the
    // parser resolve the same call to a constructor instead.
    _factory(
      node.constructorName.type.name.lexeme,
      node.constructorName.name?.name ?? '',
      node,
      node.argumentList,
    );
    super.visitInstanceCreationExpression(node);
  }

  void _factory(
    String? type,
    String name,
    AstNode node,
    ArgumentList arguments,
  ) {
    if (type == 'Stream' && name == 'periodic') {
      _add(out, node.offset, '`Stream.periodic` — recurring by definition');
      return;
    }
    if (type != 'Future' || name != 'delayed') return;
    if (node.parent is AwaitExpression) {
      // The stagger gap: the awaiting frame is suspended for the delay and
      // nothing is scheduled behind it.
      final into = gaps;
      if (into != null) {
        _add(into, node.offset, 'awaited `Future.delayed` gap');
      }
      return;
    }
    _add(out, node.offset, '`Future.delayed` that is not directly awaited — '
        'work handed to the event loop to run after this call returns is a '
        'self-scheduling timer by another name');
  }

  /// `Future<void>` → `Future`; anything that is not a bare name → itself.
  String? _baseName(String? source) => source?.split('<').first;
}

// ---------------------------------------------------------------------------
// No FFI call
// ---------------------------------------------------------------------------

/// An import of the generated FFI bindings.
class RustImport {
  RustImport(this.line, this.uri, this.shown);

  /// Line of the import directive.
  final int line;

  /// The imported URI.
  final String uri;

  /// Names the import brings in, empty when it has no `show`.
  final Set<String> shown;
}

/// Every `src/rust/` import in [source].
List<RustImport> rustImportsIn(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final out = <RustImport>[];
  for (final directive in parsed.unit.directives.whereType<ImportDirective>()) {
    final uri = directive.uri.stringValue;
    if (uri == null || !uri.contains('src/rust/')) continue;
    out.add(
      RustImport(
        parsed.lineInfo.getLocation(directive.offset).lineNumber,
        uri,
        {
          for (final shown
              in directive.combinators.whereType<ShowCombinator>())
            ...shown.shownNames.map((n) => n.name),
        },
      ),
    );
  }
  return out;
}

/// How often each FFI name imported by [source] is referenced in its code.
///
/// Directives are excluded on purpose: the name in the `show` clause is not a
/// use, and counting it would make the inventory below self-satisfying.
Map<String, int> ffiNameReferences(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final shown = {for (final i in rustImportsIn(source)) ...i.shown};
  final counter = _FfiUseCollector(parsed.lineInfo, shown, <Finding>[]);
  for (final declaration in parsed.unit.declarations) {
    declaration.accept(counter);
  }
  return counter.references;
}

/// Every FFI use in [source] that goes beyond reading a value back.
List<Finding> ffiFindings(String source) {
  final parsed = parseString(content: source, throwIfDiagnostics: false);
  final out = <Finding>[];
  int line(int offset) => parsed.lineInfo.getLocation(offset).lineNumber;

  for (final directive in parsed.unit.directives.whereType<ImportDirective>()) {
    final uri = directive.uri.stringValue;
    if (uri == null) continue;
    if (uri == 'dart:ffi' || uri.startsWith('package:ffi')) {
      out.add(
        Finding(line(directive.offset), '`$uri` imported — the coordinator '
            'reaches Rust only through injected interfaces'),
      );
    }
  }
  for (final import in rustImportsIn(source)) {
    if (import.shown.isEmpty) {
      out.add(
        Finding(import.line, '`${import.uri}` imported without a `show` — the '
            'coordinator may name a generated binding only to read a value '
            'back, so what it names has to be enumerable'),
      );
    }
  }

  final shown = {for (final i in rustImportsIn(source)) ...i.shown};
  if (shown.isNotEmpty) {
    final collector = _FfiUseCollector(parsed.lineInfo, shown, out);
    for (final declaration in parsed.unit.declarations) {
      declaration.accept(collector);
    }
  }
  return out..sort((a, b) => a.line.compareTo(b.line));
}

class _FfiUseCollector extends RecursiveAstVisitor<void> {
  _FfiUseCollector(this.lines, this.names, this.out);

  final LineInfo lines;
  final Set<String> names;
  final List<Finding> out;

  /// Every reference to a shown name, allowed or not.
  final Map<String, int> references = {};

  @override
  void visitNamedType(NamedType node) {
    final name = node.name.lexeme;
    if (names.contains(name)) {
      references[name] = (references[name] ?? 0) + 1;
      out.add(
        Finding(lines.getLocation(node.offset).lineNumber, '`$name` named as '
            'a type — an FFI value held here is one call away from being one '
            'made here; take an interface instead'),
      );
    }
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final name = node.name;
    if (!names.contains(name)) {
      super.visitSimpleIdentifier(node);
      return;
    }
    references[name] = (references[name] ?? 0) + 1;
    // `BacklogOutcomeFfi.timedOut` — reading a value an injected interface
    // handed back is the one allowed use, and the only one the coordinator
    // has. Everything else (a call, a construction, a bare value) is not.
    final parent = node.parent;
    final isValueRead =
        (parent is PrefixedIdentifier && identical(parent.prefix, node)) ||
            (parent is PropertyAccess && identical(parent.target, node));
    if (!isValueRead) {
      out.add(
        Finding(lines.getLocation(node.offset).lineNumber, '`$name` used as '
            'more than a value read — constructing or calling a generated '
            'binding here is an FFI call from a file that promises none'),
      );
    }
    super.visitSimpleIdentifier(node);
  }
}

// ---------------------------------------------------------------------------
// Reading and mutating the real sources
// ---------------------------------------------------------------------------

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this test '
      'pins a background-correctness invariant to its call sites)',
    );
  }
  return file.readAsStringSync();
}

/// Splices [statement] in as the first statement of [method]'s body in
/// [source], located through the AST rather than by string search.
String _injectIntoMethod(String source, String method, String statement) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final finder = _MethodBodyFinder(method);
  unit.accept(finder);
  final body = finder.found;
  if (body == null) {
    fail(
      'cannot mutate: no method `$method` with a block body was found. It was '
      'renamed or inlined — re-point this mutation at whatever replaced it, '
      'or these guards are no longer proven to fire on the real file.',
    );
  }
  return source.replaceRange(
    body.block.leftBracket.end,
    body.block.leftBracket.end,
    '\n$statement\n',
  );
}

class _MethodBodyFinder extends RecursiveAstVisitor<void> {
  _MethodBodyFinder(this.name);
  final String name;
  BlockFunctionBody? found;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final body = node.body;
    if (node.name.lexeme == name && body is BlockFunctionBody) found ??= body;
    super.visitMethodDeclaration(node);
  }
}

/// Splices [line] in after the last import of [source].
String _injectImport(String source, String line) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final imports = unit.directives.whereType<ImportDirective>().toList();
  if (imports.isEmpty) fail('cannot mutate: the file imports nothing');
  final at = imports.last.end;
  return source.replaceRange(at, at, '\n$line');
}

void main() {
  group('checker self-tests', () {
    test('flags a ref.watch in an ordinary method', () {
      const source = '''
class N {
  void build() {}
  Future<void> onTick() async {
    final on = ref.watch(backgroundSharingProvider);
    if (on) publish();
  }
}
''';
      final flagged = illegalWatches(source);
      expect(flagged, hasLength(1));
      expect(flagged.single.member, 'watch');
      expect(flagged.single.enclosing, 'onTick');
    });

    test('flags a ref.watch nested inside a closure in a method', () {
      // The likelier shape: the watch is inside a callback, several frames
      // from the method signature, so a line-scoped scan would miss which
      // method it belongs to.
      const source = '''
class N {
  void arm() {
    Timer(d, () {
      final on = ref.watch(p);
    });
  }
}
''';
      expect(illegalWatches(source), hasLength(1));
      expect(illegalWatches(source).single.enclosing, 'arm');
    });

    test('flags a ref.watch reached through a cascade', () {
      const source = '''
class N {
  void arm() {
    ref
      ..watch(p)
      ..read(q);
  }
}
''';
      expect(illegalWatches(source), hasLength(1));
    });

    test('does not flag a ref.watch inside build()', () {
      const source = '''
class N {
  void build() {
    final circles = ref.watch(circlesProvider);
  }
}
''';
      expect(illegalWatches(source), isEmpty);
    });

    test('does not flag ref.read, ref.listen or ref.onDispose', () {
      const source = '''
class N {
  Future<void> onTick() async {
    ref.read(p);
    ref.listen(q, (a, b) {});
    ref.onDispose(() {});
  }
}
''';
      expect(illegalWatches(source), isEmpty);
      expect(refUses(source), hasLength(3));
    });

    test('does not flag a watch on something that is not ref', () {
      const source = '''
class N {
  void go() {
    stopwatch.watch(p);
  }
}
''';
      expect(illegalWatches(source), isEmpty);
    });
  });

  group('timer checker self-tests', () {
    test('flags Timer.periodic', () {
      const source = '''
class N {
  void arm() {
    Timer.periodic(const Duration(seconds: 30), (_) {});
  }
}
''';
      expect(timerFindings(source), hasLength(1));
      expect(timerFindings(source).single.what, contains('Timer'));
    });

    test('flags a one-shot Timer and a Timer field', () {
      expect(
        timerFindings('class N { Timer? _t; void a() { Timer(d, () {}); } }'),
        hasLength(2),
      );
    });

    test('flags Stream.periodic, with and without type arguments', () {
      expect(
        timerFindings('class N { void a() { Stream.periodic(d).listen(f); } }'),
        hasLength(1),
      );
      expect(
        timerFindings('class N { void a() { Stream<int>.periodic(d); } }'),
        hasLength(1),
      );
    });

    test('flags a Future.delayed that is not awaited', () {
      // Re-arming from inside a burst, written three ways. None of them is a
      // `Timer` by name and all three are one.
      expect(
        timerFindings('class N { void a() { Future.delayed(d, _rearm); } }'),
        hasLength(1),
      );
      expect(
        timerFindings('''
class N {
  void a() {
    unawaited(Future<void>.delayed(d).then((_) => _rearm()));
  }
}
'''),
        hasLength(1),
      );
      expect(
        timerFindings(
          'class N { void a() { _t = Future.delayed(d, _rearm); } }',
        ),
        hasLength(1),
      );
    });

    test('does not flag the awaited stagger gap', () {
      // The one scheduling construct the coordinator is allowed: the frame is
      // suspended for the gap and nothing is scheduled behind it.
      const source = '''
class N {
  Future<void> a() async {
    await Future<void>.delayed(_stagger.sampleGap(totalPublishes: 3));
    await Future.delayed(gap);
  }
}
''';
      expect(timerFindings(source), isEmpty);
      expect(awaitedDelayGaps(source), 2);
    });

    test('does not flag a Timer that only exists in prose', () {
      // The coordinator's own header says "No `Timer` of its own" and quotes
      // the shape it bans. A substring scan fails this file on its own
      // documentation; an AST walk never sees a comment or a string.
      const source = '''
/// ## No `Timer` of its own
///
/// A `Timer.periodic(d, cb)` here would be a second wake source.
class N {
  String describe() => 'Timer.periodic is banned';
}
''';
      expect(timerFindings(source), isEmpty);
    });

    test('does not flag ordinary awaits or a Stopwatch', () {
      expect(
        timerFindings(
          'class N { Future<void> a() async { final s = Stopwatch()..start(); '
          'await _engine.settleBeforePause(); } }',
        ),
        isEmpty,
      );
    });
  });

  group('FFI checker self-tests', () {
    const rustImport =
        "import 'package:haven/src/rust/api.dart' show BacklogOutcomeFfi;";

    test('flags dart:ffi', () {
      expect(ffiFindings("import 'dart:ffi';\nclass N {}"), hasLength(1));
      expect(
        ffiFindings("import 'package:ffi/ffi.dart';\nclass N {}"),
        hasLength(1),
      );
    });

    test('flags a generated-bindings import with no show', () {
      final found = ffiFindings(
        "import 'package:haven/src/rust/api.dart';\nclass N {}",
      );
      expect(found, hasLength(1));
      expect(found.single.what, contains('show'));
    });

    test('flags a shown binding named as a type', () {
      final found = ffiFindings('''
import 'package:haven/src/rust/api.dart' show CircleManagerFfi;
class N {
  final CircleManagerFfi manager;
}
''');
      expect(found, hasLength(1));
      expect(found.single.what, contains('named as a type'));
    });

    test('flags a static call and a construction on a shown binding', () {
      expect(
        ffiFindings('''
import 'package:haven/src/rust/api.dart' show CircleManagerFfi;
class N {
  Future<void> a() => CircleManagerFfi.newInstance();
}
'''),
        hasLength(1),
      );
      expect(
        ffiFindings('''
import 'package:haven/src/rust/api.dart' show CircleManagerFfi;
class N {
  void a() {
    final m = CircleManagerFfi();
  }
}
'''),
        isNotEmpty,
      );
    });

    test('does not flag reading a value back from an injected interface', () {
      // The coordinator's only legitimate FFI reference, in both the shapes
      // the parser can produce for it.
      const source = '''
$rustImport
class N {
  Future<void> a() async {
    final outcome = await _engine.waitBacklogSettled();
    if (outcome == BacklogOutcomeFfi.timedOut) log();
    switch (outcome) {
      case BacklogOutcomeFfi.settled:
        break;
    }
  }
}
''';
      expect(ffiFindings(source), isEmpty);
      expect(ffiNameReferences(source)['BacklogOutcomeFfi'], 2);
    });

    test('does not count the name in the show clause as a use', () {
      // Counting it would make the inventory pass satisfy itself from the
      // import line, over a file that never touches the binding.
      expect(ffiNameReferences('$rustImport\nclass N {}'), isEmpty);
    });

    test('ignores a name that is not imported from the bindings', () {
      expect(
        ffiFindings('class N { final BacklogOutcomeFfi x; }'),
        isEmpty,
      );
    });
  });

  group('the burst path never watches', () {
    test('the coordinator touches Riverpod not at all', () {
      final source = _read(_coordinator);
      expect(
        refUses(source),
        isEmpty,
        reason:
            'the coordinator takes injected collaborators so a burst can run '
            'with no container and no frame. A `ref` here would be the first '
            'step back to a value that freezes when the app is paused.',
      );
      expect(
        source,
        isNot(contains('flutter_riverpod')),
        reason: 'importing Riverpod is how the first `ref` gets in',
      );
    });

    test('no scheduler on the burst path watches outside build()', () {
      final offenders = <String>[];
      for (final path in _burstPath) {
        for (final use in illegalWatches(_read(path))) {
          offenders.add('$path:$use');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a `ref.watch` outside build() on the burst path reads its value '
            'once and then never updates while the app is paused — no error, '
            'no failing publish, just a burst acting on a stale value for the '
            'whole background window.\nOffenders:\n  ${offenders.join('\n  ')}',
      );
    });

    test('the scan still sees the real ref call sites (anti-vacuity)', () {
      // Both schedulers are Riverpod notifiers that use `ref` heavily. A
      // walker that silently matched nothing — one wrong node type away —
      // would make the assertion above pass by inspecting an empty list.
      for (final path in _burstPath) {
        final uses = refUses(_read(path));
        expect(
          uses.where((u) => u.member == 'read'),
          isNotEmpty,
          reason: '$path: no ref.read found, so the walker has gone blind',
        );
      }
    });
  });

  group('the coordinator owns no timer', () {
    test('it schedules nothing that outlives the call that scheduled it', () {
      final findings = timerFindings(_read(_coordinator));
      expect(
        findings,
        isEmpty,
        reason:
            'ticks arrive from the schedulers, one per circle on its own '
            'jittered cadence. A timer here is a second background wake '
            'source in the phase whose entire purpose is removing them — and '
            'on iOS a background Dart timer is not reliably delivered '
            'anyway.\nFound:\n  ${findings.join('\n  ')}',
      );
    });

    test('the rule still sees the real stagger gap (anti-vacuity)', () {
      // The one construct on the allowed side. If it is gone the rule above
      // is passing over a file with nothing left to inspect, and the allowed
      // side of the line has stopped being exercised by anything real.
      expect(
        awaitedDelayGaps(_read(_coordinator)),
        greaterThan(0),
        reason:
            'no awaited `Future.delayed` in the coordinator. Either the '
            'inter-publish stagger gap moved (re-point this) or the walker '
            'has gone blind and the ban above proves nothing.',
      );
    });

    test('a Timer.periodic spliced into the real burst is caught', () {
      // Verbatim the mutation that used to survive this lint, all 55 targeted
      // tests, and `flutter analyze`.
      final mutated = _injectIntoMethod(
        _read(_coordinator),
        '_runBurst',
        'Timer.periodic(const Duration(seconds: 30), (_) {});',
      );
      expect(timerFindings(mutated), hasLength(1));
    });

    test('a fire-and-forget re-arm spliced into the real burst is caught', () {
      // The same regression written without the word `Timer`.
      final mutated = _injectIntoMethod(
        _read(_coordinator),
        '_runBurst',
        '''
unawaited(
  Future<void>.delayed(const Duration(seconds: 30))
      .then((_) => _runBurst()),
);''',
      );
      expect(timerFindings(mutated), hasLength(1));
    });

    test('another awaited gap spliced into the real burst is NOT caught', () {
      // The allowed side, proven on the real file: the rule must not fire on
      // the shape the coordinator legitimately uses.
      final mutated = _injectIntoMethod(
        _read(_coordinator),
        '_runBurst',
        'await Future<void>.delayed(const Duration(seconds: 1));',
      );
      expect(timerFindings(mutated), isEmpty);
      expect(
        awaitedDelayGaps(mutated),
        awaitedDelayGaps(_read(_coordinator)) + 1,
      );
    });
  });

  group('the coordinator makes no FFI call', () {
    test('it names a generated binding only to read a value back', () {
      final findings = ffiFindings(_read(_coordinator));
      expect(
        findings,
        isEmpty,
        reason:
            'every collaborator is an interface or a function, which is what '
            'makes the burst sequence executable in a unit test with fakes — '
            'the only way its ORDER and failure-path properties can be proved '
            'at all.\nFound:\n  ${findings.join('\n  ')}',
      );
    });

    test('the rule still sees a real binding reference (anti-vacuity)', () {
      // The check is bounded by what the `show` clauses name, so a walker
      // that read no imports, or no uses, would pass over anything.
      final source = _read(_coordinator);
      final imports = rustImportsIn(source);
      expect(
        imports,
        isNotEmpty,
        reason:
            'the coordinator no longer imports the generated bindings at all. '
            'That is a fine thing to be true — but assert it deliberately '
            'here rather than leaving this pass inspecting nothing.',
      );
      final references = ffiNameReferences(source);
      for (final import in imports) {
        for (final name in import.shown) {
          expect(
            references[name] ?? 0,
            greaterThan(0),
            reason: '`$name` is imported but never referenced, so the use '
                'walker is not being exercised by anything real',
          );
        }
      }
    });

    test('a dart:ffi import spliced into the real file is caught', () {
      final mutated = _injectImport(_read(_coordinator), "import 'dart:ffi';");
      expect(ffiFindings(mutated), hasLength(1));
    });

    test('an FFI call spliced into the real burst is caught', () {
      final mutated = _injectIntoMethod(
        _injectImport(
          _read(_coordinator),
          "import 'package:haven/src/rust/api.dart' show CircleManagerFfi;",
        ),
        '_runBurst',
        'await CircleManagerFfi.newInstance().groupEpoch();',
      );
      expect(ffiFindings(mutated), hasLength(1));
    });

    test('widening the bindings import to a bare one is caught', () {
      // Dropping the `show` is how an unbounded set of bindings gets in
      // without a single new call site to notice.
      final mutated = _injectImport(
        _read(_coordinator),
        "import 'package:haven/src/rust/frb_generated.dart';",
      );
      expect(ffiFindings(mutated), hasLength(1));
    });
  });
}
