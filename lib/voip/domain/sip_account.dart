import '../../core/config/sip_transport.dart';

class SipAccount {
  const SipAccount({
    required this.username,
    required this.domain,
    required this.proxyHost,
    required this.transport,
    this.id,
    this.authUsername,
    this.password,
    this.displayName,
    this.extension,
    this.stunServer,
    this.turnServer,
  });

  final String? id;
  final String username;
  final String? authUsername;
  final String? password;
  final String domain;
  final String proxyHost;
  final SipTransport transport;
  final String? displayName;
  final String? extension;
  final String? stunServer;
  final String? turnServer;

  bool get hasCredentials =>
      username.trim().isNotEmpty &&
      domain.trim().isNotEmpty &&
      proxyHost.trim().isNotEmpty &&
      password != null &&
      password!.isNotEmpty;

  String get sipUri => 'sip:$username@$domain';

  String get proxyUri {
    final scheme = transport == SipTransport.tls ? 'sips' : 'sip';
    return '$scheme:$proxyHost;transport=${transport.name}';
  }
}
