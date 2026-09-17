import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'decodes Windows audio endpoints from StandardMethodCodec maps',
    () async {
      const channel = MethodChannel('voipcloud/test_audio_routes');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getAudioRoutes');
            return <Object?>[
              <Object?, Object?>{
                'id': 'windows:output:speaker-id',
                'direction': 'output',
                'route': 'speaker',
                'label': 'Desktop speakers',
                'available': true,
                'selected': true,
              },
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final routes = await const VoipPlatformChannel(
        channel: channel,
      ).getAudioRoutes();

      expect(routes, hasLength(1));
      expect(routes.single['id'], 'windows:output:speaker-id');
      expect(routes.single['direction'], 'output');
      expect(routes.single['selected'], isTrue);
    },
  );

  test(
    'keeps valid devices when native payload contains malformed entries',
    () async {
      const channel = MethodChannel('voipcloud/test_audio_routes_malformed');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            return <Object?>[
              null,
              'not-a-map',
              <Object?, Object?>{42: 'ignored'},
              <Object?, Object?>{
                'id': 'windows:input:microphone-id',
                'direction': 'input',
                'route': 'streaming',
                'label': 'USB microphone',
              },
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final routes = await const VoipPlatformChannel(
        channel: channel,
      ).getAudioRoutes();

      expect(routes, hasLength(1));
      expect(routes.single['id'], 'windows:input:microphone-id');
    },
  );
}
