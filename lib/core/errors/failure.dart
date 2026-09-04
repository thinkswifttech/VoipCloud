import 'app_exception.dart';

class Failure {
  const Failure({
    required this.userMessage,
    this.technicalMessage,
    this.code,
    this.cause,
    this.stackTrace,
  });

  factory Failure.fromException(Object error, [StackTrace? stackTrace]) {
    if (error is AppException) {
      return Failure(
        userMessage: error.userMessage,
        technicalMessage: error.message,
        code: error.code,
        cause: error,
        stackTrace: stackTrace,
      );
    }

    return Failure(
      userMessage: 'Something went wrong. Please try again.',
      technicalMessage: error.toString(),
      cause: error,
      stackTrace: stackTrace,
    );
  }

  final String userMessage;
  final String? technicalMessage;
  final String? code;
  final Object? cause;
  final StackTrace? stackTrace;
}
