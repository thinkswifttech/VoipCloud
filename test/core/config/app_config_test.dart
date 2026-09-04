import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/app_config.dart';
import 'package:phone_app/core/config/app_environment.dart';
import 'package:phone_app/core/config/sip_transport.dart';

void main() {
  test('loads config values from map', () {
    final config = AppConfig.fromMap({
      'APP_ENV': 'staging',
      'API_BASE_URL': 'https://api.example.test',
      'MESSAGING_BASE_URL': 'https://messages.example.test',
      'SIP_DOMAIN': 'sip.example.test',
      'SIP_PROXY_HOST': 'proxy.example.test',
      'DEV_SIP_ACCOUNT_DOMAIN': 'tenant.example.test',
      'SIP_TRANSPORT': 'tls',
      'STUN_SERVER': 'stun:stun.example.test',
      'TURN_SERVER': 'turn:turn.example.test',
      'ENABLE_VOIP_DEBUG_LOGS': 'true',
    });

    expect(config.environment, AppEnvironment.staging);
    expect(config.apiBaseUrl, 'https://api.example.test');
    expect(config.messagingBaseUrl, 'https://messages.example.test');
    expect(config.messagingBaseUri?.host, 'messages.example.test');
    expect(config.devSipAccountDomain, 'tenant.example.test');
    expect(config.sipTransport, SipTransport.tls);
    expect(config.enableVoipDebugLogs, isTrue);
    expect(config.hasBackend, isTrue);
    expect(config.hasSipProxy, isTrue);
  });

  test('defaults to development with unset placeholders', () {
    final config = AppConfig.fromMap({});

    expect(config.environment, AppEnvironment.development);
    expect(config.hasBackend, isFalse);
    expect(config.hasSipProxy, isFalse);
    expect(config.messagingBaseUri, isNull);
  });
}
