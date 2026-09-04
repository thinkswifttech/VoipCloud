import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';
import 'package:phone_app/features/messages/domain/sms_compatibility.dart';

void main() {
  test('expands supported shortcodes into interoperable Unicode', () {
    expect(
      expandSmsEmojiShortcodes('Hello :smile: :thumbsup: unknown :nope:'),
      'Hello 😄 👍 unknown :nope:',
    );
  });

  test('formats and parses a visible carrier-safe quoted reply', () {
    final encoded = formatSmsQuotedReply(
      quotedText: 'Here is   my received\nmessage',
      response: 'And here is my response. :smile:',
    );

    expect(
      encoded,
      '"Here is my received message"\n\nAnd here is my response. 😄',
    );
    final parsed = parseSmsQuotedReply(encoded)!;
    expect(parsed.quote, 'Here is my received message');
    expect(parsed.response, 'And here is my response. 😄');
    expect(smsDisplayText(encoded), parsed.response);
  });

  test('continues to parse replies sent by older app versions', () {
    final parsed = parseSmsQuotedReply('> Previous message\n\nMy response')!;

    expect(parsed.quote, 'Previous message');
    expect(parsed.response, 'My response');
  });

  test('accepts typographic quotes from compatible messaging apps', () {
    final parsed = parseSmsQuotedReply('“Previous message”\n\nMy response')!;

    expect(parsed.quote, 'Previous message');
    expect(parsed.response, 'My response');
  });

  test('links a quoted reply to the nearest matching earlier message', () {
    final older = _message(id: 'older', text: 'Repeated message');
    final newer = _message(id: 'newer', text: 'Repeated message');
    final reply = _message(
      id: 'reply',
      text: formatSmsQuotedReply(
        quotedText: newer.text,
        response: 'My response',
      ),
    );

    final presentation = presentSmsThread([older, newer, reply]);

    expect(presentation.replyTargetMessageIdByMessageId['reply'], 'newer');
  });

  test('formats and links a photo reply without exposing an app token', () {
    final photo = _message(
      id: 'photo',
      text: '',
      attachments: const [
        MessageAttachment(id: 'image-1', contentType: 'image/jpeg'),
      ],
    );
    final replyText = formatSmsQuotedReply(
      quotedText: smsReplyTargetText(photo),
      response: 'Replied message',
    );
    final reply = _message(id: 'reply', text: replyText);

    final presentation = presentSmsThread([photo, reply]);

    expect(replyText, '"Photo"\n\nReplied message');
    expect(presentation.replyTargetMessageIdByMessageId['reply'], 'photo');
  });

  test('caps quoted excerpts without breaking the plain-text format', () {
    final excerpt = smsCompatibilityExcerpt(List.filled(140, 'a').join());
    expect(excerpt.runes.length, 120);
    expect(excerpt, endsWith('…'));
  });

  test('parses common reaction fallback wording and straight quotes', () {
    expect(
      formatSmsReaction(SmsReactionKind.like, 'See you at five'),
      '👍 to "See you at five"',
    );
    expect(
      parseSmsReaction('👍to "See you at five"')?.kind,
      SmsReactionKind.like,
    );
    expect(
      parseSmsReaction('Liked "See you at five"')?.kind,
      SmsReactionKind.like,
    );
    expect(
      parseSmsReaction('Laughed at “That was funny”')?.kind,
      SmsReactionKind.laugh,
    );
    expect(parseSmsReaction('I liked this'), isNull);
  });

  test('collapses a reaction only when it has one unique earlier target', () {
    final original = _message(id: 'original', text: 'See you at five');
    final reaction = _message(
      id: 'reaction',
      text: formatSmsReaction(SmsReactionKind.like, original.text),
      direction: MessageDirection.incoming,
    );

    final presented = presentSmsThread([original, reaction]);

    expect(presented.messages, [original]);
    expect(
      presented.reactionsByMessageId['original']?.single.kind,
      SmsReactionKind.like,
    );
  });

  test('leaves an ambiguous reaction visible as ordinary SMS', () {
    final first = _message(id: 'first', text: 'Repeated');
    final second = _message(id: 'second', text: 'Repeated');
    final reaction = _message(
      id: 'reaction',
      text: 'Loved “Repeated”',
      direction: MessageDirection.incoming,
    );

    final presented = presentSmsThread([first, second, reaction]);

    expect(presented.messages, [first, second, reaction]);
    expect(presented.reactionsByMessageId, isEmpty);
  });

  test('does not hide a failed outbound reaction', () {
    final original = _message(id: 'original', text: 'React to me');
    final failed = _message(
      id: 'failed-reaction',
      text: 'Liked “React to me”',
      status: MessageStatus.failed,
    );

    final presented = presentSmsThread([original, failed]);

    expect(presented.messages, [original, failed]);
    expect(presented.reactionsByMessageId, isEmpty);
  });

  test('optimistically attaches a queued outbound reaction', () {
    final original = _message(id: 'original', text: 'React to me');
    final queued = _message(
      id: 'queued-reaction',
      text: '👍 to "React to me"',
      status: MessageStatus.queued,
    );

    final presented = presentSmsThread([original, queued]);

    expect(presented.messages, [original]);
    final reaction = presented.reactionsByMessageId['original']!.single;
    expect(reaction.kind, SmsReactionKind.like);
    expect(reaction.isPending, isTrue);
  });

  test('latest reaction from each side replaces its earlier reaction', () {
    final original = _message(id: 'original', text: 'React to me');
    final like = _message(
      id: 'like',
      text: 'Liked “React to me”',
      direction: MessageDirection.incoming,
    );
    final love = _message(
      id: 'love',
      text: 'Loved “React to me”',
      direction: MessageDirection.incoming,
    );

    final reactions = presentSmsThread([
      original,
      like,
      love,
    ]).reactionsByMessageId['original']!;

    expect(reactions, hasLength(1));
    expect(reactions.single.kind, SmsReactionKind.love);
  });
}

CarrierMessage _message({
  required String id,
  required String text,
  MessageDirection direction = MessageDirection.outgoing,
  MessageStatus status = MessageStatus.submitted,
  List<MessageAttachment> attachments = const [],
}) {
  return CarrierMessage(
    id: id,
    remoteNumber: '+14165550100',
    direction: direction,
    text: text,
    status: status,
    createdAt: DateTime.utc(2026, 9, 1),
    attachments: attachments,
  );
}
