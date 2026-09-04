import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/features/provisioning/data/linphone_provisioning_parser.dart';

void main() {
  test('parses messaging-only device credential without directory access', () {
    final config = parseProvisionedConfiguration('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="voipcloud_device">
    <entry name="revoke_endpoint">/api/voipcloud/device</entry>
    <entry name="token">device-token</entry>
  </section>
  <section name="app">
    <entry name="carrier_messaging_enabled">1</entry>
    <entry name="carrier_messaging_did">+14165550101</entry>
    <entry name="carrier_messaging_inbox_id">inbox-uuid</entry>
  </section>
</config>
''', Uri.parse('https://provision.example.test/provisioning/token'));

    expect(config.directoryAccess, isNull);
    expect(
      config.deviceCredential?.revokeEndpoint.toString(),
      'https://provision.example.test/api/voipcloud/device',
    );
    expect(config.deviceCredential?.token, 'device-token');
    expect(config.carrierMessaging?.canUseMessaging, isTrue);
  });

  test('parses device-scoped directory access from provisioning XML', () {
    final config = parseProvisionedConfiguration('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_identity">sip:210@tenant.example.test</entry>
    <entry name="reg_proxy">sip:tenant.example.test</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">210</entry>
    <entry name="domain">tenant.example.test</entry>
    <entry name="passwd">secret</entry>
  </section>
  <section name="voipcloud_directory">
    <entry name="endpoint">/api/voipcloud/directory</entry>
    <entry name="token">device-token</entry>
  </section>
</config>
''', Uri.parse('https://tenant-provision.example.test/provisioning/token'));

    expect(
      config.directoryAccess?.endpoint.toString(),
      'https://tenant-provision.example.test/api/voipcloud/directory',
    );
    expect(config.directoryAccess?.token, 'device-token');
  });

  test('parses carrier messaging assignment from provisioning entries', () {
    final config = parseProvisionedConfiguration('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="app">
    <entry name="carrier_messaging_enabled">1</entry>
    <entry name="carrier_messaging_did">+14165550101</entry>
    <entry name="carrier_messaging_inbox_id">inbox-uuid</entry>
  </section>
</config>
''', Uri.parse('https://provision.example.test/provisioning/token'));

    expect(config.carrierMessaging?.enabled, isTrue);
    expect(config.carrierMessaging?.did, '+14165550101');
    expect(config.carrierMessaging?.inboxId, 'inbox-uuid');
    expect(config.carrierMessaging?.canUseMessaging, isTrue);
  });

  test('parses nested carrier messaging JSON', () {
    final config = parseProvisionedCarrierMessaging('''
{
  "carrierMessaging": {
    "enabled": false,
    "did": "+14165550101",
    "inboxId": "inbox-uuid"
  }
}
''');

    expect(config, isNotNull);
    expect(config!.enabled, isFalse);
    expect(config.readiness.name, 'suspended');
  });

  test('parses Linphone XML provisioning with HA1 credentials', () {
    final config = parseProvisionedSipConfig('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_identity">"Test User" &lt;sip:101@tenant.example.test&gt;</entry>
    <entry name="reg_proxy">sip:tenant.example.test</entry>
    <entry name="reg_route">sip:sip.example.test:5061;transport=tls</entry>
    <entry name="outbound_proxy">1</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">101</entry>
    <entry name="domain">tenant.example.test</entry>
    <entry name="ha1">abc123</entry>
    <entry name="realm">tenant.example.test</entry>
    <entry name="algorithm">SHA-256</entry>
  </section>
</config>
''', Uri.parse('https://provision.example.test/provisioning/token'));

    expect(config, isNotNull);
    expect(config!.sipIdentity, '101@tenant.example.test');
    expect(config.displayName, 'Test User');
    expect(config.password, isEmpty);
    expect(config.ha1, 'abc123');
    expect(config.algorithm, 'SHA-256');
    expect(config.registrar, 'sip:tenant.example.test');
    expect(config.outboundProxy, 'sip:sip.example.test:5061;transport=tls');
    expect(config.transport, SipTransport.tls);
    expect(config.hasCredentials, isTrue);
  });

  test(
    'rewrites edge host identity domain to tenant domain from provisioning host',
    () {
      final config = parseProvisionedSipConfig('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_identity">"Test User" &lt;sip:test_user@sip.example.test&gt;</entry>
    <entry name="reg_proxy">sip:sip.example.test:5061;transport=tls</entry>
    <entry name="reg_route">sip:sip.example.test:5061;transport=tls</entry>
    <entry name="outbound_proxy">1</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">test_user</entry>
    <entry name="domain">sip.example.test</entry>
    <entry name="ha1">abc123</entry>
    <entry name="realm">sip.example.test</entry>
    <entry name="algorithm">SHA-256</entry>
  </section>
</config>
''', Uri.parse('https://tenant.sip.example.test/provisioning/token'));

      expect(config, isNotNull);
      expect(config!.sipIdentity, 'test_user@tenant.example.test');
      expect(config.domain, 'tenant.example.test');
      expect(config.realm, 'sip.example.test');
      expect(config.authDomain, 'sip.example.test');
      expect(config.registrar, 'sip:tenant.example.test:5061;transport=tls');
      expect(config.outboundProxy, 'sip:sip.example.test:5061;transport=tls');
    },
  );

  test(
    'supports dev account domain override when provisioning host is the edge',
    () {
      final config = parseProvisionedSipConfig(
        '''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_identity">"Test User" &lt;sip:test_user@sip.example.test&gt;</entry>
    <entry name="reg_proxy">sip:sip.example.test:5061;transport=tls</entry>
    <entry name="reg_route">sip:sip.example.test:5061;transport=tls</entry>
    <entry name="outbound_proxy">1</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">test_user</entry>
    <entry name="domain">sip.example.test</entry>
    <entry name="ha1">abc123</entry>
    <entry name="realm">sip.example.test</entry>
    <entry name="algorithm">SHA-256</entry>
  </section>
</config>
''',
        Uri.parse('https://tenant.sip.example.test/provisioning/token'),
        accountDomainOverride: 'tenant.example.test',
      );

      expect(config, isNotNull);
      expect(config!.sipIdentity, 'test_user@tenant.example.test');
      expect(config.domain, 'tenant.example.test');
      expect(config.realm, 'sip.example.test');
      expect(config.authDomain, 'sip.example.test');
      expect(config.registrar, 'sip:tenant.example.test:5061;transport=tls');
      expect(config.outboundProxy, 'sip:sip.example.test:5061;transport=tls');
    },
  );

  test(
    'uses Flexisip edge route by default when route matches provisioning edge',
    () {
      final config = parseProvisionedSipConfig('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_identity">"Test User" &lt;sip:105@tenant.example.test&gt;</entry>
    <entry name="reg_proxy">sip:tenant.example.test</entry>
    <entry name="reg_route">sip:sip.example.test:5061;transport=tls</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">105</entry>
    <entry name="domain">tenant.example.test</entry>
    <entry name="passwd">secret</entry>
    <entry name="realm">tenant.example.test</entry>
  </section>
</config>
''', Uri.parse('https://tenant.sip.example.test/provisioning/token'));

      expect(config, isNotNull);
      expect(config!.sipIdentity, '105@tenant.example.test');
      expect(config.registrar, 'sip:tenant.example.test');
      expect(config.outboundProxy, 'sip:sip.example.test:5061;transport=tls');
    },
  );

  test('keeps explicit outbound proxy route when provisioning asks for it', () {
    final config = parseProvisionedSipConfig('''
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_identity">"Test User" &lt;sip:105@tenant.example.test&gt;</entry>
    <entry name="reg_proxy">sip:tenant.example.test</entry>
    <entry name="reg_route">sip:sip.example.test:5061;transport=tls</entry>
    <entry name="outbound_proxy">1</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">105</entry>
    <entry name="domain">tenant.example.test</entry>
    <entry name="passwd">secret</entry>
    <entry name="realm">tenant.example.test</entry>
  </section>
</config>
''', Uri.parse('https://provision.example.test/provisioning/token'));

    expect(config, isNotNull);
    expect(config!.sipIdentity, '105@tenant.example.test');
    expect(config.registrar, 'sip:tenant.example.test');
    expect(config.outboundProxy, 'sip:sip.example.test:5061;transport=tls');
  });
}
