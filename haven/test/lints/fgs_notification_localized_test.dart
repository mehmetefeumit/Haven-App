// The Android foreground-service notification is the one Haven surface a user
// reads for as long as the app sits behind other apps — and for most of the
// app's life it was English regardless of the language everything else was in.
// Its three texts now live in `app_en.arb` like all other user-visible copy,
// and so does the metadata of the CHANNEL that carries them: the name and
// description Android prints in Settings > Apps > Haven > Notifications, which
// is where a user goes to decide whether to keep the notification at all.
//
// This cannot be a widget test: `startService` and `updateService` are
// flutter_foreground_task platform channels, and MapShell's pause branch needs
// a live engine and a paused shell — the same reason
// `map_shell_detached_release_test.dart` asserts over the source. So this file
// pins IDENTIFIERS for the wiring and exact QUOTED LITERALS for the regression,
// never prose, on code with whole-line comments stripped.
//
// What it deliberately does not do: prove the translations are good, or that
// every locale carries the keys. `scripts/ci/arb_parity_check.dart` owns key
// parity, and no test can own translation quality.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The three ARB keys the foreground-service notification renders.
const _sharingKey = 'fgsNotificationSharing';
const _pausedKey = 'fgsNotificationPaused';
const _openKey = 'fgsNotificationOpen';

/// The English copy behind those keys.
///
/// Duplicated here on purpose, and checked against the ARB below: the literal
/// scan is only a guard while these strings are the ones a regression would
/// reintroduce, so the copy moving without this map moving is itself a failure.
const _englishTexts = <String, String>{
  _sharingKey: 'Haven is sending and receiving location information',
  _pausedKey: 'Haven is paused — open the app to resume sharing',
  _openKey: 'Haven is open',
};

/// The two ARB keys the notification's CHANNEL metadata renders.
const _channelNameKey = 'fgsChannelName';
const _channelDescriptionKey = 'fgsChannelDescription';

/// The English copy behind those keys, checked against the ARB like the three
/// above and for the same reason.
const _englishChannelTexts = <String, String>{
  _channelNameKey: 'Location Sharing',
  _channelDescriptionKey:
      'Keeps Haven sharing your encrypted location in the background.',
};

/// Every user-visible English string this file owns.
const _englishCopy = <String, String>{
  ..._englishTexts,
  ..._englishChannelTexts,
};

/// Every file permitted to name the notification channel's metadata.
///
/// Two, and they are different jobs: `main.dart` RESOLVES the copy (it is the
/// only place before `runApp` that holds the container, and so the user's
/// language), and the manager only forwards what it was handed.
const _channelMetadataSites = <String>{
  'lib/main.dart',
  'lib/src/services/background_location_manager.dart',
};

/// Every file permitted to name a foreground-service notification text.
///
/// A fourth call site written in isolation is exactly how the English literals
/// got in — each of the three that existed was written on its own. Pinning the
/// SET forces a new one through this file, where it has to be localized.
const _notificationTextSites = <String>{
  'lib/src/services/background_location_manager.dart',
  'lib/src/providers/background_location_provider.dart',
  'lib/src/providers/service_providers.dart',
  'lib/src/pages/map_shell.dart',
};

/// Every `.dart` file under `lib/`, minus the localization outputs.
///
/// `lib/l10n/` is where these sentences are *supposed* to live — the ARB and
/// the bundles `gen-l10n` writes from it — so scanning it would report the fix
/// as the violation.
List<File> _appSources() =>
    Directory('lib').listSync(recursive: true).whereType<File>().where((f) {
      return f.path.endsWith('.dart') && !f.path.startsWith('lib/l10n/');
    }).toList()..sort((a, b) => a.path.compareTo(b.path));

/// Strips whole-line `//` comments, then collapses whitespace runs to one
/// space, so an assertion sees syntax rather than layout.
///
/// Only whole-line comments: a trailing-comment stripper that ignored quoting
/// would truncate every line holding a URL literal, which would blind the
/// literal scan below rather than sharpen it. Prose *about* these strings is
/// what needs removing — `background_location_provider.dart` and the three
/// sharing-health files each quote the English text in a comment explaining it.
String _code(String source) => source
    .split('\n')
    .map((line) => line.trimLeft().startsWith('//') ? '' : line)
    .join('\n')
    .replaceAll(RegExp(r'\s+'), ' ');

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('expected source file not found: $path (has it moved?)');
  }
  return file.readAsStringSync();
}

void main() {
  group('the notification copy lives in the ARB', () {
    test('the five keys carry the English copy this file scans for', () {
      final arb =
          jsonDecode(_read('lib/l10n/app_en.arb')) as Map<String, dynamic>;

      for (final entry in _englishCopy.entries) {
        expect(
          arb[entry.key],
          entry.value,
          reason: 'if the copy changed, move it here too — otherwise the scan '
              'below hunts for a sentence nobody would write any more, and '
              'reports green over a reintroduced English literal',
        );
      }
    });

    test('no English notification literal survives anywhere in lib/', () {
      final offenders = <String>[];
      for (final file in _appSources()) {
        final code = _code(file.readAsStringSync());
        for (final text in _englishCopy.values) {
          if (code.contains("'$text'") || code.contains('"$text"')) {
            offenders.add('${file.path}: $text');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'a hardcoded English notification is shown to every user in '
            'every language; it must come from AppLocalizations',
      );
    });

    test('no other file sets a notification text', () {
      final owners = <String>{};
      for (final file in _appSources()) {
        final code = _code(file.readAsStringSync());
        if (code.contains('notificationText:') ||
            code.contains('updateNotification(')) {
          owners.add(file.path);
        }
      }

      expect(
        owners,
        unorderedEquals(_notificationTextSites),
        reason: 'a new notification call site must be localized like the '
            'three that exist — add it here once it is',
      );
    });

    test('no other file names the channel metadata', () {
      final owners = <String>{};
      for (final file in _appSources()) {
        final code = _code(file.readAsStringSync());
        if (code.contains('channelName:') ||
            code.contains('channelDescription:')) {
          owners.add(file.path);
        }
      }

      expect(
        owners,
        unorderedEquals(_channelMetadataSites),
        reason: 'a second place naming the channel is a second place to forget '
            'to localize it — which is exactly how the English literals got in',
      );
    });
  });

  group('every call site resolves its own text', () {
    test('the service class only forwards a text it was handed', () {
      final code = _code(
        _read('lib/src/services/background_location_manager.dart'),
      );

      expect(
        code,
        contains('required String notificationText'),
        reason: 'the service isolate has no widget tree and so no '
            'localizations; the text must arrive from the caller',
      );
      expect(
        code,
        contains('notificationText: notificationText'),
        reason: 'and be forwarded unchanged to the platform channel',
      );
      expect(
        code,
        contains('_lastNotificationText = notificationText'),
        reason: 'the redraw dedup must remember the RESOLVED text; seeding it '
            'with anything else would suppress the first update after a '
            'language change as a duplicate',
      );
    });

    test('the service class only forwards channel metadata it was handed', () {
      final code = _code(
        _read('lib/src/services/background_location_manager.dart'),
      );

      for (final param in const [
        'required String channelName',
        'required String channelDescription',
      ]) {
        expect(
          code,
          contains(param),
          reason: 'the channel name and description are read in the system '
              'settings app, and this class has no widget tree to localize '
              'them with — both must arrive from the caller',
        );
      }
      for (final forward in const [
        'channelName: channelName',
        'channelDescription: channelDescription',
      ]) {
        expect(
          code,
          contains(forward),
          reason: 'and reach the platform channel unchanged',
        );
      }
    });

    test('the channel setup resolves its copy in the user language', () {
      final code = _code(_read('lib/main.dart'));

      expect(
        code,
        contains('appLocalizationsProvider'),
        reason: '`init()` runs before `runApp` with no BuildContext, so the '
            'container is the only thing at that point that knows which '
            'language the app is about to render in',
      );
      for (final key in const [_channelNameKey, _channelDescriptionKey]) {
        expect(
          RegExp('channel[A-Za-z]*: [A-Za-z0-9_.()]*$key').hasMatch(code),
          isTrue,
          reason: 'the channel setup must pass the localized $key, or the '
              'system settings row reads English for every user',
        );
      }
    });

    test('the foreground-service start passes a localized text', () {
      final code = _code(
        _read('lib/src/providers/background_location_provider.dart'),
      );

      expect(
        code,
        contains('appLocalizationsProvider'),
        reason: 'the only source of a localized string outside a widget',
      );
      expect(
        RegExp('notificationText: [A-Za-z0-9_.()]*$_sharingKey').hasMatch(code),
        isTrue,
        reason: 'the service starts while the app is visible, so its first '
            'notification is the sharing one',
      );
    });

    test('the handover restart passes a localized text', () {
      final code = _code(_read('lib/src/providers/service_providers.dart'));

      expect(
        RegExp('notificationText: [A-Za-z0-9_.()]*$_sharingKey').hasMatch(code),
        isTrue,
        reason: 'restarting the service after a session handover rebuilds the '
            'same notification, and must rebuild it in the same language',
      );
    });

    test('the pause and resume paths use the localized keys', () {
      final code = _code(_read('lib/src/pages/map_shell.dart'));

      expect(
        code,
        contains('ref.read(appLocalizationsProvider)'),
        reason: 'MapShell resolves in the UI isolate and hands the text over',
      );
      for (final key in const [_sharingKey, _pausedKey, _openKey]) {
        expect(
          code,
          contains('.$key'),
          reason: 'the pause branch shows two of these and the resume branch '
              'the third; a missing one means a text went back to English or '
              'silently stopped being shown',
        );
      }
    });
  });
}
