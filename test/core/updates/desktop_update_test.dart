import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phone_app/core/updates/desktop_update.dart';

void main() {
  final manifestUri = Uri.parse(
    'https://updates.example.test/desktop/stable.json',
  );

  test('reports a newer desktop build', () async {
    final service = DesktopUpdateService(
      manifestUri: manifestUri,
      dio: _manifestDio(_manifest(build: 24)),
      packageInfoLoader: () async => _packageInfo(build: 23),
      platform: DesktopUpdatePlatform.windowsX64,
    );

    final result = await service.check();

    expect(result.status, DesktopUpdateStatus.available);
    expect(result.release?.version, '1.0.1');
    expect(result.release?.build, 24);
  });

  test('reports the current build as up to date', () async {
    final service = DesktopUpdateService(
      manifestUri: manifestUri,
      dio: _manifestDio(_manifest(build: 23)),
      packageInfoLoader: () async => _packageInfo(build: 23),
      platform: DesktopUpdatePlatform.windowsX64,
    );

    final result = await service.check();

    expect(result.status, DesktopUpdateStatus.upToDate);
  });

  test('rejects a download on another host', () async {
    final manifest = _manifest(build: 24);
    final release =
        (manifest['releases'] as Map<String, dynamic>)['windows-x64']
            as Map<String, dynamic>;
    release['url'] = 'https://attacker.example/VoipCloud.msi';
    final service = DesktopUpdateService(
      manifestUri: manifestUri,
      dio: _manifestDio(manifest),
      packageInfoLoader: () async => _packageInfo(build: 23),
      platform: DesktopUpdatePlatform.windowsX64,
    );

    expect(service.check, throwsFormatException);
  });

  test('rejects a malformed checksum', () async {
    final manifest = _manifest(build: 24);
    final release =
        (manifest['releases'] as Map<String, dynamic>)['windows-x64']
            as Map<String, dynamic>;
    release['sha256'] = 'not-a-checksum';
    final service = DesktopUpdateService(
      manifestUri: manifestUri,
      dio: _manifestDio(manifest),
      packageInfoLoader: () async => _packageInfo(build: 23),
      platform: DesktopUpdatePlatform.windowsX64,
    );

    expect(service.check, throwsFormatException);
  });

  test('fails closed when no manifest is configured', () async {
    final result = await DesktopUpdateService(
      manifestUri: null,
      platform: DesktopUpdatePlatform.windowsX64,
    ).check();

    expect(result.status, DesktopUpdateStatus.notConfigured);
  });

  test('application update provider checks immediately when watched', () async {
    final container = ProviderContainer(
      overrides: [
        desktopUpdateServiceProvider.overrideWithValue(
          DesktopUpdateService(
            manifestUri: manifestUri,
            dio: _manifestDio(_manifest(build: 25)),
            packageInfoLoader: () async => _packageInfo(build: 24),
            platform: DesktopUpdatePlatform.windowsX64,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(desktopUpdateProvider.future);

    expect(result.status, DesktopUpdateStatus.available);
    expect(result.release?.build, 25);
  });
}

Dio _manifestDio(Map<String, dynamic> manifest) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: manifest,
          ),
        );
      },
    ),
  );
  return dio;
}

Map<String, dynamic> _manifest({required int build}) {
  return {
    'schema_version': 1,
    'channel': 'stable',
    'releases': {
      'windows-x64': {
        'version': '1.0.1',
        'build': build,
        'url':
            'https://updates.example.test/desktop/'
            'VoipCloud-1.0.1+$build-windows-x64.msi',
        'sha256': 'a' * 64,
        'release_notes': 'Reliability improvements.',
      },
    },
  };
}

PackageInfo _packageInfo({required int build}) {
  return PackageInfo(
    appName: 'VoipCloud',
    packageName: 'ca.voipcloud.phone',
    version: '1.0.0',
    buildNumber: '$build',
  );
}
