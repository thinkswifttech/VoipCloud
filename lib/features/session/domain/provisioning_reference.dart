import 'device_status.dart';

class ProvisioningReference {
  const ProvisioningReference({
    required this.status,
    this.source,
    this.sipIdentity,
    this.tenant,
    this.displayName,
  });

  factory ProvisioningReference.fromJson(Map<String, dynamic> json) {
    return ProvisioningReference(
      source: _nullableString(json['source']),
      status: DeviceProvisioningStatusCodec.parse(_string(json['status'])),
      sipIdentity: _nullableString(json['sipIdentity']),
      tenant: _nullableString(json['tenant']),
      displayName: _nullableString(json['displayName']),
    );
  }

  final String? source;
  final DeviceProvisioningStatus status;
  final String? sipIdentity;
  final String? tenant;
  final String? displayName;

  bool get requiresProvisioning =>
      status == DeviceProvisioningStatus.notProvisioned ||
      status == DeviceProvisioningStatus.reprovisionRequired;

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'status': status.name.toUpperCase(),
      'sipIdentity': sipIdentity,
      'tenant': tenant,
      'displayName': displayName,
    };
  }
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
