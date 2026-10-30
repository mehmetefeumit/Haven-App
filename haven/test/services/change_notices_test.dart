// A change notice is acknowledged only after it was shown, and a notice a
// write superseded is read and shown again. The change card in Circle details
// is the one screen that shows them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/change_notices.dart';

class _Notice implements ChangeNoticeFfi {
  _Notice(this._notes);

  final List<ChangeNoteFfi> _notes;

  @override
  List<ChangeNoteFfi> notes() => _notes;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}

/// A manager whose notices come from [notices], in turn, and whose
/// acknowledgements answer [acks], in turn.
class _Manager implements CircleManagerFfi {
  _Manager({required this.notices, this.acks = const [true]});

  final List<ChangeNoticeFfi> notices;
  final List<bool> acks;
  final List<ChangeNoticeFfi> acknowledged = [];
  int reads = 0;

  @override
  ChangeNoticeFfi changeNotice({required List<int> mlsGroupId}) =>
      notices[(reads++).clamp(0, notices.length - 1)];

  @override
  bool acknowledgeShownNotice({required ChangeNoticeFfi notice}) {
    acknowledged.add(notice);
    return acks[(acknowledged.length - 1).clamp(0, acks.length - 1)];
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  const group = [1, 2, 3];
  final first = ChangeNoteFfi.values.first;

  test('a notice not shown is not acknowledged', () async {
    final manager = _Manager(notices: [_Notice([first])]);
    final shown = <List<ChangeNoteFfi>>[];

    await ChangeNotices(manager: () async => manager).showAndAcknowledge(
      group,
      (notes) async {
        shown.add(notes);
        return false;
      },
    );

    expect(shown, [
      [first],
    ], reason: 'premise: offered');
    expect(manager.acknowledged, isEmpty, reason: 'acknowledged unshown');
  });

  test('a notice shown is acknowledged, the very one that was read', () async {
    final notice = _Notice([first]);
    final manager = _Manager(notices: [notice]);

    await ChangeNotices(
      manager: () async => manager,
    ).showAndAcknowledge(group, (_) async => true);

    expect(manager.acknowledged, [same(notice)]);
  });

  test('a notice a write superseded is read and shown again', () async {
    final stale = _Notice([first]);
    final fresh = _Notice([first]);
    final manager = _Manager(notices: [stale, fresh], acks: [false, true]);
    var showings = 0;

    await ChangeNotices(manager: () async => manager).showAndAcknowledge(
      group,
      (_) async {
        showings++;
        return true;
      },
    );

    expect(showings, 2);
    expect(manager.acknowledged, [same(stale), same(fresh)]);
  });

  test('a notice with no note shows nothing and acknowledges nothing',
      () async {
    final manager = _Manager(notices: [_Notice(const [])]);
    var showings = 0;

    await ChangeNotices(manager: () async => manager).showAndAcknowledge(
      group,
      (_) async {
        showings++;
        return true;
      },
    );

    expect(showings, 0);
    expect(manager.acknowledged, isEmpty);
  });

  test('only the change card asks for a notice to be shown and '
      'acknowledged', () {
    // The one acknowledgement is the reader's own, and exactly one screen
    // asks it to show a notice: the change card in Circle details, which
    // reports a notice shown only once the user acknowledged it on screen.
    final callers = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.startsWith('lib/src/rust/')) continue;
      final source = file.readAsStringSync();
      if (source.contains('acknowledgeShownNotice(')) callers.add(file.path);
      if (source.contains('showAndAcknowledge(') &&
          !file.path.endsWith('change_notices.dart')) {
        callers.add('${file.path}: showAndAcknowledge');
      }
    }
    expect(callers, unorderedEquals([
      'lib/src/services/change_notices.dart',
      'lib/src/widgets/circles/change_notice_card.dart: showAndAcknowledge',
    ]));
  });
}
