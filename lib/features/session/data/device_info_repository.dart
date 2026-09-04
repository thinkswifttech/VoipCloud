import 'package:flutter/foundation.dart';

import '../../../core/network/api_endpoints.dart';
import '../../../core/network/app_client.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/device_info.dart';
import '../domain/device_status.dart';

class DeviceInfoRepository {
  const DeviceInfoRepository({
    required SecureStorageService storage,
    AppClient? client,
  }) : _storage = storage,
       _client = client;

  final SecureStorageService _storage;
  final AppClient? _client;

  Future<DeviceInfo> getDeviceInfo() async {
    var deviceId = await _storage.read(StorageKeys.appDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = 'device-${DateTime.now().microsecondsSinceEpoch}';
      await _storage.write(StorageKeys.appDeviceId, deviceId);
    }

    return DeviceInfo(
      deviceId: deviceId,
      platform: _platform(),
      appVersion: const String.fromEnvironment(
        'APP_VERSION',
        defaultValue: '1.0.0',
      ),
    );
  }

  Future<DeviceStatus?> registerDevice({String? sipIdentity}) async {
    final client = _client;
    if (client == null) {
      return null;
    }

    final device = await getDeviceInfo();
    final response = await client.post<Map<String, dynamic>>(
      ApiEndpoints.appDevice,
      data: {
        ...device.toJson(),
        if (sipIdentity != null && sipIdentity.isNotEmpty)
          'sipIdentity': sipIdentity,
      },
    );
    final data = response.data;
    return data == null ? null : DeviceStatus.fromJson(data);
  }

  Future<DeviceStatus?> getDeviceStatus() async {
    final client = _client;
    if (client == null) {
      return null;
    }
    final response = await client.get<Map<String, dynamic>>(
      ApiEndpoints.appDeviceStatus,
    );
    final data = response.data;
    return data == null ? null : DeviceStatus.fromJson(data);
  }

  Future<DeviceStatus?> revokeDevice() async {
    final client = _client;
    if (client == null) {
      return null;
    }
    final response = await client.post<Map<String, dynamic>>(
      ApiEndpoints.appDeviceRevoke,
    );
    final data = response.data;
    return data == null ? null : DeviceStatus.fromJson(data);
  }

  DevicePlatform _platform() {
    if (kIsWeb) {
      return DevicePlatform.web;
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => DevicePlatform.android,
      TargetPlatform.iOS => DevicePlatform.ios,
      TargetPlatform.windows => DevicePlatform.windows,
      TargetPlatform.macOS => DevicePlatform.macos,
      TargetPlatform.linux => DevicePlatform.linux,
      TargetPlatform.fuchsia => DevicePlatform.unknown,
    };
  }
}
