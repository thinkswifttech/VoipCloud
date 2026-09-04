import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/config_providers.dart';
import '../constants/storage_keys.dart';
import '../logging/app_logger.dart';
import '../storage/secure_storage_service.dart';
import '../storage/storage_providers.dart';
import 'api_endpoints.dart';
import 'app_client.dart';

final dioProvider = Provider<Dio>((ref) {
  final config = ref.watch(appConfigProvider);
  final storage = ref.watch(secureStorageProvider);

  final dio = Dio(
    BaseOptions(
      baseUrl: config.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {
        Headers.acceptHeader: Headers.jsonContentType,
        Headers.contentTypeHeader: Headers.jsonContentType,
      },
    ),
  );

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (!_isAuthRoute(options.path)) {
          final accessToken = await storage.read(StorageKeys.appAccessToken);
          if (accessToken != null && accessToken.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $accessToken';
          }
        }

        handler.next(options);
      },
      onError: (error, handler) async {
        final shouldClear =
            error.response?.statusCode == 401 &&
            !_isAuthRoute(error.requestOptions.path);
        if (!shouldClear) {
          handler.next(error);
          return;
        }

        await _clearStoredSession(storage);
        handler.next(error);
      },
    ),
  );

  if (kDebugMode && config.enableVoipDebugLogs) {
    dio.interceptors.add(_SafeNetworkLogInterceptor());
  }

  return dio;
});

final appClientProvider = Provider<AppClient>((ref) {
  return AppClient(ref.watch(dioProvider));
});

class _SafeNetworkLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    AppLogger.debug(
      'HTTP request',
      data: {'method': options.method, 'path': options.path},
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    AppLogger.debug(
      'HTTP response',
      data: {
        'statusCode': response.statusCode,
        'path': response.requestOptions.path,
      },
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    AppLogger.warning(
      'HTTP error',
      data: {
        'statusCode': err.response?.statusCode,
        'path': err.requestOptions.path,
        'type': err.type.name,
      },
    );
    handler.next(err);
  }
}

bool _isAuthRoute(String path) {
  return path.contains(ApiEndpoints.provisioningExchange);
}

Future<void> _clearStoredSession(SecureStorageService storage) async {
  await storage.delete(StorageKeys.appAccessToken);
  await storage.delete(StorageKeys.appRefreshToken);
  await storage.delete(StorageKeys.appUser);
  await storage.delete(StorageKeys.appService);
  await storage.delete(StorageKeys.appDevice);
  await storage.delete(StorageKeys.appProvisioning);
  await storage.delete(StorageKeys.appSipConfig);
  await storage.delete(StorageKeys.appDirectoryAccess);
  await storage.delete(StorageKeys.appCarrierMessaging);
  await storage.delete(StorageKeys.messagingAccessToken);
  await storage.delete(StorageKeys.messagingRefreshToken);
  await storage.delete(StorageKeys.messagingAccessExpiresAt);
  await storage.delete(StorageKeys.messagingRefreshExpiresAt);
  await storage.delete(StorageKeys.messagingSessionId);
  await storage.delete(StorageKeys.messagingInboxId);
  await storage.delete(StorageKeys.messagingLastSequence);
  await storage.delete(StorageKeys.authAccessToken);
  await storage.delete(StorageKeys.authRefreshToken);
  await storage.delete(StorageKeys.authExpiresAt);
  await storage.delete(StorageKeys.authUserId);
  await storage.delete(StorageKeys.authOrganizationId);
  await storage.delete(StorageKeys.authUserEmail);
  await storage.delete(StorageKeys.authUserPhoneNumber);
  await storage.delete(StorageKeys.authUserDisplayName);
  await storage.delete(StorageKeys.authUserRole);
  await storage.delete(StorageKeys.authUserStatus);
  await storage.delete(StorageKeys.authUserExtension);
}
