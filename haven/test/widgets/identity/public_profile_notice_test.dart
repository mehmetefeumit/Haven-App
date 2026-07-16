/// Widget tests for [PublicProfileNotice].
///
/// Covers the single combined "profile is public" disclosure notice: it
/// renders both the title and body text, and exposes them as one accessible
/// semantics block (title + body read together, not as two separate nodes).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/identity/public_profile_notice.dart';

import '../../helpers/localized_app_harness.dart';

void main() {
  testWidgets('renders both the title and the body', (tester) async {
    await pumpLocalized(
      tester,
      const Scaffold(body: PublicProfileNotice()),
    );

    expect(find.text('Profile is public'), findsOneWidget);
    expect(
      find.text(
        'Your display name and photo are visible to anyone on the Nostr '
        'network, not just members of your circles. Share only what '
        "you're comfortable making public.",
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'exposes title + body as a single accessible semantics block',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        const Scaffold(body: PublicProfileNotice()),
      );

      final semantics = tester.getSemantics(find.byType(PublicProfileNotice));
      expect(
        semantics.label,
        'Profile is public. Your display name and photo are visible to '
        'anyone on the Nostr network, not just members of your circles. '
        "Share only what you're comfortable making public.",
        reason:
            'A screen reader must announce the disclosure as one coherent '
            'statement, not as separate title/body nodes.',
      );

      handle.dispose();
    },
  );

  testWidgets('has no interactive controls (a standing disclosure, not a '
      'prompt)', (tester) async {
    await pumpLocalized(
      tester,
      const Scaffold(body: PublicProfileNotice()),
    );

    expect(find.byType(Switch), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });
}
