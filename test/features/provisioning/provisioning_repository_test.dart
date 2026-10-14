import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/app_config.dart';
import 'package:phone_app/core/errors/app_exception.dart';
import 'package:phone_app/core/network/app_client.dart';
import 'package:phone_app/features/provisioning/data/provisioning_repository.dart';
import 'package:phone_app/features/provisioning/domain/provisioning_activation_input.dart';
import 'package:phone_app/features/session/domain/device_info.dart';

Future<Object?> _activateWithFailure(
  DioException Function(RequestOptions) make,
) {
  final provisioningDio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(make(options)),
      ),
    );
  final repository = ProvisioningRepository(
    AppClient(Dio()),
    AppConfig.fromMap(const {'APP_ENV': 'production'}),
    provisioningDio: provisioningDio,
  );
  return repository
      .activate(
        input: ProvisioningInput(
          rawValue: 'https://sip.example.test/provisioning/token',
          provisioningUri: Uri.https('sip.example.test', '/provisioning/token'),
        ),
        device: const DeviceInfo(
          deviceId: 'test-device',
          platform: DevicePlatform.windows,
          appVersion: '1.0.0',
        ),
      )
      .then<Object?>((_) => null, onError: (Object e) => e);
}

DioException _status(RequestOptions options, int code) => DioException(
  requestOptions: options,
  type: DioExceptionType.badResponse,
  response: Response<String>(
    requestOptions: options,
    statusCode: code,
    data: 'x',
  ),
);

void main() {
  test('gives plain, actionable messages for setup link failures', () async {
    Future<String> message(DioException Function(RequestOptions) make) async {
      final error = await _activateWithFailure(make);
      return (error! as AppException).userMessage;
    }

    expect(await message((o) => _status(o, 404)), contains("isn't recognized"));
    expect(await message((o) => _status(o, 403)), contains("can't be used"));
    expect(
      await message((o) => _status(o, 429)),
      contains('Too many attempts'),
    );
    expect(
      await message((o) => _status(o, 503)),
      contains('temporarily unavailable'),
    );
    expect(
      await message(
        (o) => DioException(
          requestOptions: o,
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      contains('taking too long'),
    );
    expect(
      await message(
        (o) => DioException(
          requestOptions: o,
          type: DioExceptionType.badCertificate,
        ),
      ),
      contains('date and time'),
    );
    final offlineOrTypo = await message(
      (o) => DioException(
        requestOptions: o,
        type: DioExceptionType.connectionError,
        error: const SocketException('Failed host lookup: sip.example.test'),
      ),
    );
    expect(
      offlineOrTypo,
      anyOf(contains("You're offline"), contains('sip.example.test')),
    );
  });

  test('explains an exhausted SIP provisioning link', () async {
    final provisioningDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<String>(
                  requestOptions: options,
                  statusCode: 410,
                  data: 'Provisioning registration limit reached',
                ),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
    final repository = ProvisioningRepository(
      AppClient(Dio()),
      AppConfig.fromMap(const {'APP_ENV': 'production'}),
      provisioningDio: provisioningDio,
    );

    await expectLater(
      repository.activate(
        input: ProvisioningInput(
          rawValue: 'https://sip.example.test/provisioning/token',
          provisioningUri: Uri.https('sip.example.test', '/provisioning/token'),
        ),
        device: const DeviceInfo(
          deviceId: 'test-device',
          platform: DevicePlatform.windows,
          appVersion: '1.0.0',
        ),
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.userMessage,
          'userMessage',
          contains('registration limit'),
        ),
      ),
    );
  });
}
