import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/contacts/domain/contact_number_eligibility.dart';

void main() {
  group('isUsOrCanadianNumber', () {
    test('accepts common US and Canadian formats', () {
      expect(isUsOrCanadianNumber('+1 (416) 555-0123'), isTrue);
      expect(isUsOrCanadianNumber('212-555-0199'), isTrue);
      expect(isUsOrCanadianNumber('tel:+16045550123'), isTrue);
    });

    test('rejects international, short, and structurally invalid numbers', () {
      expect(isUsOrCanadianNumber('+44 20 7946 0958'), isFalse);
      expect(isUsOrCanadianNumber('+1 242 327 0143'), isFalse);
      expect(isUsOrCanadianNumber('555-0123'), isFalse);
      expect(isUsOrCanadianNumber('+1 012 555 0199'), isFalse);
      expect(isUsOrCanadianNumber('+1 212 155 0199'), isFalse);
      expect(isUsOrCanadianNumber(''), isFalse);
    });
  });
}
