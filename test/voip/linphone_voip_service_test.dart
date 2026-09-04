import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/features/sip/domain/sip_config.dart';
import 'package:phone_app/voip/linphone/linphone_voip_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'service does not fake SIP registration without native bridge',
    () async {
      final service = LinphoneVoipService();
      addTearDown(service.dispose);

      expect(service.initialize, throwsA(isA<MissingPluginException>()));
    },
  );

  test('dev pilot SIP payload parses without hardcoding into app logic', () {
    final config = SipConfig.fromJson(const {
      'sipIdentity': '101@tenant.example.test',
      'authId': '101',
      'password': 'secret',
      'domain': 'tenant.example.test',
      'outboundProxy': 'sip:sip.example.test:5061;transport=tls',
      'port': 5061,
      'transport': 'TLS',
    });

    expect(config.sipIdentity, '101@tenant.example.test');
    expect(config.authUsername, '101');
    expect(config.transport, SipTransport.tls);
  });
}
