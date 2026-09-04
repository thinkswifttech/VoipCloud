import 'package:phone_numbers_parser/phone_numbers_parser.dart';

/// Returns whether [value] is a valid US or Canadian phone number.
///
/// Region metadata is required because country code `1` is shared by multiple
/// North American Numbering Plan territories outside the US and Canada.
bool isUsOrCanadianNumber(String value) {
  var text = value.trim();
  if (text.isEmpty) return false;

  final lower = text.toLowerCase();
  if (lower.startsWith('tel:')) text = text.substring(4);

  final digits = text.replaceAll(RegExp(r'\D'), '');
  final international = switch (digits.length) {
    10 => '+1$digits',
    11 when digits.startsWith('1') => '+$digits',
    _ => text,
  };
  try {
    final number = PhoneNumber.parse(international);
    return (number.isoCode == IsoCode.US || number.isoCode == IsoCode.CA) &&
        number.isValid();
  } on PhoneNumberException {
    return false;
  } on FormatException {
    return false;
  }
}
