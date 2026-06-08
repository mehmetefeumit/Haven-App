/// Registers map data & tile-provider licences with [LicenseRegistry].
///
/// Makes the OpenStreetMap (ODbL), Stadia Maps, and OpenMapTiles licences
/// appear in the app's "Open-source licenses" page (`showLicensePage`),
/// alongside the Flutter-package licences Flutter registers automatically.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:haven/src/constants/tiles.dart';

/// Registers the OpenStreetMap (ODbL), Stadia Maps, and OpenMapTiles licence
/// entries with [LicenseRegistry].
///
/// Call once during startup, before `runApp`. Registration is synchronous; the
/// bundled ODbL text is loaded lazily inside the generator the first time the
/// licenses page is opened.
void registerMapLicenses() {
  LicenseRegistry.addLicense(() async* {
    final odbl = await rootBundle.loadString('assets/licenses/odbl-1.0.txt');
    yield LicenseEntryWithLineBreaks(
      const ['OpenStreetMap data (ODbL 1.0)'],
      odbl,
    );
    yield const LicenseEntryWithLineBreaks(
      ['Stadia Maps'],
      'Map tiles © Stadia Maps, provided under the Stadia Maps Terms of '
      'Service ($kStadiaTermsUrl).\n\n'
      'Tile data © OpenMapTiles ($kOpenMapTilesUrl) '
      '© OpenStreetMap contributors ($kOsmCopyrightUrl).',
    );
    yield const LicenseEntryWithLineBreaks(
      ['OpenMapTiles'],
      'OpenMapTiles ($kOpenMapTilesUrl): map schema and cartography under '
      'BSD-3-Clause (code) and CC-BY 4.0 (design). Underlying data '
      '© OpenStreetMap contributors under ODbL 1.0.',
    );
  });
}
