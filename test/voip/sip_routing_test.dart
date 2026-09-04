import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/sip_transport.dart';
import 'package:phone_app/features/sip/domain/sip_config.dart';
import 'package:phone_app/features/sip/domain/sip_routing.dart';

void main() {
  group('alignSipRouting', () {
    test('does not add a proxy when none is configured', () {
      final aligned = alignSipRouting(_config(), '');

      expect(aligned.outboundProxy, isEmpty);
    });

    test('uses an explicitly configured proxy host', () {
      final aligned = alignSipRouting(_config(), 'edge.example.test');

      expect(
        aligned.outboundProxy,
        'sip:edge.example.test:5061;transport=tls;lr',
      );
    });

    test('preserves an outbound proxy supplied by provisioning', () {
      final original = _config().copyWith(
        outboundProxy: 'sip:provisioned.example.com:5071;transport=tls',
      );

      expect(alignSipRouting(original, ''), same(original));
    });

    test('does not route an account when no proxy is configured', () {
      final original = _config(
        domain: 'pbx.example.com',
        registrar: 'sip:pbx.example.com',
      );

      expect(alignSipRouting(original, ''), same(original));
    });
  });
}

SipConfig _config({
  String domain = 'tenant.example.test',
  String registrar = 'sip:tenant.example.test',
}) {
  return SipConfig(
    extension: '101',
    sipUsername: '101',
    authUsername: '101',
    password: '',
    ha1: 'sha256-ha1',
    algorithm: 'SHA-256',
    domain: domain,
    registrar: registrar,
    outboundProxy: '',
    port: 5061,
    transport: SipTransport.tls,
  );
}
