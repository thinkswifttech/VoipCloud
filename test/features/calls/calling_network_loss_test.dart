import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/calls/domain/calling_network_loss.dart';

void main() {
  group('callingNetworkLossPathFrom', () {
    test('reads the network from the end message marker', () {
      expect(
        callingNetworkLossPathFrom('Call ended | calling_network_lost:wifi'),
        'wifi',
      );
      expect(
        callingNetworkLossPathFrom('calling_network_lost:cellular'),
        'cellular',
      );
    });

    test('ignores ordinary end messages and unknown networks', () {
      expect(callingNetworkLossPathFrom(null), isNull);
      expect(callingNetworkLossPathFrom(''), isNull);
      expect(callingNetworkLossPathFrom('Call completed elsewhere'), isNull);
      expect(
        callingNetworkLossPathFrom('calling_network_lost:bluetooth'),
        isNull,
      );
    });
  });

  group('callingNetworkLossMessage', () {
    test('names Wi-Fi without technical terms', () {
      final text = callingNetworkLossMessage('wifi');
      expect(text, contains('Wi‑Fi connection was lost'));
      expect(text, contains('Check your connection'));
      expect(text, contains('choose Auto'));
    });

    test('names mobile data', () {
      expect(
        callingNetworkLossMessage('cellular'),
        contains('mobile data connection was lost'),
      );
    });
  });
}
