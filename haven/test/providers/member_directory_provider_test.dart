/// Tests for the member-directory providers (plan §9.3/§9.4).
///
/// The load-once-then-filter-in-memory split is the whole design, so what is
/// proven here is the split itself: exactly one service call per opening of
/// the picker, zero for any amount of typing, and a filtered list that is
/// available in the same turn the query changed.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/member_directory_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/member_directory_service.dart';
import 'package:haven/src/services/profile_service.dart';

import '../mocks/mock_member_directory_service.dart';

const _alice =
    'a11ce0000000000000000000000000000000000000000000000000000000cafe';
const _bob =
    'b0b0000000000000000000000000000000000000000000000000000000000dad';
const _carol =
    'ca401000000000000000000000000000000000000000000000000000000beef0';

const _aliceNpub =
    'npub15ywwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqetlqhgm683';
const _bobNpub =
    'npub1kzcqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpkksrcdwkr';
const _carolNpub =
    'npub1efqpqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqtamcqhprsfg';

DirectoryEntry _entry(String pubkeyHex, String npub) {
  return DirectoryEntry(
    pubkeyHex: pubkeyHex,
    npub: npub,
    tier: DirectoryTier.current,
  );
}

MemberDirectory _threePeople() {
  return buildDirectory(
    entries: [
      _entry(_alice, _aliceNpub),
      _entry(_bob, _bobNpub),
      _entry(_carol, _carolNpub),
    ],
    profiles: const {
      _alice: Profile(pubkeyHex: _alice, displayName: 'Alice Aardvark'),
      _bob: Profile(pubkeyHex: _bob, displayName: 'Bob Badger'),
      _carol: Profile(pubkeyHex: _carol, displayName: 'Carol Coyote'),
    },
  );
}

ProviderContainer _containerFor(
  MockMemberDirectoryService service, {
  List<Circle> circles = const [],
}) {
  return ProviderContainer(
    overrides: [
      memberDirectoryServiceProvider.overrideWithValue(service),
      circlesProvider.overrideWith((ref) => Future.value(circles)),
    ],
  );
}

/// Opens the picker: holds the results for [query] alive the way a rendered
/// list does, and returns the current filtered list.
List<MemberCandidate> _results(
  ProviderContainer container, {
  String query = '',
}) {
  final provider = memberDirectoryResultsProvider(query);
  final sub = container.listen(provider, (_, _) {}, fireImmediately: true);
  addTearDown(sub.close);
  return container.read(provider);
}

/// Waits for [memberDirectoryProvider] to settle (resolve OR error) in
/// [container], regardless of how many microtask hops its dependency chain
/// needs — `circlesProvider` resolving before `loadDirectory` is called adds
/// one over a bare synchronous mock, so a fixed number of `pump()` calls
/// would be timing-fragile. The error is expected here (the mock throws);
/// this only waits, it never asserts.
Future<void> _settle(ProviderContainer container) async {
  try {
    await container.read(memberDirectoryProvider.future);
  } on Object catch (_) {
    // Expected when the mock is configured to throw — this helper only
    // waits for the provider to settle, the calling test asserts the result.
  }
}

/// Types [value] into the rendered field and lets the list rebuild.
Future<void> _type(WidgetTester tester, String value) async {
  tester.state<_SearchFieldState>(find.byType(_SearchField)).type(value);
  await tester.pump();
}

/// A field whose text lives where a search field's text lives — in widget
/// state — with the filtered list derived from it.
class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  String query = '';

  void type(String value) => setState(() => query = value);

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final results = ref.watch(memberDirectoryResultsProvider(query));
        return Text(
          '${results.length}',
          textDirection: TextDirection.ltr,
        );
      },
    );
  }
}

void main() {
  group('memberDirectoryProvider', () {
    test('loads the directory once when the picker opens', () async {
      final service = MockMemberDirectoryService(directory: _threePeople());
      final container = _containerFor(service);
      addTearDown(container.dispose);
      final sub = container.listen(
        memberDirectoryProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      final directory = await container.read(memberDirectoryProvider.future);

      expect(directory.entries, hasLength(3));
      expect(service.methodCalls, hasLength(1));
      expect(service.methodCalls.single.method, equals('loadDirectory'));
    });

    test('re-reads on the next open, so a new co-member appears', () async {
      // autoDispose: the directory is screen-scoped, not a process cache, so
      // closing the picker releases it and re-opening asks again.
      final service = MockMemberDirectoryService(directory: _threePeople());
      final container = _containerFor(service);
      addTearDown(container.dispose);

      final first = container.listen(
        memberDirectoryProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await container.read(memberDirectoryProvider.future);
      first.close();
      await container.pump();

      final second = container.listen(
        memberDirectoryProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(second.close);
      await container.read(memberDirectoryProvider.future);

      expect(service.methodCalls, hasLength(2));
    });
  });

  group('memberDirectoryResultsProvider', () {
    test('shows the whole directory before anything is typed', () async {
      final service = MockMemberDirectoryService(directory: _threePeople());
      final container = _containerFor(service);
      addTearDown(container.dispose);
      _results(container);
      await container.read(memberDirectoryProvider.future);

      expect(
        _results(container).map((c) => c.pubkeyHex),
        orderedEquals(<String>[_alice, _bob, _carol]),
      );
    });

    test('filters in the same turn as the keystroke, with no await',
        () async {
      final service = MockMemberDirectoryService(directory: _threePeople());
      final container = _containerFor(service);
      addTearDown(container.dispose);
      _results(container);
      await container.read(memberDirectoryProvider.future);

      // Deliberately no await between the keystroke and the read: a
      // debounced or asynchronous filter would still be showing three rows.
      expect(
        _results(container, query: 'badger').map((c) => c.pubkeyHex),
        orderedEquals(<String>[_bob]),
      );
    });

    test('restores the whole directory when the query is cleared', () async {
      final service = MockMemberDirectoryService(directory: _threePeople());
      final container = _containerFor(service);
      addTearDown(container.dispose);
      _results(container);
      await container.read(memberDirectoryProvider.future);

      expect(_results(container, query: 'badger'), hasLength(1));
      expect(_results(container), hasLength(3));
    });

    test('is empty while the directory is still loading', () async {
      final service = MockMemberDirectoryService(directory: _threePeople())
        ..loadGate = Completer<void>();
      final container = _containerFor(service);
      addTearDown(container.dispose);

      expect(_results(container), isEmpty);

      service.loadGate!.complete();
      await container.read(memberDirectoryProvider.future);

      expect(_results(container), hasLength(3));
    });

    test('is empty, never an error, when the load fails', () async {
      // The suggestion list is an accelerator over a screen whose paste and
      // QR paths still work. A failure hides the accelerator; it must never
      // put an error in front of the field.
      final service = MockMemberDirectoryService()
        ..shouldThrowOnLoadDirectory = true;
      final container = _containerFor(service);
      addTearDown(container.dispose);
      _results(container);
      await _settle(container);

      expect(_results(container), isEmpty);
      expect(() => _results(container, query: 'alice'), returnsNormally);
    });

    test('keeps filtering after a failed load, without a service call',
        () async {
      final service = MockMemberDirectoryService()
        ..shouldThrowOnLoadDirectory = true;
      final container = _containerFor(service);
      addTearDown(container.dispose);
      _results(container);
      await _settle(container);

      expect(_results(container, query: 'alice'), isEmpty);
      expect(service.methodCalls, hasLength(1));
    });
  });

  group('typing costs nothing', () {
    testWidgets('a whole npub typed in and backspaced out loads once',
        (tester) async {
      // R2/R4's central promise, proven through a real rebuild: the query
      // lives in widget state, so each keystroke watches a DIFFERENT
      // provider. If that handover ever let the directory fall to zero
      // listeners, every keystroke would re-open SQLCipher.
      final service = MockMemberDirectoryService(directory: _threePeople());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberDirectoryServiceProvider.overrideWithValue(service),
            circlesProvider.overrideWith(
              (ref) => Future.value(const <Circle>[]),
            ),
          ],
          child: const _SearchField(),
        ),
      );
      await tester.pump();

      for (var i = 1; i <= _aliceNpub.length; i++) {
        await _type(tester, _aliceNpub.substring(0, i));
      }
      for (var i = _aliceNpub.length - 1; i >= 0; i--) {
        await _type(tester, _aliceNpub.substring(0, i));
      }

      expect(service.methodCalls, hasLength(1));
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('narrows to the typed name and back again', (tester) async {
      final service = MockMemberDirectoryService(directory: _threePeople());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memberDirectoryServiceProvider.overrideWithValue(service),
            circlesProvider.overrideWith(
              (ref) => Future.value(const <Circle>[]),
            ),
          ],
          child: const _SearchField(),
        ),
      );
      await tester.pump();

      await _type(tester, 'badger');
      expect(find.text('1'), findsOneWidget);

      await _type(tester, '');
      expect(find.text('3'), findsOneWidget);
      expect(service.methodCalls, hasLength(1));
    });
  });
}
