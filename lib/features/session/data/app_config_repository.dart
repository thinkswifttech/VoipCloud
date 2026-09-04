import '../../../core/errors/app_exception.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/app_client.dart';
import '../../sip/domain/sip_config.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import '../domain/current_user.dart';
import '../domain/device_status.dart';
import '../domain/provisioning_reference.dart';
import '../domain/service_account.dart';

class AppConfigSnapshot {
  const AppConfigSnapshot({
    required this.user,
    required this.service,
    required this.device,
    required this.provisioning,
    required this.sipConfig,
    this.carrierMessaging,
  });

  final CurrentUser user;
  final ServiceAccount service;
  final DeviceStatus device;
  final ProvisioningReference provisioning;
  final SipConfig? sipConfig;
  final CarrierMessagingConfig? carrierMessaging;
}

class AppConfigRepository {
  const AppConfigRepository(this._client);

  final AppClient _client;

  Future<AppConfigSnapshot> getConfig() async {
    final response = await _client.get<Map<String, dynamic>>(
      ApiEndpoints.appConfig,
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing app config response',
      );
    }

    final user = data['user'];
    final service = data['service'];
    final device = data['device'];
    final provisioning = data['provisioning'];
    final sip = data['sip'];
    if (user is! Map || service is! Map) {
      throw const ApiException(
        statusCode: null,
        message: 'Invalid app config response',
      );
    }

    return AppConfigSnapshot(
      user: CurrentUser.fromJson(Map<String, dynamic>.from(user)),
      service: ServiceAccount.fromJson(Map<String, dynamic>.from(service)),
      device: device is Map
          ? DeviceStatus.fromJson(Map<String, dynamic>.from(device))
          : const DeviceStatus(
              provisioningStatus: DeviceProvisioningStatus.unknown,
              sessionStatus: DeviceSessionStatus.unknown,
              revoked: false,
            ),
      provisioning: provisioning is Map
          ? ProvisioningReference.fromJson(
              Map<String, dynamic>.from(provisioning),
            )
          : const ProvisioningReference(
              status: DeviceProvisioningStatus.unknown,
            ),
      sipConfig: sip is Map
          ? SipConfig.fromJson(Map<String, dynamic>.from(sip))
          : null,
      carrierMessaging: _carrierMessagingFromResponse(data),
    );
  }
}

CarrierMessagingConfig? _carrierMessagingFromResponse(
  Map<String, dynamic> data,
) {
  final value =
      data['carrierMessaging'] ??
      data['carrier_messaging'] ??
      data['messaging'];
  if (value is Map) {
    return CarrierMessagingConfig.fromJson(Map<String, dynamic>.from(value));
  }
  return null;
}
