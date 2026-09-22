import 'dart:math' as math;

import 'package:characters/characters.dart';

enum SmsEncoding { gsm7, ucs2 }

/// Replaces visually equivalent Unicode typography that would otherwise force
/// an entire SMS into UCS-2. Meaningful Unicode is deliberately preserved.
String smartEncodeSmsText(String value) {
  var result = value;
  for (final entry in _smartEncodingReplacements.entries) {
    result = result.replaceAll(entry.key, entry.value);
  }
  return result;
}

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

/// Counts independent provider submissions using the carrier's per-request
/// ceiling. Ordinary text wraps at whitespace; only a single word/grapheme
/// that is itself longer than the ceiling may require a hard split.
SmsSegmentInfo analyzeIndependentSmsParts(String text) {
  final base = analyzeSmsSegments(text);
  if (text.isEmpty || base.segmentCount == 1) return base;

  final graphemes = text.characters.toList(growable: false);
  final costs = graphemes
      .map(
        (grapheme) => base.encoding == SmsEncoding.gsm7
            ? _gsmUnits(grapheme)
            : grapheme.codeUnits.length,
      )
      .toList(growable: false);
  final perSubmit = base.encoding == SmsEncoding.gsm7 ? 160 : 70;
  var offset = 0;
  var parts = 0;
  var remaining = 0;
  while (offset < costs.length) {
    var end = offset;
    var used = 0;
    while (end < costs.length && used + costs[end] <= perSubmit) {
      used += costs[end];
      end++;
    }
    if (end == offset) {
      // Preserve extended emoji/combining sequences as atomic graphemes.
      return SmsSegmentInfo(
        encoding: base.encoding,
        units: base.units,
        segmentCount: 1 << 30,
        unitsRemaining: 0,
      );
    }
    if (end < costs.length) {
      var boundary = -1;
      for (var index = end - 1; index > offset; index--) {
        if (_smsWhitespace.hasMatch(graphemes[index])) {
          boundary = index;
          break;
        }
      }
      if (boundary >= 0) {
        end = boundary;
        used = 0;
        for (var index = offset; index < end; index++) {
          used += costs[index];
        }
        do {
          end++;
        } while (end < graphemes.length &&
            _smsWhitespace.hasMatch(graphemes[end]));
      }
    }
    parts++;
    remaining = math.max(0, perSubmit - used);
    offset = end;
  }
  return SmsSegmentInfo(
    encoding: base.encoding,
    units: base.units,
    segmentCount: parts,
    unitsRemaining: remaining,
  );
}

int _gsmUnits(String value) {
  var units = 0;
  for (final rune in value.runes) {
    units += _gsm7ExtensionRunes.contains(rune) ? 2 : 1;
  }
  return units;
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
final RegExp _smsWhitespace = RegExp(r'^\s+$', unicode: true);

const _smartEncodingReplacements = <String, String>{
  '\u00a0': ' ',
  '\u2000': ' ',
  '\u2001': ' ',
  '\u2002': ' ',
  '\u2003': ' ',
  '\u2004': ' ',
  '\u2005': ' ',
  '\u2006': ' ',
  '\u2007': ' ',
  '\u2008': ' ',
  '\u2009': ' ',
  '\u200a': ' ',
  '\u202f': ' ',
  '\u205f': ' ',
  '\u3000': ' ',
  '\u200b': '',
  '\ufeff': '',
  '\u2018': "'",
  '\u2019': "'",
  '\u201a': "'",
  '\u201b': "'",
  '\u2032': "'",
  '\u00b4': "'",
  '\u0060': "'",
  '\u201c': '"',
  '\u201d': '"',
  '\u201e': '"',
  '\u201f': '"',
  '\u2033': '"',
  '\u00ab': '"',
  '\u00bb': '"',
  '\u2010': '-',
  '\u2011': '-',
  '\u2012': '-',
  '\u2013': '-',
  '\u2014': '-',
  '\u2015': '-',
  '\u2212': '-',
  '\u2026': '...',
  '\uff08': '(',
  '\uff09': ')',
  '\uff0c': ',',
  '\uff0e': '.',
  '\uff1a': ':',
  '\uff1b': ';',
  '\uff01': '!',
  '\uff1f': '?',
};
