/// Cross-isolate read semantics for
/// `BackgroundLocationManager.readLastPublishTime()`.
///
/// The stamp it reads is written by the FOREGROUND SERVICE isolate
/// (`background_location_task.dart:2093`) and read by the UI isolate
/// (`map_shell.dart:2503`, which seeds the resume overlap guard from it).
/// `SharedPreferences` keeps the whole store in a per-isolate in-memory cache
/// populated once, at that isolate's first `getInstance()`
/// (`shared_preferences_legacy.dart:79-107`, pinned 2.5.5), and every getter
/// answers from that map — so a reader that does not `reload()` never sees the
/// other isolate's write at all. That is what made the B1 lane's heartbeat
/// print `lastBackgroundPublish=none yet` in CI runs 34511084722 and
/// 34642726338 while the same logcat carried three `Published to 1/1 due
/// circle(s)` lines.
///
/// ## Why this is a FILE of its own
///
/// The fixture here is the real `MethodChannelSharedPreferencesStore` over a
/// mock platform store — the only way to write into the store BEHIND this
/// isolate's cache, which is precisely the shape of a foreign-isolate write.
/// `SharedPreferences.setMockInitialValues`, used throughout
/// `background_location_manager_test.dart`, replaces
/// `SharedPreferencesStorePlatform.instance` process-wide and cannot be
/// undone from the plugin's public API, so sharing a file with it would make
/// this fixture depend on declaration order.
///
/// A plugin that renamed its legacy channel fails these tests loudly rather
/// than passing them vacuously: the handler below would never be consulted,
/// the store would stay unread, and the reads would come back null.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The plugin's legacy store channel
  // (`method_channel_shared_preferences.dart:11-13`).
  const channel = MethodChannel('plugins.flutter.io/shared_preferences');

  /// The ONE platform store both isolates share, keyed the way the plugin
  /// keys it on the platform side: every key carries the `flutter.` prefix.
  final store = <String, Object>{};

  /// The platform read failing — a channel error, not an absent value.
  var readsFail = false;

  /// Writes [ms] the way the FGS isolate's write ARRIVES here: into the shared
  /// store, with nothing touching this isolate's cache.
  void foregroundServiceWrote(int ms) {
    store['flutter.$kBackgroundLastPublishMsKey'] = ms;
  }

  setUp(() {
    store.clear();
    readsFail = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getAll':
              if (readsFail) {
                throw PlatformException(code: 'store-unavailable');
              }
              return Map<String, Object>.from(store);
            case 'setInt':
              final args = (call.arguments as Map).cast<String, Object>();
              store[args['key']! as String] = args['value']!;
              return true;
            case 'remove':
              final args = (call.arguments as Map).cast<String, Object>();
              store.remove(args['key']);
              return true;
          }
          throw MissingPluginException(call.method);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('readLastPublishTime — the writer is another isolate', () {
    test('observes a publish stamped after this isolate loaded its '
        'preferences', () async {
      // The UI isolate loads its preferences at launch (`main.dart:121`),
      // when nothing has published yet.
      await SharedPreferences.getInstance();
      expect(
        await BackgroundLocationManager.readLastPublishTime(),
        isNull,
        reason: 'nothing has been written yet',
      );

      // The service publishes while the app is backgrounded.
      final published = DateTime.fromMillisecondsSinceEpoch(1757620000000);
      foregroundServiceWrote(published.millisecondsSinceEpoch);

      expect(
        await BackgroundLocationManager.readLastPublishTime(),
        published,
        reason:
            'the FGS isolate wrote through to the shared store; a reader '
            'answering from the cache it loaded at launch reports "never '
            'published" for a service that has been publishing for hours',
      );
    });

    test("supersedes this isolate's own handoff stamp with the service's "
        'later publish', () async {
      // The product path, in order. `_onPaused` hands publishing over and
      // writes what the FOREGROUND last published (`map_shell.dart:2021`) —
      // populating this isolate's cache...
      final handoff = DateTime.fromMillisecondsSinceEpoch(1757620000000);
      await BackgroundLocationManager.writeLastPublishTime(handoff);
      expect(
        store['flutter.$kBackgroundLastPublishMsKey'],
        handoff.millisecondsSinceEpoch,
        reason: 'the handoff stamp must reach the shared store',
      );

      // ...then the service publishes repeatedly for hours, and `_onResumed`
      // seeds its overlap guard from the LAST of those
      // (`map_shell.dart:2503`). A cached handoff stamp would suppress or
      // duplicate the first foreground publish after the resume.
      final latest = handoff.add(const Duration(hours: 3));
      foregroundServiceWrote(latest.millisecondsSinceEpoch);

      expect(
        await BackgroundLocationManager.readLastPublishTime(),
        latest,
        reason:
            'a non-null cached value is just as stale as an absent one — the '
            "resume seed must be the service's last publish, not the stamp "
            'this isolate wrote when it handed over',
      );
    });

    test('reports "nothing recorded" instead of throwing when the store '
        'cannot be read', () async {
      // The caller is mid-`_onResumed`, which has no try/catch of its own:
      // everything after the read (ending the MLS handoff, re-anchoring the
      // engine, the resume catch-up) would be abandoned by a throw here.
      expect(await BackgroundLocationManager.readLastPublishTime(), isNull);

      readsFail = true;

      expect(
        await BackgroundLocationManager.readLastPublishTime(),
        isNull,
        reason: 'a failed platform read must degrade, never abort the resume',
      );
    });
  });
}
