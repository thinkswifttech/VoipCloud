class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.platform,
    required this.appVersion,
  });

  final String deviceId;
  final DevicePlatform platform;
  final String appVersion;

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'platform': platform.name.toUpperCase(),
      'appVersion': appVersion,
    };
  }
}

enum DevicePlatform { android, ios, windows, macos, linux, web, unknown }

extension DevicePlatformCodec on DevicePlatform {
  static DevicePlatform parse(String value) {
    return switch (value.trim().toUpperCase()) {
      'ANDROID' => DevicePlatform.android,
      'IOS' => DevicePlatform.ios,
      'WINDOWS' => DevicePlatform.windows,
      'MACOS' => DevicePlatform.macos,
      'LINUX' => DevicePlatform.linux,
      'WEB' => DevicePlatform.web,
      _ => DevicePlatform.unknown,
    };
  }
}
