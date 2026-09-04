class MessagingSessionCredentials {
  const MessagingSessionCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required this.sessionId,
    required this.inboxId,
  });

  factory MessagingSessionCredentials.fromJson(Map<String, dynamic> json) {
    final inbox = json['inbox'];
    final inboxValues = inbox is Map
        ? Map<String, dynamic>.from(inbox)
        : const <String, dynamic>{};
    return MessagingSessionCredentials(
      accessToken: _required(json['access_token'], 'access_token'),
      refreshToken: _required(json['refresh_token'], 'refresh_token'),
      accessExpiresAt: _requiredDate(
        json['access_expires_at'],
        'access_expires_at',
      ),
      refreshExpiresAt: _requiredDate(
        json['refresh_expires_at'],
        'refresh_expires_at',
      ),
      sessionId: _required(json['session_id'], 'session_id'),
      inboxId: _required(inboxValues['id'], 'inbox.id'),
    );
  }

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final String sessionId;
  final String inboxId;

  bool accessIsUsable(DateTime now) =>
      accessExpiresAt.isAfter(now.add(const Duration(minutes: 1)));

  bool refreshIsUsable(DateTime now) =>
      refreshExpiresAt.isAfter(now.add(const Duration(minutes: 1)));
}

class MessagingProvisioningContext {
  const MessagingProvisioningContext({
    required this.directoryToken,
    required this.deviceId,
    required this.platform,
    required this.appVersion,
    this.expectedInboxId,
  });

  final String directoryToken;
  final String deviceId;
  final String platform;
  final String appVersion;
  final String? expectedInboxId;
}

String _required(Object? value, String field) {
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty) throw FormatException('Missing $field');
  return text;
}

DateTime _requiredDate(Object? value, String field) {
  final parsed = DateTime.tryParse('${value ?? ''}');
  if (parsed == null) throw FormatException('Invalid $field');
  return parsed.toUtc();
}
