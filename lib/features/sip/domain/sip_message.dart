/// A plain SIP `MESSAGE` event from liblinphone.
///
/// This is a technical SIP capability and must never be used as the carrier
/// SMS/MMS product transport.
class SipMessage {
  const SipMessage({
    required this.id,
    required this.remoteUri,
    required this.direction,
    required this.text,
    required this.status,
    required this.createdAt,
  });

  factory SipMessage.fromPlatformEvent(Map<String, dynamic> event) {
    return SipMessage(
      id: _string(
        event['id'],
        fallback: '${DateTime.now().microsecondsSinceEpoch}',
      ),
      remoteUri: _string(event['remoteUri']),
      direction: SipMessageDirectionCodec.parse(_string(event['direction'])),
      text: _string(event['text']),
      status: SipMessageStatusCodec.parse(_string(event['status'])),
      createdAt: _date(event['createdAt']) ?? DateTime.now(),
    );
  }

  final String id;
  final String remoteUri;
  final SipMessageDirection direction;
  final String text;
  final SipMessageStatus status;
  final DateTime createdAt;
}

enum SipMessageDirection { incoming, outgoing }

extension SipMessageDirectionCodec on SipMessageDirection {
  static SipMessageDirection parse(String value) {
    return value.trim().toLowerCase() == 'incoming'
        ? SipMessageDirection.incoming
        : SipMessageDirection.outgoing;
  }
}

enum SipMessageStatus { pending, sent, delivered, failed }

extension SipMessageStatusCodec on SipMessageStatus {
  static SipMessageStatus parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'pending' => SipMessageStatus.pending,
      'delivered' => SipMessageStatus.delivered,
      'failed' => SipMessageStatus.failed,
      _ => SipMessageStatus.sent,
    };
  }
}

String _string(Object? value, {String fallback = ''}) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? fallback : text;
}

DateTime? _date(Object? value) {
  if (value is num) {
    final raw = value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      raw < 10000000000 ? raw * 1000 : raw,
    );
  }
  return DateTime.tryParse('${value ?? ''}');
}
