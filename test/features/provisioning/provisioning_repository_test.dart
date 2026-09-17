import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/config/app_config.dart';
import 'package:phone_app/core/errors/app_exception.dart';
import 'package:phone_app/core/network/app_client.dart';
import 'package:phone_app/features/provisioning/data/provisioning_repository.dart';
import 'package:phone_app/features/provisioning/domain/provisioning_activation_input.dart';
import 'package:phone_app/features/session/domain/device_info.dart';

void main() {
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
