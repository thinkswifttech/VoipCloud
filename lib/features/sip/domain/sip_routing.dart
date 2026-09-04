import '../../../core/config/sip_transport.dart';
import 'sip_config.dart';

SipConfig alignSipRouting(SipConfig sip, String configuredProxyHost) {
  if (sip.outboundProxy.trim().isNotEmpty) {
    return sip;
  }

  final configuredHost = configuredProxyHost.trim();
  if (configuredHost.isEmpty) {
    return sip;
  }

  return sip.copyWith(
    outboundProxy: 'sip:$configuredHost:5061;transport=tls;lr',
    port: 5061,
    transport: SipTransport.tls,
  );
}
