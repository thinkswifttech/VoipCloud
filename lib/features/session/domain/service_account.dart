class ServiceAccount {
  const ServiceAccount({
    required this.serviceStatus,
    this.whmcsClientId,
    this.whmcsServiceId,
    this.planCode,
  });

  factory ServiceAccount.fromJson(Map<String, dynamic> json) {
    return ServiceAccount(
      whmcsClientId: _nullableString(json['whmcsClientId']),
      whmcsServiceId: _nullableString(json['whmcsServiceId']),
      serviceStatus: ServiceStatusCodec.parse(_string(json['serviceStatus'])),
      planCode: _nullableString(json['planCode']),
    );
  }

  final String? whmcsClientId;
  final String? whmcsServiceId;
  final ServiceStatus serviceStatus;
  final String? planCode;

  bool get isActive => serviceStatus == ServiceStatus.active;

  bool get blocksSip => !isActive;

  Map<String, dynamic> toJson() {
    return {
      'whmcsClientId': whmcsClientId,
      'whmcsServiceId': whmcsServiceId,
      'serviceStatus': serviceStatus.name.toUpperCase(),
      'planCode': planCode,
    };
  }
}

enum ServiceStatus {
  active,
  suspended,
  terminated,
  cancelled,
  pending,
  unknown,
}

extension ServiceStatusCodec on ServiceStatus {
  static ServiceStatus parse(String value) {
    return switch (value.trim().toUpperCase()) {
      'ACTIVE' => ServiceStatus.active,
      'SUSPENDED' => ServiceStatus.suspended,
      'TERMINATED' => ServiceStatus.terminated,
      'CANCELLED' || 'CANCELED' => ServiceStatus.cancelled,
      'PENDING' => ServiceStatus.pending,
      _ => ServiceStatus.unknown,
    };
  }

  String get label {
    return switch (this) {
      ServiceStatus.active => 'Active',
      ServiceStatus.suspended => 'Suspended',
      ServiceStatus.terminated => 'Terminated',
      ServiceStatus.cancelled => 'Cancelled',
      ServiceStatus.pending => 'Pending',
      ServiceStatus.unknown => 'Unknown',
    };
  }

  String get accountMessage {
    return switch (this) {
      ServiceStatus.suspended =>
        'Your Softphone service is currently suspended. Please contact support.',
      ServiceStatus.terminated =>
        'Your Softphone service has been terminated. Please contact support.',
      ServiceStatus.cancelled =>
        'Your Softphone service has been cancelled. Please contact support.',
      ServiceStatus.pending =>
        'Your Softphone service is pending activation. Please contact support if this does not change soon.',
      ServiceStatus.active => 'Your Softphone service is active.',
      ServiceStatus.unknown =>
        'Your Softphone service status could not be confirmed. Please contact support.',
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
