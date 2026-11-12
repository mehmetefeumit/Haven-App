/// Captures accessibility announcements so tests can assert what a screen
/// reader is told.
///
/// `SemanticsService.sendAnnouncement` is a one-shot platform message, not a
/// node in the tree, so nothing in the widget hierarchy records it: without a
/// channel mock an announcement is indistinguishable from silence, and every
/// "announced exactly once" promise would be untestable.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One captured announcement and the priority it was sent with.
typedef CapturedAnnouncement = ({String message, Assertiveness assertiveness});

/// Returns a growing list of the announcement texts sent during the test, in
/// order. The mock handler is torn down automatically.
List<String> captureAccessibilityAnnouncements(WidgetTester tester) {
  final texts = <String>[];
  _capture(tester, (a) => texts.add(a.message));
  return texts;
}

/// Like [captureAccessibilityAnnouncements], but also records each
/// announcement's [Assertiveness].
List<CapturedAnnouncement> captureAccessibilityAnnouncementsWithPriority(
  WidgetTester tester,
) {
  final captured = <CapturedAnnouncement>[];
  _capture(tester, captured.add);
  return captured;
}

void _capture(
  WidgetTester tester,
  void Function(CapturedAnnouncement) record,
) {
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (message) async {
      if (message is Map &&
          message['type'] == 'announce' &&
          message['data'] is Map) {
        final data = message['data'] as Map;
        final text = data['message'];
        if (text is String) {
          // The channel omits the key for polite.
          final level = data['assertiveness'];
          record((
            message: text,
            assertiveness: level == Assertiveness.assertive.index
                ? Assertiveness.assertive
                : Assertiveness.polite,
          ));
        }
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
}
