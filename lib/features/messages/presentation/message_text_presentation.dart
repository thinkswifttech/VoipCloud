class MessageTextPresentation {
  const MessageTextPresentation({required this.fontSize, required this.height});

  final double fontSize;
  final double height;
}

/// Gives emoji-only messages the visual weight users expect from modern
/// messaging apps while leaving mixed and ordinary text at the standard size.
MessageTextPresentation messageTextPresentation(String value) {
  final emojiCount = _emojiOnlyBaseCount(value);
  if (emojiCount == null) {
    return const MessageTextPresentation(fontSize: 14, height: 1.35);
  }
  if (emojiCount <= 3) {
    return const MessageTextPresentation(fontSize: 30, height: 1.15);
  }
  if (emojiCount <= 6) {
    return const MessageTextPresentation(fontSize: 25, height: 1.18);
  }
  return const MessageTextPresentation(fontSize: 20, height: 1.25);
}

int? _emojiOnlyBaseCount(String value) {
  var count = 0;
  var hasKeycap = false;
  final runes = value.runes.toList(growable: false);
  for (final rune in runes) {
    if (_isWhitespace(rune) || _isEmojiComponent(rune)) {
      if (rune == 0x20E3) hasKeycap = true;
      continue;
    }
    if (_isEmojiBase(rune)) {
      count++;
      continue;
    }
    if ((rune == 0x23 || rune == 0x2A || (rune >= 0x30 && rune <= 0x39)) &&
        runes.contains(0x20E3)) {
      count++;
      continue;
    }
    return null;
  }
  if (count == 0 || (hasKeycap && count == 0)) return null;
  return count;
}

bool _isWhitespace(int rune) =>
    rune == 0x09 || rune == 0x0A || rune == 0x0D || rune == 0x20;

bool _isEmojiComponent(int rune) =>
    rune == 0x200D ||
    rune == 0x20E3 ||
    rune == 0xFE0E ||
    rune == 0xFE0F ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF);

bool _isEmojiBase(int rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) ||
    (rune >= 0x2300 && rune <= 0x23FF) ||
    (rune >= 0x2600 && rune <= 0x27BF) ||
    (rune >= 0x2B00 && rune <= 0x2BFF) ||
    const {
      0x00A9,
      0x00AE,
      0x203C,
      0x2049,
      0x2122,
      0x2139,
      0x3030,
      0x303D,
      0x3297,
      0x3299,
    }.contains(rune);
