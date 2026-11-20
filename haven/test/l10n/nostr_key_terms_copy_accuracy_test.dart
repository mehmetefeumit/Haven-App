// Copy accuracy for how Haven names the two Nostr keys, in EVERY supported
// locale (owner-directed 2026-11-16).
//
// The person being invited is found by their public key (npub), and the key a
// user imports is their secret key (nsec). Every string that asks for, checks
// or labels a person's npub calls it this locale's "public key" — the term the
// Public Key QR page already uses — never a Haven-invented "ID", "member ID"
// or "identifier"; and the import error names the secret key in the same
// words as the import screen above it, not a "backup key".
//
// Matched by stems, so a grammatical case or a possessive still matches.
//
// Not covered: whether a translation is idiomatic. That is the reviewer half
// of the l10n workflow.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

/// Per locale: the stems of "public key", of "secret key", and the old term
/// for a person's npub that no string may use any more.
final _terms = <String, (List<String>, List<String>, Pattern)>{
  'en': (['public key'], ['secret key'], RegExp('identi(fier|ty)')),
  'ar': (['مفتاح', 'عام'], ['مفتاح', 'سري'], 'معرّف'),
  'de': (
    ['öffentlich', 'schlüssel'],
    ['geheim', 'schlüssel'],
    RegExp('kennung|identität'),
  ),
  'es': (['clave pública'], ['clave secreta'], 'identificador'),
  'fa': (['کلید عمومی'], ['کلید خصوصی'], 'شناسه'),
  'fr': (['clé publique'], ['clé secrète'], 'identifiant'),
  'hi': (['सार्वजनिक कुंजी'], ['गुप्त कुंजी'], 'पहचान'),
  'ja': (['公開鍵'], ['秘密鍵'], '識別'),
  'ne': (['सार्वजनिक कुञ्जी'], ['गोप्य कुञ्जी'], 'पहिचान'),
  'pt': (['chave pública'], ['chave secreta'], 'identificador'),
  'ru': (['публичн', 'ключ'], ['секретн', 'ключ'], 'идентификатор'),
  'tr': (['açık anahtar'], ['gizli anahtar'], 'kimli'),
  'ur': (['عوامی کلید'], ['خفیہ کلید'], 'شناخت'),
};

/// "ID" as a word, in any script that borrowed it.
final _id = RegExp(r'(^|[^A-Za-z])ID([^A-Za-z]|$)');

List<String> _publicKeyCopy(AppLocalizations l) => [
  l.createCircleEmptyMessage,
  l.createCircleNoIdInQr,
  l.memberLookupNotFound,
  l.memberLookupIncomplete,
  l.memberSearchHint,
  l.memberSearchHelper,
  l.memberSearchNoValidId,
  l.memberPickerReasonSelf,
  l.invitationCardInvitedBySemantics('npub1abc…xyz'),
  l.npubQrSemanticsLabel,
];

void main() {
  test('every supported locale has vocabulary', () {
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      _terms.keys.toSet(),
    );
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;
    final (publicKey, secretKey, oldTerm) = _terms[code]!;

    test("$code: a person's npub is called their public key", () async {
      final l = await AppLocalizations.delegate.load(locale);
      expect(
        l.qrCodeYourPublicKeyLabel.toLowerCase(),
        stringContainsInOrder(publicKey),
        reason: "$code: the Public Key QR page's own term",
      );
      for (final text in _publicKeyCopy(l)) {
        final lower = text.toLowerCase();
        for (final stem in publicKey) {
          expect(lower, contains(stem), reason: '$code: "$text"');
        }
        expect(text, isNot(contains(_id)), reason: '$code: "$text"');
        expect(lower, isNot(contains(oldTerm)), reason: '$code: "$text"');
      }
    });

    test('$code: the import error names the secret key as the import screen '
        'does', () async {
      final l = await AppLocalizations.delegate.load(locale);
      for (final text in [l.onboardingImportBody, l.onboardingImportInvalid]) {
        final lower = text.toLowerCase();
        for (final stem in secretKey) {
          expect(lower, contains(stem), reason: '$code: "$text"');
        }
      }
    });
  }
}
