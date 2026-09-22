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

    test('counts independent GSM submissions without visible numbering', () {
      final two = analyzeIndependentSmsParts('a' * 161);
      final three = analyzeIndependentSmsParts('a' * 321);

      expect(two.encoding, SmsEncoding.gsm7);
      expect(two.segmentCount, 2);
      expect(two.unitsRemaining, 159);
      expect(three.segmentCount, 3);
    });

    test(
      'counts independent Unicode submissions without visible numbering',
      () {
        final two = analyzeIndependentSmsParts('漢' * 71);

        expect(two.encoding, SmsEncoding.ucs2);
        expect(two.segmentCount, 2);
        expect(two.unitsRemaining, 69);
      },
    );

    test('never splits a grapheme cluster across independent parts', () {
      final result = analyzeIndependentSmsParts('👨‍👩‍👧‍👦' * 20);

      expect(result.encoding, SmsEncoding.ucs2);
      expect(result.segmentCount, greaterThan(1));
    });

    test('fails closed when one grapheme cannot fit one submission', () {
      final result = analyzeIndependentSmsParts('a${'\u0301' * 80}b');

      expect(result.segmentCount, greaterThan(10));
    });

    test('smart encoding removes accidental Unicode segment inflation', () {
      final original = "I\u00a0think I\u2019m ready\u2026";
      final encoded = smartEncodeSmsText(original);

      expect(encoded, "I think I'm ready...");
      expect(analyzeSmsSegments(original).encoding, SmsEncoding.ucs2);
      expect(analyzeSmsSegments(encoded).encoding, SmsEncoding.gsm7);
    });

    test('smart encoding preserves meaningful Unicode', () {
      const original = 'Café 👍 漢字';
      expect(smartEncodeSmsText(original), original);
    });

    test('normalizes the reported pasted message from five parts to two', () {
      const original =
          'hi Eugene.\u00a0 I can give you their contact info,\u00a0 I only use '
          'them to cut my grass 1x a week.\u00a0 I think they have a tree '
          'crusher, mulching unit but I\u2019m not sure how much they will charge '
          'or the process to book it.\u00a0 Sam from Example Landscaping '
          '(416) 555-0101 or (416) 555-0102\u00a0 contact@example.test';
      final encoded = smartEncodeSmsText(original);

      expect(analyzeIndependentSmsParts(original).segmentCount, 5);
      expect(analyzeIndependentSmsParts(encoded).encoding, SmsEncoding.gsm7);
      expect(analyzeIndependentSmsParts(encoded).segmentCount, 2);
    });
  });
}
