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
    return 'That attachment is too large to send. Try a smaller file.';
  }
  if (statusCode == 422) {
    // The server refuses a text that needs more parts than it allows.
    if ('${error.response?.data}'.contains('SMS parts')) {
      return 'This message is too long to send. Please shorten it.';
    }
    return "We couldn't send that message. Check the number and attachment, then try again.";
  }
  if (statusCode == 429) {
    return 'You have sent a lot of messages recently. Please wait a minute and try again.';
  }
  if (statusCode == 401) {
    return "Messaging needs to be set up again on this device. Please contact support.";
  }
  if (statusCode == 403) {
    return "Texting isn't turned on for this number. Contact your administrator.";
  }
  if (statusCode != null && statusCode >= 500) {
    return 'Messaging is temporarily unavailable. Please try again soon.';
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout) {
    return "Messages aren't sending right now. Please try again.";
  }
  return "Messages aren't sending right now. Please try again.";
}
