import 'dart:convert';

import 'package:xml/xml.dart';

import '../../../core/config/sip_transport.dart';
import '../../sip/domain/sip_config.dart';
import '../../directory/domain/directory_access.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import '../../session/domain/device_credential.dart';

class ProvisionedConfiguration {
  const ProvisionedConfiguration({
    this.sipConfig,
    this.directoryAccess,
    this.deviceCredential,
    this.carrierMessaging,
  });

  final SipConfig? sipConfig;
  final DirectoryAccess? directoryAccess;
  final DeviceCredential? deviceCredential;
  final CarrierMessagingConfig? carrierMessaging;
}

ProvisionedConfiguration parseProvisionedConfiguration(
  String body,
  Uri provisioningUri, {
  String? accountDomainOverride,
}) {
  return ProvisionedConfiguration(
    sipConfig: parseProvisionedSipConfig(
      body,
      provisioningUri,
      accountDomainOverride: accountDomainOverride,
    ),
    directoryAccess: parseProvisionedDirectoryAccess(body, provisioningUri),
    deviceCredential: parseProvisionedDeviceCredential(body, provisioningUri),
    carrierMessaging: parseProvisionedCarrierMessaging(body),
  );
}

DeviceCredential? parseProvisionedDeviceCredential(
  String body,
  Uri provisioningUri,
) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  Map<String, dynamic>? raw;
  if (trimmed.startsWith('<')) {
    final document = XmlDocument.parse(trimmed);
    for (final section in document.descendants.whereType<XmlElement>()) {
      if (section.name.local == 'section' &&
          section.getAttribute('name') == 'voipcloud_device') {
        raw = Map<String, dynamic>.from(_entries(section));
        break;
      }
    }
  } else {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final nested =
          decoded['deviceCredential'] ?? decoded['device_credential'];
      if (nested is Map) raw = Map<String, dynamic>.from(nested);
    }
  }
  if (raw == null) return null;
  final endpointText =
      '${raw['revoke_endpoint'] ?? raw['revokeEndpoint'] ?? ''}'.trim();
  final parsedEndpoint = Uri.tryParse(endpointText);
  final endpoint = parsedEndpoint == null
      ? null
      : parsedEndpoint.hasScheme
      ? parsedEndpoint
      : provisioningUri.resolveUri(parsedEndpoint);
  return DeviceCredential.fromJson({
    'revokeEndpoint': endpoint?.toString() ?? '',
    'token': raw['token'],
  });
}

CarrierMessagingConfig? parseProvisionedCarrierMessaging(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  Map<String, dynamic>? values;
  if (trimmed.startsWith('<')) {
    final document = XmlDocument.parse(trimmed);
    final entries = <String, dynamic>{};
    for (final entry in document.descendants.whereType<XmlElement>()) {
      if (entry.name.local != 'entry') continue;
      final name = entry.getAttribute('name')?.trim() ?? '';
      if (_carrierMessagingKeys.contains(name)) {
        entries[name] = entry.innerText.trim();
      }
    }
    if (entries.isNotEmpty) values = entries;
  } else {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final payload = Map<String, dynamic>.from(decoded);
      final nested =
          payload['carrierMessaging'] ??
          payload['carrier_messaging'] ??
          payload['messaging'];
      values = nested is Map
          ? Map<String, dynamic>.from(nested)
          : payload.keys.any(_carrierMessagingKeys.contains)
          ? payload
          : null;
    }
  }
  return values == null ? null : CarrierMessagingConfig.fromJson(values);
}

const _carrierMessagingKeys = {
  'carrier_messaging_enabled',
  'carrier_messaging_did',
  'carrier_messaging_inbox_id',
};

DirectoryAccess? parseProvisionedDirectoryAccess(
  String body,
  Uri provisioningUri,
) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  Map<String, dynamic>? raw;
  if (trimmed.startsWith('<')) {
    final document = XmlDocument.parse(trimmed);
    for (final section in document.descendants.whereType<XmlElement>()) {
      if (section.name.local == 'section' &&
          section.getAttribute('name') == 'voipcloud_directory') {
        raw = Map<String, dynamic>.from(_entries(section));
        break;
      }
    }
  } else {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map && decoded['directory'] is Map) {
      raw = Map<String, dynamic>.from(decoded['directory'] as Map);
    }
  }
  if (raw == null) return null;
  final endpointText = '${raw['endpoint'] ?? raw['url'] ?? ''}'.trim();
  final parsedEndpoint = Uri.tryParse(endpointText);
  final endpoint = parsedEndpoint == null
      ? null
      : parsedEndpoint.hasScheme
      ? parsedEndpoint
      : provisioningUri.resolveUri(parsedEndpoint);
  return DirectoryAccess.fromJson({
    'endpoint': endpoint?.toString() ?? '',
    'token': raw['token'],
  });
}

SipConfig? parseProvisionedSipConfig(
  String body,
  Uri provisioningUri, {
  String? accountDomainOverride,
}) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  if (trimmed.startsWith('<')) {
    return parseLinphoneXmlSipConfig(
      trimmed,
      provisioningUri,
      accountDomainOverride: accountDomainOverride,
    );
  }

  final decoded = jsonDecode(trimmed);
  if (decoded is! Map) {
    return null;
  }
  return sipConfigFromJsonPayload(Map<String, dynamic>.from(decoded));
}

SipConfig? sipConfigFromJsonPayload(Map<String, dynamic> payload) {
  final nested = payload['sip'] ?? payload['sipConfig'] ?? payload['account'];
  if (nested is Map) {
    return SipConfig.fromJson(Map<String, dynamic>.from(nested));
  }

  final hasTopLevelSip =
      payload.containsKey('sipIdentity') ||
      payload.containsKey('sipUsername') ||
      payload.containsKey('username');
  return hasTopLevelSip ? SipConfig.fromJson(payload) : null;
}

SipConfig? parseLinphoneXmlSipConfig(
  String body,
  Uri provisioningUri, {
  String? accountDomainOverride,
}) {
  final document = XmlDocument.parse(body);
  final sections = <String, Map<String, String>>{};
  for (final section in document.descendants.whereType<XmlElement>()) {
    if (section.name.local != 'section') {
      continue;
    }
    final name = section.getAttribute('name')?.trim();
    if (name == null || name.isEmpty) {
      continue;
    }
    sections[name] = _entries(section);
  }

  final proxy = sections['proxy_0'] ?? const <String, String>{};
  final auth = sections['auth_info_0'] ?? const <String, String>{};
  final identity = _parseIdentity(proxy['reg_identity']);
  final username = auth['username'] ?? identity.username;
  final edgeProxyHost = _edgeProxyHostFromProvisioningUri(provisioningUri);
  final tenantDomain = _tenantDomainFromProvisioningUri(provisioningUri);
  final parsedDomain = auth['domain'] ?? auth['realm'] ?? identity.domain;
  final domain = _normalizeAccountDomain(
    parsedDomain,
    edgeProxyHost: edgeProxyHost,
    tenantDomain: tenantDomain,
    accountDomainOverride: accountDomainOverride,
  );
  if (username == null ||
      username.isEmpty ||
      domain == null ||
      domain.isEmpty) {
    return null;
  }

  final outboundProxy = _useOutboundProxy(proxy, edgeProxyHost: edgeProxyHost)
      ? _firstNotEmpty([proxy['reg_route']]) ?? ''
      : '';
  final registrar =
      _firstNotEmpty([
        proxy['reg_proxy'],
        proxy['server_addr'],
        identity.domain,
        domain,
      ]) ??
      domain;

  final normalizedRegistrar = _normalizeRegistrarUri(
    registrar,
    edgeProxyHost: edgeProxyHost,
    accountDomain: domain,
  );

  return SipConfig.fromJson({
    'extension': username,
    'sipUsername': username,
    'authUsername': username,
    'domain': domain,
    'realm': auth['realm'] ?? parsedDomain ?? domain,
    'authDomain': auth['domain'] ?? auth['realm'] ?? parsedDomain ?? domain,
    'password': auth['passwd'] ?? auth['password'],
    'ha1': auth['ha1'],
    'algorithm': auth['algorithm'],
    'sipIdentity': '$username@$domain',
    'registrar': normalizedRegistrar,
    'outboundProxy': outboundProxy.isEmpty
        ? ''
        : _normalizeSipUri(outboundProxy),
    'port': _portFromSipUri(outboundProxy),
    'transport': _transportFromSipUri(outboundProxy).name,
    'displayName': identity.displayName,
  });
}

Map<String, String> _entries(XmlElement section) {
  final entries = <String, String>{};
  for (final entry in section.childElements) {
    if (entry.name.local != 'entry') {
      continue;
    }
    final name = entry.getAttribute('name')?.trim();
    if (name == null || name.isEmpty) {
      continue;
    }
    entries[name] = entry.innerText.trim();
  }
  return entries;
}

({String? displayName, String? username, String? domain}) _parseIdentity(
  String? value,
) {
  final text = value?.trim();
  if (text == null || text.isEmpty) {
    return (displayName: null, username: null, domain: null);
  }
  final match = RegExp(
    r'^(?:"([^"]*)"\s*)?<?sip:([^@>]+)@([^>]+)>?$',
  ).firstMatch(text);
  if (match == null) {
    return (displayName: null, username: null, domain: null);
  }
  return (
    displayName: _emptyToNull(match.group(1)),
    username: _emptyToNull(match.group(2)),
    domain: _emptyToNull(match.group(3)),
  );
}

String _normalizeSipUri(String value) {
  var normalized = value.trim();
  if (normalized.startsWith('<') && normalized.endsWith('>')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  if (!normalized.startsWith('sip:') && !normalized.startsWith('sips:')) {
    normalized = 'sip:$normalized';
  }
  return normalized;
}

String _normalizeRegistrarUri(
  String value, {
  required String edgeProxyHost,
  required String accountDomain,
}) {
  final normalized = _normalizeSipUri(value);
  final host = _hostFromSipUri(normalized);
  if (host == null || accountDomain.isEmpty || host == accountDomain) {
    return normalized;
  }
  if (host == edgeProxyHost || host.endsWith('.$edgeProxyHost')) {
    return _replaceSipUriHost(normalized, accountDomain);
  }
  return normalized;
}

String _replaceSipUriHost(String uri, String host) {
  final match = RegExp(
    r'^([a-z]+:)([^@;:>]+@)?([^:;>]+)(.*)$',
    caseSensitive: false,
  ).firstMatch(uri);
  if (match == null) {
    return uri;
  }
  return '${match.group(1)}${match.group(2) ?? ''}$host${match.group(4) ?? ''}';
}

String _edgeProxyHostFromProvisioningUri(Uri uri) {
  final labels = uri.host.split('.');
  if (labels.length > 3 && labels[1] == 'sip') {
    return labels.skip(1).join('.');
  }
  return uri.host;
}

String? _tenantDomainFromProvisioningUri(Uri uri) {
  final labels = uri.host.split('.');
  if (labels.length > 3 && labels[1] == 'sip') {
    return [labels.first, ...labels.skip(2)].join('.');
  }
  return null;
}

String? _normalizeAccountDomain(
  String? value, {
  required String edgeProxyHost,
  required String? tenantDomain,
  required String? accountDomainOverride,
}) {
  final domain = value?.trim();
  final override = _emptyToNull(accountDomainOverride);
  if (domain == null || domain.isEmpty) {
    return override ?? tenantDomain;
  }
  if (tenantDomain == null || tenantDomain.isEmpty) {
    if (domain == edgeProxyHost) {
      return override ?? domain;
    }
    return domain;
  }
  if (domain == edgeProxyHost || domain.endsWith('.$edgeProxyHost')) {
    return tenantDomain;
  }
  return domain;
}

int _portFromSipUri(String value) {
  final match = RegExp(r'^[a-z]+:[^:;>]+:(\d+)').firstMatch(value);
  return int.tryParse(match?.group(1) ?? '') ?? 5061;
}

SipTransport _transportFromSipUri(String value) {
  final match = RegExp(
    r'(?:^|[;?&])transport=([^;&]+)',
    caseSensitive: false,
  ).firstMatch(value);
  return SipTransport.parse(match?.group(1) ?? 'TLS');
}

String? _firstNotEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

String? _emptyToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _useOutboundProxy(
  Map<String, String> proxy, {
  required String edgeProxyHost,
}) {
  final flag = proxy['outbound_proxy']?.trim().toLowerCase();
  if (flag != null && flag.isNotEmpty) {
    return flag == '1' || flag == 'true' || flag == 'yes';
  }
  final routeHost = _hostFromSipUri(proxy['reg_route']);
  return routeHost != null && routeHost == edgeProxyHost;
}

String? _hostFromSipUri(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  final match = RegExp(
    r'^(?:sip|sips):([^:;>]+)',
    caseSensitive: false,
  ).firstMatch(text);
  return match?.group(1);
}
