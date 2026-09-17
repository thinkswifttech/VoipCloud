import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/config_providers.dart';
import '../constants/storage_keys.dart';
import '../logging/app_logger.dart';
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
        // A 401 can mean an expired control-plane token or a transient server
        // policy mismatch. It must never delete the independently valid SIP
        // provisioning. Session deletion is limited to explicit Reset/Logout.
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
