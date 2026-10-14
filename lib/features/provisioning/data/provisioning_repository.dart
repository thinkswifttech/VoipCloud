import 'dart:io';

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
        userMessage: 'Paste the setup link you were sent, or scan the QR code.',
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
          userMessage:
              "This setup link didn't return any phone settings. $_askForNewLink",
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
      throw await _describeSetupLinkFailure(
        error,
        provisioningUri,
        _internetReachable,
      );
    }
    final data = response.data;
    if (data == null || data.trim().isEmpty) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing SIP provisioning response',
        userMessage:
            "This setup link didn't return any phone settings. $_askForNewLink",
      );
    }
    try {
      return parseProvisionedConfiguration(
        data,
        provisioningUri,
        accountDomainOverride: _devAccountDomainOverride,
      );
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw ApiException(
        statusCode: null,
        message: 'Unreadable SIP provisioning response: $error',
        userMessage:
            "This setup link didn't return settings the app can read. "
            '$_askForNewLink',
      );
    }
  }

  String? get _devAccountDomainOverride {
    if (_config.environment == AppEnvironment.production) {
      return null;
    }
    final value = _config.devSipAccountDomain.trim();
    return value.isEmpty ? null : value;
  }
}

const _askForNewLink = 'Ask your administrator for a new QR code or link.';

Future<bool> _internetReachable() async {
  try {
    final result = await InternetAddress.lookup(
      'voipcloud.ca',
    ).timeout(const Duration(seconds: 4));
    return result.isNotEmpty;
  } on Object {
    return false;
  }
}

bool _isHostLookupFailure(DioException error) {
  final cause = error.error;
  if (cause is! SocketException) {
    return false;
  }
  final text = '${cause.message} ${cause.osError?.message ?? ''}'.toLowerCase();
  return text.contains('host lookup') ||
      text.contains('no address associated') ||
      text.contains('nodename nor servname') ||
      text.contains('no such host') ||
      text.contains('name or service not known') ||
      cause.osError?.errorCode == 11001;
}

/// Turns a failed setup-link request into a message a customer can act on.
Future<AppException> _describeSetupLinkFailure(
  DioException error,
  Uri link,
  Future<bool> Function() internetReachable,
) async {
  final mapped = ApiExceptionMapper.mapDioException(error);
  AppException failure(String userMessage) => ApiException(
    statusCode: error.response?.statusCode,
    message: mapped.message,
    code: mapped.code,
    details: mapped.details,
    userMessage: userMessage,
  );

  switch (error.type) {
    case DioExceptionType.badCertificate:
      return failure(
        "We couldn't make a secure connection. Check that your device's date "
        'and time are correct, then try again.',
      );
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.transformTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return failure(
        'The setup server is taking too long to answer. Check your internet '
        'connection and try again.',
      );
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
      if (_isHostLookupFailure(error)) {
        if (await internetReachable()) {
          return failure(
            "We couldn't find a server at ${link.host}. Check the link for "
            'typing mistakes, or scan the QR code instead.',
          );
        }
        return failure(
          "You're offline. Connect to Wi-Fi or mobile data and try again.",
        );
      }
      return failure(
        "We couldn't reach the setup server. Check your internet connection "
        'and try again.',
      );
    case DioExceptionType.cancel:
      return mapped;
    case DioExceptionType.badResponse:
      break;
  }

  final status = error.response?.statusCode;
  if (status == 410) {
    return failure(
      'This setup link has expired or reached its registration limit. '
      '$_askForNewLink',
    );
  }
  if (status == 404) {
    return failure(
      "This setup link isn't recognized. Check that you copied all of it, "
      'or scan the QR code instead. $_askForNewLink',
    );
  }
  if (status == 400 || status == 401 || status == 403) {
    return failure("This setup link can't be used. $_askForNewLink");
  }
  if (status == 429) {
    return failure('Too many attempts. Wait a minute and try again.');
  }
  if (status != null && status >= 500) {
    return failure(
      'The setup service is temporarily unavailable. Please try again in a '
      'few minutes.',
    );
  }
  return failure("We couldn't use this setup link. $_askForNewLink");
}

ApiException _provisioningExchangeException(ApiException error) {
  if (error.statusCode == 400) {
    return ApiException(
      statusCode: error.statusCode,
      message: error.message,
      code: error.code,
      details: error.details,
      userMessage: "This setup link can't be used. $_askForNewLink",
    );
  }
  return error;
}
