import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/domain/audio_volume_levels.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop audio volumes use typed native values', () async {
    const channel = MethodChannel('voipcloud/test_audio_volume');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getAudioVolumeLevels') {
            return <Object?, Object?>{
              'microphone': 80,
              'callAudio': 65,
              'ringtone': 40,
              'ringback': 30,
            };
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    const platform = VoipPlatformChannel(channel: channel);
    final levels = AudioVolumeLevels.fromPlatform(
      await platform.getAudioVolumeLevels(),
    );
    await platform.setAudioVolume(AudioVolumeKind.callAudio.platformValue, 65);
    await platform.setAudioVolume(AudioVolumeKind.ringback.platformValue, 30);

    expect(levels.microphone, 80);
    expect(levels.callAudio, 65);
    expect(levels.ringtone, 40);
    expect(levels.ringback, 30);
    expect(calls.map((call) => call.method), [
      'getAudioVolumeLevels',
      'setAudioVolume',
      'setAudioVolume',
    ]);
    expect(calls[1].arguments, {'kind': 'callAudio', 'level': 65});
    expect(calls.last.arguments, {'kind': 'ringback', 'level': 30});
  });

  test('malformed platform levels fall back safely and clamp', () {
    final levels = AudioVolumeLevels.fromPlatform({
      'microphone': -10,
      'callAudio': 135,
      'ringtone': 'invalid',
      'ringback': -5,
    });

    expect(levels.microphone, 0);
    expect(levels.callAudio, 100);
    expect(levels.ringtone, 100);
    expect(levels.ringback, 0);
  });
}
