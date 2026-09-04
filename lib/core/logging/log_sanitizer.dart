class LogSanitizer {
  const LogSanitizer._();

  static const _sensitiveFragments = {
    'authorization',
    'access_token',
    'accessToken',
    'refresh_token',
    'refreshToken',
    'password',
    'sipPassword',
    'secret',
    'credential',
    'pushToken',
    'fcmToken',
    'apnsToken',
    'token',
    'provisioningUrl',
  };

  static Object? sanitize(Object? value) {
    if (value is Map) {
      return value.map((key, dynamic child) {
        final keyText = key.toString();
        if (_isSensitiveKey(keyText)) {
          return MapEntry(key, '<redacted>');
        }
        return MapEntry(key, sanitize(child));
      });
    }

    if (value is Iterable) {
      return value.map(sanitize).toList(growable: false);
    }

    return value;
  }

  static String sanitizeText(String value) {
    var sanitized = value;
    for (final fragment in _sensitiveFragments) {
      sanitized = sanitized.replaceAll(
        RegExp('$fragment=[^,\\s}]+', caseSensitive: false),
        '$fragment=<redacted>',
      );
    }
    sanitized = sanitized.replaceAll(
      RegExp(r'https://[^\s,}]+provision[^\s,}]*', caseSensitive: false),
      '<redacted-provisioning-url>',
    );
    return sanitized;
  }

  static bool _isSensitiveKey(String key) {
    return _sensitiveFragments.any(
      (fragment) => key.toLowerCase().contains(fragment.toLowerCase()),
    );
  }
}
