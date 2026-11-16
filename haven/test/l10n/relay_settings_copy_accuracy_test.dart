// Copy accuracy for what the Relays page says about an empty relay list.
//
// Two promises the code keeps, and nothing wider:
//
// * Haven refuses to remove the last relay of a list
//   (`storage_relay_prefs.rs` `remove_user_relay`,
//   `remove_user_relay_blocks_last_in_category`). It does not keep a list from
//   being empty: a failed seed leaves one empty, which is when the "no relays"
//   note shows. So the info panels promise the refusal, never that Haven
//   "always keeps" a relay.
// * The "no relays" note is one note for every empty list, the Inbox and the
//   KeyPackage list both included (`_HoldNotes` shows each hold once), so it
//   never says exactly one list is empty.
//
// Each banned claim is proved non-vacuous against a FROZEN copy of the
// sentence that made it, never a live ARB value. English only: no other
// locale carries these keys yet.
@TestOn('vm')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('the info panels promise the refusal, not a list never empty', () {
    final standing = RegExp(r'\balways keeps\b', caseSensitive: false);
    final refusal = RegExp(
      r"\bwon't let you remove the last relay\b",
      caseSensitive: false,
    );
    const frozen =
        'You can add or remove relays. Haven always keeps at least one. Every '
        'relay on this list is public: anyone can see it in your relay list. '
        'When you remove a relay, Haven asks it to delete your old relay list.';

    test('the banned claim matches the copy that made it', () {
      expect(standing.hasMatch(frozen), isTrue);
      expect(refusal.hasMatch(frozen), isFalse);
    });

    for (final (name, text) in [
      ('relaySettingsInboxInfoActions', l10n.relaySettingsInboxInfoActions),
      (
        'relaySettingsKeyPackageInfoActions',
        l10n.relaySettingsKeyPackageInfoActions,
      ),
    ]) {
      test(name, () {
        expect(text, isNot(matches(standing)));
        expect(text, matches(refusal));
      });
    }
  });

  test('the no-relays note is true when both lists are empty', () {
    final oneList = RegExp(
      r'\bone of your lists\b|\bits\b',
      caseSensitive: false,
    );
    const frozen =
        'One of your lists above has no relays, so Haven has nowhere to '
        'publish it. Restore its defaults to publish it again.';
    expect(oneList.hasMatch(frozen), isTrue);
    expect(l10n.relaySettingsHeldNoRelays, isNot(matches(oneList)));
  });
}
