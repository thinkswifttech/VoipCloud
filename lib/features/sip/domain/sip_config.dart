import '../../../core/config/sip_transport.dart';
import 'sip_push_config.dart';

class SipConfig {
  const SipConfig({
    required this.extension,
    required this.sipUsername,
    required this.authUsername,
    required this.password,
    required this.domain,
    required this.registrar,
    required this.outboundProxy,
    required this.port,
    required this.transport,
    this.realm,
    this.authDomain,
    this.ha1,
    this.algorithm,
    this.displayName,
    this.pushConfig,
  });

  factory SipConfig.fromJson(Map<String, dynamic> json) {
    final identity = _string(
      json['sipIdentity'] ?? json['identity'] ?? json['username'],
    );
    final parsedIdentity = _parseIdentity(identity);
    final domain = _string(
      json['domain'] ?? json['realm'] ?? parsedIdentity.$2,
      fallback: '',
    );
    final registrar = _string(
      json['registrar'] ??
          json['registrarServer'] ??
          json['serverAddress'] ??
          json['regProxy'],
      fallback: domain,
    );
    final sipUsername = _string(
      json['sipUsername'] ?? json['username'] ?? parsedIdentity.$1,
    );
    final password = _string(
      json['password'] ?? json['secret'] ?? json['passwd'],
    );
    final ha1 = _string(json['ha1']);
    final push = json['push'];
    if (password.isEmpty && ha1.isEmpty) {
      throw const FormatException('Missing "password" or "ha1" in SIP config');
    }
    return SipConfig(
      extension: _string(json['extension'], fallback: sipUsername),
      sipUsername: _requiredValue(sipUsername, 'sipUsername'),
      authUsername: _string(
        json['authUsername'] ?? json['authId'] ?? json['userid'],
        fallback: sipUsername,
      ),
      password: password,
      domain: _requiredValue(domain, 'domain'),
      registrar: _requiredValue(registrar, 'registrar'),
      outboundProxy: _string(json['outboundProxy'] ?? json['proxy']),
      port: _int(json['port'], fallback: 5061),
      transport: SipTransport.parse(
        _string(json['transport'], fallback: 'TLS'),
      ),
      realm: _nullableString(json['realm']),
      authDomain: _nullableString(json['authDomain']),
      ha1: _nullableString(ha1),
      algorithm: _nullableString(json['algorithm']),
      displayName: _nullableString(json['displayName']),
      pushConfig: push is Map
          ? SipPushConfig.fromJson(Map<String, dynamic>.from(push))
          : null,
    );
  }

  final String extension;
  final String sipUsername;
  final String authUsername;
  final String password;
  final String domain;
  final String registrar;
  final String outboundProxy;
  final int port;
  final SipTransport transport;
  final String? realm;
  final String? authDomain;
  final String? ha1;
  final String? algorithm;
  final String? displayName;
  final SipPushConfig? pushConfig;

  bool get hasCredentials =>
      sipUsername.isNotEmpty &&
      authUsername.isNotEmpty &&
      (password.isNotEmpty || (ha1 != null && ha1!.isNotEmpty)) &&
      domain.isNotEmpty &&
      registrar.isNotEmpty;

  String get transportLabel => transport.name.toUpperCase();

  String get sipIdentity => '$sipUsername@$domain';

  SipConfig copyWith({
    String? outboundProxy,
    int? port,
    SipTransport? transport,
    SipPushConfig? pushConfig,
    bool clearPushConfig = false,
  }) {
    return SipConfig(
      extension: extension,
      sipUsername: sipUsername,
      authUsername: authUsername,
      password: password,
      domain: domain,
      registrar: registrar,
      outboundProxy: outboundProxy ?? this.outboundProxy,
      port: port ?? this.port,
      transport: transport ?? this.transport,
      realm: realm,
      authDomain: authDomain,
      ha1: ha1,
      algorithm: algorithm,
      displayName: displayName,
      pushConfig: clearPushConfig ? null : pushConfig ?? this.pushConfig,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'extension': extension,
      'sipUsername': sipUsername,
      'authUsername': authUsername,
      'password': password,
      'domain': domain,
      'registrar': registrar,
      'outboundProxy': outboundProxy,
      'port': port,
      'transport': transport.name.toUpperCase(),
      'realm': realm,
      'authDomain': authDomain,
      'ha1': ha1,
      'algorithm': algorithm,
      'displayName': displayName,
      'push': pushConfig?.toJson(),
    };
  }
}

String _requiredValue(String value, String key) {
  if (value.isEmpty) {
    throw FormatException('Missing "$key" in SIP config');
  }
  return value;
}

(String, String) _parseIdentity(String value) {
  var normalized = value.trim();
  if (normalized.startsWith('sip:')) {
    normalized = normalized.substring(4);
  }
  final parts = normalized.split('@');
  if (parts.length < 2) {
    return (normalized, '');
  }
  return (parts.first, parts.sublist(1).join('@'));
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}

int _int(Object? value, {required int fallback}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse('$value') ?? fallback;
}
