/// Smoke tests for IdentityPage.
///
/// IdentityPage consumes Riverpod providers (identityNotifierProvider,
/// displayNameProvider) and instantiates services backed by Rust FFI in
/// production. Real end-to-end coverage lives in `integration_test/`.
///
/// The substantive widget-level tests for the display-name card live in
/// `test/widgets/identity/display_name_card_test.dart`, which can mock
/// `identityServiceProvider` without the Rust bridge.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/identity/npub_qr_code.dart';

void main() {
  group('IdentityPage support types', () {
    testWidgets('NpubQrCode encodes nostr: URI prefix', (tester) async {
      const npub =
          'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqspcd5tr';
      const widget = NpubQrCode(npub: npub);
      expect(widget.qrData, equals('nostr:$npub'));
    });

    testWidgets('NpubQrSize enum has expected dimensions', (tester) async {
      expect(NpubQrSize.small.dimension, 150);
      expect(NpubQrSize.medium.dimension, 200);
      expect(NpubQrSize.large.dimension, 280);
    });
  });
}
