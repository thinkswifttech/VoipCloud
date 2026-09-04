import 'dart:typed_data';

import 'carrier_message.dart';
import 'carrier_messaging_config.dart';

abstract interface class MessagingRepository {
  bool get isConfigured;

  bool get canSend;

  bool get canSendMms;

  int get maxOutboundAttachmentBytes;

  Set<String> get outboundAttachmentMimeTypes;

  Future<CarrierMessagingConfig?> discoverConfig();

  Future<MessagingInboxSnapshot> loadInbox({
    required CarrierMessagingConfig config,
    String? cursor,
  });

  Stream<CarrierMessage> watchMessages({
    required CarrierMessagingConfig config,
  });

  /// Signals that the authoritative inbox index changed. This includes
  /// message activity, read state, blocks, and inbox-local deletions.
  Stream<void> watchInboxInvalidations({
    required CarrierMessagingConfig config,
  });

  Future<MessagingMessagePage> loadConversation({
    required CarrierMessagingConfig config,
    required String remoteNumber,
    String? cursor,
  });

  Future<CarrierMessage?> loadMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  });

  Future<MessageAttachmentContent> loadAttachment({
    required CarrierMessagingConfig config,
    required MessageAttachment attachment,
  });

  Future<CarrierMessage> sendMessage({
    required CarrierMessagingConfig config,
    required String destination,
    required String text,
    required String clientId,
    OutboundMessageAttachment? attachment,
    void Function(int sent, int total)? onSendProgress,
  });

  Future<CarrierMessage> retryMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  });

  Future<void> markConversationRead({
    required CarrierMessagingConfig config,
    required String remoteNumber,
  });

  Future<void> deleteConversation({
    required CarrierMessagingConfig config,
    required String remoteNumber,
  });

  Future<void> deleteMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  });

  Future<MessagingBlock> blockNumber({
    required CarrierMessagingConfig config,
    required String remoteNumber,
    String? reason,
  });

  Future<void> unblockNumber({
    required CarrierMessagingConfig config,
    required String blockId,
  });

  Future<void> clearLocalData();
}

class OutboundMessageAttachment {
  const OutboundMessageAttachment({
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  final Uint8List bytes;
  final String fileName;
  final String contentType;
}

class MessagingInboxSnapshot {
  const MessagingInboxSnapshot({
    this.messages = const [],
    this.remoteNumbers = const [],
    this.unreadByRemoteNumber = const {},
    this.blocksByRemoteNumber = const {},
    this.nextCursor,
  });

  final List<CarrierMessage> messages;
  final List<String> remoteNumbers;
  final Map<String, int> unreadByRemoteNumber;
  final Map<String, MessagingBlock> blocksByRemoteNumber;
  final String? nextCursor;
}

class MessagingMessagePage {
  const MessagingMessagePage({this.messages = const [], this.nextCursor});

  final List<CarrierMessage> messages;
  final String? nextCursor;
}

class MessagingBlock {
  const MessagingBlock({
    required this.id,
    required this.remoteNumber,
    this.reason,
    this.blockedAt,
  });

  factory MessagingBlock.fromJson(Map<String, dynamic> json) {
    final blockedAt = '${json['blocked_at'] ?? ''}'.trim();
    return MessagingBlock(
      id: '${json['id'] ?? ''}'.trim(),
      remoteNumber: '${json['remote_e164'] ?? ''}'.trim(),
      reason: '${json['reason'] ?? ''}'.trim().isEmpty
          ? null
          : '${json['reason']}'.trim(),
      blockedAt: DateTime.tryParse(blockedAt),
    );
  }

  final String id;
  final String remoteNumber;
  final String? reason;
  final DateTime? blockedAt;
}

class MessagingIntegrationUnavailable implements Exception {
  const MessagingIntegrationUnavailable();

  @override
  String toString() => 'Carrier messaging data plane is not configured.';
}

class MessagingOutboundUnavailable implements Exception {
  const MessagingOutboundUnavailable();

  @override
  String toString() => 'Outbound carrier messaging is not enabled.';
}
