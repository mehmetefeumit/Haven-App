// Static guards for the member directory's two structural claims — the ones
// no host test can execute.
//
// 1. Search normalisation has exactly ONE owner, `fold_for_search` in
//    haven-core. `flutter test` cannot call it (no `RustLib.init()`), so the
//    Unicode suite runs against RECORDED outputs; that recording is only
//    worth anything if production still calls the real function. This pins
//    that call site.
// 2. The directory holds no picture bytes AND never asks for any. The first
//    is a claim about a type's shape, so it is pinned at the source rather
//    than asserted through an instance that happens not to have any. The
//    second is a claim about the LOADING path, which a grep over the data
//    class cannot see at all — the type honoured it while the loader fetched
//    and dropped one thumbnail per person. So the loader's source is pinned
//    to the bytes-free read, and what that read actually does is proven
//    behaviourally in `nostr_profile_cached_batch_test.dart`.
//
// Matches identifiers over comment-stripped source, never prose, so a
// comment rewrite can neither satisfy nor break it. Mirrors
// `tile_eviction_wiring_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) {
  final file = File(relativePath);
  if (!file.existsSync()) {
    fail(
      'expected source file not found: $relativePath (has it moved? this '
      'test pins a search-correctness invariant to its call site)',
    );
  }
  return file.readAsStringSync();
}

/// Strips `//`/`///` line comments so a comment merely mentioning an
/// identifier can never satisfy this test on its own.
String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('searchFold routes production through the Rust fold', () {
    late String code;

    setUp(() => code = _codeOnly(_read('lib/src/utils/search_fold.dart')));

    test('calls foldForSearch on the generated bridge', () {
      expect(
        code,
        contains('rust.foldForSearch(query: value)'),
        reason: 'search normalisation has exactly one owner. A second Dart '
            'fold would be a second Unicode database, drifting against '
            "haven-core's on every SDK bump",
      );
    });

    test('reaches the stand-in only from the bridge failure path', () {
      final withoutDeclaration = code
          .split('\n')
          .where((line) => !line.startsWith('String fallbackSearchFold('))
          .join('\n');
      expect(
        'fallbackSearchFold('.allMatches(withoutDeclaration).length,
        equals(1),
        reason: 'the stand-in exists for the bridge-less unit-test process '
            'only; a second call site would make it a production fold',
      );
      expect(code, contains('on Object catch'));
    });

    test('is called from nowhere else in lib/', () {
      final offenders = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('utils/search_fold.dart'))
          .where((f) => _codeOnly(f.readAsStringSync()).contains(
                'fallbackSearchFold',
              ))
          .map((f) => f.path)
          .toList();

      expect(
        offenders,
        isEmpty,
        reason: 'production code must fold through searchFold, which owns '
            'the bridge call and its one degradation path',
      );
    });
  });

  group('the directory carries identifiers, never image data', () {
    test('the candidate type holds no picture bytes', () {
      // Thumbnails for a whole roster cost tens of megabytes; rows resolve
      // their own bytes when they scroll into view.
      final code = _codeOnly(
        _read('lib/src/services/member_directory_service.dart'),
      );
      expect(code, isNot(contains('Uint8List')));
      expect(code, isNot(contains('pictureBytes')));
    });

    test('the loader never materializes picture bytes either', () {
      // The claim the type-shape check above CANNOT make: bytes fetched and
      // dropped still cost the decrypt, the FFI copy and the peak memory.
      final code = _codeOnly(
        _read('lib/src/services/nostr_member_directory_service.dart'),
      );
      expect(code, isNot(contains('Uint8List')));
      expect(code, isNot(contains('pictureBytes')));
      expect(
        code,
        isNot(contains('getMemberProfile(')),
        reason: 'the single-pubkey read resolves picture bytes for every '
            'person with a picture, all of which the directory discards',
      );
    });
  });

  group('the directory never reaches the network', () {
    late String code;

    setUp(
      () => code = _codeOnly(
        _read('lib/src/services/nostr_member_directory_service.dart'),
      ),
    );

    test('reads only the cache-only, bytes-free batch lookup', () {
      expect(
        code,
        contains('getCachedMemberProfiles('),
        reason: 'the cached read is how a candidate gets a name at all',
      );
      expect(
        code,
        isNot(contains('refreshMemberProfiles')),
        reason: 'R2/R4 promise no new wire traffic; the batch refresh dials '
            'relays',
      );
      expect(
        code,
        isNot(contains('forceRefresh')),
        reason: 'forceRefresh turns the cached read into a relay fetch',
      );
    });
  });
}
