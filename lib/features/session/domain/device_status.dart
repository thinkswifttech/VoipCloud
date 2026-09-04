import 'device_info.dart';

class DeviceStatus {
  const DeviceStatus({
    required this.provisioningStatus,
    required this.sessionStatus,
    required this.revoked,
    this.sessionId,
    this.deviceId,
    this.platform,
    this.appVersion,
    this.sipIdentity,
    this.pushTokenType,
    this.lastSeenAt,
    this.revokedAt,
  });

  factory DeviceStatus.fromJson(Map<String, dynamic> json) {
    return DeviceStatus(
      sessionId: _nullableString(json['sessionId']),
      deviceId: _nullableString(json['deviceId']),
      platform: DevicePlatformCodec.parse(_string(json['platform'])),
      appVersion: _nullableString(json['appVersion']),
      sipIdentity: _nullableString(json['sipIdentity']),
      provisioningStatus: DeviceProvisioningStatusCodec.parse(
        _string(json['provisioningStatus']),
      ),
      sessionStatus: DeviceSessionStatusCodec.parse(
        _string(json['sessionStatus']),
      ),
      revoked: json['revoked'] == true,
      pushTokenType: _nullableString(
        json['pushTokenType'] ?? json['pushProvider'],
      ),
      lastSeenAt: _date(json['lastSeenAt']),
      revokedAt: _date(json['revokedAt']),
    );
  }

  final String? sessionId;
  final String? deviceId;
  final DevicePlatform? platform;
  final String? appVersion;
  final String? sipIdentity;
  final DeviceProvisioningStatus provisioningStatus;
  final DeviceSessionStatus sessionStatus;
  final bool revoked;
  final String? pushTokenType;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;

  bool get isUsable =>
      !revoked &&
      sessionStatus == DeviceSessionStatus.active &&
      provisioningStatus == DeviceProvisioningStatus.provisioned;

  bool get requiresProvisioning =>
      provisioningStatus == DeviceProvisioningStatus.notProvisioned ||
      provisioningStatus == DeviceProvisioningStatus.reprovisionRequired;

  DeviceStatus copyWithSipIdentity(String? value) {
    if (value == null || value.isEmpty) {
      return this;
    }
    return DeviceStatus(
      sessionId: sessionId,
      deviceId: deviceId,
      platform: platform,
      appVersion: appVersion,
      sipIdentity: value,
      provisioningStatus: provisioningStatus,
      sessionStatus: sessionStatus,
      revoked: revoked,
      pushTokenType: pushTokenType,
      lastSeenAt: lastSeenAt,
      revokedAt: revokedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'deviceId': deviceId,
      'platform': platform?.name.toUpperCase(),
      'appVersion': appVersion,
      'sipIdentity': sipIdentity,
      'provisioningStatus': provisioningStatus.name.toUpperCase(),
      'sessionStatus': sessionStatus.name.toUpperCase(),
      'revoked': revoked,
      'pushTokenType': pushTokenType,
      'lastSeenAt': lastSeenAt?.toIso8601String(),
      'revokedAt': revokedAt?.toIso8601String(),
    };
  }
}

enum DeviceProvisioningStatus {
  notProvisioned,
  provisioned,
  reprovisionRequired,
  unknown,
}

extension DeviceProvisioningStatusCodec on DeviceProvisioningStatus {
  static DeviceProvisioningStatus parse(String value) {
    return switch (value.trim().toUpperCase()) {
      'NOT_PROVISIONED' => DeviceProvisioningStatus.notProvisioned,
      'PROVISIONED' => DeviceProvisioningStatus.provisioned,
      'REPROVISION_REQUIRED' => DeviceProvisioningStatus.reprovisionRequired,
      _ => DeviceProvisioningStatus.unknown,
    };
  }

  String get label {
    return switch (this) {
      DeviceProvisioningStatus.notProvisioned => 'Not provisioned',
      DeviceProvisioningStatus.provisioned => 'Provisioned',
      DeviceProvisioningStatus.reprovisionRequired => 'Reprovision required',
      DeviceProvisioningStatus.unknown => 'Unknown',
    };
  }
}

enum DeviceSessionStatus { active, revoked, expired, unknown }

extension DeviceSessionStatusCodec on DeviceSessionStatus {
  static DeviceSessionStatus parse(String value) {
    return switch (value.trim().toUpperCase()) {
      'ACTIVE' => DeviceSessionStatus.active,
      'REVOKED' => DeviceSessionStatus.revoked,
      'EXPIRED' => DeviceSessionStatus.expired,
      _ => DeviceSessionStatus.unknown,
    };
  }

  String get label {
    return switch (this) {
      DeviceSessionStatus.active => 'Active',
      DeviceSessionStatus.revoked => 'Revoked',
      DeviceSessionStatus.expired => 'Expired',
      DeviceSessionStatus.unknown => 'Unknown',
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

DateTime? _date(Object? value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse('$value');
}
