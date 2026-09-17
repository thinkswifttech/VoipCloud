import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop audio test uses the native lifecycle and clamps levels', () async {
    const channel = MethodChannel('voipcloud/test_audio_test');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getAudioInputLevel') return 1.7;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    const platform = VoipPlatformChannel(channel: channel);
    await platform.startAudioInputTest();
    expect(await platform.getAudioInputLevel(), 1);
    await platform.playAudioTestSound();
    await platform.stopAudioInputTest();

    expect(calls, [
      'startAudioInputTest',
      'getAudioInputLevel',
      'playAudioTestSound',
      'stopAudioInputTest',
    ]);
  });
}
