class CarrierMessagingConfig {
  const CarrierMessagingConfig({
    required this.enabled,
    required this.did,
    required this.inboxId,
  });

  factory CarrierMessagingConfig.fromJson(Map<String, dynamic> json) {
    final nested = json['carrierMessaging'] ?? json['carrier_messaging'];
    final values = nested is Map ? Map<String, dynamic>.from(nested) : json;
    return CarrierMessagingConfig(
      enabled: _bool(values['enabled'] ?? values['carrier_messaging_enabled']),
      did: _string(values['did'] ?? values['carrier_messaging_did']),
      inboxId: _string(
        values['inboxId'] ??
            values['inbox_id'] ??
            values['carrier_messaging_inbox_id'],
      ),
    );
  }

  final bool enabled;
  final String did;
  final String inboxId;

  CarrierMessagingReadiness get readiness {
    if (!enabled) {
      return did.isNotEmpty || inboxId.isNotEmpty
          ? CarrierMessagingReadiness.suspended
          : CarrierMessagingReadiness.notAssigned;
    }
    if (!_isE164(did) || inboxId.isEmpty) {
      return CarrierMessagingReadiness.incomplete;
    }
    return CarrierMessagingReadiness.ready;
  }

  bool get canUseMessaging => readiness == CarrierMessagingReadiness.ready;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'did': did,
    'inboxId': inboxId,
  };
}

enum CarrierMessagingReadiness { notAssigned, suspended, incomplete, ready }

bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return switch ('${value ?? ''}'.trim().toLowerCase()) {
    '1' || 'true' || 'yes' || 'enabled' => true,
    _ => false,
  };
}

String _string(Object? value) => '${value ?? ''}'.trim();

bool _isE164(String value) => RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(value);
