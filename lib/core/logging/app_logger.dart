import 'package:flutter/foundation.dart';

import 'log_sanitizer.dart';

class AppLogger {
  const AppLogger._();

  static void debug(String message, {Object? data}) {
    if (!kDebugMode) {
      return;
    }
    _write('DEBUG', message, data: data);
  }

  static void info(String message, {Object? data}) {
    if (!kDebugMode) {
      return;
    }
    _write('INFO', message, data: data);
  }

  static void warning(String message, {Object? data}) {
    if (!kDebugMode) {
      return;
    }
    _write('WARN', message, data: data);
  }

  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Object? data,
  }) {
    _write('ERROR', message, data: data ?? error);
    if (kDebugMode && stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }

  static void _write(String level, String message, {Object? data}) {
    final sanitizedMessage = LogSanitizer.sanitizeText(message);
    final sanitizedData = LogSanitizer.sanitize(data);
    if (sanitizedData == null) {
      debugPrint('[$level] $sanitizedMessage');
    } else {
      debugPrint('[$level] $sanitizedMessage $sanitizedData');
    }
  }
}
