import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/device_credential.dart';

final deviceCredentialRepositoryProvider = Provider(
  (ref) => DeviceCredentialRepository(),
);

class DeviceCredentialRepository {
  DeviceCredentialRepository({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<void> revoke(DeviceCredential credential) async {
    try {
      await _dio.deleteUri<void>(
        credential.revokeEndpoint,
        options: Options(
          headers: {'Authorization': 'Bearer ${credential.token}'},
        ),
      );
    } on DioException {
      // A local reset must still complete if the control plane is offline.
    }
  }
}
