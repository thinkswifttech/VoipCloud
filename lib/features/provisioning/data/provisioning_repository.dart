import 'package:dio/dio.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_environment.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception_mapper.dart';
import '../../../core/network/app_client.dart';
import '../../session/domain/app_session.dart';
import '../../session/domain/device_info.dart';
import '../../session/domain/device_status.dart';
import 'linphone_provisioning_parser.dart';
import '../domain/provisioning_activation_input.dart';

class ProvisioningRepository {
  const ProvisioningRepository(
    this._client,
    this._config, {
    Dio? provisioningDio,
  }) : _provisioningDio = provisioningDio;

  final AppClient _client;
  final AppConfig _config;
  final Dio? _provisioningDio;

  Future<AppSession> activate({
    required ProvisioningInput input,
    required DeviceInfo device,
  }) async {
    if (!input.hasUsableValue) {
      throw const AppException(
        message: 'Missing provisioning token',
        userMessage: 'Enter a provisioning token or Softphone activation link.',
      );
    }

    final provisioned = input.provisioningUri == null
        ? null
        : await _fetchConfiguration(input.provisioningUri!, device);
    final sipConfig = provisioned?.sipConfig;
    final backendToken = input.backendToken;
    if (backendToken == null || backendToken.isEmpty) {
      if (sipConfig == null) {
        throw const AppException(
          message: 'Missing provisioning result',
          userMessage: 'This activation link did not return SIP configuration.',
        );
      }
      return AppSession.localSip(
        sipConfig: sipConfig,
        directoryAccess: provisioned?.directoryAccess,
        deviceCredential: provisioned?.deviceCredential,
        carrierMessaging: provisioned?.carrierMessaging,
        device: DeviceStatus(
          deviceId: device.deviceId,
          platform: device.platform,
          appVersion: device.appVersion,
          sipIdentity: sipConfig.sipIdentity,
          provisioningStatus: DeviceProvisioningStatus.provisioned,
          sessionStatus: DeviceSessionStatus.active,
          revoked: false,
        ),
      );
    }
    final session = await _exchange(token: backendToken, device: device);

    return session.copyWith(
      sipConfig: sipConfig ?? session.sipConfig,
      directoryAccess: provisioned?.directoryAccess ?? session.directoryAccess,
      deviceCredential:
          provisioned?.deviceCredential ?? session.deviceCredential,
      carrierMessaging:
          provisioned?.carrierMessaging ?? session.carrierMessaging,
      device: session.device.copyWithSipIdentity(
        sipConfig?.sipIdentity ?? session.device.sipIdentity,
      ),
    );
  }

  Future<AppSession> _exchange({
    required String token,
    required DeviceInfo device,
  }) async {
    final normalized = token.trim();
    final Response<Map<String, dynamic>> response;
    try {
      response = await _client.post<Map<String, dynamic>>(
        ApiEndpoints.provisioningExchange,
        data: {'token': normalized, 'device': device.toJson()},
      );
    } on ApiException catch (error) {
      throw _provisioningExchangeException(error);
    }
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing provisioning response',
      );
    }
    return AppSession.fromExchangeJson(data);
  }

  Future<ProvisionedConfiguration> _fetchConfiguration(
    Uri provisioningUri,
    DeviceInfo device,
  ) async {
    final dio = _provisioningDio ?? Dio();
    final Response<String> response;
    try {
      response = await dio.getUri<String>(
        provisioningUri,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            Headers.acceptHeader: 'application/xml, text/xml, application/json',
            'x-linphone-provisioning': 'true',
            'x-voipcloud-device-id': device.deviceId,
          },
        ),
      );
    } on DioException catch (error) {
      throw _sipProvisioningException(
        ApiExceptionMapper.mapDioException(error),
      );
    }
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing SIP provisioning response',
      );
    }
    return parseProvisionedConfiguration(
      data,
      provisioningUri,
      accountDomainOverride: _devAccountDomainOverride,
    );
  }

  String? get _devAccountDomainOverride {
    if (_config.environment == AppEnvironment.production) {
      return null;
    }
    final value = _config.devSipAccountDomain.trim();
    return value.isEmpty ? null : value;
  }
}

AppException _sipProvisioningException(AppException error) {
  if (error is ApiException && error.statusCode == 410) {
    return ApiException(
      statusCode: error.statusCode,
      message: error.message,
      code: error.code,
      details: error.details,
      userMessage:
          'This activation link has expired or reached its registration limit. Request a new QR code or ask an administrator to allow unlimited registrations.',
    );
  }
  if (error is ApiException && error.statusCode == 400) {
    return ApiException(
      statusCode: error.statusCode,
      message: error.message,
      code: error.code,
      details: error.details,
      userMessage:
          'The SIP provisioning server rejected this activation link. Request a new QR code or link.',
    );
  }
  return error;
}

ApiException _provisioningExchangeException(ApiException error) {
  if (error.statusCode == 400) {
    return ApiException(
      statusCode: error.statusCode,
      message: error.message,
      code: error.code,
      details: error.details,
      userMessage:
          'The app backend rejected this activation token. Request a new QR code or link.',
    );
  }
  return error;
}
