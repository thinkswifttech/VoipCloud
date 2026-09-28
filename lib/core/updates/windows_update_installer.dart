import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'desktop_update.dart';

/// Downloads a release without exposing an unverified MSI to the installer.
/// The native updater rechecks the digest after VoipCloud exits.
class WindowsUpdateInstaller {
  WindowsUpdateInstaller({
    Dio? dio,
    MethodChannel? channel,
    Directory? cacheDirectory,
    bool? isWindows,
  }) : _dio = dio ?? Dio(),
       _channel = channel ?? const MethodChannel('voipcloud/windows_update'),
       _cacheDirectory = cacheDirectory,
       _isWindows = isWindows ?? Platform.isWindows;

  static const int maximumInstallerBytes = 128 * 1024 * 1024;

  final Dio _dio;
  final MethodChannel _channel;
  final Directory? _cacheDirectory;
  final bool _isWindows;

  Future<void> install(
    DesktopRelease release, {
    void Function(double progress)? onProgress,
    Future<bool> Function()? canInstall,
  }) async {
    if (!_isWindows) {
      throw UnsupportedError('Automatic installation is Windows-only.');
    }

    final fileName =
        'VoipCloud-${release.version}+${release.build}-windows-x64.msi';
    if (release.downloadUri.pathSegments.last != fileName) {
      throw const FormatException('Unexpected Windows installer filename.');
    }

    final root =
        _cacheDirectory ??
        Directory(
          '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
          'ThinkSwift${Platform.pathSeparator}VoipCloud${Platform.pathSeparator}'
          'updates',
        );
    await root.create(recursive: true);
    final installer = File('${root.path}${Platform.pathSeparator}$fileName');
    final partial = File('${installer.path}.part');

    if (await installer.exists() &&
        await _hasExpectedDigest(installer, release.sha256)) {
      onProgress?.call(1);
    } else {
      if (await partial.exists()) await partial.delete();
      final cancelToken = CancelToken();
      try {
        await _dio.downloadUri(
          release.downloadUri,
          partial.path,
          cancelToken: cancelToken,
          options: Options(
            followRedirects: false,
            receiveTimeout: const Duration(seconds: 30),
            validateStatus: (status) => status == 200,
          ),
          onReceiveProgress: (received, total) {
            if (received > maximumInstallerBytes) {
              cancelToken.cancel('Installer exceeds the 128 MB limit.');
              return;
            }
            if (total > 0) {
              onProgress?.call((received / total).clamp(0, 1));
            }
          },
        );
        final size = await partial.length();
        if (size == 0 || size > maximumInstallerBytes) {
          throw const FormatException('Invalid installer size.');
        }
        if (!await _hasExpectedDigest(partial, release.sha256)) {
          throw const FormatException('Installer checksum did not match.');
        }
        if (await installer.exists()) await installer.delete();
        await partial.rename(installer.path);
        onProgress?.call(1);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }

    if (canInstall != null && !await canInstall()) {
      throw StateError('Finish the current call before installing an update.');
    }
    await _channel.invokeMethod<void>('install', {
      'path': installer.path,
      'sha256': release.sha256,
    });
  }

  Future<bool> _hasExpectedDigest(File file, String expected) async {
    if (!await file.exists()) return false;
    final size = await file.length();
    if (size == 0 || size > maximumInstallerBytes) return false;
    final actual = await sha256.bind(file.openRead()).first;
    return actual.toString().toLowerCase() == expected.toLowerCase();
  }
}
