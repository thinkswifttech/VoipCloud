import 'carrier_message.dart';

/// Carrier-safe presentation helpers for features that SMS does not natively
/// model. The wire representation is always readable plain text so recipients
/// never need VoIPCloud to understand a message.
class SmsQuotedReply {
  const SmsQuotedReply({required this.quote, required this.response});

  final String quote;
  final String response;
}

enum SmsReactionKind { love, like, dislike, laugh, emphasize, question }

extension SmsReactionKindPresentation on SmsReactionKind {
  String get emoji => switch (this) {
    SmsReactionKind.love => '❤️',
    SmsReactionKind.like => '👍',
    SmsReactionKind.dislike => '👎',
    SmsReactionKind.laugh => '😂',
    SmsReactionKind.emphasize => '‼️',
    SmsReactionKind.question => '❓',
  };

  String get fallbackVerb => switch (this) {
    SmsReactionKind.love => 'Loved',
    SmsReactionKind.like => 'Liked',
    SmsReactionKind.dislike => 'Disliked',
    SmsReactionKind.laugh => 'Laughed at',
    SmsReactionKind.emphasize => 'Emphasized',
    SmsReactionKind.question => 'Questioned',
  };
}

class SmsReactionFallback {
  const SmsReactionFallback({required this.kind, required this.excerpt});

  final SmsReactionKind kind;
  final String excerpt;
}

class SmsReactionPresentation {
  const SmsReactionPresentation({
    required this.kind,
    required this.direction,
    required this.carrierMessageId,
    required this.status,
  });

  final SmsReactionKind kind;
  final MessageDirection direction;
  final String carrierMessageId;
  final MessageStatus status;

  bool get isPending =>
      status == MessageStatus.queued || status == MessageStatus.sending;
}

class SmsThreadPresentation {
  const SmsThreadPresentation({
    required this.messages,
    required this.reactionsByMessageId,
    required this.replyTargetMessageIdByMessageId,
  });

  final List<CarrierMessage> messages;
  final Map<String, List<SmsReactionPresentation>> reactionsByMessageId;
  final Map<String, String> replyTargetMessageIdByMessageId;
}

const _emojiShortcodes = <String, String>{
  ':smile:': '😄',
  ':grin:': '😁',
  ':laugh:': '😂',
  ':joy:': '😂',
  ':wink:': '😉',
  ':heart:': '❤️',
  ':thumbsup:': '👍',
  ':+1:': '👍',
  ':thumbsdown:': '👎',
  ':-1:': '👎',
  ':ok:': '👌',
  ':clap:': '👏',
  ':pray:': '🙏',
  ':wave:': '👋',
  ':fire:': '🔥',
  ':party:': '🎉',
  ':sad:': '😞',
  ':cry:': '😢',
};

String expandSmsEmojiShortcodes(String value) {
  var expanded = value;
  for (final entry in _emojiShortcodes.entries) {
    expanded = expanded.replaceAll(entry.key, entry.value);
  }
  return expanded;
}

String formatSmsQuotedReply({
  required String quotedText,
  required String response,
}) {
  final quote = smsCompatibilityExcerpt(quotedText);
  final body = expandSmsEmojiShortcodes(response.trim());
  if (quote.isEmpty) return body;
  if (body.isEmpty) return '"$quote"';
  return '"$quote"\n\n$body';
}

SmsQuotedReply? parseSmsQuotedReply(String value) {
  final normalized = value.replaceAll('\r\n', '\n');
  final quoted = _parseDelimitedQuotedReply(normalized);
  if (quoted != null) return quoted;

  // Continue understanding replies produced by older VoIPCloud clients.
  if (!normalized.startsWith('> ')) return null;
  final endOfQuote = normalized.indexOf('\n');
  if (endOfQuote < 0) {
    final quote = normalized.substring(2).trim();
    return quote.isEmpty ? null : SmsQuotedReply(quote: quote, response: '');
  }
  final quote = normalized.substring(2, endOfQuote).trim();
  if (quote.isEmpty) return null;
  var response = normalized.substring(endOfQuote + 1);
  if (response.startsWith('\n')) response = response.substring(1);
  return SmsQuotedReply(quote: quote, response: response.trim());
}

SmsQuotedReply? _parseDelimitedQuotedReply(String value) {
  final separator = value.indexOf('\n\n');
  if (separator < 0) return null;
  final quotedLine = value.substring(0, separator).trim();
  if (quotedLine.length < 2) return null;
  final hasStraightQuotes =
      quotedLine.startsWith('"') && quotedLine.endsWith('"');
  final hasCurlyQuotes = quotedLine.startsWith('“') && quotedLine.endsWith('”');
  if (!hasStraightQuotes && !hasCurlyQuotes) return null;
  final quote = quotedLine.substring(1, quotedLine.length - 1).trim();
  final response = value.substring(separator + 2).trim();
  if (quote.isEmpty || response.isEmpty) return null;
  return SmsQuotedReply(quote: quote, response: response);
}

String formatSmsReaction(SmsReactionKind kind, String targetText) {
  final excerpt = smsCompatibilityExcerpt(targetText);
  if (excerpt.isEmpty) {
    throw const FormatException('A text message is required for a reaction.');
  }
  return '${kind.emoji} to "$excerpt"';
}

SmsReactionFallback? parseSmsReaction(String value) {
  final trimmed = value.trim();
  for (final kind in SmsReactionKind.values) {
    final emoji = RegExp.escape(kind.emoji);
    final emojiMatch = RegExp(
      '^$emoji[ ]*to[ ]+[“"](.+)[”"]'
      r'$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmed);
    final emojiExcerpt = emojiMatch?.group(1)?.trim() ?? '';
    if (emojiExcerpt.isNotEmpty) {
      return SmsReactionFallback(kind: kind, excerpt: emojiExcerpt);
    }

    // Keep accepting established legacy fallback wording so reactions sent by
    // older VoIPCloud builds, iMessage, and other SMS apps still reconstruct.
    final verb = RegExp.escape(kind.fallbackVerb);
    final match = RegExp(
      '^$verb[ ]+[“"](.+)[”"]'
      r'$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmed);
    final excerpt = match?.group(1)?.trim() ?? '';
    if (excerpt.isNotEmpty) {
      return SmsReactionFallback(kind: kind, excerpt: excerpt);
    }
  }
  return null;
}

String smsDisplayText(String value) {
  final quoted = parseSmsQuotedReply(value);
  if (quoted == null) return value;
  return quoted.response.isEmpty ? quoted.quote : quoted.response;
}

String smsReactionTargetText(CarrierMessage message) {
  return smsDisplayText(message.text).trim();
}

String smsReplyTargetText(CarrierMessage message) {
  final text = smsReactionTargetText(message);
  if (text.isNotEmpty) return text;
  if (_hasImageAttachment(message)) return 'Photo';
  return message.attachments.isNotEmpty ? 'Attachment' : 'Message';
}

String smsCompatibilityExcerpt(String value, {int maximumRunes = 120}) {
  final flattened = smsDisplayText(
    value,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flattened.isEmpty) return '';
  final runes = flattened.runes.toList(growable: false);
  if (runes.length <= maximumRunes) return flattened;
  return '${String.fromCharCodes(runes.take(maximumRunes - 1))}…';
}

/// Resolves only unique, earlier text matches. Ambiguous or unrecognized
/// fallback messages remain visible as ordinary SMS instead of being attached
/// to the wrong message.
SmsThreadPresentation presentSmsThread(List<CarrierMessage> source) {
  final visible = <CarrierMessage>[];
  final reactions = <String, List<SmsReactionPresentation>>{};
  final replyTargets = <String, String>{};
  for (final message in source) {
    final fallback = parseSmsReaction(message.text);
    final canCollapse =
        fallback != null &&
        message.status != MessageStatus.failed &&
        message.status != MessageStatus.undelivered;
    if (canCollapse) {
      final candidates = visible
          .where((candidate) {
            final target = smsReactionTargetText(candidate);
            return target.isNotEmpty &&
                _excerptMatches(target, fallback.excerpt);
          })
          .toList(growable: false);
      if (candidates.length == 1) {
        final target = candidates.single;
        final current = reactions.putIfAbsent(target.id, () => []);
        current.removeWhere(
          (reaction) => reaction.direction == message.direction,
        );
        current.add(
          SmsReactionPresentation(
            kind: fallback.kind,
            direction: message.direction,
            carrierMessageId: message.id,
            status: message.status,
          ),
        );
        continue;
      }
    }
    final quotedReply = parseSmsQuotedReply(message.text);
    if (quotedReply != null) {
      final target = _latestReplyTarget(visible, quotedReply.quote);
      if (target != null) replyTargets[message.id] = target.id;
    }
    visible.add(message);
  }
  return SmsThreadPresentation(
    messages: List.unmodifiable(visible),
    reactionsByMessageId: {
      for (final entry in reactions.entries)
        entry.key: List.unmodifiable(entry.value),
    },
    replyTargetMessageIdByMessageId: Map.unmodifiable(replyTargets),
  );
}

CarrierMessage? _latestReplyTarget(
  List<CarrierMessage> candidates,
  String excerpt,
) {
  final photoReply = excerpt.trim().toLowerCase() == 'photo';
  for (final candidate in candidates.reversed) {
    if (photoReply && !_hasImageAttachment(candidate)) continue;
    if (_excerptMatches(smsReplyTargetText(candidate), excerpt)) {
      return candidate;
    }
  }
  return null;
}

bool _hasImageAttachment(CarrierMessage message) => message.attachments.any(
  (attachment) => attachment.contentType.startsWith('image/'),
);

bool _excerptMatches(String target, String excerpt) {
  final normalizedTarget = target.replaceAll(RegExp(r'\s+'), ' ').trim();
  final normalizedExcerpt = excerpt.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalizedExcerpt.endsWith('…')) {
    return normalizedTarget.startsWith(
      normalizedExcerpt.substring(0, normalizedExcerpt.length - 1),
    );
  }
  return normalizedTarget == normalizedExcerpt;
}
