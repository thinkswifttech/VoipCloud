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
    super.userMessage = "We couldn't complete that. Please try again.",
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
            _userMessageForCode(code) ??
            "Some of your details don't look right. Please check them and try again.",
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
        userMessage:
            "Your account can't do that. Contact your administrator if you think this is a mistake.",
        code: code,
        details: details,
      );
    }
    if (statusCode == 404) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Not found',
        userMessage: "We couldn't find that. It may have been removed.",
        code: code,
        details: details,
      );
    }
    if (statusCode != null && statusCode >= 500) {
      return ApiException(
        statusCode: statusCode,
        message: message ?? 'Server error',
        userMessage:
            'Our service is temporarily unavailable. Please try again in a few minutes.',
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
        "This activation link isn't valid. Check the link or scan the QR code again.",
      'PROVISIONING_TOKEN_EXPIRED' =>
        'This activation link has expired. Ask your administrator for a new one.',
      'PROVISIONING_TOKEN_USED' =>
        'This activation link has already been used.',
      'PROVISIONING_TOKEN_REVOKED' =>
        'This activation link is no longer active.',
      'SERVICE_NOT_ACTIVE' =>
        "Your phone service isn't active yet. Please contact support.",
      _ => null,
    };
  }
}

class NetworkException extends AppException {
  const NetworkException({
    required super.message,
    super.userMessage =
        "Can't connect right now. Check your internet connection and try again.",
    super.code,
    super.details,
  });
}

class AuthException extends AppException {
  const AuthException({
    required super.message,
    super.userMessage = "We couldn't sign you in. Please try again.",
    super.code,
    super.details,
  });
}

class VoipException extends AppException {
  const VoipException({
    required super.message,
    super.userMessage =
        "Calling isn't ready yet. Please try again in a moment.",
    super.code,
    super.details,
  });
}

class StorageException extends AppException {
  const StorageException({
    required super.message,
    super.userMessage =
        "Couldn't access secure storage on this device. Restart the app and try again.",
    super.code,
    super.details,
  });
}
