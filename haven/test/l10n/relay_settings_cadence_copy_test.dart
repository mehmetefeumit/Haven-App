// The not-on-relay legend tells the user how often Haven retries, in minutes,
// in every locale. Those minutes are the maintenance scheduler's nominal
// intervals, so a changed constant must redden each locale that still states
// the old number — no translation would change on its own.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart';
import 'package:intl/intl.dart';

void main() {
  test('the cadence intervals are whole minutes', () {
    for (final interval in [
      keyPackageMaintenanceInterval,
      relayListMaintenanceInterval,
    ]) {
      expect(interval, Duration(minutes: interval.inMinutes));
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final tag = locale.toLanguageTag();
    test('relaySettingsLegendNotOnRelay states the cadence in $tag', () {
      final text = lookupAppLocalizations(locale).relaySettingsLegendNotOnRelay;
      final native = NumberFormat.decimalPattern(tag);

      // CLDR gives fa and ne native digits, but a translation may keep
      // Western ones (ur does); the digit guards stop 10 matching 100.
      int positionOf(Duration interval) {
        final minutes = interval.inMinutes;
        final match = RegExp(
          r'(?<!\p{Nd})'
          '(?:$minutes|${RegExp.escape(native.format(minutes))})'
          r'(?!\p{Nd})',
          unicode: true,
        ).firstMatch(text);
        expect(match, isNotNull, reason: '$tag never says $minutes minutes');
        return match!.start;
      }

      expect(
        positionOf(keyPackageMaintenanceInterval),
        lessThan(positionOf(relayListMaintenanceInterval)),
        reason: '$tag must name the KeyPackage interval before the lists one',
      );
    });
  }
}
