import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/errors/app_exception.dart';
import '../domain/carrier_message.dart';
import '../domain/carrier_messaging_config.dart';
import '../domain/messaging_repository.dart';
import '../domain/sms_segment_info.dart';
import 'messaging_api_client.dart';
import 'messaging_attachment_cache.dart';
import 'messaging_connectivity.dart';
import 'message_image_normalizer.dart';
import 'messaging_outbox_store.dart';
import 'messaging_push_token_service.dart';
import 'messaging_replay_order.dart';
import 'messaging_session_manager.dart';
import 'messaging_session_store.dart';
import 'pusher_realtime_client.dart';

class DataPlaneMessagingRepository implements MessagingRepository {
  DataPlaneMessagingRepository({
    required MessagingApiClient api,
    required MessagingSessionManager sessions,
    required MessagingSessionStore store,
    Future<MessagingPushRegistration?> Function()? loadPushRegistration,
    MessagingOutboxStore? outbox,
    MessagingAttachmentCache? attachmentCache,
    MessagingConnectivity? connectivity,
  }) : _api = api,
       _sessions = sessions,
       _store = store,
       _loadPushRegistration = loadPushRegistration,
       _outbox = outbox,
       _attachmentCache = attachmentCache,
       _connectivity = connectivity {
    _realtime = PusherRealtimeClient(api);
    if (outbox != null && connectivity != null) {
      _connectivitySubscription = connectivity.changes.listen((online) {
        if (online) unawaited(_drainOutbox());
      });
    }
  }

  final MessagingApiClient _api;
  final MessagingSessionManager _sessions;
  final MessagingSessionStore _store;
  final Future<MessagingPushRegistration?> Function()? _loadPushRegistration;
  final MessagingOutboxStore? _outbox;
  final MessagingAttachmentCache? _attachmentCache;
  final MessagingConnectivity? _connectivity;
  late PusherRealtimeClient _realtime;
  final Map<String, String> _conversationByRemote = {};
  final Map<String, String> _remoteByConversation = {};
  StreamController<CarrierMessage> _messages =
      StreamController<CarrierMessage>.broadcast();
  StreamController<void> _inboxInvalidations =
      StreamController<void>.broadcast();
  StreamSubscription<int>? _realtimeSubscription;
  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _outboxRetryTimer;
  Timer? _replayRetryTimer;
  Future<void>? _outboxDrainInFlight;
  int _outboxBackoffAttempt = 0;
  int _replayBackoffAttempt = 0;
  Future<void>? _replayInFlight;
  CarrierMessagingConfig? _activeConfig;
  bool _realtimeStarted = false;
  bool _canSend = false;
  bool _canSendMms = false;
  int _maxOutboundSmsSegments = 10;
  int _maxOutboundAttachmentBytes = 1000000;
  Set<String> _outboundAttachmentMimeTypes = const {'image/jpeg'};

  @override
  bool get isConfigured => true;

  @override
  bool get canSend => _canSend;

  @override
  bool get canSendMms => _canSendMms;

  @override
  int get maxOutboundSmsSegments => _maxOutboundSmsSegments;

  @override
  int get maxOutboundAttachmentBytes => _maxOutboundAttachmentBytes;

  @override
  Set<String> get outboundAttachmentMimeTypes => _outboundAttachmentMimeTypes;

  @override
  Future<CarrierMessagingConfig?> discoverConfig() async {
    try {
      await _sessions.ensure();
      final response = await _api.get<Map<String, dynamic>>(
        '/api/v1/messaging/session',
      );
      final inbox = response.data?['inbox'];
      if (inbox is! Map) return null;
      final values = Map<String, dynamic>.from(inbox);
      final inboxId = '${values['id'] ?? ''}'.trim();
      final did = '${values['did_e164'] ?? ''}'.trim();
      final enabled =
          values['sms_capable'] == true || values['mms_capable'] == true;
      if (inboxId.isEmpty || did.isEmpty) return null;
      return CarrierMessagingConfig(
        enabled: enabled,
        did: did,
        inboxId: inboxId,
      );
    } on ApiException catch (error) {
      if (error.statusCode == 403) return null;
      rethrow;
    }
  }

  @override
  Future<MessagingInboxSnapshot> loadInbox({
    required CarrierMessagingConfig config,
    String? cursor,
  }) async {
    _activeConfig = config;
    final capabilityResponse = await _api.get<Map<String, dynamic>>(
      '/api/v1/messaging/capabilities',
    );
    final capabilityData = capabilityResponse.data?['data'];
    _canSend = capabilityData is Map && capabilityData['can_send'] == true;
    _canSendMms =
        capabilityData is Map && capabilityData['can_send_mms'] == true;
    if (capabilityData is Map) {
      _maxOutboundSmsSegments =
          (_int(capabilityData['outbound_sms_max_segments']) ?? 10).clamp(
            1,
            255,
          );
      _maxOutboundAttachmentBytes =
          _int(capabilityData['outbound_mms_max_attachment_bytes']) ?? 1000000;
      final mimeTypes = capabilityData['outbound_mms_allowed_mime_types'];
      _outboundAttachmentMimeTypes = mimeTypes is List
          ? mimeTypes
                .map((value) => '$value'.trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toSet()
          : const {'image/jpeg'};
    }
    final blocksResponse = await _api.get<Map<String, dynamic>>(
      '/api/v1/messaging/blocks',
    );
    final blocks = <String, MessagingBlock>{};
    for (final row in _maps(blocksResponse.data?['data'])) {
      final block = MessagingBlock.fromJson(row);
      if (block.id.isNotEmpty && block.remoteNumber.isNotEmpty) {
        blocks[block.remoteNumber] = block;
      }
    }
    await _registerPushEndpoint();
    final response = await _api.get<Map<String, dynamic>>(
      '/api/v1/messaging/conversations',
      queryParameters: {
        'limit': 100,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    final data = response.data ?? const {};
    final rows = _maps(data['data']);
    final messages = <CarrierMessage>[];
    final unread = <String, int>{};
    final remotes = <String>[];

    for (final row in rows) {
      final conversationId = '${row['id'] ?? ''}'.trim();
      final remote = '${row['remote_e164'] ?? ''}'.trim();
      if (conversationId.isEmpty || remote.isEmpty) continue;
      _conversationByRemote[remote] = conversationId;
      _remoteByConversation[conversationId] = remote;
      remotes.add(remote);
      unread[remote] = _int(row['unread_count']) ?? 0;
      final lastMessage = row['last_message'];
      if (lastMessage is Map) {
        messages.add(
          CarrierMessage.fromJson(
            Map<String, dynamic>.from(lastMessage),
            localNumber: config.did,
          ),
        );
      }
    }

    return MessagingInboxSnapshot(
      messages: messages,
      remoteNumbers: remotes,
      unreadByRemoteNumber: unread,
      blocksByRemoteNumber: blocks,
      nextCursor: _nullable(data['next_cursor']),
    );
  }

  @override
  Future<MessagingMessagePage> loadConversation({
    required CarrierMessagingConfig config,
    required String remoteNumber,
    String? cursor,
  }) async {
    _activeConfig = config;
    var conversationId = _conversationByRemote[remoteNumber];
    if (conversationId == null) {
      await loadInbox(config: config);
      conversationId = _conversationByRemote[remoteNumber];
    }
    if (conversationId == null) return const MessagingMessagePage();

    final response = await _api.get<Map<String, dynamic>>(
      '/api/v1/messaging/conversations/$conversationId/messages',
      queryParameters: {
        'limit': 100,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    return MessagingMessagePage(
      messages: _maps(response.data?['data'])
          .map((row) => CarrierMessage.fromJson(row, localNumber: config.did))
          .toList(growable: false),
      nextCursor: _nullable(response.data?['next_cursor']),
    );
  }

  @override
  Future<CarrierMessage?> loadMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  }) async {
    final normalizedId = messageId.trim();
    if (normalizedId.isEmpty) return null;
    final response = await _api.get<Map<String, dynamic>>(
      '/api/v1/messaging/messages/$normalizedId',
    );
    final row = response.data?['data'];
    if (row is! Map) return null;
    return CarrierMessage.fromJson(
      Map<String, dynamic>.from(row),
      localNumber: config.did,
    );
  }

  @override
  Future<MessageAttachmentContent> loadAttachment({
    required CarrierMessagingConfig config,
    required MessageAttachment attachment,
  }) async {
    final cache = _attachmentCache;
    if (cache != null) {
      return cache.getOrLoad(
        inboxId: config.inboxId,
        attachment: attachment,
        loader: () => _downloadAttachment(attachment),
      );
    }
    return _downloadAttachment(attachment);
  }

  Future<MessageAttachmentContent> _downloadAttachment(
    MessageAttachment attachment,
  ) async {
    final uri = attachment.downloadUri;
    if (uri == null || uri.toString().trim().isEmpty) {
      throw const FormatException('Attachment is not ready for download.');
    }
    final response = await _api.get<List<int>>(
      uri.toString(),
      responseType: ResponseType.bytes,
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('Attachment download was empty.');
    }
    final responseType = response.headers
        .value(Headers.contentTypeHeader)
        ?.split(';')
        .first
        .trim();
    final contentType = responseType?.isNotEmpty == true
        ? responseType!
        : attachment.contentType;
    return MessageAttachmentContent(
      bytes: await normalizeMessageImage(
        bytes: Uint8List.fromList(bytes),
        contentType: contentType,
      ),
      contentType: contentType,
    );
  }

  @override
  Stream<CarrierMessage> watchMessages({
    required CarrierMessagingConfig config,
  }) {
    _activeConfig = config;
    if (!_realtimeStarted) {
      _realtimeStarted = true;
      _realtimeSubscription = _realtime.invalidations.listen((_) {
        _notifyInboxInvalidated();
        _requestReplay();
      }, onError: _messages.addError);
      unawaited(_realtime.start());
      _requestReplay();
      unawaited(_restoreThenDrainOutbox());
    }
    return _messages.stream;
  }

  @override
  Stream<void> watchInboxInvalidations({
    required CarrierMessagingConfig config,
  }) {
    _activeConfig = config;
    return _inboxInvalidations.stream;
  }

  @override
  Future<CarrierMessage> sendMessage({
    required CarrierMessagingConfig config,
    required String destination,
    required String text,
    required String clientId,
    OutboundMessageAttachment? attachment,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    if (attachment == null) {
      final segments = analyzeSmsSegments(text);
      if (!segments.fitsWithin(_maxOutboundSmsSegments)) {
        throw MessagingSmsSegmentLimitExceeded(
          actualSegments: segments.segmentCount,
          maximumSegments: _maxOutboundSmsSegments,
        );
      }
    }
    if (!_canSend) throw const MessagingOutboundUnavailable();
    if (attachment != null && !_canSendMms) {
      throw const MessagingOutboundUnavailable();
    }
    if (attachment != null &&
        (attachment.bytes.length > _maxOutboundAttachmentBytes ||
            !_outboundAttachmentMimeTypes.contains(
              attachment.contentType.toLowerCase(),
            ))) {
      throw const FormatException(
        'The attachment exceeds the current carrier media policy.',
      );
    }
    final item = MessagingOutboxItem(
      clientId: clientId,
      destination: destination,
      text: text,
      createdAt: DateTime.now(),
      attachment: attachment,
    );
    final outbox = _outbox;
    final connectivity = _connectivity;
    if (outbox != null &&
        connectivity != null &&
        !await connectivity.hasNetwork()) {
      await outbox.enqueue(item);
      return _queuedMessage(item);
    }
    try {
      return await _submitOutboxItem(
        config,
        item,
        onSendProgress: onSendProgress,
      );
    } on ApiException catch (error) {
      if (outbox == null || !_isRetryable(error)) rethrow;
      await outbox.enqueue(item);
      _scheduleOutboxRetry();
      return _queuedMessage(item);
    }
  }

  @override
  Future<CarrierMessage> retryMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  }) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/api/v1/messaging/messages/$messageId/retry',
    );
    final row = response.data?['data'];
    if (row is! Map) {
      throw const FormatException('Messaging API returned no message.');
    }
    return CarrierMessage.fromJson(
      Map<String, dynamic>.from(row),
      localNumber: config.did,
    );
  }

  Future<CarrierMessage> _submitOutboxItem(
    CarrierMessagingConfig config,
    MessagingOutboxItem item, {
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final attachment = item.attachment;
    final data = attachment == null
        ? <String, dynamic>{
            'client_message_id': item.clientId,
            'to_e164': item.destination,
            'body': item.text,
          }
        : FormData.fromMap({
            'client_message_id': item.clientId,
            'to_e164': item.destination,
            'body': item.text,
            'attachments[]': MultipartFile.fromBytes(
              attachment.bytes,
              filename: attachment.fileName,
            ),
          });
    final response = await _api.post<Map<String, dynamic>>(
      attachment == null
          ? '/api/v1/messaging/messages'
          : '/api/v1/messaging/messages/mms',
      data: data,
      onSendProgress: onSendProgress,
    );
    final row = response.data?['data'];
    if (row is! Map) {
      throw const FormatException('Messaging API returned no message.');
    }
    return CarrierMessage.fromJson(
      Map<String, dynamic>.from(row),
      localNumber: config.did,
    );
  }

  @override
  Future<void> markConversationRead({
    required CarrierMessagingConfig config,
    required String remoteNumber,
  }) async {
    var conversationId = _conversationByRemote[remoteNumber];
    if (conversationId == null) {
      await loadInbox(config: config);
      conversationId = _conversationByRemote[remoteNumber];
    }
    if (conversationId == null) return;
    await _api.post<void>(
      '/api/v1/messaging/conversations/$conversationId/read',
    );
  }

  @override
  Future<void> deleteConversation({
    required CarrierMessagingConfig config,
    required String remoteNumber,
  }) async {
    var conversationId = _conversationByRemote[remoteNumber];
    if (conversationId == null) {
      await loadInbox(config: config);
      conversationId = _conversationByRemote[remoteNumber];
    }
    if (conversationId == null) return;
    await _api.delete<void>('/api/v1/messaging/conversations/$conversationId');
    await _attachmentCache?.clear(deleteKey: false);
    _conversationByRemote.remove(remoteNumber);
    _remoteByConversation.remove(conversationId);
  }

  @override
  Future<void> deleteMessage({
    required CarrierMessagingConfig config,
    required String messageId,
  }) async {
    await _api.delete<void>('/api/v1/messaging/messages/$messageId');
    await _attachmentCache?.clear(deleteKey: false);
  }

  @override
  Future<MessagingBlock> blockNumber({
    required CarrierMessagingConfig config,
    required String remoteNumber,
    String? reason,
  }) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/api/v1/messaging/blocks',
      data: {
        'remote_e164': remoteNumber,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    final row = response.data?['data'];
    if (row is! Map) {
      throw const FormatException('Messaging API returned no block record.');
    }
    return MessagingBlock.fromJson(Map<String, dynamic>.from(row));
  }

  @override
  Future<void> unblockNumber({
    required CarrierMessagingConfig config,
    required String blockId,
  }) => _api.delete<void>('/api/v1/messaging/blocks/$blockId');

  @override
  Future<void> clearLocalData() async {
    await _sessions.revoke();
    await _stopRealtime();
    _realtime = PusherRealtimeClient(_api);
    _conversationByRemote.clear();
    _remoteByConversation.clear();
    _activeConfig = null;
    _canSend = false;
    _canSendMms = false;
    _maxOutboundAttachmentBytes = 1000000;
    _outboundAttachmentMimeTypes = const {'image/jpeg'};
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _outboxBackoffAttempt = 0;
    _replayRetryTimer?.cancel();
    _replayRetryTimer = null;
    _replayBackoffAttempt = 0;
    await _outbox?.clear();
    await _attachmentCache?.clear();
    await _messages.close();
    _messages = StreamController<CarrierMessage>.broadcast();
    await _inboxInvalidations.close();
    _inboxInvalidations = StreamController<void>.broadcast();
  }

  Future<void> dispose() async {
    _outboxRetryTimer?.cancel();
    _replayRetryTimer?.cancel();
    await _connectivitySubscription?.cancel();
    await _connectivity?.dispose();
    await _stopRealtime();
    await _messages.close();
    await _inboxInvalidations.close();
  }

  Future<void> _registerPushEndpoint() async {
    final loader = _loadPushRegistration;
    if (loader == null) return;
    try {
      final registration = await loader();
      if (registration == null) return;
      await _api.post<Map<String, dynamic>>(
        '/api/v1/messaging/push-endpoints',
        data: {
          'provider': registration.provider,
          'token': registration.token,
          'environment': registration.environment,
        },
      );
    } catch (_) {
      // Push registration is retried on the next inbox synchronization. It
      // must never prevent history or realtime messaging from loading.
    }
  }

  Future<void> _restoreOutbox() async {
    final outbox = _outbox;
    if (outbox == null) return;
    try {
      for (final item in await outbox.readAll()) {
        _messages.add(_queuedMessage(item));
      }
    } catch (error) {
      _messages.addError(error);
    }
  }

  Future<void> _restoreThenDrainOutbox() async {
    await _restoreOutbox();
    await _drainOutbox();
  }

  Future<void> _drainOutbox() {
    final pending = _outboxDrainInFlight;
    if (pending != null) return pending;
    final future = _performOutboxDrain();
    _outboxDrainInFlight = future;
    return future.whenComplete(() {
      if (identical(_outboxDrainInFlight, future)) {
        _outboxDrainInFlight = null;
      }
    });
  }

  Future<void> _performOutboxDrain() async {
    final outbox = _outbox;
    final connectivity = _connectivity;
    final config = _activeConfig;
    if (outbox == null || connectivity == null || config == null || !_canSend) {
      return;
    }
    if (!await connectivity.hasNetwork()) return;
    final pending = await outbox.readAll();
    for (final item in pending) {
      try {
        final sent = await _submitOutboxItem(config, item);
        await outbox.remove(item.clientId);
        _messages.add(sent);
        _outboxBackoffAttempt = 0;
      } on ApiException catch (error) {
        if (_isRetryable(error)) {
          _scheduleOutboxRetry();
          return;
        }
        await outbox.remove(item.clientId);
        _messages.add(_failedOutboxMessage(item, error.code));
      }
    }
  }

  void _scheduleOutboxRetry() {
    if (_outboxRetryTimer?.isActive == true) return;
    final exponent = _outboxBackoffAttempt.clamp(0, 6);
    final seconds = (5 * (1 << exponent)).clamp(5, 300);
    _outboxBackoffAttempt++;
    _outboxRetryTimer = Timer(Duration(seconds: seconds), () {
      _outboxRetryTimer = null;
      unawaited(_drainOutbox());
    });
  }

  bool _isRetryable(ApiException error) {
    final status = error.statusCode;
    return status == null || status == 408 || status == 429 || status >= 500;
  }

  CarrierMessage _queuedMessage(MessagingOutboxItem item) => CarrierMessage(
    id: item.clientId,
    clientId: item.clientId,
    remoteNumber: item.destination,
    direction: MessageDirection.outgoing,
    text: item.text,
    status: MessageStatus.queued,
    createdAt: item.createdAt,
    attachments: _localAttachments(item),
  );

  CarrierMessage _failedOutboxMessage(
    MessagingOutboxItem item,
    String? errorCode,
  ) => CarrierMessage(
    id: '${item.clientId}-failed',
    clientId: item.clientId,
    errorCode: errorCode,
    remoteNumber: item.destination,
    direction: MessageDirection.outgoing,
    text: item.text,
    status: MessageStatus.failed,
    createdAt: item.createdAt,
    attachments: _localAttachments(item),
  );

  List<MessageAttachment> _localAttachments(MessagingOutboxItem item) {
    final attachment = item.attachment;
    if (attachment == null) return const [];
    return [
      MessageAttachment(
        id: '${item.clientId}-attachment',
        contentType: attachment.contentType,
        state: MessageAttachmentState.pending,
        fileName: attachment.fileName,
        sizeBytes: attachment.bytes.length,
      ),
    ];
  }

  Future<void> _stopRealtime() async {
    _realtimeStarted = false;
    await _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    await _realtime.dispose();
  }

  Future<void> _replay() {
    final pending = _replayInFlight;
    if (pending != null) return pending;
    final future = _performReplay();
    _replayInFlight = future;
    return future.whenComplete(() {
      if (identical(_replayInFlight, future)) _replayInFlight = null;
    });
  }

  Future<void> _performReplay() async {
    final config = _activeConfig;
    if (config == null) return;
    var after = await _store.readLastSequence();

    var processedEvent = false;
    for (var page = 0; page < 20; page++) {
      final response = await _api.get<Map<String, dynamic>>(
        '/api/v1/messaging/events',
        queryParameters: {'after': after, 'limit': 500},
      );
      final data = response.data ?? const {};
      final events = orderedMessagingEventsAfter(data['data'], after: after);
      for (final event in events) {
        processedEvent = true;
        final eventType = '${event['event_type'] ?? ''}';
        final payload = event['payload'];
        final values = payload is Map
            ? Map<String, dynamic>.from(payload)
            : const <String, dynamic>{};
        final conversationId = '${event['conversation_id'] ?? ''}'.trim();
        if (conversationId.isNotEmpty &&
            !_remoteByConversation.containsKey(conversationId)) {
          await loadInbox(config: config);
        }
        if (eventType.startsWith('message.') &&
            eventType != 'message.blocked' &&
            eventType != 'message.deleted') {
          final messageId = '${values['message_id'] ?? ''}'.trim();
          if (messageId.isNotEmpty) {
            try {
              final messageResponse = await _api.get<Map<String, dynamic>>(
                '/api/v1/messaging/messages/$messageId',
              );
              final row = messageResponse.data?['data'];
              if (row is Map) {
                _messages.add(
                  CarrierMessage.fromJson(
                    Map<String, dynamic>.from(row),
                    localNumber: config.did,
                  ),
                );
              }
            } on ApiException catch (error) {
              // A deleted/hidden message is an event-stream tombstone. It
              // must not prevent every newer status event from replaying.
              if (error.statusCode != 404 && error.statusCode != 410) rethrow;
            }
          }
        }
        after = _int(event['sequence']) ?? after;
      }
      await _store.writeLastSequence(after);
      if (data['has_more'] != true || events.isEmpty) break;
    }
    if (processedEvent) _notifyInboxInvalidated();
  }

  void _notifyInboxInvalidated() {
    if (!_inboxInvalidations.isClosed) _inboxInvalidations.add(null);
  }

  void _requestReplay() => unawaited(_runReplaySafely());

  Future<void> _runReplaySafely() async {
    try {
      await _replay();
      _replayRetryTimer?.cancel();
      _replayRetryTimer = null;
      _replayBackoffAttempt = 0;
    } catch (error, stackTrace) {
      if (!_messages.isClosed) _messages.addError(error, stackTrace);
      _scheduleReplayRetry();
    }
  }

  void _scheduleReplayRetry() {
    if (!_realtimeStarted || _replayRetryTimer?.isActive == true) return;
    final exponent = _replayBackoffAttempt.clamp(0, 6);
    final seconds = (5 * (1 << exponent)).clamp(5, 300);
    _replayBackoffAttempt++;
    _replayRetryTimer = Timer(Duration(seconds: seconds), () {
      _replayRetryTimer = null;
      _requestReplay();
    });
  }
}

List<Map<String, dynamic>> _maps(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

String? _nullable(Object? value) {
  final text = '${value ?? ''}'.trim();
  return text.isEmpty ? null : text;
}

int? _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');
