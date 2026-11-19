import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/config_providers.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../../core/storage/storage_providers.dart';

import '../../accounts/domain/account_line.dart';
import '../../accounts/presentation/accounts_controller.dart';
import '../../session/data/device_info_repository.dart';
import '../../session/data/secure_session_storage.dart';
import '../domain/messaging_repository.dart';
import '../domain/messaging_session.dart';
import 'data_plane_messaging_repository.dart';
import 'line_scoped_storage.dart';
import 'link_shortener.dart';
import 'messaging_api_client.dart';
import 'messaging_attachment_cache.dart';
import 'messaging_connectivity.dart';
import 'messaging_deletion_store.dart';
import 'messaging_outbox_store.dart';
import 'messaging_push_token_service.dart';
import 'messaging_session_manager.dart';
import 'messaging_session_store.dart';
import 'unconfigured_messaging_repository.dart';

/// Secure storage for one account's messaging: the primary keeps its original
/// keys, the second account gets its own.
SecureStorageService _storageFor(Ref ref, AccountLine line) {
  final storage = ref.watch(secureStorageProvider);
  return line == AccountLine.primary
      ? storage
      : LineScopedStorage(storage, 'line2.');
}

final messagingDeletionStoreForLineProvider =
    Provider.family<MessagingDeletionStore, AccountLine>(
      (ref, line) => MessagingDeletionStore(_storageFor(ref, line)),
    );

final messagingDeletionStoreProvider = Provider<MessagingDeletionStore>(
  (ref) =>
      ref.watch(messagingDeletionStoreForLineProvider(AccountLine.primary)),
);

/// The primary account's messaging repository.
final messagingRepositoryProvider = Provider<MessagingRepository>(
  (ref) => ref.watch(messagingRepositoryForLineProvider(AccountLine.primary)),
);

final messagingRepositoryForLineProvider =
    Provider.family<MessagingRepository, AccountLine>((ref, line) {
      final config = ref.watch(appConfigProvider);
      final baseUri = config.messagingBaseUri;
      if (baseUri == null) return const UnconfiguredMessagingRepository();

      final rootStorage = ref.watch(secureStorageProvider);
      final storage = _storageFor(ref, line);
      final sessionStorage = SecureSessionStorage(rootStorage);
      final sessionStore = MessagingSessionStore(storage);
      Future<Directory> supportDirectory() async {
        final root = await getApplicationSupportDirectory();
        return line == AccountLine.primary
            ? root
            : Directory('${root.path}${Platform.pathSeparator}line2');
      }

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
          final second = line == AccountLine.primary
              ? null
              : await ref.read(accountsRepositoryProvider).readSecondary();
          if (line != AccountLine.primary && second == null) return null;
          final directory =
              second?.directoryAccess ?? appSession?.directoryAccess;
          final deviceCredential =
              second?.deviceCredential ?? appSession?.deviceCredential;
          final messaging =
              second?.carrierMessaging ?? appSession?.carrierMessaging;
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
        outbox: MessagingOutboxStore(
          secureStorage: storage,
          supportDirectory: supportDirectory,
        ),
        attachmentCache: MessagingAttachmentCache(
          secureStorage: storage,
          supportDirectory: supportDirectory,
        ),
        connectivity: PlatformMessagingConnectivity(),
        linkShortenerFactory: (baseUrl) => _linkShortenerFor(baseUrl, sessions),
        linkShortenerOverride: linkShortenerBaseUrl,
      );
      ref.onDispose(() => repository.dispose());
      return repository;
    });

/// Builds the link shortener for the address the messaging server published
/// (or a development override). The repository validates the address first.
LinkShortener _linkShortenerFor(
  String baseUrl,
  MessagingSessionManager sessions,
) {
  return ApiLinkShortener(
    baseUrl: baseUrl,
    minLength: linkShortenerMinLength,
    dio: Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        headers: const {Headers.acceptHeader: Headers.jsonContentType},
      ),
    ),
    accessToken: ({bool forceRefresh = false}) async =>
        (await sessions.ensure(forceRefresh: forceRefresh)).accessToken,
  );
}
