import '../../sip/domain/sip_config.dart';
import '../../directory/domain/directory_access.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import 'current_user.dart';
import 'device_status.dart';
import 'device_credential.dart';
import 'provisioning_reference.dart';
import 'service_account.dart';

class AppSession {
  const AppSession({
    required this.accessToken,
    required this.user,
    required this.service,
    required this.device,
    required this.provisioning,
    required this.sipConfig,
    this.directoryAccess,
    this.deviceCredential,
    this.carrierMessaging,
    this.refreshToken,
  });

  factory AppSession.localSip({
    required SipConfig sipConfig,
    required DeviceStatus device,
    DirectoryAccess? directoryAccess,
    DeviceCredential? deviceCredential,
    CarrierMessagingConfig? carrierMessaging,
  }) {
    return AppSession(
      accessToken: '',
      user: CurrentUser(
        id: sipConfig.sipIdentity,
        fullName: sipConfig.displayName ?? sipConfig.sipUsername,
        status: UserStatus.active,
      ),
      service: const ServiceAccount(serviceStatus: ServiceStatus.active),
      device: device,
      provisioning: ProvisioningReference(
        source: 'FLEXIAPI',
        status: DeviceProvisioningStatus.provisioned,
        sipIdentity: sipConfig.sipIdentity,
        displayName: sipConfig.displayName,
      ),
      sipConfig: sipConfig,
      directoryAccess: directoryAccess,
      deviceCredential: deviceCredential,
      carrierMessaging: carrierMessaging,
    );
  }

  factory AppSession.fromExchangeJson(Map<String, dynamic> json) {
    final sip = json['sip'];
    return AppSession(
      accessToken: _requiredString(json, 'accessToken'),
      refreshToken: _nullableString(json['refreshToken']),
      user: CurrentUser.fromJson(_requiredMap(json['user'], 'user')),
      service: ServiceAccount.fromJson(
        _requiredMap(json['service'], 'service'),
      ),
      device: _optionalDevice(json['device']),
      provisioning: _optionalProvisioning(json['provisioning']),
      sipConfig: sip is Map
          ? SipConfig.fromJson(Map<String, dynamic>.from(sip))
          : null,
      directoryAccess: json['directory'] is Map
          ? DirectoryAccess.fromJson(
              Map<String, dynamic>.from(json['directory'] as Map),
            )
          : null,
      deviceCredential: _optionalDeviceCredential(json),
      carrierMessaging: _optionalCarrierMessaging(json),
    );
  }

  final String accessToken;
  final String? refreshToken;
  final CurrentUser user;
  final ServiceAccount service;
  final DeviceStatus device;
  final ProvisioningReference provisioning;
  final SipConfig? sipConfig;
  final DirectoryAccess? directoryAccess;
  final DeviceCredential? deviceCredential;
  final CarrierMessagingConfig? carrierMessaging;

  bool get hasBackendSession => accessToken.trim().isNotEmpty;

  AppSession copyWith({
    String? accessToken,
    String? refreshToken,
    CurrentUser? user,
    ServiceAccount? service,
    DeviceStatus? device,
    ProvisioningReference? provisioning,
    SipConfig? sipConfig,
    DirectoryAccess? directoryAccess,
    DeviceCredential? deviceCredential,
    CarrierMessagingConfig? carrierMessaging,
    bool clearSipConfig = false,
    bool clearDirectoryAccess = false,
    bool clearDeviceCredential = false,
    bool clearCarrierMessaging = false,
  }) {
    return AppSession(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      user: user ?? this.user,
      service: service ?? this.service,
      device: device ?? this.device,
      provisioning: provisioning ?? this.provisioning,
      sipConfig: clearSipConfig ? null : sipConfig ?? this.sipConfig,
      directoryAccess: clearDirectoryAccess
          ? null
          : directoryAccess ?? this.directoryAccess,
      deviceCredential: clearDeviceCredential
          ? null
          : deviceCredential ?? this.deviceCredential,
      carrierMessaging: clearCarrierMessaging
          ? null
          : carrierMessaging ?? this.carrierMessaging,
    );
  }

  bool get canRegisterSip =>
      service.isActive &&
      device.isUsable &&
      sipConfig != null &&
      sipConfig!.hasCredentials;
}

DeviceCredential? _optionalDeviceCredential(Map<String, dynamic> json) {
  final value = json['deviceCredential'] ?? json['device_credential'];
  return value is Map
      ? DeviceCredential.fromJson(Map<String, dynamic>.from(value))
      : null;
}

CarrierMessagingConfig? _optionalCarrierMessaging(Map<String, dynamic> json) {
  final value =
      json['carrierMessaging'] ??
      json['carrier_messaging'] ??
      json['messaging'];
  if (value is Map) {
    return CarrierMessagingConfig.fromJson(Map<String, dynamic>.from(value));
  }
  if (json.containsKey('carrier_messaging_enabled') ||
      json.containsKey('carrier_messaging_did') ||
      json.containsKey('carrier_messaging_inbox_id')) {
    return CarrierMessagingConfig.fromJson(json);
  }
  return null;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  throw FormatException('Missing "$key" in app session');
}

String? _nullableString(Object? value) {
  if (value == null) {
    return null;
  }
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

Map<String, dynamic> _requiredMap(Object? value, String key) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  throw FormatException('Missing "$key" in app session');
}

DeviceStatus _optionalDevice(Object? value) {
  if (value is Map) {
    return DeviceStatus.fromJson(Map<String, dynamic>.from(value));
  }
  return const DeviceStatus(
    provisioningStatus: DeviceProvisioningStatus.unknown,
    sessionStatus: DeviceSessionStatus.unknown,
    revoked: false,
  );
}

ProvisioningReference _optionalProvisioning(Object? value) {
  if (value is Map) {
    return ProvisioningReference.fromJson(Map<String, dynamic>.from(value));
  }
  return const ProvisioningReference(status: DeviceProvisioningStatus.unknown);
}
