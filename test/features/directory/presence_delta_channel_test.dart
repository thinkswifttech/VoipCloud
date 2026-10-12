import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/blf-delta');
  const bridge = VoipPlatformChannel(channel: channel);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('full desired set and deltas retain order and generation', () async {
    await bridge.setPresenceTargets(['211', '210', '211'], 7);
    await bridge.enqueuePresenceTargets(['211', '211'], 7);
    expect(calls[0].method, 'setPresenceTargets');
    expect(calls[0].arguments, {
      'extensions': ['211', '210'],
      'generation': 7,
    });
    expect(calls[1].method, 'enqueuePresenceTargets');
    expect(calls[1].arguments, {
      'additions': ['211'],
      'generation': 7,
    });
  });

  test('ordinary BLF target updates do not call DND or stop methods', () async {
    await bridge.setPresenceTargets([], 8);
    await bridge.enqueuePresenceTargets(['210'], 8);
    expect(calls.map((call) => call.method), [
      'setPresenceTargets',
      'enqueuePresenceTargets',
    ]);
  });
}
