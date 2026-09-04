import 'package:dio/dio.dart';

import '../errors/app_exception.dart';

class ApiExceptionMapper {
  const ApiExceptionMapper._();

  static AppException mapDioException(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.transformTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => NetworkException(
        message: error.message ?? 'Network error',
      ),
      DioExceptionType.badResponse => ApiException.fromStatusCode(
        statusCode: error.response?.statusCode,
        message: _messageFromResponse(error.response) ?? error.message,
        code: _codeFromResponse(error.response),
        details: error.response?.data,
      ),
      DioExceptionType.cancel => const NetworkException(
        message: 'Request cancelled',
        userMessage: 'The request was cancelled.',
      ),
      DioExceptionType.badCertificate => const NetworkException(
        message: 'Bad TLS certificate',
        userMessage: 'Secure connection failed.',
      ),
      DioExceptionType.unknown => NetworkException(
        message: error.message ?? 'Unknown network error',
        details: error.error,
      ),
    };
  }

  static String? _messageFromResponse(Response<dynamic>? response) {
    final data = response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    return null;
  }

  static String? _codeFromResponse(Response<dynamic>? response) {
    final data = response?.data;
    if (data is Map && data['code'] is String) {
      return data['code'] as String;
    }
    return null;
  }
}
