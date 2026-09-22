import 'dart:typed_data';

class CarrierMessage {
  const CarrierMessage({
    required this.id,
    required this.remoteNumber,
    required this.direction,
    required this.text,
    required this.status,
    required this.createdAt,
    this.clientId,
    this.errorCode,
    this.segmentCount = 1,
    this.segmentsSubmitted = 0,
    this.attachments = const [],
  });

  factory CarrierMessage.fromJson(
    Map<String, dynamic> json, {
    String? localNumber,
  }) {
    final attachments = json['attachments'];
    final direction = MessageDirectionCodec.parse(_string(json['direction']));
    final from = _string(json['from_e164'] ?? json['from']);
    final to = _string(json['to_e164'] ?? json['to']);
    final explicitRemote = _string(
      json['remoteNumber'] ?? json['remote_number'] ?? json['participant'],
    );
    return CarrierMessage(
      id: _string(json['id']),
      clientId: _nullableString(json['clientId'] ?? json['client_id']),
      errorCode: _nullableString(json['errorCode'] ?? json['error_code']),
      segmentCount: _int(json['segmentCount'] ?? json['segment_count']) ?? 1,
      segmentsSubmitted:
          _int(json['segmentsSubmitted'] ?? json['segments_submitted']) ?? 0,
      remoteNumber: explicitRemote.isNotEmpty
          ? explicitRemote
          : _remoteNumber(
              direction: direction,
              from: from,
              to: to,
              localNumber: localNumber,
            ),
      direction: direction,
      text: _string(json['text'] ?? json['body']),
      status: MessageStatusCodec.parse(
        _string(json['status'] ?? json['state']),
      ),
      createdAt:
          _date(json['createdAt'] ?? json['created_at']) ?? DateTime.now(),
      attachments: attachments is List
          ? attachments
                .whereType<Map>()
                .map(
                  (item) => MessageAttachment.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }

  final String id;
  final String? clientId;
  final String? errorCode;
  final int segmentCount;
  final int segmentsSubmitted;
  final String remoteNumber;
  final MessageDirection direction;
  final String text;
  final MessageStatus status;
  final DateTime createdAt;
  final List<MessageAttachment> attachments;

  bool get canRetry =>
      direction == MessageDirection.outgoing &&
      (status == MessageStatus.failed || status == MessageStatus.undelivered) &&
      errorCode != 'submission_uncertain' &&
      (attachments.isEmpty ||
          (attachments.length == 1 &&
              attachments.single.state == MessageAttachmentState.ready &&
              attachments.single.downloadUri != null));
}

class MessageAttachment {
  const MessageAttachment({
    required this.id,
    required this.contentType,
    this.state = MessageAttachmentState.pending,
    this.fileName,
    this.sizeBytes,
    this.downloadUri,
  });

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    final rawDownloadUri = _nullableString(
      json['downloadUrl'] ?? json['download_url'] ?? json['url'],
    );
    final rawState = _string(json['state']);
    return MessageAttachment(
      id: _string(json['id']),
      contentType: _string(
        json['contentType'] ?? json['content_type'] ?? json['mime_type'],
      ),
      state: rawState.isEmpty && rawDownloadUri != null
          ? MessageAttachmentState.ready
          : MessageAttachmentStateCodec.parse(rawState),
      fileName: _nullableString(json['fileName'] ?? json['file_name']),
      sizeBytes: _int(json['sizeBytes'] ?? json['size_bytes']),
      downloadUri: rawDownloadUri == null ? null : Uri.tryParse(rawDownloadUri),
    );
  }

  final String id;
  final String contentType;
  final MessageAttachmentState state;
  final String? fileName;
  final int? sizeBytes;
  final Uri? downloadUri;
}

enum MessageAttachmentState { pending, retrying, ready, rejected, expired }

extension MessageAttachmentStateCodec on MessageAttachmentState {
  static MessageAttachmentState parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'ready' => MessageAttachmentState.ready,
      'retry' || 'fetching' => MessageAttachmentState.retrying,
      'rejected' || 'failed' => MessageAttachmentState.rejected,
      'expired' || 'purged' => MessageAttachmentState.expired,
      _ => MessageAttachmentState.pending,
    };
  }
}

class MessageAttachmentContent {
  const MessageAttachmentContent({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}

enum MessageDirection { incoming, outgoing }

extension MessageDirectionCodec on MessageDirection {
  static MessageDirection parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'incoming' || 'inbound' => MessageDirection.incoming,
      _ => MessageDirection.outgoing,
    };
  }
}

enum MessageStatus {
  received,
  queued,
  sending,
  submitted,
  sent,
  delivered,
  undelivered,
  failed,
}

extension MessageStatusCodec on MessageStatus {
  static MessageStatus parse(String value) {
    return switch (value.trim().toLowerCase()) {
      'accepted' || 'queued' || 'pending' => MessageStatus.queued,
      'sending' => MessageStatus.sending,
      'submitted' => MessageStatus.submitted,
      'sent' => MessageStatus.sent,
      'delivered' => MessageStatus.delivered,
      'undelivered' => MessageStatus.undelivered,
      'failed' => MessageStatus.failed,
      'received' => MessageStatus.received,
      // Delivery must fail closed. An unfamiliar provider state is not proof
      // that the carrier accepted or delivered the outbound message.
      _ => MessageStatus.queued,
    };
  }
}

String _string(Object? value) => '${value ?? ''}'.trim();
String? _nullableString(Object? value) {
  final result = _string(value);
  return result.isEmpty ? null : result;
}

int? _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');

DateTime? _date(Object? value) {
  if (value is num) {
    final raw = value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      raw < 10000000000 ? raw * 1000 : raw,
    );
  }
  return DateTime.tryParse(_string(value));
}

String _remoteNumber({
  required MessageDirection direction,
  required String from,
  required String to,
  String? localNumber,
}) {
  final local = localNumber?.trim() ?? '';
  if (local.isNotEmpty) {
    if (from == local) return to;
    if (to == local) return from;
  }
  return direction == MessageDirection.incoming ? from : to;
}
