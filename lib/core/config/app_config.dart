import 'package:flutter/foundation.dart';

import 'app_environment.dart';
import 'sip_transport.dart';

class AppConfig {
  const AppConfig({
    required this.environment,
    required this.apiBaseUrl,
    required this.messagingBaseUrl,
    required this.sipDomain,
    required this.sipProxyHost,
    required this.devSipAccountDomain,
    required this.sipTransport,
    required this.stunServer,
    required this.turnServer,
    required this.enableVoipDebugLogs,
    required this.desktopUpdateManifestUrl,
  });

  factory AppConfig.fromEnvironment() {
    const envFromDefine = String.fromEnvironment('APP_ENV');
    final environment = envFromDefine.isNotEmpty
        ? AppEnvironment.parse(envFromDefine)
        : (kReleaseMode
              ? AppEnvironment.production
              : AppEnvironment.development);

    return AppConfig(
      environment: environment,
      apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
      messagingBaseUrl: const String.fromEnvironment('MESSAGING_BASE_URL'),
      sipDomain: const String.fromEnvironment('SIP_DOMAIN'),
      sipProxyHost: const String.fromEnvironment('SIP_PROXY_HOST'),
      devSipAccountDomain: const String.fromEnvironment(
        'DEV_SIP_ACCOUNT_DOMAIN',
      ),
      sipTransport: SipTransport.parse(
        const String.fromEnvironment('SIP_TRANSPORT', defaultValue: 'udp'),
      ),
      stunServer: const String.fromEnvironment('STUN_SERVER'),
      turnServer: const String.fromEnvironment('TURN_SERVER'),
      enableVoipDebugLogs: const bool.fromEnvironment('ENABLE_VOIP_DEBUG_LOGS'),
      desktopUpdateManifestUrl: const String.fromEnvironment(
        'DESKTOP_UPDATE_MANIFEST_URL',
      ),
    );
  }

  factory AppConfig.fromMap(Map<String, String> values) {
    return AppConfig(
      environment: AppEnvironment.parse(values['APP_ENV'] ?? 'development'),
      apiBaseUrl: values['API_BASE_URL'] ?? '',
      messagingBaseUrl: values['MESSAGING_BASE_URL'] ?? '',
      sipDomain: values['SIP_DOMAIN'] ?? '',
      sipProxyHost: values['SIP_PROXY_HOST'] ?? '',
      devSipAccountDomain: values['DEV_SIP_ACCOUNT_DOMAIN'] ?? '',
      sipTransport: SipTransport.parse(values['SIP_TRANSPORT'] ?? 'udp'),
      stunServer: values['STUN_SERVER'] ?? '',
      turnServer: values['TURN_SERVER'] ?? '',
      enableVoipDebugLogs:
          (values['ENABLE_VOIP_DEBUG_LOGS'] ?? '').toLowerCase() == 'true',
      desktopUpdateManifestUrl: values['DESKTOP_UPDATE_MANIFEST_URL'] ?? '',
    );
  }

  final AppEnvironment environment;
  final String apiBaseUrl;
  final String messagingBaseUrl;
  final String sipDomain;
  final String sipProxyHost;
  final String devSipAccountDomain;
  final SipTransport sipTransport;
  final String stunServer;
  final String turnServer;
  final bool enableVoipDebugLogs;
  final String desktopUpdateManifestUrl;

  bool get isProduction => environment == AppEnvironment.production;

  bool get hasBackend => apiBaseUrl.trim().isNotEmpty;

  Uri? get messagingBaseUri {
    final uri = Uri.tryParse(messagingBaseUrl.trim());
    if (uri == null || uri.host.isEmpty || !uri.hasScheme) {
      return null;
    }
    if (isProduction && uri.scheme.toLowerCase() != 'https') {
      return null;
    }
    return uri;
  }

  bool get hasSipProxy =>
      sipDomain.trim().isNotEmpty && sipProxyHost.trim().isNotEmpty;

  Uri? get apiBaseUri {
    if (!hasBackend) {
      return null;
    }
    return Uri.tryParse(apiBaseUrl);
  }

  Uri? get desktopUpdateManifestUri {
    final uri = Uri.tryParse(desktopUpdateManifestUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }
}
