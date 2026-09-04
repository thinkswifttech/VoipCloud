import 'package:dio/dio.dart';

import '../../../core/errors/app_exception.dart';
import 'messaging_session_manager.dart';

class MessagingApiClient {
  const MessagingApiClient(this._dio, this._sessions);

  final Dio _dio;
  final MessagingSessionManager _sessions;

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
  }) {
    return _authorized<T>(
      'GET',
      path,
      queryParameters: queryParameters,
      responseType: responseType,
    );
  }

  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    void Function(int sent, int total)? onSendProgress,
  }) {
    return _authorized<T>(
      'POST',
      path,
      data: data,
      onSendProgress: onSendProgress,
    );
  }

  Future<Response<T>> delete<T>(String path) {
    return _authorized<T>('DELETE', path);
  }

  Future<Response<T>> _authorized<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    ResponseType? responseType,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    var credentials = await _sessions.ensure();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _dio.request<T>(
          path,
          data: data,
          queryParameters: queryParameters,
          options: Options(
            method: method,
            responseType: responseType,
            headers: {'Authorization': 'Bearer ${credentials.accessToken}'},
          ),
          onSendProgress: onSendProgress,
        );
      } on DioException catch (error) {
        if (attempt == 0 && error.response?.statusCode == 401) {
          credentials = await _sessions.ensure(forceRefresh: true);
          continue;
        }
        final statusCode = error.response?.statusCode;
        throw ApiException(
          statusCode: statusCode,
          message: 'Messaging API request failed.',
          code: 'messaging_api_error',
          userMessage: _safeUserMessage(error),
        );
      }
    }
    throw const AppException(message: 'Messaging authorization retry failed.');
  }
}

String _safeUserMessage(DioException error) {
  final statusCode = error.response?.statusCode;
  if (statusCode == 413) {
    return 'The attachment is larger than the server upload limit.';
  }
  if (statusCode == 422) {
    final validationMessage = _firstValidationMessage(error.response?.data);
    return validationMessage ?? 'The message or attachment was not accepted.';
  }
  if (statusCode == 429) {
    return 'Too many messages were sent recently. Please wait and try again.';
  }
  if (statusCode == 401) {
    return 'Your messaging session has expired. Please sign in again.';
  }
  if (statusCode == 403) {
    return 'Messaging is not currently permitted for this number.';
  }
  if (statusCode != null && statusCode >= 500) {
    return 'The messaging service is temporarily unavailable.';
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout) {
    return 'The messaging service did not respond in time.';
  }
  return 'The messaging request could not be completed.';
}

String? _firstValidationMessage(Object? data) {
  if (data is! Map) return null;
  final errors = data['errors'];
  if (errors is Map) {
    for (final value in errors.values) {
      if (value is List && value.isNotEmpty) {
        final message = '${value.first}'.trim();
        if (message.isNotEmpty) return message;
      }
      final message = '$value'.trim();
      if (message.isNotEmpty) return message;
    }
  }
  final message = '${data['message'] ?? ''}'.trim();
  return message.isEmpty ? null : message;
}
