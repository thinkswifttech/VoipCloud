class SipLogEntry {
  const SipLogEntry({
    required this.at,
    required this.level,
    required this.source,
    required this.message,
  });

  factory SipLogEntry.fromMap(Map<String, dynamic> map) {
    return SipLogEntry(
      at: DateTime.tryParse('${map['at'] ?? ''}') ?? DateTime.now(),
      level: normalizeLevel('${map['level'] ?? 'info'}'),
      source: '${map['source'] ?? 'native'}'.trim().isEmpty
          ? 'native'
          : '${map['source']}'.trim(),
      message: '${map['message'] ?? ''}',
    );
  }

  final DateTime at;
  final String level;
  final String source;
  final String message;

  String get line {
    final stamp = at.toUtc().toIso8601String();
    return '$stamp [${level.toUpperCase()}] [$source] $message';
  }

  static String normalizeLevel(String value) {
    return switch (value.trim().toLowerCase()) {
      'error' || 'fatal' || 'err' => 'error',
      'warn' || 'warning' => 'warn',
      'debug' || 'trace' || 'verbose' => 'debug',
      _ => 'info',
    };
  }
}
