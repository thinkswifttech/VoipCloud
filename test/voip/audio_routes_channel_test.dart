import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/voip/platform/voip_platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passes the exact output endpoint and confirmed route', () async {
    const channel = MethodChannel('voipcloud/test_select_output');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setAudioRoute');
      expect(call.arguments, {'route': 'bluetooth', 'endpointId': 'headset-2'});
      return 'bluetooth';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(
      await const VoipPlatformChannel(
        channel: channel,
      ).setAudioRoute('bluetooth', endpointId: 'headset-2'),
      'bluetooth',
    );
  });

  test('keeps microphone selection separate from output selection', () async {
    const channel = MethodChannel('voipcloud/test_select_input');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setAudioInputDevice');
      expect(call.arguments, {'endpointId': 'windows:input:usb-mic'});
      return 'windows:input:usb-mic';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(
      await const VoipPlatformChannel(
        channel: channel,
      ).setAudioInputDevice('windows:input:usb-mic'),
      'windows:input:usb-mic',
    );
  });

  test('propagates failed activation instead of claiming success', () async {
    const channel = MethodChannel('voipcloud/test_route_failure');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'AUDIO_ROUTE',
        message: 'Endpoint unavailable',
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await expectLater(
      const VoipPlatformChannel(
        channel: channel,
      ).setAudioRoute('bluetooth', endpointId: 'disconnected'),
      throwsA(isA<PlatformException>()),
    );
  });

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
