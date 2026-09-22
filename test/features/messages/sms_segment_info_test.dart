import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/sms_segment_info.dart';

void main() {
  group('SMS segment calculation', () {
    test('uses GSM-7 single and concatenated capacities', () {
      final one = analyzeSmsSegments('a' * 160);
      final two = analyzeSmsSegments('a' * 161);

      expect(one.encoding, SmsEncoding.gsm7);
      expect(one.segmentCount, 1);
      expect(one.unitsRemaining, 0);
      expect(two.encoding, SmsEncoding.gsm7);
      expect(two.segmentCount, 2);
      expect(two.unitsRemaining, 145);
    });

    test('counts GSM extension-table characters as two septets', () {
      expect(analyzeSmsSegments('^' * 80).segmentCount, 1);
      expect(analyzeSmsSegments('^' * 81).segmentCount, 2);
    });

    test('uses UCS-2 capacities when text contains Unicode', () {
      final one = analyzeSmsSegments('漢' * 70);
      final two = analyzeSmsSegments('漢' * 71);

      expect(one.encoding, SmsEncoding.ucs2);
      expect(one.segmentCount, 1);
      expect(two.encoding, SmsEncoding.ucs2);
      expect(two.segmentCount, 2);
      expect(two.unitsRemaining, 63);
    });

    test('emoji surrogate pairs consume two UCS-2 units', () {
      expect(analyzeSmsSegments('👍' * 35).segmentCount, 1);
      expect(analyzeSmsSegments('👍' * 36).segmentCount, 2);
    });

    test('reports whether the carrier segment ceiling is exceeded', () {
      expect(analyzeSmsSegments('a' * (153 * 10)).fitsWithin(10), isTrue);
      expect(analyzeSmsSegments('a' * (153 * 10 + 1)).fitsWithin(10), isFalse);
    });
  });
}
