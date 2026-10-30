/// What a circle has not been told about its changes, and the acknowledgement
/// that may only follow its showing.
library;

import 'package:haven/src/rust/api.dart';

/// The notes that say what IS rather than what happened: the core clears each
/// where it stops being so, and no acknowledgement drops one. The sharing
/// card says the last two (a relay change awaiting the foreground, a routing
/// collision) as causes; the change card lists none of them as something to
/// acknowledge, and shows unread locations as information.
const Set<ChangeNoteFfi> kLevelNotes = {
  ChangeNoteFfi.unreadChange,
  ChangeNoteFfi.unreadLocation,
  ChangeNoteFfi.awaitsForeground,
  ChangeNoteFfi.routingCollision,
};

/// The notes of [notes] the user is told and acknowledges, in the order
/// given.
List<ChangeNoteFfi> toldNotes(List<ChangeNoteFfi> notes) =>
    notes.where((note) => !kLevelNotes.contains(note)).toList();

/// One read of a circle's notice: its notes, and the notice that can be
/// acknowledged once they have been SHOWN.
class NoticeRead {
  NoticeRead._(this._notice, this.notes);

  final ChangeNoticeFfi _notice;

  /// What the circle is to be shown, as the engine wrote it.
  final List<ChangeNoteFfi> notes;
}

/// Reads change notices and acknowledges the ones that were shown.
///
/// Reading takes nothing: a process that dies before a notice is acknowledged
/// reads it again. An acknowledgement takes a [NoticeRead], so only a notice
/// that was read can be acknowledged — and [showAndAcknowledge] acknowledges
/// one only after the caller reports it shown.
class ChangeNotices {
  /// Creates the reader over the circle manager [manager] yields.
  ChangeNotices({required Future<CircleManagerFfi> Function() manager})
    : _manager = manager;

  final Future<CircleManagerFfi> Function() _manager;

  /// The notice for [mlsGroupId], or `null` when it carries no note.
  Future<NoticeRead?> read(List<int> mlsGroupId) async {
    final notice = (await _manager()).changeNotice(mlsGroupId: mlsGroupId);
    final notes = notice.notes();
    return notes.isEmpty ? null : NoticeRead._(notice, notes);
  }

  /// Shows [mlsGroupId]'s notice through [show] — which answers whether the
  /// notes were shown — and acknowledges it only then. A write since the read
  /// supersedes it: the next notice is read and shown in its turn.
  Future<void> showAndAcknowledge(
    List<int> mlsGroupId,
    Future<bool> Function(List<ChangeNoteFfi> notes) show,
  ) async {
    while (true) {
      final read = await this.read(mlsGroupId);
      if (read == null || !await show(read.notes)) return;
      final manager = await _manager();
      if (manager.acknowledgeShownNotice(notice: read._notice)) return;
    }
  }
}
