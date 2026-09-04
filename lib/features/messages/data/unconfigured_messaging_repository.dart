import '../domain/carrier_message.dart';
import '../domain/carrier_messaging_config.dart';
import '../domain/messaging_repository.dart';

class UnconfiguredMessagingRepository implements MessagingRepository {
  const UnconfiguredMessagingRepository();

  @override
  bool get isConfigured => false;

  @override
  bool get canSend => false;

  @override
  bool get canSendMms => false;

  @override
  int get maxOutboundAttachmentBytes => 1000000;

  @override
  Set<String> get outboundAttachmentMimeTypes => const {'image/jpeg'};

  @override
  Future<CarrierMessagingConfig?> discoverConfig() async => null;

  @override
  Future<MessagingInboxSnapshot> loadInbox({
    required CarrierMessagingConfig config,
    String? cursor,
  }) async => const MessagingInboxSnapshot();

  @override
  Stream<CarrierMessage> watchMessages({
    required CarrierMessagingConfig config,
  }) => const Stream.empty();

  @override
  Stream<void> watchInboxInvalidations({
    required CarrierMessagingConfig config,
  }) => const Stream.empty();

  @override
  Future<MessagingMessagePage> loadConversation({
    required CarrierMessagingConfig config,
    required String remoteNumber,
    String? cursor,
  }) async => const MessagingMessagePage();

  @override
  Future<CarrierMessage?> loadMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  }) async => null;

  @override
  Future<MessageAttachmentContent> loadAttachment({
    required CarrierMessagingConfig config,
    required MessageAttachment attachment,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<CarrierMessage> sendMessage({
    required CarrierMessagingConfig config,
    required String destination,
    required String text,
    required String clientId,
    OutboundMessageAttachment? attachment,
    void Function(int sent, int total)? onSendProgress,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<CarrierMessage> retryMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<void> markConversationRead({
    required CarrierMessagingConfig config,
    required String remoteNumber,
  }) async {}

  @override
  Future<void> deleteConversation({
    required CarrierMessagingConfig config,
    required String remoteNumber,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<void> deleteMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<MessagingBlock> blockNumber({
    required CarrierMessagingConfig config,
    required String remoteNumber,
    String? reason,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<void> unblockNumber({
    required CarrierMessagingConfig config,
    required String blockId,
  }) => Future.error(const MessagingIntegrationUnavailable());

  @override
  Future<void> clearLocalData() async {}
}
