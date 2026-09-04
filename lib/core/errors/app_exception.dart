class AppException implements Exception {
  const AppException({
    required this.message,
    this.userMessage = 'Something went wrong. Please try again.',
    this.code,
    this.details,
  });

  final String message;
  final String userMessage;
  final String? code;
  final Object? details;

  @override
  String toString() {
    final codeText = code == null ? '' : '[$code] ';
    return 'AppException: $codeText$message';
  }
}

class ApiException extends AppException {
  const ApiException({
    required super.message,
    required this.statusCode,
    super.userMessage = 'The server could not process the request.',
    super.code,
    super.details,
  });

  final int? statusCode;

  factory ApiException.fromStatusCode({
    required int? statusCode,
    String? message,
    String? code,
    Object? details,
  }) {
    if (statusCode == 400) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Bad request',
        userMessage:
            _userMessageForCode(code) ?? 'Please check the submitted details.',
        code: code,
        details: details,
      );
    }
    if (statusCode == 401) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Unauthorized',
        userMessage: 'Your session has expired. Please sign in again.',
        code: code,
        details: details,
      );
    }
    if (statusCode == 403) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Forbidden',
        userMessage: 'You do not have permission to do that.',
        code: code,
        details: details,
      );
    }
    if (statusCode == 404) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Not found',
        userMessage: 'The requested resource was not found.',
        code: code,
        details: details,
      );
    }
    if (statusCode != null && statusCode >= 500) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Server error',
        userMessage: 'The service is temporarily unavailable.',
        code: code,
        details: details,
      );
    }

    return ApiException(
      statusCode: statusCode,
      message: message ?? 'Unexpected API error',
      code: code,
      details: details,
    );
  }

  static String? _userMessageForCode(String? code) {
    return switch (code) {
      'PROVISIONING_TOKEN_INVALID' =>
        'This provisioning token is invalid. Check the link or scan the QR code again.',
      'PROVISIONING_TOKEN_EXPIRED' =>
        'This provisioning token has expired. Please request a new activation link.',
      'PROVISIONING_TOKEN_USED' =>
        'This provisioning token has already been used.',
      'PROVISIONING_TOKEN_REVOKED' =>
        'This provisioning token has been revoked.',
      'SERVICE_NOT_ACTIVE' =>
        'This Softphone service is not active. Please contact support.',
      _ => null,
    };
  }
}

class NetworkException extends AppException {
  const NetworkException({
    required super.message,
    super.userMessage = 'Network connection failed. Please try again.',
    super.code,
    super.details,
  });
}

class AuthException extends AppException {
  const AuthException({
    required super.message,
    super.userMessage = 'Authentication failed. Please sign in again.',
    super.code,
    super.details,
  });
}

class VoipException extends AppException {
  const VoipException({
    required super.message,
    super.userMessage = 'Calling service is not ready yet.',
    super.code,
    super.details,
  });
}

class StorageException extends AppException {
  const StorageException({
    required super.message,
    super.userMessage = 'Secure storage is unavailable on this device.',
    super.code,
    super.details,
  });
}
