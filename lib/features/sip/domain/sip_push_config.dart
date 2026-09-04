class SipPushConfig {
  const SipPushConfig({
    required this.provider,
    required this.token,
    this.param,
    this.bundleId,
    this.teamId,
  });

  factory SipPushConfig.fromJson(Map<String, dynamic> json) {
    return SipPushConfig(
      provider: _string(json['provider']),
      token: _string(json['token'] ?? json['prid'] ?? json['deviceToken']),
      param: _nullableString(json['param']),
      bundleId: _nullableString(json['bundleId']),
      teamId: _nullableString(json['teamId']),
    );
  }

  final String provider;
  final String token;
  final String? param;
  final String? bundleId;
  final String? teamId;

  bool get isUsable => provider.trim().isNotEmpty && token.trim().isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'provider': provider,
      'token': token,
      'param': param,
      'bundleId': bundleId,
      'teamId': teamId,
    };
  }
}

String _string(Object? value) {
  if (value == null) {
    return '';
  }
  return '$value'.trim();
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}
