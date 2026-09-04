import 'package:dio/dio.dart';

import '../../../core/errors/app_exception.dart';
import '../domain/messaging_repository.dart';
import '../domain/messaging_session.dart';
import 'messaging_session_store.dart';

typedef MessagingProvisioningLoader =
    Future<MessagingProvisioningContext?> Function();

class MessagingSessionManager {
  MessagingSessionManager({
    required Dio dio,
    required MessagingSessionStore store,
    required MessagingProvisioningLoader loadProvisioning,
  }) : _dio = dio,
       _store = store,
       _loadProvisioning = loadProvisioning;

  final Dio _dio;
  final MessagingSessionStore _store;
  final MessagingProvisioningLoader _loadProvisioning;
  Future<MessagingSessionCredentials>? _renewal;

  Future<MessagingSessionCredentials> ensure({bool forceRefresh = false}) {
    final pending = _renewal;
    if (pending != null) return pending;

    final future = _ensure(forceRefresh: forceRefresh);
    _renewal = future;
    return future.whenComplete(() {
      if (identical(_renewal, future)) _renewal = null;
    });
  }

  Future<void> revoke() async {
    final existing = await _store.read();
    try {
      if (existing != null) {
        await _dio.delete<void>(
          '/api/v1/messaging/session',
          options: Options(
            headers: {'Authorization': 'Bearer ${existing.accessToken}'},
          ),
        );
      }
    } on DioException {
      // A local logout must still clear credentials if the edge is offline.
    } finally {
      await _store.clear();
    }
  }

  Future<MessagingSessionCredentials> _ensure({
    required bool forceRefresh,
  }) async {
    final now = DateTime.now().toUtc();
    final context = await _loadProvisioning();
    if (context == null ||
        context.directoryToken.isEmpty ||
        context.deviceId.isEmpty) {
      throw const MessagingIntegrationUnavailable();
    }

    var stored = await _store.read();
    final expectedInboxId = context.expectedInboxId?.trim();
    if (stored != null &&
        expectedInboxId?.isNotEmpty == true &&
        stored.inboxId != expectedInboxId) {
      await _store.clear();
      stored = null;
    } else if (!forceRefresh && stored?.accessIsUsable(now) == true) {
      return stored!;
    }

    if (stored?.refreshIsUsable(now) == true) {
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          '/api/v1/messaging/session/refresh',
          options: Options(
            headers: {
              'Authorization': 'Bearer ${stored!.refreshToken}',
              'X-VoIPCloud-Device-ID': context.deviceId,
            },
          ),
        );
        return _accept(response.data, expectedInboxId);
      } on DioException catch (error) {
        if (error.response?.statusCode != 401 &&
            error.response?.statusCode != 403) {
          throw _networkException(error);
        }
        await _store.clear();
      }
    }

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/messaging/session/exchange',
        data: {
          'platform': context.platform.toLowerCase(),
          'app_version': context.appVersion,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${context.directoryToken}',
            'X-VoIPCloud-Device-ID': context.deviceId,
          },
        ),
      );
      return _accept(response.data, expectedInboxId);
    } on DioException catch (error) {
      throw _networkException(error);
    }
  }

  Future<MessagingSessionCredentials> _accept(
    Map<String, dynamic>? data,
    String? expectedInboxId,
  ) async {
    if (data == null) {
      throw const FormatException('Missing messaging session response');
    }
    final credentials = MessagingSessionCredentials.fromJson(data);
    if (expectedInboxId?.isNotEmpty == true &&
        credentials.inboxId != expectedInboxId) {
      await _store.clear();
      throw const AppException(
        message: 'Messaging session inbox does not match provisioning.',
        userMessage: 'Messaging access changed. Reprovision this device.',
      );
    }
    await _store.write(credentials);
    return credentials;
  }

  AppException _networkException(DioException error) {
    final status = error.response?.statusCode;
    return ApiException(
      statusCode: status,
      message: 'Messaging session request failed.',
      code: status == 401 || status == 403
          ? 'messaging_session_rejected'
          : 'messaging_session_unavailable',
      userMessage: status == 401 || status == 403
          ? 'Messaging access is unavailable. Reprovision this device.'
          : 'Messaging is temporarily unavailable.',
    );
  }
}
