import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/domain/audio_output_route.dart';

void main() {
  group('AudioOutputRouteOption', () {
    test('retains Telecom endpoint identity and selection', () {
      final option = AudioOutputRouteOption.fromPlatform(const {
        'id': 'endpoint-airpods',
        'route': 'bluetooth',
        'label': 'AirPods',
        'available': true,
        'selected': true,
      });

      expect(option.endpointId, 'endpoint-airpods');
      expect(option.route, AudioOutputRoute.bluetooth);
      expect(option.label, 'AirPods');
      expect(option.available, isTrue);
      expect(option.selected, isTrue);
    });

    test('supports wired and automotive streaming endpoints', () {
      final wired = AudioOutputRouteOption.fromPlatform(const {
        'id': 'wired-1',
        'route': 'wired',
        'label': 'USB headset',
      });
      final streaming = AudioOutputRouteOption.fromPlatform(const {
        'id': 'car-1',
        'route': 'streaming',
        'label': 'Android Auto',
      });

      expect(wired.route, AudioOutputRoute.wired);
      expect(streaming.route, AudioOutputRoute.streaming);
    });

    test('falls back safely for legacy Linphone routes', () {
      final option = AudioOutputRouteOption.fromPlatform(const {
        'route': 'unknown',
        'label': '',
      });

      expect(option.route, AudioOutputRoute.earpiece);
      expect(option.endpointId, isNull);
      expect(option.label, 'Audio');
    });
  });
}
