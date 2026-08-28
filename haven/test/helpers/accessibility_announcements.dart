/// Captures accessibility announcements so tests can assert what a screen
/// reader is told.
///
/// `SemanticsService.sendAnnouncement` is a one-shot platform message, not a
/// node in the tree, so nothing in the widget hierarchy records it: without a
/// channel mock an announcement is indistinguishable from silence, and every
/// "announced exactly once" promise would be untestable.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns a growing list of the announcement texts sent during the test, in
/// order. The mock handler is torn down automatically.
List<String> captureAccessibilityAnnouncements(WidgetTester tester) {
  final announcements = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (message) async {
      if (message is Map &&
          message['type'] == 'announce' &&
          message['data'] is Map) {
        final text = (message['data'] as Map)['message'];
        if (text is String) announcements.add(text);
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
  return announcements;
}
