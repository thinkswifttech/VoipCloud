import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/config_providers.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/storage_providers.dart';
import '../../session/data/device_info_repository.dart';
import '../../session/data/secure_session_storage.dart';
import '../domain/messaging_repository.dart';
import '../domain/messaging_session.dart';
import 'data_plane_messaging_repository.dart';
import 'messaging_api_client.dart';
import 'messaging_attachment_cache.dart';
import 'messaging_connectivity.dart';
import 'messaging_deletion_store.dart';
import 'messaging_outbox_store.dart';
import 'messaging_push_token_service.dart';
import 'messaging_session_manager.dart';
import 'messaging_session_store.dart';
import 'unconfigured_messaging_repository.dart';

final messagingDeletionStoreProvider = Provider<MessagingDeletionStore>((ref) {
  return MessagingDeletionStore(ref.watch(secureStorageProvider));
});

final messagingRepositoryProvider = Provider<MessagingRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final baseUri = config.messagingBaseUri;
  if (baseUri == null) return const UnconfiguredMessagingRepository();

  final storage = ref.watch(secureStorageProvider);
  final sessionStorage = SecureSessionStorage(storage);
  final sessionStore = MessagingSessionStore(storage);
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUri.toString(),
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {
        Headers.acceptHeader: Headers.jsonContentType,
        Headers.contentTypeHeader: Headers.jsonContentType,
      },
    ),
  );
  late final MessagingSessionManager sessions;
  sessions = MessagingSessionManager(
    dio: dio,
    store: sessionStore,
    loadProvisioning: () async {
      final appSession = await sessionStorage.readSession();
      final directory = appSession?.directoryAccess;
      final deviceCredential = appSession?.deviceCredential;
      final messaging = appSession?.carrierMessaging;
      final bootstrapToken = deviceCredential?.token ?? directory?.token;
      if (bootstrapToken == null || bootstrapToken.isEmpty) return null;
      final device = await DeviceInfoRepository(
        storage: storage,
      ).getDeviceInfo();
      final storedDeviceId = appSession?.device.deviceId?.trim();
      final deviceId = storedDeviceId?.isNotEmpty == true
          ? storedDeviceId!
          : device.deviceId;
      final persistedDeviceId = await storage.read(StorageKeys.appDeviceId);
      if (persistedDeviceId != null &&
          persistedDeviceId.isNotEmpty &&
          persistedDeviceId != deviceId) {
        return null;
      }
      return MessagingProvisioningContext(
        directoryToken: bootstrapToken,
        deviceId: deviceId,
        platform: device.platform.name,
        appVersion: device.appVersion,
        expectedInboxId: messaging?.inboxId,
      );
    },
  );
  final repository = DataPlaneMessagingRepository(
    api: MessagingApiClient(dio, sessions),
    sessions: sessions,
    store: sessionStore,
    loadPushRegistration: const MessagingPushTokenService().load,
    outbox: MessagingOutboxStore(secureStorage: storage),
    attachmentCache: MessagingAttachmentCache(secureStorage: storage),
    connectivity: PlatformMessagingConnectivity(),
  );
  ref.onDispose(() => repository.dispose());
  return repository;
});
