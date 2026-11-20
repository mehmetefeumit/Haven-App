import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/network_change_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockStreamHandler(
      PlatformNetworkChangeSource.channel,
      null,
    ),
  );

  test('serves the channel the native handlers register', () {
    expect(PlatformNetworkChangeSource.channel.name, 'haven.app/network_change');
  });

  test('a listen and a cancel reach the platform, and each native event is '
      'one change whatever it carries', () async {
    var listens = 0;
    var cancels = 0;
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      PlatformNetworkChangeSource.channel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          listens++;
          sink = events;
        },
        onCancel: (arguments) => cancels++,
      ),
    );

    var changes = 0;
    final subscription = const PlatformNetworkChangeSource().changes().listen(
      (_) => changes++,
    );
    await pumpEventQueue();
    expect(listens, 1);

    // The native side sends null; anything else is still only "changed".
    sink!
      ..success(null)
      ..success('wss://relay.example.invalid')
      ..success(<String, Object?>{'network': 101});
    await pumpEventQueue();
    expect(changes, 3);

    await subscription.cancel();
    await pumpEventQueue();
    expect(cancels, 1, reason: 'the native callback is unregistered');
  });
}
