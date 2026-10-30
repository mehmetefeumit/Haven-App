import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/change_notices.dart';

/// A change notice holding [notes].
class FakeNotice implements ChangeNoticeFfi {
  FakeNotice(this._notes);

  final List<ChangeNoteFfi> _notes;

  @override
  List<ChangeNoteFfi> notes() => _notes;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}

/// A circle manager whose notice for any circle holds [notes] (or [error] is
/// thrown), and whose acknowledgements answer [acks] in turn, recording the
/// notices acknowledged.
class FakeNoticeManager implements CircleManagerFfi {
  FakeNoticeManager({this.notes = const [], this.acks = const [true]});

  /// What the next read hands over; a test changes it to write a note.
  List<ChangeNoteFfi> notes;

  /// When set, what the next read of a circle hands over, by its group id;
  /// [notes] otherwise.
  List<ChangeNoteFfi> Function(List<int> mlsGroupId)? notesFor;

  /// When set, every read throws it.
  Object? error;

  final List<bool> acks;
  final List<ChangeNoticeFfi> acknowledged = [];

  /// The notes each acknowledged notice held, in order.
  final List<List<ChangeNoteFfi>> acknowledgedNotes = [];
  int reads = 0;

  @override
  ChangeNoticeFfi changeNotice({required List<int> mlsGroupId}) {
    reads++;
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, StackTrace.current);
    return FakeNotice(List.of(notesFor?.call(mlsGroupId) ?? notes));
  }

  @override
  bool acknowledgeShownNotice({required ChangeNoticeFfi notice}) {
    acknowledged.add(notice);
    acknowledgedNotes.add(notice.notes());
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

/// The reader over [manager], for `changeNoticesProvider.overrideWithValue`.
ChangeNotices fakeChangeNotices(FakeNoticeManager manager) =>
    ChangeNotices(manager: () async => manager);
