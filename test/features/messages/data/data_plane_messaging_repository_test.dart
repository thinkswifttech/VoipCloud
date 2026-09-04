import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/storage/secure_storage_service.dart';
import 'package:phone_app/features/messages/data/data_plane_messaging_repository.dart';
import 'package:phone_app/features/messages/data/messaging_api_client.dart';
import 'package:phone_app/features/messages/data/messaging_connectivity.dart';
import 'package:phone_app/features/messages/data/messaging_outbox_store.dart';
import 'package:phone_app/features/messages/data/messaging_push_token_service.dart';
import 'package:phone_app/features/messages/data/messaging_session_manager.dart';
import 'package:phone_app/features/messages/data/messaging_session_store.dart';
import 'package:phone_app/features/messages/domain/carrier_messaging_config.dart';
import 'package:phone_app/features/messages/domain/carrier_message.dart';
import 'package:phone_app/features/messages/domain/messaging_repository.dart';
import 'package:phone_app/features/messages/domain/messaging_session.dart';

void main() {
  const config = CarrierMessagingConfig(
    enabled: true,
    did: '+19055550101',
    inboxId: 'inbox-1',
  );

  test('server capability keeps outbound disabled', () async {
    final fixture = await _fixture(canSend: false);

    await fixture.repository.loadInbox(config: config);

    expect(fixture.repository.canSend, isFalse);
    expect(
      () => fixture.repository.sendMessage(
        config: config,
        destination: '+14165550123',
        text: 'Blocked before transport',
        clientId: 'client-message-1',
      ),
      throwsA(isA<MessagingOutboundUnavailable>()),
    );
  });

  test(
    'discovers the assigned inbox from the authenticated server session',
    () async {
      final fixture = await _fixture(canSend: false);

      final discovered = await fixture.repository.discoverConfig();

      expect(discovered?.enabled, isTrue);
      expect(discovered?.did, '+19055550101');
      expect(discovered?.inboxId, 'inbox-1');
    },
  );

  test('certified server capability enables carrier send API', () async {
    final fixture = await _fixture(canSend: true);

    await fixture.repository.loadInbox(config: config);
    final message = await fixture.repository.sendMessage(
      config: config,
      destination: '+14165550123',
      text: 'Hello from the app',
      clientId: 'client-message-2',
    );

    expect(fixture.repository.canSend, isTrue);
    expect(message.id, 'message-2');
    expect(message.remoteNumber, '+14165550123');
    expect(fixture.adapter.lastPostData, {
      'client_message_id': 'client-message-2',
      'to_e164': '+14165550123',
      'body': 'Hello from the app',
    });
  });

  test('MMS capability uses authenticated multipart upload endpoint', () async {
    final fixture = await _fixture(canSend: true, canSendMms: true);
    await fixture.repository.loadInbox(config: config);

    final message = await fixture.repository.sendMessage(
      config: config,
      destination: '+14165550123',
      text: 'Photo attached',
      clientId: 'client-message-mms-1',
      attachment: OutboundMessageAttachment(
        bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
        fileName: 'photo.jpg',
        contentType: 'image/jpeg',
      ),
    );

    expect(fixture.repository.canSendMms, isTrue);
    expect(fixture.repository.maxOutboundAttachmentBytes, 1300000);
    expect(fixture.repository.outboundAttachmentMimeTypes, {
      'image/jpeg',
      'image/png',
    });
    expect(fixture.adapter.lastPostPath, '/api/v1/messaging/messages/mms');
    final data = fixture.adapter.lastPostData as FormData;
    expect(Map.fromEntries(data.fields), {
      'client_message_id': 'client-message-mms-1',
      'to_e164': '+14165550123',
      'body': 'Photo attached',
    });
    expect(data.files.single.key, 'attachments[]');
    expect(data.files.single.value.filename, 'photo.jpg');
    expect(data.files.single.value.length, 4);
    expect(message.id, 'message-mms-1');
  });

  test(
    'retries a failed server message through its logical message id',
    () async {
      final fixture = await _fixture(canSend: true);
      await fixture.repository.loadInbox(config: config);

      final message = await fixture.repository.retryMessage(
        config: config,
        messageId: 'failed-message-1',
      );

      expect(message.id, 'failed-message-1');
      expect(message.status, MessageStatus.queued);
      expect(
        fixture.adapter.lastPostPath,
        '/api/v1/messaging/messages/failed-message-1/retry',
      );
    },
  );

  test(
    'replay skips deleted message tombstones and continues statuses',
    () async {
      final fixture = await _fixture(canSend: true, replayTombstones: true);
      await fixture.repository.loadInbox(config: config);

      final submitted = await fixture.repository
          .watchMessages(config: config)
          .firstWhere((message) => message.id == 'message-after-tombstone')
          .timeout(const Duration(seconds: 2));

      expect(submitted.status, MessageStatus.submitted);
      expect(fixture.adapter.missingMessageLookupCount, 1);
      await fixture.repository.dispose();
    },
  );

  test('replay invalidates the authoritative inbox index', () async {
    final fixture = await _fixture(canSend: true, replayTombstones: true);
    await fixture.repository.loadInbox(config: config);
    final invalidated = fixture.repository
        .watchInboxInvalidations(config: config)
        .first
        .timeout(const Duration(seconds: 2));

    fixture.repository.watchMessages(config: config);

    await invalidated;
    await fixture.repository.dispose();
  });

  test(
    'loads an opaque push message id through the authenticated API',
    () async {
      final fixture = await _fixture(canSend: false);

      final message = await fixture.repository.loadMessage(
        config: config,
        messageId: 'message-from-push',
      );

      expect(message?.id, 'message-from-push');
      expect(message?.remoteNumber, '+14165550999');
      expect(message?.text, 'Private message body');
    },
  );

  test(
    'registers a standard messaging push token without exposing it',
    () async {
      final fixture = await _fixture(
        canSend: false,
        pushRegistration: const MessagingPushRegistration(
          provider: 'fcm',
          token: 'private-fcm-registration-token',
          environment: 'production',
        ),
      );

      await fixture.repository.loadInbox(config: config);

      expect(fixture.adapter.lastPushData, {
        'provider': 'fcm',
        'token': 'private-fcm-registration-token',
        'environment': 'production',
      });
    },
  );

  test('downloads attachment bytes through the authenticated API', () async {
    final fixture = await _fixture(canSend: false);

    final content = await fixture.repository.loadAttachment(
      config: config,
      attachment: MessageAttachment(
        id: 'attachment-1',
        contentType: 'image/jpeg',
        downloadUri: Uri.parse('/api/v1/messaging/media/attachment-1'),
      ),
    );

    expect(content.bytes, Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]));
    expect(content.contentType, 'image/jpeg');
    expect(fixture.adapter.mediaAuthorization, 'Bearer access-token');
  });

  test('loads, creates, and removes SMS/MMS-only blocks', () async {
    final fixture = await _fixture(canSend: true);

    final inbox = await fixture.repository.loadInbox(config: config);
    expect(inbox.blocksByRemoteNumber['+14165550777']?.reason, 'user_blocked');

    final block = await fixture.repository.blockNumber(
      config: config,
      remoteNumber: '+14165550888',
      reason: 'spam_report',
    );
    expect(block.id, 'block-created');
    expect(block.reason, 'spam_report');
    expect(fixture.adapter.lastBlockData, {
      'remote_e164': '+14165550888',
      'reason': 'spam_report',
    });

    await fixture.repository.unblockNumber(config: config, blockId: block.id);
    expect(
      fixture.adapter.lastDeletePath,
      '/api/v1/messaging/blocks/block-created',
    );
  });

  test('preserves the server cursor for older conversation messages', () async {
    final fixture = await _fixture(canSend: true);
    await fixture.repository.loadInbox(config: config);

    final page = await fixture.repository.loadConversation(
      config: config,
      remoteNumber: '+14165550123',
    );

    expect(page.messages.single.id, 'history-message-1');
    expect(page.nextCursor, 'older-message-cursor');
  });

  test('deletes only through authenticated inbox history routes', () async {
    final fixture = await _fixture(canSend: true);
    await fixture.repository.loadInbox(config: config);

    await fixture.repository.deleteMessage(
      config: config,
      messageId: 'message-to-hide',
    );
    expect(
      fixture.adapter.lastDeletePath,
      '/api/v1/messaging/messages/message-to-hide',
    );

    await fixture.repository.deleteConversation(
      config: config,
      remoteNumber: '+14165550123',
    );
    expect(
      fixture.adapter.lastDeletePath,
      '/api/v1/messaging/conversations/conversation-1',
    );
  });

  test(
    'queues offline sends and drains them in order after reconnect',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'messaging-repository-outbox-',
      );
      final outbox = MessagingOutboxStore(
        secureStorage: InMemorySecureStorageService(),
        supportDirectory: () async => directory,
      );
      final connectivity = _FakeMessagingConnectivity(online: false);
      final fixture = await _fixture(
        canSend: true,
        outbox: outbox,
        connectivity: connectivity,
      );
      await fixture.repository.loadInbox(config: config);

      final queued = await fixture.repository.sendMessage(
        config: config,
        destination: '+14165550123',
        text: 'Wait for network',
        clientId: 'offline-message-1',
      );
      expect(queued.status, MessageStatus.queued);
      expect((await outbox.readAll()).single.clientId, 'offline-message-1');

      connectivity.setOnline(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await outbox.readAll(), isEmpty);
      expect(fixture.adapter.lastPostPath, '/api/v1/messaging/messages');

      await fixture.repository.dispose();
      await directory.delete(recursive: true);
    },
  );
}

Future<_Fixture> _fixture({
  required bool canSend,
  bool canSendMms = false,
  MessagingPushRegistration? pushRegistration,
  MessagingOutboxStore? outbox,
  MessagingConnectivity? connectivity,
  bool replayTombstones = false,
}) async {
  final adapter = _MessagingAdapter(
    canSend: canSend,
    canSendMms: canSendMms,
    replayTombstones: replayTombstones,
  );
  final dio = Dio(BaseOptions(baseUrl: 'https://messaging.example.test'))
    ..httpClientAdapter = adapter;
  final store = MessagingSessionStore(InMemorySecureStorageService());
  await store.write(
    MessagingSessionCredentials(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
      refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      sessionId: 'session-1',
      inboxId: 'inbox-1',
    ),
  );
  final sessions = MessagingSessionManager(
    dio: dio,
    store: store,
    loadProvisioning: () async => const MessagingProvisioningContext(
      directoryToken: 'directory-token',
      deviceId: 'device-1',
      expectedInboxId: 'inbox-1',
      platform: 'android',
      appVersion: '1.0.0',
    ),
  );
  return _Fixture(
    adapter,
    DataPlaneMessagingRepository(
      api: MessagingApiClient(dio, sessions),
      sessions: sessions,
      store: store,
      loadPushRegistration: pushRegistration == null
          ? null
          : () async => pushRegistration,
      outbox: outbox,
      connectivity: connectivity,
    ),
  );
}

class _Fixture {
  const _Fixture(this.adapter, this.repository);

  final _MessagingAdapter adapter;
  final DataPlaneMessagingRepository repository;
}

class _FakeMessagingConnectivity implements MessagingConnectivity {
  _FakeMessagingConnectivity({required bool online}) : _online = online;

  bool _online;
  final _controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get changes => _controller.stream;

  @override
  Future<bool> hasNetwork() async => _online;

  @override
  Future<void> dispose() => close();

  void setOnline(bool value) {
    _online = value;
    _controller.add(value);
  }

  Future<void> close() => _controller.close();
}

class _MessagingAdapter implements HttpClientAdapter {
  _MessagingAdapter({
    required this.canSend,
    required this.canSendMms,
    required this.replayTombstones,
  });

  final bool canSend;
  final bool canSendMms;
  final bool replayTombstones;
  int missingMessageLookupCount = 0;
  Object? lastPostData;
  String? lastPostPath;
  Object? lastPushData;
  Object? lastBlockData;
  String? lastDeletePath;
  String? mediaAuthorization;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/session') {
      return _json({
        'session_id': 'session-1',
        'inbox': {
          'id': 'inbox-1',
          'did_e164': '+19055550101',
          'sms_capable': true,
          'mms_capable': true,
        },
      });
    }
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/capabilities') {
      return _json({
        'data': {
          'can_send': canSend,
          'can_send_mms': canSendMms,
          'outbound_mms_max_attachment_bytes': 1300000,
          'outbound_mms_allowed_mime_types': ['image/jpeg', 'image/png'],
        },
      });
    }
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/conversations') {
      return _json({
        'data': [
          {
            'id': 'conversation-1',
            'remote_e164': '+14165550123',
            'unread_count': 0,
            'last_message': null,
          },
        ],
        'next_cursor': null,
      });
    }
    if (options.method == 'GET' &&
        options.path ==
            '/api/v1/messaging/conversations/conversation-1/messages') {
      return _json({
        'data': [
          {
            'id': 'history-message-1',
            'direction': 'outbound',
            'to_e164': '+14165550123',
            'body': 'Older history',
            'state': 'sent',
            'created_at': '2026-08-11T10:00:00Z',
          },
        ],
        'next_cursor': 'older-message-cursor',
      });
    }
    if (options.method == 'GET' && options.path == '/api/v1/messaging/blocks') {
      return _json({
        'data': [
          {
            'id': 'block-existing',
            'remote_e164': '+14165550777',
            'scope': 'sms_mms',
            'reason': 'user_blocked',
            'blocked_at': '2026-08-13T14:00:00Z',
          },
        ],
      });
    }
    if (options.method == 'GET' && options.path == '/api/v1/messaging/events') {
      return _json({
        'data': replayTombstones
            ? [
                {
                  'sequence': 1,
                  'event_type': 'message.updated',
                  'conversation_id': 'conversation-1',
                  'payload': {'message_id': 'missing-message'},
                },
                {
                  'sequence': 2,
                  'event_type': 'message.deleted',
                  'conversation_id': 'conversation-1',
                  'payload': {'message_id': 'deleted-message'},
                },
                {
                  'sequence': 3,
                  'event_type': 'message.submitted',
                  'conversation_id': 'conversation-1',
                  'payload': {'message_id': 'message-after-tombstone'},
                },
              ]
            : <Object?>[],
        'has_more': false,
      });
    }
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/messages/missing-message') {
      missingMessageLookupCount++;
      return ResponseBody.fromString('Not found', 404);
    }
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/messages/message-after-tombstone') {
      return _json({
        'data': {
          'id': 'message-after-tombstone',
          'client_message_id': 'client-after-tombstone',
          'direction': 'outbound',
          'to_e164': '+14165550123',
          'body': 'Status continued',
          'state': 'submitted',
          'created_at': '2026-08-24T13:40:00Z',
        },
      });
    }
    if (options.method == 'POST' &&
        options.path == '/api/v1/messaging/blocks') {
      lastBlockData = options.data;
      final data = Map<String, dynamic>.from(options.data as Map);
      return _json({
        'data': {
          'id': 'block-created',
          'remote_e164': data['remote_e164'],
          'scope': 'sms_mms',
          'reason': data['reason'],
          'blocked_at': '2026-08-13T14:05:00Z',
        },
      });
    }
    if (options.method == 'DELETE' &&
        options.path.startsWith('/api/v1/messaging/')) {
      lastDeletePath = options.path;
      return ResponseBody.fromString('', 204);
    }
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/messages/message-from-push') {
      return _json({
        'data': {
          'id': 'message-from-push',
          'direction': 'inbound',
          'from_e164': '+14165550999',
          'to_e164': '+19055550101',
          'body': 'Private message body',
          'state': 'received',
          'created_at': '2026-08-12T17:49:04Z',
        },
      });
    }
    if (options.method == 'GET' &&
        options.path == '/api/v1/messaging/media/attachment-1') {
      mediaAuthorization = options.headers['Authorization']?.toString();
      return ResponseBody.fromBytes(
        [0xff, 0xd8, 0xff, 0xd9],
        200,
        headers: {
          Headers.contentTypeHeader: ['image/jpeg'],
          Headers.contentLengthHeader: ['4'],
        },
      );
    }
    if (options.method == 'POST' &&
        options.path == '/api/v1/messaging/push-endpoints') {
      lastPushData = options.data;
      return _json({
        'data': {'id': 'endpoint-1'},
      }, statusCode: 201);
    }
    if (options.method == 'POST' &&
        options.path == '/api/v1/messaging/messages/failed-message-1/retry') {
      lastPostPath = options.path;
      return _json({
        'data': {
          'id': 'failed-message-1',
          'client_message_id': 'client-failed-message-1',
          'direction': 'outbound',
          'to_e164': '+14165550123',
          'body': 'Retry me',
          'state': 'queued',
          'created_at': '2026-08-24T13:30:00Z',
        },
      }, statusCode: 202);
    }
    if (options.method == 'POST' &&
        options.path == '/api/v1/messaging/messages') {
      lastPostData = options.data;
      lastPostPath = options.path;
      return _json({
        'data': {
          'id': 'message-2',
          'client_message_id': 'client-message-2',
          'direction': 'outbound',
          'to_e164': '+14165550123',
          'body': 'Hello from the app',
          'state': 'queued',
          'created_at': '2026-08-11T12:00:00Z',
        },
      }, statusCode: 202);
    }
    if (options.method == 'POST' &&
        options.path == '/api/v1/messaging/messages/mms') {
      lastPostData = options.data;
      lastPostPath = options.path;
      return _json({
        'data': {
          'id': 'message-mms-1',
          'client_message_id': 'client-message-mms-1',
          'direction': 'outbound',
          'to_e164': '+14165550123',
          'body': 'Photo attached',
          'state': 'queued',
          'created_at': '2026-08-13T14:00:00Z',
          'attachments': [
            {
              'id': 'attachment-mms-1',
              'mime_type': 'image/jpeg',
              'size_bytes': 4,
              'state': 'ready',
            },
          ],
        },
      }, statusCode: 202);
    }
    return ResponseBody.fromString('Not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, Object?> body, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
