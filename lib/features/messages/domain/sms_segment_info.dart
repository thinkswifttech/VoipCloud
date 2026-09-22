import 'dart:math' as math;

enum SmsEncoding { gsm7, ucs2 }

class SmsSegmentInfo {
  const SmsSegmentInfo({
    required this.encoding,
    required this.units,
    required this.segmentCount,
    required this.unitsRemaining,
  });

  final SmsEncoding encoding;

  /// GSM-7 septets or UTF-16 code units, depending on [encoding].
  final int units;
  final int segmentCount;
  final int unitsRemaining;

  bool fitsWithin(int maximumSegments) => segmentCount <= maximumSegments;
}

/// Calculates the number of over-the-air SMS segments without changing the
/// logical message. The carrier is responsible for adding concatenation
/// headers and the receiving handset reassembles the parts into one message.
SmsSegmentInfo analyzeSmsSegments(String text) {
  if (text.isEmpty) {
    return const SmsSegmentInfo(
      encoding: SmsEncoding.gsm7,
      units: 0,
      segmentCount: 0,
      unitsRemaining: 160,
    );
  }

  var gsmUnits = 0;
  var isGsm7 = true;
  for (final rune in text.runes) {
    if (_gsm7BasicRunes.contains(rune)) {
      gsmUnits += 1;
    } else if (_gsm7ExtensionRunes.contains(rune)) {
      // Extension-table characters require an escape septet.
      gsmUnits += 2;
    } else {
      isGsm7 = false;
      break;
    }
  }

  if (isGsm7) {
    return _result(
      encoding: SmsEncoding.gsm7,
      units: gsmUnits,
      singleSegmentCapacity: 160,
      concatenatedSegmentCapacity: 153,
    );
  }

  // SMS transports commonly call this UCS-2. Dart's UTF-16 code units match
  // the transport cost of BMP characters and surrogate-pair emoji.
  return _result(
    encoding: SmsEncoding.ucs2,
    units: text.codeUnits.length,
    singleSegmentCapacity: 70,
    concatenatedSegmentCapacity: 67,
  );
}

SmsSegmentInfo _result({
  required SmsEncoding encoding,
  required int units,
  required int singleSegmentCapacity,
  required int concatenatedSegmentCapacity,
}) {
  final segmentCount = units <= singleSegmentCapacity
      ? 1
      : (units / concatenatedSegmentCapacity).ceil();
  final capacity = segmentCount == 1
      ? singleSegmentCapacity
      : segmentCount * concatenatedSegmentCapacity;
  return SmsSegmentInfo(
    encoding: encoding,
    units: units,
    segmentCount: segmentCount,
    unitsRemaining: math.max(0, capacity - units),
  );
}

final Set<int> _gsm7BasicRunes = {
  for (final rune
      in '@£\$¥èéùìòÇ\nØø\rÅåΔ_\u03a6ΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà'
          .runes)
    rune,
};

final Set<int> _gsm7ExtensionRunes = '^{}\\[~]|€'.runes.toSet();
