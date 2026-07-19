/// Unit tests for [MapShell] pure helpers.
///
/// The widget itself depends on the Rust bridge and is exercised through the
/// integration suite; these cover the platform/lifecycle decision logic that
/// can be verified without pumping the widget.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map_shell.dart';

void main() {
  group('MapShell.shouldKeepRelayConnectedWhilePaused', () {
    test('keeps the relay warm only on the iOS background branch', () {
      expect(
        MapShell.shouldKeepRelayConnectedWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: true,
        ),
        isTrue,
      );
    });

    test('disconnects on Android even with background sharing on', () {
      // Android hands publishing to the foreground-service isolate, which
      // owns its own relay — the foreground socket should close.
      expect(
        MapShell.shouldKeepRelayConnectedWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: false,
        ),
        isFalse,
      );
    });

    test('disconnects on iOS when background sharing is off', () {
      // No retention stream is started, so the app is genuinely going idle.
      expect(
        MapShell.shouldKeepRelayConnectedWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: true,
        ),
        isFalse,
      );
    });

    test('disconnects when neither condition holds', () {
      expect(
        MapShell.shouldKeepRelayConnectedWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: false,
        ),
        isFalse,
      );
    });
  });

  group('MapShell.shouldKeepPublishingWhilePaused', () {
    test('keeps publishing only on the iOS background branch', () {
      // The unified background-capable location stream keeps the process
      // executable, so the send scheduler and motion trigger stay live.
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: true,
        ),
        isTrue,
      );
    });

    test('stops on Android even with background sharing on', () {
      // Android hands publishing to the foreground-service isolate; the
      // foreground scheduler must stop (MLS single-writer handoff).
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: true,
          isIOS: false,
        ),
        isFalse,
      );
    });

    test('stops on iOS when background sharing is off', () {
      // The stream carries no keep-alive; the app genuinely goes idle.
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: true,
        ),
        isFalse,
      );
    });

    test('stops when neither condition holds', () {
      expect(
        MapShell.shouldKeepPublishingWhilePaused(
          backgroundSharingEnabled: false,
          isIOS: false,
        ),
        isFalse,
      );
    });
  });
}
